"""
    JavaRef is abstract parent for JavaLocalRef, JavaGlobalRef, and JavaNullRef in the JavaCall Module

    It is distinct from its parent type, JavaCall.JNI.AbstractJavaRef, since its use is defined in 
    JavaCall itself rather than the JNI submodule.
"""
abstract type JavaRef <: JNI.AbstractJavaRef end

"""
    JavaLocalRef is a JavaRef that is meant to be used with local variables in a function call.
    After the function call these references may be freed and garbage collected. See note about
    JNI memory management below.

    This is the default reference type returned from the JNI.

    Use this with JNI.PushLocalFrame / JNI.PopLocalFrame for memory management.
    Also see JNI.EnsureLocalCapacity.

    The internal pointer should be deleted using JNI.DeleteLocalRef
"""
struct JavaLocalRef <: JavaRef
    ptr::Ptr{Nothing}
end

"""
    JavaGlobalRef is a JavaRef that is meant to be used with global variables that live beyond 
    a single function call.
"""
struct JavaGlobalRef <: JavaRef
    ptr::Ptr{Nothing}
end

"""
    JavaNullRef is a JavaRef that serves as a placeholder to mark where references have already been deleted.

    See J_NULL
"""
struct JavaNullRef <: JavaRef
    ptr::Ptr{Nothing}
    JavaNullRef() = new(C_NULL)
end

""" Constant JavaNullRef """
const J_NULL = JavaNullRef()

Ptr(ref::JavaRef) = ref.ptr
Ptr{Nothing}(ref::JavaRef) = ref.ptr

JavaLocalRef(ref::JavaRef) = with_env() do env; JavaLocalRef(JNI.NewLocalRef(Ptr(ref), env)); end
JavaGlobalRef(ref::JavaRef) = with_env() do env; JavaGlobalRef(JNI.NewGlobalRef(Ptr(ref), env)); end

"""
    deleteref deletes a JavaRef using either JNI.DeleteLocalRef or JNI.DeleteGlobalRef
"""
function deleteref(x::JavaRef)
    x.ptr == C_NULL && return
    JNI.is_env_loaded() || return
    # Synchronous deletion via with_env — the calling OS thread gets
    # attached on demand if it isn't already. The original Phase 2 spec
    # called for routing finalizer-driven deletion through the dispatch
    # task, but the resulting async cleanup couldn't keep up with
    # synchronous-allocation throughput in tight loops (the JVM heap
    # ran out before the dispatch task drained DeleteRef messages).
    # Daemon-attaching every Julia OS thread that runs a finalizer is
    # acceptable: the thread count is bounded by JULIA_NUM_THREADS, the
    # attachment is daemon (so it doesn't block VM shutdown), and the
    # JVM's per-thread bookkeeping is O(1) per attached thread.
    # The dispatch task remains for Phase 2C callbacks.
    with_env() do env
        if x isa JavaLocalRef
            JNI.DeleteLocalRef(x.ptr, env)
        elseif x isa JavaGlobalRef
            JNI.DeleteGlobalRef(x.ptr, env)
        end
    end
    return
end

"""
    jlocalframe(f, [returntype]; [capacity = 16])
    
    Manages java local references by using JNI's PushLocalFrame and PopLocalFrame.
    Only the local reference returned by f will be valid. Other local references
    will be freed and available for garbage collection.

    Specifying a `returntype` will allow for type stability. If `returntype` is
    specified and is not `Nothing` or `Any`, it will also be passed to the function.

    Capacity specifies the minimum number of local references that can be
    created. See the [JNI documentation](
    https://docs.oracle.com/en/java/javase/15/docs/specs/jni/functions.html#pushlocalframe
    )
    for further information.

    # Example
    ```
    julia> jlocalframe() do
               a = JObject() # Local reference created, will be GCed
               println(a)
               b = JObject() # Local reference returned
               println(b)
               b
           end

    julia> jlocalframe(JObject) do T # Specify returntype for type stability
               a = T()
               println(a)
               b = T()
               println(b)
               b
           end
    
    julia> jlocalframe(Nothing) do # Specify Nothing if you do want to return anything
               a = JObject()
               println(a)
           end
    ```
"""
function jlocalframe(f::Function, returntype::Type = Any; capacity = 16)
    with_env() do env
        JNI.PushLocalFrame(jint(capacity), env)
        result_ref = C_NULL
        return_ref = JavaLocalRef(result_ref)
        result = nothing
        # Holds a strong reference to the original f() return value so that, if
        # it is a JavaObject, its finalizer cannot fire (and thus DeleteLocalRef
        # cannot run) between when we extract its raw pointer and when
        # PopLocalFrame consumes it below.
        result_keep = nothing
        try
            if returntype == Any
                result = f()
            else
                result = f(returntype)
            end
            result_keep = result
            if isa(result, JavaObject)
                result = Ptr{Nothing}(result)
            end
            if isa(result, Ptr{Nothing}) &&
               JNI.GetObjectRefType(result, env) == JNI.JNILocalRefType
                result_ref = result
            end
        catch err
            rethrow(err)
        finally
            GC.@preserve result_keep begin
                return_ref = JavaLocalRef( JNI.PopLocalFrame(result_ref, env) )
            end
        end

        # Return
        if returntype == Any # Not Type Stable
            if !isnull(return_ref.ptr)
                return narrow( JObject(return_ref) )
            else
                return result
            end
        elseif returntype <: JavaObject
            return returntype(return_ref)
        else
            return result::returntype
        end
    end
end

# Closer to https://github.com/ahnlabb/BioformatsLoader.jl/commit/4d4e2d5decd87c8bfd2bfca2fdfbc4214b120977
function jlocalframe(f::Function, returntype::Type{Nothing}; capacity = 16)
    with_env() do env
        JNI.PushLocalFrame(jint(capacity), env)
        try
            f()
        catch err
            rethrow(err)
        finally
            JNI.PopLocalFrame(C_NULL, env)
        end
        return nothing
    end
end

"""
    JavaMetaClass represents meta information about a Java class

    These are usually cached in _jmc_cache and are meant to live
    as long as the cache is valid.
"""
struct JavaMetaClass{T} <: JNI.AbstractJavaRef
    ref::JavaRef
end

#The metaclass, sort of equivalent to a the
JavaMetaClass(T, ref::JavaRef) = JavaMetaClass{T}(ref)
JavaMetaClass(T, ptr::Ptr{Nothing}) = JavaMetaClass{T}(JavaGlobalRef(ptr))

ref(mc::JavaMetaClass{T}) where T = mc.ref
Ptr(mc::JavaMetaClass{T}) where T = Ptr(mc.ref)
Ptr{Nothing}(mc::JavaMetaClass{T}) where T = Ptr(mc.ref)

"""
    JavaObject{T} is the main JavaCall type representing either an instance
    or a static class

    T is usually a symbol referring a Java class name
"""
mutable struct JavaObject{T} <: JNI.AbstractJavaRef
    ref::JavaRef

    #This below is ugly. Once we stop supporting 0.5, this can be replaced by
    # function JavaObject{T}(ptr) where T
    function JavaObject{T}(ref) where T
        j = new{T}(ref)
        finalizer(deleteref, j)
        return j
    end

    #replace with: JavaObject{T}(argtypes::Tuple, args...) where T
    JavaObject{T}(argtypes::Tuple, args...) where {T} = jnew(T, argtypes, args...)
end

# JavaObject Construction
JavaObject(ptr) = JObject(ptr)
JavaObject(T, ptr) = JavaObject{T}(ptr)
JavaObject{T}() where {T} = JavaObject{T}((),)
JavaObject{T}(ptr::Ptr{Nothing}) where {T} = JavaObject{T}(JavaLocalRef(ptr))

# JavaObject Reference Management
ref(x::JavaObject{T}) where T = x.ref
copyref(x::JavaObject{T}) where T = JavaObject{T}(JavaLocalRef(x.ref))
deleteref(x::JavaObject{T}) where T = ( deleteref(x.ref); x.ref = J_NULL )

# Obtain the underlying pointer for a JavaObject
Ptr(x::JavaObject{T}) where T = Ptr(x.ref)
Ptr{Nothing}(x::JavaObject{T}) where T = Ptr(x.ref)

"""
   jglobal(x::JavaObject) creates a new JavaGlobalRef and deletes the prior JavaRef
"""
function jglobal(x::JavaObject)
    with_env() do env
        gref = JavaGlobalRef(JNI.NewGlobalRef(Ptr(x), env))
        deleteref(x.ref)
        x.ref = gref
    end
end

"""
```
isnull(obj::JavaObject)
```
Checks if the passed JavaObject is null or not

### Args
* obj: The object of type JavaObject

### Returns
true if the passed object is null else false
"""
isnull(obj::JavaObject) = Ptr(obj) == C_NULL
isnull(obj::Ptr{Nothing}) = obj == C_NULL

"""
```
isnull(obj::JavaMetaClass)
```
Checks if the passed JavaMetaClass is null or not

### Args
* obj: The object of type JavaMetaClass

### Returns
true if the passed object is null else false
"""
isnull(obj::JavaMetaClass) = Ptr(obj) == C_NULL

macro checknull(expr, msg="")
    if expr isa Expr && expr.head == :call
        jnifun = "$(expr.args[1])"
        quote
            local ptr = $(esc(expr))
            if isnull(ptr) && geterror() === nothing
                throw(JavaCallError("JavaCall."*$jnifun*": "*$(esc(msg))))
            end
            ptr
        end
    else
        quote
            local ptr = $(esc(expr))
            if isnull(ptr) && geterror() === nothing
                throw(JavaCallError($(esc(msg))))
            end
            ptr
        end
    end
end

function checknull(ptr, msg="Unexpected null pointer from Java Native Interface", jnifun=nothing)
    if isnull(ptr) && geterror() === nothing
        if jnifun === nothing
            throw(JavaCallError(msg))
        else
            throw(JavaCallError("JavaCall.JNI.$jnifun: $msg"))
        end
    end
    ptr
end

const JClass = JavaObject{Symbol("java.lang.Class")}
const JObject = JavaObject{Symbol("java.lang.Object")}
const JMethod = JavaObject{Symbol("java.lang.reflect.Method")}
const JConstructor = JavaObject{Symbol("java.lang.reflect.Constructor")}
const JField = JavaObject{Symbol("java.lang.reflect.Field")}
const JThread = JavaObject{Symbol("java.lang.Thread")}
const JClassLoader = JavaObject{Symbol("java.lang.ClassLoader")}
const JString = JavaObject{Symbol("java.lang.String")}

#JavaObject(ptr::Ptr{Nothing}) = ptr == C_NULL ? JavaObject(ptr) : JavaObject{Symbol(getclassname(getclass(ptr)))}(ptr)

function JString(str::AbstractString)
    with_env() do env
        JString(env, str)
    end
end

function JString(env::Ptr{JNI.JNIEnv}, str::AbstractString)
    jstring = @checknull JNI.NewStringUTF(String(str), env)
    return JString(jstring)
end

# Encode Julia values into a JValue (the C jvalue union). The function
# name is lowercase `jvalue` to match the C convention; the type name is
# `JValue` (CamelCase Julia primitive type).
jvalue(v::Integer)::JNI.JValue = JNI.JValue(Int64(v))
# Use UInt32 (zero-extension to Int64) rather than Int32 (sign-extension)
# so the high 4 bytes of the 8-byte jvalue slot are clean. Currently
# harmless on every Julia-supported architecture (all little-endian, where
# the JVM reads jfloat from bytes 0-3).
jvalue(v::Float32)::JNI.JValue = JNI.JValue(Int64(reinterpret(UInt32, v)))
jvalue(v::Float64)::JNI.JValue = JNI.JValue(reinterpret(Int64, v))
jvalue(v::Ptr)::JNI.JValue = JNI.JValue(Int64(UInt(v)))
jvalue(v::JavaObject) = jvalue(Ptr(v))


function _jimport(juliaclass)
    for str ∈ [" ", "(", ")"]
        juliaclass = replace(juliaclass, str=>"")
    end
    :(JavaObject{Symbol($juliaclass)})
end

macro jimport(class::Expr)
    juliaclass = sprint(Base.show_unquoted, class)
    _jimport(juliaclass)
end
macro jimport(class::Symbol)
    juliaclass = string(class)
    _jimport(juliaclass)
end
macro jimport(class::AbstractString)
    _jimport(class)
end

const primitive_names_to_types = Dict(
    :boolean => jboolean,
    :byte    => jbyte,
    :char    => jchar,
    :short   => jshort,
    :int     => jint,
    :long    => jlong,
    :float   => jfloat,
    :double  => jdouble,
    :void    => jvoid
)
jimport(juliaclass::Symbol) = juliaclass == :void ? Nothing :
    haskey(primitive_names_to_types, juliaclass) ? jimport(juliaclass, Val(true), Val(false)) : JavaObject{juliaclass}
jimport(juliaclass::Symbol, isprimitive::Val{false}, isarray::Val{false}) = jimport(juliaclass)
jimport(juliaclass::Symbol, isprimitive::Val{true},  isarray::Val{false}) = primitive_names_to_types[juliaclass]

jimport(juliaclass::String, args...) = isarray(juliaclass) ? Vector{ jimport(Symbol(juliaclass[1:end-2])) } : jimport(Symbol(juliaclass), args...)

function jimport(juliaclass::JClass)
    jimport(juliaclass, Val(isprimitive(juliaclass)), Val(isarray(juliaclass)))
end
function jimport(juliaclass::JClass, isprimitive, isarray::Val{true})
    elementType = jimport( jcall(juliaclass, "getComponentType", JClass) )
    Vector{elementType}
end
jimport(juliaclass::JClass, isprimitive, isarray::Val{false}) = jimport(getname(juliaclass), isprimitive, isarray)

isprimitive(juliaclass::JClass) = jcall(juliaclass, "isPrimitive", jboolean, ()) == 0x01
isarray(juliaclass::JClass) = jcall(juliaclass, "isArray", jboolean, ()) == 0x01
isarray(juliaclass::String) = endswith(juliaclass, "[]")

function jnew(T::Symbol, argtypes::Tuple = (), args...)
    assertloaded()
    with_env() do env
        jmethodId = _cached_method_id(env, T, "<init>", Nothing, argtypes, false)
        _jcall(env, metaclass(env, T), jmethodId, JavaObject{T}, argtypes, args...; callmethod=JNI.NewObjectA)
    end
end

_jcallable(typ::Type{JavaObject{T}}) where T = metaclass(T)
function _jcallable(obj::JavaObject)
    isnull(obj) && throw(JavaCallError("Attempt to call method on Java NULL"))
    obj
end

function jcall(ref, method::AbstractString, rettype::Type, argtypes::Tuple = (), args...)
    assertloaded()
    with_env() do env
        jmethodId = get_method_id(env, ref, method, rettype, argtypes)
        _jcall(env, _jcallable(ref), jmethodId, rettype, argtypes, args...)
    end
end

function jcall(ref, method::JMethod, args...)
    assertloaded()
    with_env() do env
        jmethodId = get_method_id(env, method)
        rettype = jimport(getreturntype(method))
        argtypes = Tuple(jimport.(getparametertypes(method)))
        _jcall(env, _jcallable(ref), jmethodId, rettype, argtypes, args...)
    end
end

function get_method_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    _cached_method_id(env, T, method, rettype, argtypes, true)
end

function get_method_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject{T}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    _cached_method_id(env, T, method, rettype, argtypes, false)
end

get_method_id(env::Ptr{JNI.JNIEnv}, method::JMethod) = @checknull JNI.FromReflectedMethod(Ptr(method), env)

# JMethod invoke
(m::JMethod)(obj, args...) = jcall(obj, m, args...)


"""
    jfield(ref, field, [fieldType])

Get a pointer to a field of of a Java class or object.
* `ref` could be a JavaObject{T} type or a JavaObject
* `field` can be an AbstractString or JField
* `fieldType` is a Type
"""
function jfield(ref, field, fieldType)
    assertloaded()
    with_env() do env
        jfieldID = get_field_id(env, ref, field, fieldType)
        _jfield(env, _jcallable(ref), jfieldID, fieldType)
    end
end

function jfield(ref, field)
    assertloaded()
    with_env() do env
        fieldType = jimport(gettype(field))
        jfieldID = get_field_id(env, ref, field, fieldType)
        _jfield(env, _jcallable(ref), jfieldID, fieldType)
    end
end

function jfield(ref, field::AbstractString)
    assertloaded()
    with_env() do env
        field = listfields(ref, field)[]
        fieldType = jimport(gettype(field))
        jfieldID = get_field_id(env, ref, field)
        _jfield(env, _jcallable(ref), jfieldID, fieldType)
    end
end

jfield(ref, field::Symbol) = jfield(ref, String(field))

function get_field_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, field::AbstractString, fieldType::Type) where T
    @checknull JNI.GetStaticFieldID(Ptr(metaclass(env, T)), String(field), signature(fieldType), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::Type{JavaObject{T}}, field::JField) where T
    @checknull JNI.FromReflectedField(field, env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::Type{JavaObject{T}}, field::JField, fieldType::Type) where T
    @checknull JNI.FromReflectedField(field, env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::AbstractString, fieldType::Type)
    @checknull JNI.GetFieldID(Ptr(metaclass(env, obj)), String(field), signature(fieldType), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::JField, fieldType::Type)
    @checknull JNI.FromReflectedField(field, env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::JField)
    @checknull JNI.FromReflectedField(field, env)
end

# JField invoke
(f::JField)(obj) = jfield(obj, f)

for (x, name) in [(:(<:Any),  :Object),
                  (:jboolean, :Boolean),
                  (:jchar,    :Char   ),
                  (:jbyte,    :Byte   ),
                  (:jshort,   :Short  ),
                  (:jint,     :Int    ),
                  (:jlong,    :Long   ),
                  (:jfloat,   :Float  ),
                  (:jdouble,  :Double ),
                  (:jvoid,    :Void   )]
    for (t, callprefix, getprefix) in [
        (:JavaObject,    :Call, :Get ),
        (:JavaMetaClass, :CallStatic, :GetStatic )
    ]
        callmethod = :(JNI.$(Symbol(callprefix, name, :MethodA)))
        fieldmethod = :(JNI.$(Symbol(getprefix, name, :Field)))
        m = quote
            function _jfield(env::Ptr{JNI.JNIEnv}, obj::T, jfieldID::Ptr{Nothing}, fieldType::Type{$x}) where T <: $t
                result = $fieldmethod(Ptr(obj), jfieldID, env)
                geterror(env)
                return convert_result(env, fieldType, result)
            end
            function _jcall(env::Ptr{JNI.JNIEnv}, obj::T, jmethodId::Ptr{Nothing}, rettype::Type{$x},
                            argtypes::Tuple, args...; callmethod=$callmethod) where T <: $t
                savedArgs, convertedArgs = convert_args(env, argtypes, args...)
                GC.@preserve obj savedArgs convertedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.JValue}(jvalue.(convertedArgs)), env)
                end
                cleanup_arg.(convertedArgs)
                geterror(env)
                return convert_result(env, rettype, result)
            end
        end
        eval(m)
    end
end

cleanup_arg(arg) = nothing

# cleanup_arg runs inside _jcall on the same JVM-attached thread that just
# made the call, so it can free the local ref synchronously rather than
# routing through the dispatch task. The dispatch route is reserved for
# *finalizers*, which can fire on any thread (including Julia GC threads
# that are not JVM-attached). Routing cleanup_arg through the channel
# instead caused a real OOM regression: tight `for i in 1:N` loops over
# `jcall(..., big_array)` would accumulate N un-freed Java arrays before
# the cooperative scheduler ran the dispatch task.
function cleanup_arg(arg::JavaObject)
    ref = arg.ref
    ref.ptr == C_NULL && return
    JNI.is_env_loaded() || return
    with_env() do env
        if ref isa JavaLocalRef
            JNI.DeleteLocalRef(ref.ptr, env)
        elseif ref isa JavaGlobalRef
            JNI.DeleteGlobalRef(ref.ptr, env)
        end
    end
    arg.ref = J_NULL
    return
end

const _jmc_cache_lock = ReentrantLock()
const _jmc_cache_v2 = Dict{Symbol, JavaMetaClass}()

struct MethodKey
    class::Symbol
    name::Symbol
    signature::String
end

const _method_id_cache = Dict{MethodKey, Ptr{Nothing}}()
const _method_id_cache_lock = ReentrantLock()

function _cached_method_id(env::Ptr{JNI.JNIEnv}, class_sym::Symbol, name::AbstractString,
                           rettype::Type, argtypes::Tuple, isstatic::Bool)
    sig = method_signature(rettype, argtypes...)
    key = MethodKey(class_sym, Symbol(name), sig)
    lock(_method_id_cache_lock) do
        get!(_method_id_cache, key) do
            mc = metaclass(env, class_sym)
            jnifun = isstatic ? JNI.GetStaticMethodID : JNI.GetMethodID
            @checknull jnifun(Ptr(mc), String(name), sig, env) "Problem getting method id for $class_sym.$name $sig"
        end
    end
end

function _metaclass(env::Ptr{JNI.JNIEnv}, class::Symbol)
    jclass = javaclassname(class)
    jclassptr = @checknull JNI.FindClass(jclass, env)
    # FindClass returns a local ref; promote to a global ref so the cache
    # entry survives PopLocalFrame and outlives the caller's frame.
    globalptr = JNI.NewGlobalRef(jclassptr, env)
    JNI.DeleteLocalRef(jclassptr, env)
    return JavaMetaClass{class}(JavaGlobalRef(globalptr))
end

function metaclass(env::Ptr{JNI.JNIEnv}, class::Symbol)
    lock(_jmc_cache_lock) do
        get!(_jmc_cache_v2, class) do
            _metaclass(env, class)
        end
    end
end

# Convenience: fetch env on demand if caller did not pass one.
metaclass(class::Symbol) = with_env() do env
    metaclass(env, class)
end

metaclass(env::Ptr{JNI.JNIEnv}, ::Type{JavaObject{T}}) where {T} = metaclass(env, T)
metaclass(env::Ptr{JNI.JNIEnv}, ::JavaObject{T}) where {T} = metaclass(env, T)
metaclass(env::Ptr{JNI.JNIEnv}, ::Type{T}) where T <: AbstractVector = metaclass(env, Symbol(JavaCall.signature(T)))

# Backwards-compat single-arg forms
metaclass(::Type{JavaObject{T}}) where {T} = metaclass(T)
metaclass(::JavaObject{T}) where {T} = metaclass(T)
metaclass(::Type{T}) where T <: AbstractVector = metaclass( Symbol( JavaCall.signature(T) ) )

javaclassname(class::Symbol) = replace(string(class), "."=>"/")
javaclassname(class::AbstractString) = replace(class, "."=>"/")
javaclassname(::Type{T}) where T <: AbstractVector = JavaCall.signature(T)

function _notnull_assert(ptr)
    isnull(ptr) && throw(JavaCallError("Java Exception thrown, but no details could be retrieved from the JVM"))
end

function get_exception_string(env::Ptr{JNI.JNIEnv}, jthrow)
    jthrowable = JNI.FindClass("java/lang/Throwable", env)
    _notnull_assert(jthrowable)
    res = C_NULL
    try
        tostring_method = JNI.GetMethodID(jthrowable, "toString", "()Ljava/lang/String;", env)
        _notnull_assert(tostring_method)
        res = JNI.CallObjectMethodA(jthrow, tostring_method, JNI.JValue[], env)
        _notnull_assert(res)
        # Use the Ptr{Nothing} overload of unsafe_string to copy out the
        # UTF-8 chars without wrapping res in a JString JavaObject — that
        # would attach a finalizer racing with the eager DeleteLocalRef
        # below.
        return unsafe_string(env, res)
    finally
        # Eagerly free both local refs. A long exception-handling loop
        # would otherwise exhaust the JNI local ref table waiting on
        # Julia GC of the (no longer created) JString wrapper.
        res != C_NULL && JNI.DeleteLocalRef(res, env)
        JNI.DeleteLocalRef(jthrowable, env)
    end
end

function geterror(env::Ptr{JNI.JNIEnv})
    isexception = JNI.ExceptionCheck(env)

    if isexception == JNI_TRUE
        jthrow = JNI.ExceptionOccurred(env)
        _notnull_assert(jthrow)
        try
            JNI.ExceptionDescribe(env) #Print java stackstrace to stdout

            msg = get_exception_string(env, jthrow)
            throw(JavaCallError(string("Error calling Java: ", msg)))
        finally
            JNI.ExceptionClear(env)
            JNI.DeleteLocalRef(jthrow, env)
        end
    end
end

# Backwards-compatible no-arg form
geterror() = with_env() do env
    geterror(env)
end

#get the JNI signature string for a method, given its
#return type and argument types
function method_signature(rettype, argtypes...)
    s=IOBuffer()
    write(s, "(")
    for arg in argtypes
        write(s, signature(arg))
    end
    write(s, ")")
    write(s, signature(rettype))
    return String(take!(s))
end

#get the JNI signature string for a given type
signature(::Type{jboolean}) = "Z"
signature(::Type{jbyte}) = "B"
signature(::Type{jchar}) = "C"
signature(::Type{jshort}) = "S"
signature(::Type{jint}) = "I"
signature(::Type{jlong}) = "J"
signature(::Type{jfloat}) = "F"
signature(::Type{jdouble}) = "D"
signature(::Type{jvoid}) = "V"
signature(::Type{Array{T,N}}) where {T,N} = string("[" ^ N, signature(T))
signature(arg::Type{JavaObject{T}}) where {T} = string("L", javaclassname(T), ";")
signature(arg::Type{JavaObject{T}}) where {T <: AbstractVector} = JavaCall.javaclassname(T)

