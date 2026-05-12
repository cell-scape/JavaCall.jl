# JNI edge for JProxies callbacks: the @cfunction Java calls into, RegisterNatives
# wiring, and Object[] argument / result marshalling.
#
# Threading note: in the supported single-threaded configuration the Java→native
# call (`invokeNative`) lands on the same OS thread that issued the outer `jcall`,
# i.e. the JavaCall dispatch / main thread. The native function nevertheless
# hands the actual Julia handler invocation to the dispatch task (via a `Callback`
# `DispatchMsg`) and blocks on the result box; the dispatch task is pinned to the
# same OS thread, so all JNI local references stay valid for the whole upcall.

struct JProxiesError <: Exception
    msg::String
end
Base.showerror(io::IO, e::JProxiesError) = print(io, "JProxiesError: ", e.msg)

# --- handler registry: handler_id -> (julia_value, julia_type) ----------------
const _proxy_registry = Dict{Int64, Tuple{Any, DataType}}()
const _proxy_registry_lock = ReentrantLock()
const _next_handler_id = Ref{Int64}(1)

function _register_handler!(value)
    lock(_proxy_registry_lock) do
        id = _next_handler_id[]
        _next_handler_id[] += 1
        _proxy_registry[id] = (value, typeof(value))
        return id
    end
end

_unregister_handler!(id::Int64) = lock(_proxy_registry_lock) do
    delete!(_proxy_registry, id)
    return nothing
end

# (julia_type, :methodName) -> handler function(self, args...)
const _proxy_method_table = Dict{Tuple{DataType, Symbol}, Any}()

# --- marshalling helpers ------------------------------------------------------

function _jstring_to_julia(penv, jstr)
    jstr == C_NULL && return ""
    chars = JNI.GetStringUTFChars(jstr, Ptr{JNI.jboolean}(C_NULL), penv)
    s = Base.unsafe_string(chars)
    JNI.ReleaseStringUTFChars(jstr, chars, penv)
    return s
end

# Object[] -> Vector{Any}. Boxed primitives & Strings come back as Julia values
# (so handlers can do arithmetic / string ops directly); other objects come back
# as narrowed JavaObjects. Null elements -> `nothing`.
function _unmarshal_object_array(penv, jarr)
    jarr == C_NULL && return Any[]
    n = Int(JNI.GetArrayLength(jarr, penv))
    out = Vector{Any}(undef, n)
    for i in 0:(n - 1)
        elt = JNI.GetObjectArrayElement(jarr, i, penv)
        out[i + 1] = _wrap_arg(elt)
    end
    return out
end

function _wrap_arg(ptr)
    ptr == C_NULL && return nothing
    obj = JavaObject{Symbol("java.lang.Object")}(JavaLocalRef(ptr))
    return _juliafy(narrow(obj))
end

# Julia result -> jobject pointer. `nothing` -> NULL; JavaObject -> its ref;
# String -> Java String; Bool/Integer/AbstractFloat -> boxed java.lang.X.
function _marshal_result(penv, result)
    result === nothing && return Ptr{Cvoid}(C_NULL)
    if result isa JavaObject
        return Ptr{Cvoid}(JavaCall.Ptr(result))
    end
    boxed = if result isa AbstractString
        convert(JString, String(result))
    elseif result isa Bool
        convert(JavaObject{Symbol("java.lang.Boolean")}, result)
    elseif result isa Integer
        # widest sensible box; callers wanting a narrower box should return one
        if result isa Union{Int8, Int16, Int32} || (typemin(Int32) <= result <= typemax(Int32))
            convert(JavaObject{Symbol("java.lang.Integer")}, result)
        else
            convert(JavaObject{Symbol("java.lang.Long")}, result)
        end
    elseif result isa AbstractFloat
        convert(JavaObject{Symbol("java.lang.Double")}, result)
    elseif result isa Char
        convert(JavaObject{Symbol("java.lang.Character")}, result)
    else
        throw(JProxiesError("cannot marshal callback result of type $(typeof(result))"))
    end
    return Ptr{Cvoid}(JavaCall.Ptr(boxed))
end

function _throw_to_java(penv, msg::AbstractString)
    cls = JNI.FindClass("java/lang/RuntimeException", penv)
    if cls != C_NULL
        JNI.ThrowNew(cls, String(msg), penv)
    end
    return Ptr{Cvoid}(C_NULL)
end

# --- the native function bound to JavaCallInvocationHandler.invokeNative -------
# static native Object invokeNative(long id, String name, Object[] args)
#   => (JNIEnv*, jclass, jlong, jstring, jobjectArray) -> jobject
function _proxy_invoke_native(penv::Ptr{JNI.JNIEnv}, _jclass::Ptr{Cvoid},
                              handler_id::Int64, jname::Ptr{Cvoid},
                              jargs::Ptr{Cvoid})::Ptr{Cvoid}
    try
        name = _jstring_to_julia(penv, jname)
        entry = lock(_proxy_registry_lock) do
            get(_proxy_registry, handler_id, nothing)
        end
        entry === nothing && return _throw_to_java(penv, "no Julia handler registered for id $handler_id")
        value, vtype = entry
        fn = get(_proxy_method_table, (vtype, Symbol(name)), nothing)
        fn === nothing && return _throw_to_java(penv, "$(vtype) does not implement $(name)")

        julia_args = _unmarshal_object_array(penv, jargs)

        box = Channel{Any}(1)
        thunk = let fn = fn, value = value, julia_args = julia_args
            () -> fn(value, julia_args...)
        end
        push!(JavaCall._dispatch_channel, JavaCall.Callback(thunk, (), box))
        result = take!(box)
        result isa Exception && return _throw_to_java(penv, sprint(showerror, result))
        return _marshal_result(penv, result)
    catch err
        # A Julia exception must never unwind into the JVM.
        return _throw_to_java(penv, "JProxies callback failed: $(sprint(showerror, err))")
    end
end

# --- one-time native registration --------------------------------------------
const _native_registered = Ref(false)
const _REGISTERED_KEEPALIVE = Any[]   # keep cfunction + cstring buffers rooted

function _ensure_native_registered()
    _native_registered[] && return nothing
    JavaCall.assertloaded()
    env = JavaCall.with_env() do e; e; end
    handlercls = JNI.FindClass("org/juliainterop/JavaCallInvocationHandler", env)
    handlercls == C_NULL && throw(JProxiesError(
        "org.juliainterop.JavaCallInvocationHandler not found on the classpath — " *
        "make sure `using JProxies` (which runs JProxies.__init__) happens before `JavaCall.init()`"))

    cfn = @cfunction(_proxy_invoke_native, Ptr{Cvoid},
                     (Ptr{JNI.JNIEnv}, Ptr{Cvoid}, Int64, Ptr{Cvoid}, Ptr{Cvoid}))

    name_buf = Vector{UInt8}(codeunits("invokeNative")); push!(name_buf, 0x00)
    sig_buf  = Vector{UInt8}(codeunits("(JLjava/lang/String;[Ljava/lang/Object;)Ljava/lang/Object;")); push!(sig_buf, 0x00)
    # C `JNINativeMethod { char* name; char* signature; void* fnPtr; }`
    method_struct = Ptr{Cvoid}[ pointer(name_buf), pointer(sig_buf), Base.unsafe_convert(Ptr{Cvoid}, cfn) ]

    push!(_REGISTERED_KEEPALIVE, cfn)
    push!(_REGISTERED_KEEPALIVE, name_buf)
    push!(_REGISTERED_KEEPALIVE, sig_buf)

    rc = GC.@preserve cfn name_buf sig_buf method_struct begin
        JNI.RegisterNatives(handlercls, method_struct, jint(1), env)
    end
    JavaCall.geterror(env)
    rc == 0 || throw(JProxiesError("RegisterNatives failed for JavaCallInvocationHandler.invokeNative (rc=$rc)"))
    _native_registered[] = true
    return nothing
end
