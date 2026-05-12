# JNI edge for JProxies callbacks: the @cfunction Java calls into, RegisterNatives
# wiring, and Object[] argument / result marshalling.
#
# Threading note: in the supported single-threaded configuration the Java→native
# call (`invokeNative`) lands on the same OS thread that issued the outer `jcall`.
# `_proxy_invoke_native` does its JNI work (arg unmarshalling, result boxing)
# *itself*, on that thread, inside the native-method frame — that is the only
# place JNI calls are valid here: the dispatch task runs on the *same* OS thread
# while the native frame is parked, and re-entering the JVM from a parked-upcall
# thread (whose C stack has been swapped to the dispatch task's stack) corrupts
# the JVM's per-thread state. So the dispatch task only ever runs *pure Julia*
# handler code; it never touches JNI.
#
# Lifetime rule (the bug fixed in phase-2c/jproxy-callbacks-fixup): a JNI *local*
# ref created inside a native method is freed by the JVM when that method returns.
# Wrapping such a ref in a JavaCall `JavaObject` (whose finalizer later calls
# `DeleteLocalRef`) is a time bomb — Julia GC may finalize the wrapper long after
# the native frame is gone, so the `DeleteLocalRef` hits a recycled / invalid
# slot → intermittent SIGSEGV in libjvm. Therefore `_proxy_invoke_native` must
# not let any local-ref-backed `JavaObject` escape: incoming `Object[]` elements
# are either unboxed to plain Julia values (no ref) or promoted to JNI *global*
# refs (a `JavaGlobalRef` finalizer's `DeleteGlobalRef` is valid from any thread
# at any time), and the result `JavaObject`s `_marshal_result` builds have their
# ref detached before return so their finalizers become no-ops.

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

# --- cached box-type handles --------------------------------------------------
# Global class refs + method IDs for the wrapper types, looked up once at native
# registration. Used to unbox `Object[]` callback arguments without ever creating
# a transient local-ref `JavaObject` inside the native-method frame. Method IDs
# are stable for the JVM's lifetime; the class refs are *global* refs (kept alive
# here for the process lifetime).
mutable struct _BoxCache
    String::Ptr{Cvoid}      # java.lang.String  (global ref)
    Boolean::Ptr{Cvoid}     # java.lang.Boolean (global ref)
    Character::Ptr{Cvoid}   # java.lang.Character
    Long::Ptr{Cvoid}        # java.lang.Long
    Double::Ptr{Cvoid}      # java.lang.Double
    Float::Ptr{Cvoid}       # java.lang.Float
    Number::Ptr{Cvoid}      # java.lang.Number
    m_booleanValue::Ptr{Cvoid}
    m_charValue::Ptr{Cvoid}
    m_longValue::Ptr{Cvoid}
    m_doubleValue::Ptr{Cvoid}
    m_intValue::Ptr{Cvoid}
    _BoxCache() = new(ntuple(_ -> Ptr{Cvoid}(C_NULL), 12)...)
end
const _box_cache = _BoxCache()

function _gref_class(env, name::String)
    c = JNI.FindClass(name, env)
    c == C_NULL && throw(JProxiesError("FindClass($name) failed during JProxies native registration"))
    g = JNI.NewGlobalRef(c, env)
    g == C_NULL && throw(JProxiesError("NewGlobalRef($name) failed during JProxies native registration"))
    JNI.DeleteLocalRef(c, env)   # the local ref is created on the registration thread; drop it now
    return g
end

function _getmethodid(env, cls::Ptr{Cvoid}, name::String, sig::String, what::String)
    m = JNI.GetMethodID(cls, name, sig, env)
    m == C_NULL && error("JProxies: failed to resolve $what for the callback box cache")
    return m
end

function _init_box_cache!(env)
    _box_cache.String    = _gref_class(env, "java/lang/String")
    _box_cache.Boolean   = _gref_class(env, "java/lang/Boolean")
    _box_cache.Character = _gref_class(env, "java/lang/Character")
    _box_cache.Long      = _gref_class(env, "java/lang/Long")
    _box_cache.Double    = _gref_class(env, "java/lang/Double")
    _box_cache.Float     = _gref_class(env, "java/lang/Float")
    _box_cache.Number    = _gref_class(env, "java/lang/Number")
    _box_cache.m_booleanValue = _getmethodid(env, _box_cache.Boolean,   "booleanValue", "()Z", "Boolean.booleanValue()")
    _box_cache.m_charValue    = _getmethodid(env, _box_cache.Character,  "charValue",    "()C", "Character.charValue()")
    _box_cache.m_longValue    = _getmethodid(env, _box_cache.Number,     "longValue",    "()J", "Number.longValue()")
    _box_cache.m_doubleValue  = _getmethodid(env, _box_cache.Number,     "doubleValue",  "()D", "Number.doubleValue()")
    _box_cache.m_intValue     = _getmethodid(env, _box_cache.Number,     "intValue",     "()I", "Number.intValue()")
    return nothing
end

# --- marshalling helpers ------------------------------------------------------

function _jstring_to_julia(penv, jstr)
    jstr == C_NULL && return ""
    chars = JNI.GetStringUTFChars(jstr, Ptr{JNI.jboolean}(C_NULL), penv)
    s = Base.unsafe_string(chars)
    JNI.ReleaseStringUTFChars(jstr, chars, penv)
    return s
end

const _NOEMPTY_JVALUES = JNI.JValue[]

# Object[] -> Vector{Any}. Each element comes in as a raw JNI *local* ref scoped
# to the native-method frame. We never wrap one in a long-lived JavaObject:
# boxed primitives & Strings are unboxed to plain Julia values right here (on the
# Java callback thread, a valid native-method context), other objects are
# promoted to a JNI *global* ref and handed back as a `java.lang.Object` wrapper
# (safe to outlive the upcall). Null elements -> `nothing`.
function _unmarshal_object_array(penv, jarr)
    jarr == C_NULL && return Any[]
    n = Int(JNI.GetArrayLength(jarr, penv))
    out = Vector{Any}(undef, n)
    for i in 0:(n - 1)
        elt = JNI.GetObjectArrayElement(jarr, i, penv)
        out[i + 1] = _wrap_arg(penv, elt)
        # `elt` is a local ref scoped to this native frame; once `_wrap_arg` has
        # either copied out a Julia value or made a global ref, drop the local.
        elt != C_NULL && JNI.DeleteLocalRef(elt, penv)
    end
    return out
end

# Convert one `Object[]` element ref to either a plain Julia value (for boxed
# primitives / Strings) or a global-ref-backed `JavaObject{java.lang.Object}`.
# Pure JNI; creates no local-ref-backed JavaObject.
function _wrap_arg(penv, ptr)
    ptr == C_NULL && return nothing
    c = _box_cache
    if JNI.IsInstanceOf(ptr, c.String, penv) != 0
        return _jstring_to_julia(penv, ptr)
    elseif JNI.IsInstanceOf(ptr, c.Boolean, penv) != 0
        return JNI.CallBooleanMethodA(ptr, c.m_booleanValue, _NOEMPTY_JVALUES, penv) != 0
    elseif JNI.IsInstanceOf(ptr, c.Character, penv) != 0
        return Char(JNI.CallCharMethodA(ptr, c.m_charValue, _NOEMPTY_JVALUES, penv))
    elseif JNI.IsInstanceOf(ptr, c.Number, penv) != 0
        if JNI.IsInstanceOf(ptr, c.Double, penv) != 0 ||
           JNI.IsInstanceOf(ptr, c.Float, penv) != 0
            return Float64(JNI.CallDoubleMethodA(ptr, c.m_doubleValue, _NOEMPTY_JVALUES, penv))
        elseif JNI.IsInstanceOf(ptr, c.Long, penv) != 0
            return Int64(JNI.CallLongMethodA(ptr, c.m_longValue, _NOEMPTY_JVALUES, penv))
        else  # Integer / Short / Byte
            return Int32(JNI.CallIntMethodA(ptr, c.m_intValue, _NOEMPTY_JVALUES, penv))
        end
    else
        # Arbitrary object: hand back a global ref so it survives this native
        # frame. Callbacks needing to introspect it must do so off the upcall
        # (e.g. by returning it); JNI on the dispatch task during the upcall is
        # unsafe (see the threading note above).
        return JavaObject{Symbol("java.lang.Object")}(JavaGlobalRef(JNI.NewGlobalRef(ptr, penv)))
    end
end

# Detach `obj`'s JNI ref and return the raw pointer. The native method hands the
# pointer to the JVM, which owns it for the duration of the native frame; the
# `JavaObject`'s finalizer must therefore NOT also try to free it later.
function _detach_ref!(obj::JavaObject)
    p = JavaCall.Ptr(obj)
    obj.ref = JavaCall.J_NULL
    return Ptr{Cvoid}(p)
end

# Julia result -> jobject pointer. `nothing` -> NULL; JavaObject -> its ref;
# String -> Java String; Bool/Integer/AbstractFloat -> boxed java.lang.X.
"""
    _marshal_result(penv, result) -> Ptr{Cvoid}

Convert a Julia callback return value into the `jobject` pointer the native method
hands back to the JVM. `nothing` → NULL; an existing `JavaObject`/`JProxyRef` →
its (borrowed, not detached) ref; `String`/`Bool`/`Integer`/`AbstractFloat`/`Char`
→ a freshly-boxed `java.lang.X` whose ref is *detached* so its finalizer won't
double-free the pointer the native frame now owns. Unsupported types → `JProxiesError`.
"""
function _marshal_result(penv, result)
    result === nothing && return Ptr{Cvoid}(C_NULL)
    if result isa JProxyRef
        # A callback returning another proxy (e.g. a Comparator-like method that
        # yields a Function-like callback). The `JProxyRef` owns the ref and
        # outlives this native frame, so the JVM may borrow the raw pointer
        # without us detaching it.
        return Ptr{Cvoid}(JavaCall.Ptr(result.obj))
    end
    if result isa JavaObject
        # Pre-existing handler-owned object; its ref stays owned by the handler
        # (the JVM only borrows the pointer for the native-frame's lifetime).
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
    # `boxed` is a freshly-allocated JavaObject local to this function; detach so
    # its finalizer can't later DeleteLocalRef a ref the JVM/native frame owns.
    return _detach_ref!(boxed)
end

function _throw_to_java(penv, msg::AbstractString)
    # `cls` is a raw local ref (not wrapped in a JavaObject), so it has no
    # finalizer; the JVM frees it when this native method returns. No explicit
    # DeleteLocalRef — that would run with the just-set exception pending.
    cls = JNI.FindClass("java/lang/RuntimeException", penv)
    cls != C_NULL && JNI.ThrowNew(cls, String(msg), penv)
    return Ptr{Cvoid}(C_NULL)
end

# --- the native function bound to JavaCallInvocationHandler.invokeNative -------
# static native Object invokeNative(long id, String name, Object[] args)
#   => (JNIEnv*, jclass, jlong, jstring, jobjectArray) -> jobject
"""
    _proxy_invoke_native(penv, jclass, handler_id, jname, jargs) -> Ptr{Cvoid}

The `@cfunction` registered as `JavaCallInvocationHandler.invokeNative`. Looks up
the Julia handler for `handler_id`/`jname`, unmarshals the `Object[]` args *on this
(native-frame) thread* — the only safe place for JNI here — posts the pure-Julia
handler call to JavaCall's dispatch task, waits for the result, and marshals it
back. Any Julia exception (or a missing handler/dispatch task) is converted to a
Java `RuntimeException` rather than unwinding into the JVM.
"""
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

        # All JNI work (unmarshalling here, boxing in `_marshal_result`) happens
        # on *this* thread, inside the native-method frame — the only safe place
        # (see the threading note at the top of this file). `julia_args` are
        # plain Julia values and/or global-ref `JavaObject`s; no local-ref
        # JavaObject escapes.
        julia_args = _unmarshal_object_array(penv, jargs)

        if !(isassigned(JavaCall._dispatch_task) && !istaskdone(JavaCall._dispatch_task[]))
            return _throw_to_java(penv, "JavaCall dispatch task is not running; cannot service the callback")
        end

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

"""
    _ensure_native_registered()

Idempotently wire `_proxy_invoke_native` into the JVM: on first call (under the
registry lock, double-checked) `RegisterNatives` binds it to
`org.juliainterop.JavaCallInvocationHandler.invokeNative`, the `@cfunction` and its
name/signature C-string buffers are rooted for the process lifetime, and the
box-type class/method cache is populated. Throws `JProxiesError` if the handler
class isn't on the classpath (i.e. `using JProxies` ran after `JavaCall.init()`).
"""
function _ensure_native_registered()
    _native_registered[] && return nothing   # fast path: already registered
    lock(_proxy_registry_lock) do
        _native_registered[] && return nothing   # double-checked under the lock
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
        JNI.DeleteLocalRef(handlercls, env)
        _init_box_cache!(env)
        _native_registered[] = true
        return nothing
    end
end
