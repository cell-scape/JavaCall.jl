module JProxies

import JavaCall: JavaCall, JNI,
        JavaObject, JavaMetaClass, JavaLocalRef, JavaGlobalRef,
        JString, JObject, JClass, JMethod, JConstructor, JField,
        jint, jlong, jbyte, jboolean, jchar, jshort, jfloat, jdouble, jvoid,
        @jimport, jcall, jnew, jfield, isnull, unsafe_string,
        getname, getclass, listmethods, listfields, getreturntype, getparametertypes,
        gettype, classforname, narrow, metaclass

import Base: getproperty, setproperty!, convert, show

export JProxy, jproxy, @jproxy, @jimport, unwrap

const _classdir = abspath(joinpath(@__DIR__, "..", "java"))

function __init__()
    # Register the bundled InvocationHandler class dir so `jproxy()` (M3) can find it.
    # Must run before JavaCall.init(); JavaCall's own __init__ only sets state, so
    # ordering across packages works as long as the user has not yet called init().
    isdir(_classdir) && JavaCall.addClassPath(_classdir)
end

"""
    JProxies.init(args...)

Convenience: forwards to `JavaCall.init`. Safe to call when you only need
`JProxy` dot-access.
"""
function init(args...)
    JavaCall.init(args...)
    return nothing
end

include("dotaccess.jl")
include("native.jl")
include("callbacks.jl")

end # module
