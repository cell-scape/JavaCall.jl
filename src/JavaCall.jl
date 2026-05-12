module JavaCall

# Cuts runtests.jl time by one to two seconds
# https://github.com/JuliaLang/julia/pull/34896
@static if isdefined(Base, :Experimental) &&
           isdefined(Base.Experimental, Symbol("@optlevel"))
    Base.Experimental.@optlevel 1
end

export JavaObject, JavaMetaClass, JNIVector,
       jint, jlong, jbyte, jboolean, jchar, jshort, jfloat, jdouble, jvoid,
       JObject, JClass, JMethod, JConstructor, JField, JString,
       JavaRef, JavaLocalRef, JavaGlobalRef, JavaNullRef,
       @jimport, @jcall, jcall, jfield, jlocalframe, isnull,
       getname, getclass, listmethods, getreturntype, getparametertypes, classforname,
       listfields, gettype,
       narrow,
       is_virtual_thread,
       with_critical_array,
       JDirectBuffer

# using Compat, Compat.Dates

# using Sys: iswindows, islinux, isunix, isapple

import DataStructures: OrderedSet
using Dates

@static if Sys.iswindows()
    using WinReg
end


import Base: convert, unsafe_convert, unsafe_string, Ptr

include("JNI.jl")
using .JNI
include("jvm.jl")
include("env.jl")
include("dispatch.jl")
include("core.jl")
include("convert.jl")
include("reflect.jl")
include("jniarray.jl")
include("buffer.jl")
include("jcall_macro.jl")

Base.@deprecate_binding jnifunc JavaCall.JNI.jniref[]

function __init__()
    # No-op for now. The JVM lifecycle is owned by JavaCall.init() /
    # JavaCall.destroy() in src/jvm.jl, which spawn / stop the dispatch
    # task as part of init_new_vm. There's no per-Julia-process state
    # to set up here.
end


end # module
