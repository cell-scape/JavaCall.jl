module JNI

import Libdl

# jnienv.jl exports
export JNINativeInterface, JNIEnv, JNIInvokeInterface, JavaVM
# jni_md.h exports
export jint, jlong, jbyte
# jni.h exports
export jboolean, jchar, jshort, jfloat, jdouble, jsize, jprimitive
export jvoid, JValue
# constant export
export JNI_TRUE, JNI_FALSE
export JNI_VERSION_1_1, JNI_VERSION_1_2, JNI_VERSION_1_4, JNI_VERSION_1_6, JNI_VERSION_1_8
# export JNI_VERSION_9, JNI_VERSION_10 # Intentionally excluded, use JNI.JNI_VERSION_9
export JNI_OK, JNI_ERR, JNI_EDETACHED, JNI_EVERSION, JNI_ENOMEM, JNI_EEXIST, JNI_EINV
#export jnifunc

include("jnienv.jl")

const jniref = Ref(JNINativeInterface())
#global jnifunc
Base.@deprecate_binding jnifunc jniref[]

const ppenv = [Ptr{JNIEnv}(C_NULL)]
const ppjvm = Ref(Ptr{JavaVM}(C_NULL))
const jvmfunc = Ref{JNIInvokeInterface}()


"""
    jint, jlong, jbyte, jboolean, jchar, jshort, jfloat, jdouble, jvoid

Julia aliases for the JNI primitive C types, mirroring `<jni_md.h>`/`<jni.h>`:
`jint === Cint`, `jlong === Clonglong`, `jbyte === Cchar`, `jboolean === Cuchar`,
`jchar === Cushort`, `jshort === Cshort`, `jfloat === Cfloat`, `jdouble ===
Cdouble`, `jvoid === Nothing`. Use these (not Julia's `Int`, `Float64`, …) for the
return-type and argument-type tuples passed to `jcall` so the JNI signature is
unambiguous. `jprimitive` is the `Union` of all of them.
"""
# jni_md.h
const jint = Cint
#ifdef _LP64 /* 64-bit Solaris */
# typedef long jlong;
const jlong = Clonglong
const jbyte = Cchar

# jni.h

const jboolean = Cuchar
const jchar = Cushort
const jshort = Cshort
const jfloat = Cfloat
const jdouble = Cdouble
const jsize = jint
jprimitive = Union{jboolean, jchar, jshort, jfloat, jdouble, jint, jlong}

const jvoid = Nothing

jobject = Ptr{Nothing}
jclass = Ptr{Nothing}
jthrowable = Ptr{Nothing}
jweak = Ptr{Nothing}
jmethodID = Ptr{Nothing}
jfieldID = Ptr{Nothing}
jstring = Ptr{Nothing}
jarray = Ptr{Nothing}
JNINativeMethod = Ptr{Nothing}
jobjectArray = Ptr{Nothing}
jbooleanArray = Ptr{Nothing}
jbyteArray = Ptr{Nothing}
jshortArray = Ptr{Nothing}
jintArray = Ptr{Nothing}
jlongArray = Ptr{Nothing}
jfloatArray = Ptr{Nothing}
jdoubleArray = Ptr{Nothing}
jcharArray = Ptr{Nothing}
"""
    JValue

JNI's `jvalue` C union as a Julia primitive type. 64 bits wide. Values
of any JNI primitive (jint, jlong, jfloat, jdouble, jboolean, jbyte,
jchar, jshort) or a jobject pointer are encoded into a JValue via the
`jvalue(...)` functions in core.jl, which handle endianness and bit
placement explicitly. JValue is bit-compatible with Int64 but the
distinct type catches accidental mixing of Java values and Julia
integers in ccall signatures.
"""
primitive type JValue 64 end

JValue(x::Int64)   = reinterpret(JValue, x)
JValue(x::UInt64)  = reinterpret(JValue, x)
JValue(x::Float64) = reinterpret(JValue, x)
JValue(x::Float32) = reinterpret(JValue, Int64(reinterpret(UInt32, x)))
JValue(x::Ptr)     = reinterpret(JValue, Int64(UInt(x)))
Base.zero(::Type{JValue}) = reinterpret(JValue, Int64(0))
Base.convert(::Type{JValue}, x::Integer) = JValue(Int64(x))

@enum jobjectRefType begin
    JNIInvalidRefType    = 0
    JNILocalRefType      = 1
    JNIGlobalRefType     = 2
    JNIWeakGlobalRefType = 3
end

"""
    AbstractJavaRef

    Abstract type for jobject in jni.h
    Must be convertible to a `Ptr{Nothing}` by `ccall` usually by overriding unsafe_convert.
"""
abstract type AbstractJavaRef end


const JNI_VERSION_1_1 = convert(Cint, 0x00010001)
const JNI_VERSION_1_2 = convert(Cint, 0x00010002)
const JNI_VERSION_1_4 = convert(Cint, 0x00010004)
const JNI_VERSION_1_6 = convert(Cint, 0x00010006)
const JNI_VERSION_1_8 = convert(Cint, 0x00010008)
const JNI_VERSION_9   = convert(Cint, 0x00090000)
const JNI_VERSION_10  = convert(Cint, 0x000a0000)
const JNI_VERSION_19  = convert(Cint, 0x00130000)
const JNI_VERSION_20  = convert(Cint, 0x00140000)
const JNI_VERSION_21  = convert(Cint, 0x00150000)

const JNI_TRUE = convert(Cchar, 1)
const JNI_FALSE = convert(Cchar, 0)

# Return Values
const JNI_OK           = convert(Cint, 0)               #/* success */
const JNI_ERR          = convert(Cint, -1)              #/* unknown error */
const JNI_EDETACHED    = convert(Cint, -2)              #/* thread detached from the VM */
const JNI_EVERSION     = convert(Cint, -3)              #/* JNI version error */
const JNI_ENOMEM       = convert(Cint, -4)              #/* not enough memory */
const JNI_EEXIST       = convert(Cint, -5)              #/* VM already created */
const JNI_EINVAL       = convert(Cint, -6)              #/* invalid arguments */

# There is likely over specification here
PtrIsCopy = Union{Ptr{jboolean},Ref{jboolean},Array{jboolean,}}
AnyString = Union{AbstractString,Cstring,Ptr{UInt8}}
jobject_arg = Union{jobject,AbstractJavaRef}
jobjectArray_arg = Union{jobjectArray,AbstractJavaRef}

struct JNIError <: Exception
    msg::String
end

struct JavaVMOption
    optionString::Ptr{UInt8}
    extraInfo::Ptr{Nothing}
end

struct JavaVMInitArgs
    version::Cint
    nOptions::Cint
    options::Ptr{JavaVMOption}
    ignoreUnrecognized::Cchar
end

struct JavaVMAttachArgs
    version::Cint #jint version

    name::Ptr{UInt8} #char* name (modified UTF-8 string)
    group::Ptr{Nothing} #jobject group
end

function load_jni(penv::Ptr{JNIEnv})
    global jnienv = unsafe_load(penv)
    jniref[] = unsafe_load(jnienv.JNINativeInterface_) #The JNI Function table
    #global jnifunc = jniref[]
end
is_jni_loaded() = jniref[].GetVersion != C_NULL
is_env_loaded() = ppenv[1] != C_NULL


"""
    init_new_vm(opts)

Initialize a new Java virtual machine.
"""
function init_new_vm(libpath,opts)
    libjvm = load_libjvm(libpath)
    create = Libdl.dlsym(libjvm, :JNI_CreateJavaVM)
    opt = [JavaVMOption(pointer(x), C_NULL) for x in opts]
    # Preserve both the option struct array AND the underlying option strings:
    # `opt` holds raw pointers into each string in `opts`, but does not keep
    # those strings rooted on its own.
    GC.@preserve opt opts begin
        vm_args = JavaVMInitArgs(JNI_VERSION_1_8, convert(Cint, length(opts)),
                                 convert(Ptr{JavaVMOption}, pointer(opt)), JNI_TRUE)
        res = ccall(create, Cint, (Ptr{Ptr{JavaVM}}, Ptr{Ptr{JNIEnv}}, Ptr{JavaVMInitArgs}), ppjvm, ppenv,
                    Ref(vm_args))
        res < 0 && throw(JNIError("Unable to initialise Java VM: $(res)"))
    end
    jvm = unsafe_load(ppjvm[])
    jvmfunc[] = unsafe_load(jvm.JNIInvokeInterface_)
    load_jni(ppenv[1])
    return
end


"""
    init_current_vm()

Allow initialization from running VM. Uses the first VM it finds.
"""
function init_current_vm(libpath)
    libjvm = load_libjvm(libpath)
    pnum = Array{Cint}(undef, 1)
    ccall(Libdl.dlsym(libjvm, :JNI_GetCreatedJavaVMs), Cint, (Ptr{Ptr{JavaVM}}, Cint, Ptr{Cint}), ppjvm, 1, pnum)
    jvm = unsafe_load(ppjvm[])
    global jvmfunc[] = unsafe_load(jvm.JNIInvokeInterface_)
    ccall(jvmfunc[].GetEnv, Cint, (Ptr{Nothing}, Ptr{Ptr{JNIEnv}}, Cint), ppjvm[], ppenv, JNI.JNI_VERSION_1_8)
    load_jni(ppenv[1])
end

function load_libjvm(libpath::AbstractString)
    libjvm = Libdl.dlopen(libpath)
    @debug("Loaded $libpath")
    libjvm
end

function load_libjvm(libpaths::NTuple{N,String}) where N
    Libdl.dlopen.(libpaths)
    load_libjvm(libpaths[end])
end

function destroy()
    if !is_env_loaded()
        throw(JNIError("Called destroy without initialising Java VM"))
    end
    res = ccall(jvmfunc[].DestroyJavaVM, Cint, (Ptr{Nothing},), ppjvm[])
    res < 0 && throw(JavaCallError("Unable to destroy Java VM"))
    ppenv[1] = C_NULL
    ppjvm[] = C_NULL
    nothing
end


# === Below Generated by make_jni2.jl ===

GetVersion(penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetVersion)(penv::Ptr{JNIEnv})::jint

DefineClass(name::AnyString, loader::jobject_arg, buf::Array{jbyte,1}, len::Integer, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].DefineClass)(penv::Ptr{JNIEnv}, name::Cstring, loader::jobject, buf::Ptr{jbyte}, len::jsize)::jclass

FindClass(name::AnyString, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].FindClass)(penv::Ptr{JNIEnv}, name::Cstring)::jclass

FromReflectedMethod(method::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].FromReflectedMethod)(penv::Ptr{JNIEnv}, method::jobject)::jmethodID

FromReflectedField(field::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].FromReflectedField)(penv::Ptr{JNIEnv}, field::jobject)::jfieldID

ToReflectedMethod(cls::jclass, methodID::jmethodID, isStatic::jboolean, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ToReflectedMethod)(penv::Ptr{JNIEnv}, cls::jclass, methodID::jmethodID, isStatic::jboolean)::jobject

GetSuperclass(sub::jclass, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetSuperclass)(penv::Ptr{JNIEnv}, sub::jclass)::jclass

IsAssignableFrom(sub::jclass, sup::jclass, penv::Ptr{JNIEnv}) =
  ccall(jniref[].IsAssignableFrom, jboolean, (Ptr{JNIEnv}, jclass, jclass,), penv, sub, sup)

ToReflectedField(cls::jclass, fieldID::jfieldID, isStatic::jboolean, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ToReflectedField)(penv::Ptr{JNIEnv}, cls::jclass, fieldID::jfieldID, isStatic::jboolean)::jobject

Throw(obj::jthrowable, penv::Ptr{JNIEnv}) =
  ccall(jniref[].Throw, jint, (Ptr{JNIEnv}, jthrowable,), penv, obj)

ThrowNew(clazz::jclass, msg::AnyString, penv::Ptr{JNIEnv}) =
  ccall(jniref[].ThrowNew, jint, (Ptr{JNIEnv}, jclass, Cstring,), penv, clazz, msg)

ExceptionOccurred(penv::Ptr{JNIEnv}) =
  ccall(jniref[].ExceptionOccurred, jthrowable, (Ptr{JNIEnv},), penv)

ExceptionDescribe(penv::Ptr{JNIEnv}) =
  ccall(jniref[].ExceptionDescribe, Nothing, (Ptr{JNIEnv},), penv)

ExceptionClear(penv::Ptr{JNIEnv}) =
  ccall(jniref[].ExceptionClear, Nothing, (Ptr{JNIEnv},), penv)

FatalError(msg::AnyString, penv::Ptr{JNIEnv}) =
  ccall(jniref[].FatalError, Nothing, (Ptr{JNIEnv}, Cstring,), penv, msg)

PushLocalFrame(capacity::jint, penv::Ptr{JNIEnv}) =
  ccall(jniref[].PushLocalFrame, jint, (Ptr{JNIEnv}, jint,), penv, capacity)

PopLocalFrame(result::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].PopLocalFrame, jobject, (Ptr{JNIEnv}, jobject,), penv, result)

NewGlobalRef(lobj::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewGlobalRef, jobject, (Ptr{JNIEnv}, jobject,), penv, lobj)

DeleteGlobalRef(gref::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].DeleteGlobalRef, Nothing, (Ptr{JNIEnv}, jobject,), penv, gref)

DeleteLocalRef(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].DeleteLocalRef, Nothing, (Ptr{JNIEnv}, jobject,), penv, obj)

IsSameObject(obj1::jobject_arg, obj2::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].IsSameObject, jboolean, (Ptr{JNIEnv}, jobject, jobject,), penv, obj1, obj2)

NewLocalRef(ref::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewLocalRef, jobject, (Ptr{JNIEnv}, jobject,), penv, ref)

EnsureLocalCapacity(capacity::jint, penv::Ptr{JNIEnv}) =
  ccall(jniref[].EnsureLocalCapacity, jint, (Ptr{JNIEnv}, jint,), penv, capacity)

AllocObject(clazz::jclass, penv::Ptr{JNIEnv}) =
  ccall(jniref[].AllocObject, jobject, (Ptr{JNIEnv}, jclass,), penv, clazz)

NewObjectA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].NewObjectA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jobject

GetObjectClass(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetObjectClass)(penv::Ptr{JNIEnv}, obj::jobject)::jclass

IsInstanceOf(obj::jobject_arg, clazz::jclass, penv::Ptr{JNIEnv}) =
  ccall(jniref[].IsInstanceOf, jboolean, (Ptr{JNIEnv}, jobject, jclass,), penv, obj, clazz)

GetMethodID(clazz::jclass, name::AnyString, sig::AnyString, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetMethodID)(penv::Ptr{JNIEnv}, clazz::jclass, name::Cstring, sig::Cstring)::jmethodID

CallObjectMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallObjectMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jobject

CallBooleanMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallBooleanMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jboolean

CallByteMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallByteMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jbyte

CallCharMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallCharMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jchar

CallShortMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallShortMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jshort

CallIntMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallIntMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jint

CallLongMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallLongMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jlong

CallFloatMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallFloatMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jfloat

CallDoubleMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallDoubleMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::jdouble

CallVoidMethodA(obj::jobject_arg, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallVoidMethodA)(penv::Ptr{JNIEnv}, obj::jobject, methodID::jmethodID, args::Ptr{JValue})::Nothing

CallNonvirtualObjectMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualObjectMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jobject

CallNonvirtualBooleanMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualBooleanMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jboolean

CallNonvirtualByteMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualByteMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jbyte

CallNonvirtualCharMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualCharMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jchar

CallNonvirtualShortMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualShortMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jshort

CallNonvirtualIntMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualIntMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jint

CallNonvirtualLongMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualLongMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jlong

CallNonvirtualFloatMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualFloatMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jfloat

CallNonvirtualDoubleMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualDoubleMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jdouble

CallNonvirtualVoidMethodA(obj::jobject_arg, clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallNonvirtualVoidMethodA)(penv::Ptr{JNIEnv}, obj::jobject, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::Nothing

GetFieldID(clazz::jclass, name::AnyString, sig::AnyString, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetFieldID)(penv::Ptr{JNIEnv}, clazz::jclass, name::Cstring, sig::Cstring)::jfieldID

GetObjectField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetObjectField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jobject

GetBooleanField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetBooleanField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jboolean

GetByteField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetByteField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jbyte

GetCharField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetCharField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jchar

GetShortField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetShortField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jshort

GetIntField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetIntField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jint

GetLongField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetLongField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jlong

GetFloatField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetFloatField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jfloat

GetDoubleField(obj::jobject_arg, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetDoubleField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID)::jdouble

SetObjectField(obj::jobject_arg, fieldID::jfieldID, val::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetObjectField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jobject)::Nothing

SetBooleanField(obj::jobject_arg, fieldID::jfieldID, val::jboolean, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetBooleanField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jboolean)::Nothing

SetByteField(obj::jobject_arg, fieldID::jfieldID, val::jbyte, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetByteField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jbyte)::Nothing

SetCharField(obj::jobject_arg, fieldID::jfieldID, val::jchar, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetCharField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jchar)::Nothing

SetShortField(obj::jobject_arg, fieldID::jfieldID, val::jshort, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetShortField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jshort)::Nothing

SetIntField(obj::jobject_arg, fieldID::jfieldID, val::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetIntField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jint)::Nothing

SetLongField(obj::jobject_arg, fieldID::jfieldID, val::jlong, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetLongField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jlong)::Nothing

SetFloatField(obj::jobject_arg, fieldID::jfieldID, val::jfloat, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetFloatField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jfloat)::Nothing

SetDoubleField(obj::jobject_arg, fieldID::jfieldID, val::jdouble, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetDoubleField)(penv::Ptr{JNIEnv}, obj::jobject, fieldID::jfieldID, val::jdouble)::Nothing

GetStaticMethodID(clazz::jclass, name::AnyString, sig::AnyString, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticMethodID)(penv::Ptr{JNIEnv}, clazz::jclass, name::Cstring, sig::Cstring)::jmethodID

CallStaticObjectMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticObjectMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jobject

CallStaticBooleanMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticBooleanMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jboolean

CallStaticByteMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticByteMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jbyte

CallStaticCharMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticCharMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jchar

CallStaticShortMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticShortMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jshort

CallStaticIntMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticIntMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jint

CallStaticLongMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticLongMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jlong

CallStaticFloatMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticFloatMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jfloat

CallStaticDoubleMethodA(clazz::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticDoubleMethodA)(penv::Ptr{JNIEnv}, clazz::jclass, methodID::jmethodID, args::Ptr{JValue})::jdouble

CallStaticVoidMethodA(cls::jclass, methodID::jmethodID, args::Array{JValue,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].CallStaticVoidMethodA)(penv::Ptr{JNIEnv}, cls::jclass, methodID::jmethodID, args::Ptr{JValue})::Nothing

GetStaticFieldID(clazz::jclass, name::AnyString, sig::AnyString, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticFieldID)(penv::Ptr{JNIEnv}, clazz::jclass, name::Cstring, sig::Cstring)::jfieldID

GetStaticObjectField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticObjectField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jobject

GetStaticBooleanField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticBooleanField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jboolean

GetStaticByteField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticByteField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jbyte

GetStaticCharField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticCharField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jchar

GetStaticShortField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticShortField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jshort

GetStaticIntField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticIntField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jint

GetStaticLongField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticLongField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jlong

GetStaticFloatField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticFloatField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jfloat

GetStaticDoubleField(clazz::jclass, fieldID::jfieldID, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStaticDoubleField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID)::jdouble

SetStaticObjectField(clazz::jclass, fieldID::jfieldID, value::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticObjectField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jobject)::Nothing

SetStaticBooleanField(clazz::jclass, fieldID::jfieldID, value::jboolean, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticBooleanField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jboolean)::Nothing

SetStaticByteField(clazz::jclass, fieldID::jfieldID, value::jbyte, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticByteField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jbyte)::Nothing

SetStaticCharField(clazz::jclass, fieldID::jfieldID, value::jchar, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticCharField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jchar)::Nothing

SetStaticShortField(clazz::jclass, fieldID::jfieldID, value::jshort, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticShortField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jshort)::Nothing

SetStaticIntField(clazz::jclass, fieldID::jfieldID, value::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticIntField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jint)::Nothing

SetStaticLongField(clazz::jclass, fieldID::jfieldID, value::jlong, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticLongField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jlong)::Nothing

SetStaticFloatField(clazz::jclass, fieldID::jfieldID, value::jfloat, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticFloatField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jfloat)::Nothing

SetStaticDoubleField(clazz::jclass, fieldID::jfieldID, value::jdouble, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetStaticDoubleField)(penv::Ptr{JNIEnv}, clazz::jclass, fieldID::jfieldID, value::jdouble)::Nothing

NewString(unicode::Array{jchar,1}, len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewString, jstring, (Ptr{JNIEnv}, Ptr{jchar}, jsize,), penv, unicode, len)

GetStringLength(str::jstring, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStringLength)(penv::Ptr{JNIEnv}, str::jstring)::jsize

GetStringChars(str::jstring, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStringChars)(penv::Ptr{JNIEnv}, str::jstring, isCopy::Ptr{jboolean})::Ptr{jchar}

ReleaseStringChars(str::jstring, chars::Array{jchar,1}, penv::Ptr{JNIEnv}) =
  ccall(jniref[].ReleaseStringChars, Nothing, (Ptr{JNIEnv}, jstring, Ptr{jchar},), penv, str, chars)

NewStringUTF(utf::AnyString, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewStringUTF, jstring, (Ptr{JNIEnv}, Cstring,), penv, utf)

GetStringUTFLength(str::jstring, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStringUTFLength)(penv::Ptr{JNIEnv}, str::jstring)::jsize

GetStringUTFChars(str::jstring, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStringUTFChars)(penv::Ptr{JNIEnv}, str::jstring, isCopy::Ptr{jboolean})::Cstring

## Prior to this module we used UInt8 instead of Cstring, must match return value of above
#ReleaseStringUTFChars(str::jstring, chars::Ptr{UInt8}, penv::Ptr{JNIEnv}) =
#  ccall(jniref[].ReleaseStringUTFChars, Nothing, (Ptr{JNIEnv}, jstring, Ptr{UInt8},), penv, str, chars)
ReleaseStringUTFChars(str::jstring, chars::AnyString, penv::Ptr{JNIEnv}) =
  ccall(jniref[].ReleaseStringUTFChars, Nothing, (Ptr{JNIEnv}, jstring, Cstring,), penv, str, chars)

GetArrayLength(array::jarray, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetArrayLength)(penv::Ptr{JNIEnv}, array::jarray)::jsize

NewObjectArray(len::Integer, clazz::jclass, init::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].NewObjectArray)(penv::Ptr{JNIEnv}, len::jsize, clazz::jclass, init::jobject)::jobjectArray

GetObjectArrayElement(array::jobjectArray_arg, index::Integer, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetObjectArrayElement)(penv::Ptr{JNIEnv}, array::jobjectArray, index::jsize)::jobject

SetObjectArrayElement(array::jobjectArray_arg, index::Integer, val::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetObjectArrayElement)(penv::Ptr{JNIEnv}, array::jobjectArray, index::jsize, val::jobject)::Nothing

NewBooleanArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewBooleanArray, jbooleanArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewByteArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewByteArray, jbyteArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewCharArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewCharArray, jcharArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewShortArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewShortArray, jshortArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewIntArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewIntArray, jintArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewLongArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewLongArray, jlongArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewFloatArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewFloatArray, jfloatArray, (Ptr{JNIEnv}, jsize,), penv, len)

NewDoubleArray(len::Integer, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewDoubleArray, jdoubleArray, (Ptr{JNIEnv}, jsize,), penv, len)

GetBooleanArrayElements(array::jbooleanArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetBooleanArrayElements)(penv::Ptr{JNIEnv}, array::jbooleanArray, isCopy::Ptr{jboolean})::Ptr{jboolean}

GetByteArrayElements(array::jbyteArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetByteArrayElements)(penv::Ptr{JNIEnv}, array::jbyteArray, isCopy::Ptr{jboolean})::Ptr{jbyte}

GetCharArrayElements(array::jcharArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetCharArrayElements)(penv::Ptr{JNIEnv}, array::jcharArray, isCopy::Ptr{jboolean})::Ptr{jchar}

GetShortArrayElements(array::jshortArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetShortArrayElements)(penv::Ptr{JNIEnv}, array::jshortArray, isCopy::Ptr{jboolean})::Ptr{jshort}

GetIntArrayElements(array::jintArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetIntArrayElements)(penv::Ptr{JNIEnv}, array::jintArray, isCopy::Ptr{jboolean})::Ptr{jint}

GetLongArrayElements(array::jlongArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetLongArrayElements)(penv::Ptr{JNIEnv}, array::jlongArray, isCopy::Ptr{jboolean})::Ptr{jlong}

GetFloatArrayElements(array::jfloatArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetFloatArrayElements)(penv::Ptr{JNIEnv}, array::jfloatArray, isCopy::Ptr{jboolean})::Ptr{jfloat}

GetDoubleArrayElements(array::jdoubleArray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetDoubleArrayElements)(penv::Ptr{JNIEnv}, array::jdoubleArray, isCopy::Ptr{jboolean})::Ptr{jdouble}

ReleaseBooleanArrayElements(array::jbooleanArray, elems::Ptr{jboolean}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseBooleanArrayElements)(penv::Ptr{JNIEnv}, array::jbooleanArray, elems::Ptr{jboolean}, mode::jint)::Nothing

ReleaseByteArrayElements(array::jbyteArray, elems::Ptr{jbyte}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseByteArrayElements)(penv::Ptr{JNIEnv}, array::jbyteArray, elems::Ptr{jbyte}, mode::jint)::Nothing

ReleaseCharArrayElements(array::jcharArray, elems::Ptr{jchar}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseCharArrayElements)(penv::Ptr{JNIEnv}, array::jcharArray, elems::Ptr{jchar}, mode::jint)::Nothing

ReleaseShortArrayElements(array::jshortArray, elems::Ptr{jshort}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseShortArrayElements)(penv::Ptr{JNIEnv}, array::jshortArray, elems::Ptr{jshort}, mode::jint)::Nothing

ReleaseIntArrayElements(array::jintArray, elems::Ptr{jint}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseIntArrayElements)(penv::Ptr{JNIEnv}, array::jintArray, elems::Ptr{jint}, mode::jint)::Nothing

ReleaseLongArrayElements(array::jlongArray, elems::Ptr{jlong}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseLongArrayElements)(penv::Ptr{JNIEnv}, array::jlongArray, elems::Ptr{jlong}, mode::jint)::Nothing

ReleaseFloatArrayElements(array::jfloatArray, elems::Ptr{jfloat}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseFloatArrayElements)(penv::Ptr{JNIEnv}, array::jfloatArray, elems::Ptr{jfloat}, mode::jint)::Nothing

ReleaseDoubleArrayElements(array::jdoubleArray, elems::Ptr{jdouble}, mode::jint, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].ReleaseDoubleArrayElements)(penv::Ptr{JNIEnv}, array::jdoubleArray, elems::Ptr{jdouble}, mode::jint)::Nothing

GetBooleanArrayRegion(array::jbooleanArray, start::Integer, l::Integer, buf::Array{jboolean,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetBooleanArrayRegion)(penv::Ptr{JNIEnv}, array::jbooleanArray, start::jsize, l::jsize, buf::Ptr{jboolean})::Nothing

GetByteArrayRegion(array::jbyteArray, start::Integer, len::Integer, buf::Array{jbyte,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetByteArrayRegion)(penv::Ptr{JNIEnv}, array::jbyteArray, start::jsize, len::jsize, buf::Ptr{jbyte})::Nothing

GetCharArrayRegion(array::jcharArray, start::Integer, len::Integer, buf::Array{jchar,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetCharArrayRegion)(penv::Ptr{JNIEnv}, array::jcharArray, start::jsize, len::jsize, buf::Ptr{jchar})::Nothing

GetShortArrayRegion(array::jshortArray, start::Integer, len::Integer, buf::Array{jshort,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetShortArrayRegion)(penv::Ptr{JNIEnv}, array::jshortArray, start::jsize, len::jsize, buf::Ptr{jshort})::Nothing

GetIntArrayRegion(array::jintArray, start::Integer, len::Integer, buf::Array{jint,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetIntArrayRegion)(penv::Ptr{JNIEnv}, array::jintArray, start::jsize, len::jsize, buf::Ptr{jint})::Nothing

GetLongArrayRegion(array::jlongArray, start::Integer, len::Integer, buf::Array{jlong,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetLongArrayRegion)(penv::Ptr{JNIEnv}, array::jlongArray, start::jsize, len::jsize, buf::Ptr{jlong})::Nothing

GetFloatArrayRegion(array::jfloatArray, start::Integer, len::Integer, buf::Array{jfloat,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetFloatArrayRegion)(penv::Ptr{JNIEnv}, array::jfloatArray, start::jsize, len::jsize, buf::Ptr{jfloat})::Nothing

GetDoubleArrayRegion(array::jdoubleArray, start::Integer, len::Integer, buf::Array{jdouble,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetDoubleArrayRegion)(penv::Ptr{JNIEnv}, array::jdoubleArray, start::jsize, len::jsize, buf::Ptr{jdouble})::Nothing

SetBooleanArrayRegion(array::jbooleanArray, start::Integer, l::Integer, buf::Array{jboolean,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetBooleanArrayRegion)(penv::Ptr{JNIEnv}, array::jbooleanArray, start::jsize, l::jsize, buf::Ptr{jboolean})::Nothing

SetByteArrayRegion(array::jbyteArray, start::Integer, len::Integer, buf::Array{jbyte,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetByteArrayRegion)(penv::Ptr{JNIEnv}, array::jbyteArray, start::jsize, len::jsize, buf::Ptr{jbyte})::Nothing

SetCharArrayRegion(array::jcharArray, start::Integer, len::Integer, buf::Array{jchar,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetCharArrayRegion)(penv::Ptr{JNIEnv}, array::jcharArray, start::jsize, len::jsize, buf::Ptr{jchar})::Nothing

SetShortArrayRegion(array::jshortArray, start::Integer, len::Integer, buf::Array{jshort,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetShortArrayRegion)(penv::Ptr{JNIEnv}, array::jshortArray, start::jsize, len::jsize, buf::Ptr{jshort})::Nothing

SetIntArrayRegion(array::jintArray, start::Integer, len::Integer, buf::Array{jint,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetIntArrayRegion)(penv::Ptr{JNIEnv}, array::jintArray, start::jsize, len::jsize, buf::Ptr{jint})::Nothing

SetLongArrayRegion(array::jlongArray, start::Integer, len::Integer, buf::Array{jlong,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetLongArrayRegion)(penv::Ptr{JNIEnv}, array::jlongArray, start::jsize, len::jsize, buf::Ptr{jlong})::Nothing

SetFloatArrayRegion(array::jfloatArray, start::Integer, len::Integer, buf::Array{jfloat,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetFloatArrayRegion)(penv::Ptr{JNIEnv}, array::jfloatArray, start::jsize, len::jsize, buf::Ptr{jfloat})::Nothing

SetDoubleArrayRegion(array::jdoubleArray, start::Integer, len::Integer, buf::Array{jdouble,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].SetDoubleArrayRegion)(penv::Ptr{JNIEnv}, array::jdoubleArray, start::jsize, len::jsize, buf::Ptr{jdouble})::Nothing

RegisterNatives(clazz::jclass, methods::Array{JNINativeMethod,1}, nMethods::jint, penv::Ptr{JNIEnv}) =
  ccall(jniref[].RegisterNatives, jint, (Ptr{JNIEnv}, jclass, Ptr{JNINativeMethod}, jint,), penv, clazz, methods, nMethods)

UnregisterNatives(clazz::jclass, penv::Ptr{JNIEnv}) =
  ccall(jniref[].UnregisterNatives, jint, (Ptr{JNIEnv}, jclass,), penv, clazz)

MonitorEnter(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].MonitorEnter, jint, (Ptr{JNIEnv}, jobject,), penv, obj)

MonitorExit(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].MonitorExit, jint, (Ptr{JNIEnv}, jobject,), penv, obj)

GetJavaVM(vm::Array{JavaVM,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetJavaVM)(penv::Ptr{JNIEnv}, vm::Array{JavaVM,1})::jint

GetStringRegion(str::jstring, start::Integer, len::Integer, buf::Array{jchar,1}, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStringRegion)(penv::Ptr{JNIEnv}, str::jstring, start::jsize, len::jsize, buf::Ptr{jchar})::Nothing

GetStringUTFRegion(str::jstring, start::Integer, len::Integer, buf::AnyString, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetStringUTFRegion)(penv::Ptr{JNIEnv}, str::jstring, start::jsize, len::jsize, buf::Cstring)::Nothing

GetPrimitiveArrayCritical(array::jarray, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  ccall(jniref[].GetPrimitiveArrayCritical, Ptr{Nothing}, (Ptr{JNIEnv}, jarray, Ptr{jboolean},), penv, array, isCopy)

ReleasePrimitiveArrayCritical(array::jarray, carray::Ptr{Nothing}, mode::jint, penv::Ptr{JNIEnv}) =
  ccall(jniref[].ReleasePrimitiveArrayCritical, Nothing, (Ptr{JNIEnv}, jarray, Ptr{Nothing}, jint,), penv, array, carray, mode)

GetStringCritical(string::jstring, isCopy::PtrIsCopy, penv::Ptr{JNIEnv}) =
  ccall(jniref[].GetStringCritical, Ptr{jchar}, (Ptr{JNIEnv}, jstring, Ptr{jboolean},), penv, string, isCopy)

ReleaseStringCritical(string::jstring, cstring::Array{jchar,1}, penv::Ptr{JNIEnv}) =
  ccall(jniref[].ReleaseStringCritical, Nothing, (Ptr{JNIEnv}, jstring, Ptr{jchar},), penv, string, cstring)

NewWeakGlobalRef(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewWeakGlobalRef, jweak, (Ptr{JNIEnv}, jobject,), penv, obj)

DeleteWeakGlobalRef(ref::jweak, penv::Ptr{JNIEnv}) =
  ccall(jniref[].DeleteWeakGlobalRef, Nothing, (Ptr{JNIEnv}, jweak,), penv, ref)

ExceptionCheck(penv::Ptr{JNIEnv}) =
  ccall(jniref[].ExceptionCheck, jboolean, (Ptr{JNIEnv},), penv)

NewDirectByteBuffer(address::Ptr{Nothing}, capacity::jlong, penv::Ptr{JNIEnv}) =
  ccall(jniref[].NewDirectByteBuffer, jobject, (Ptr{JNIEnv}, Ptr{Nothing}, jlong,), penv, address, capacity)

GetDirectBufferAddress(buf::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetDirectBufferAddress)(penv::Ptr{JNIEnv}, buf::jobject)::Ptr{Nothing}

GetDirectBufferCapacity(buf::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetDirectBufferCapacity)(penv::Ptr{JNIEnv}, buf::jobject)::jlong

GetObjectRefType(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  @ccall gc_safe=true $(jniref[].GetObjectRefType)(penv::Ptr{JNIEnv}, obj::jobject)::jobjectRefType

IsVirtualThread(obj::jobject_arg, penv::Ptr{JNIEnv}) =
  ccall(jniref[].IsVirtualThread, jboolean, (Ptr{JNIEnv}, jobject,), penv, obj)


# === Above Generated by make_jni2.jl ===

end
