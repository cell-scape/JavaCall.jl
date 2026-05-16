# Dot-access on Java objects: JProxy(obj).method(args...) and JProxy(obj).field.
# No runtime eval; overload resolution is delegated to `JavaCall.resolve_call`.

"""
    JProxy(obj::JavaObject)        # instance methods + instance fields
    JProxy(::Type{JavaObject{T}})  # static methods + static fields

Ergonomic wrapper around a Java object (or class). `jp.name` is either a field
read (if `name` is a field) or a `JProxyMethod` that resolves overloads when
called. Use `unwrap(jp)` to drop back to the underlying `JavaObject` /
`Type{JavaObject{T}}` when you need explicit `jcall` control.

Field writes are not supported in this version; assign via the low-level
JavaCall API if you need them.

# Iteration

A `JProxy` wrapping a Java `Iterable`, `Collection`, `Set`, `List`, `Map`, Java
array, or raw `Iterator` is iterable. Each yielded value is passed through the
same Java→Julia decoding used for `JProxy.method(...)` results — so
`for s in JProxy(jstringList) … end` yields Julia `String`s, and
`for n in JProxy(jintList) … end` yields `jint`s. Map iteration yields Julia
`Pair{Any,Any}`, so `for (k, v) in JProxy(jmap) … end` destructures cleanly.
`length(JProxy(jp))` works for `Collection`, `Map`, and arrays; raw `Iterator`s
throw `ArgumentError` (no known size).
"""
struct JProxy{T, W}
    wrapped::W
end

JProxy(obj::JavaObject{T}) where {T} = JProxy{T, JavaObject{T}}(obj)
JProxy(::Type{JavaObject{T}}) where {T} = JProxy{T, Type{JavaObject{T}}}(JavaObject{T})

"""
    unwrap(jp::JProxy)

Return the wrapped `JavaObject` instance (or `Type{JavaObject{T}}` for a static
proxy) — the escape hatch back to the low-level `jcall`/`jfield` API.
"""
unwrap(jp::JProxy) = getfield(jp, :wrapped)

_is_static(::JProxy{T, Type{JavaObject{T}}}) where {T} = true
_is_static(::JProxy) = false

function show(io::IO, jp::JProxy{T}) where {T}
    if _is_static(jp)
        print(io, "JProxy(", JavaObject{T}, ")")
    else
        print(io, "JProxy{", T, "}(…)")
    end
end

# Boxed-primitive class name -> the Julia primitive to convert it to.
const _UNBOX_BY_NAME = Dict{String, DataType}(
    "java.lang.Boolean"   => jboolean,
    "java.lang.Byte"      => jbyte,
    "java.lang.Short"     => jshort,
    "java.lang.Integer"   => jint,
    "java.lang.Long"      => jlong,
    "java.lang.Float"     => jfloat,
    "java.lang.Double"    => jdouble,
)

# Bring a Java return value back into Julia-land: narrow to its runtime class,
# then convert Strings and boxed primitives to native Julia values. Other
# objects come back as a narrowed `JavaObject`. Non-`JavaObject` values
# (primitives that JavaCall already converted) pass through untouched.
function _juliafy(x)
    x isa JavaObject || return x
    isnull(x) && return nothing
    n = x isa JString ? x : narrow(x)
    n isa JString && return unsafe_string(n)
    cn = string(typeof(n).parameters[1])
    haskey(_UNBOX_BY_NAME, cn) && return convert(_UNBOX_BY_NAME[cn], n)
    return n
end

"""
    getproperty(jp::JProxy, name::Symbol)

`jp.name`: if `name` is a Java field, read it (and Julia-fy the value); otherwise
return a [`JProxyMethod`](@ref) bound to `name` for later overload-resolved calls.
"""
function getproperty(jp::JProxy, name::Symbol)
    w = unwrap(jp)
    flds = listfields(w, String(name))
    if !isempty(flds)
        # Pass the already-reflected JField to jfield to avoid a second
        # getFields() round-trip; jfield(ref, ::JField) auto-detects the field
        # type and works for both instance objects and Type{JavaObject{T}}.
        return _juliafy(jfield(w, flds[1]))
    end
    return JProxyMethod{typeof(jp)}(jp, name)
end

"""
    setproperty!(jp::JProxy, name::Symbol, value)

Always throws — `JProxy` does not support Java field writes; use the low-level
[`jfield`](@ref)-based JavaCall API instead.
"""
function setproperty!(jp::JProxy, name::Symbol, value)
    throw(ArgumentError("JProxy does not support field writes (v0.9.0); use the low-level JavaCall API"))
end

"""
    JProxyMethod{P}(jp::P, name::Symbol)

A bound, not-yet-resolved Java method. Calling it picks the best overload for the
given argument types via [`JavaCall.resolve_call`](@ref), dispatches via `jcall`
(instance or static — `jcall` dispatches on the wrapped value), and Julia-fies
the result (narrow + JString→String + boxed-primitive→Julia).
"""
struct JProxyMethod{P}
    jp::P
    name::Symbol
end

show(io::IO, m::JProxyMethod) = print(io, "JProxyMethod(", getfield(m, :name), ")")

function (m::JProxyMethod)(args...)
    w = unwrap(getfield(m, :jp))
    # Overload resolution (scoring ladder + cache) lives in JavaCall src/overload.jl.
    r = resolve_call(w, String(m.name), args)
    callargs = r.varargs ? _pack_varargs(r, args) : args
    # jcall(ref, method::JMethod, args...) derives rettype/argtypes from the
    # reflected method itself, and _jcallable(ref) routes static vs instance.
    # _juliafy (not _resolved_result): also unboxes java.lang.Integer/Double/…
    # to Julia primitives — required by the JProxy dot-access contract.
    return _juliafy(jcall(w, r.member::JMethod, callargs...))
end
