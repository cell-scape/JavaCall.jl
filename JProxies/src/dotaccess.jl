# Dot-access on Java objects: JProxy(obj).method(args...) and JProxy(obj).field.
# No runtime eval; overload resolution is a small quality-score ladder, cached.

"""
    JProxy(obj::JavaObject)        # instance methods + instance fields
    JProxy(::Type{JavaObject{T}})  # static methods + static fields

Ergonomic wrapper around a Java object (or class). `jp.name` is either a field
read (if `name` is a field) or a `JProxyMethod` that resolves overloads when
called. Use `unwrap(jp)` to drop back to the underlying `JavaObject` /
`Type{JavaObject{T}}` when you need explicit `jcall` control.

Field writes are not supported in this version; assign via the low-level
JavaCall API if you need them.
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
given argument types (cached), then dispatches via `jcall` (instance or static —
`jcall` dispatches on the wrapped value), and `narrow`s the result.
"""
struct JProxyMethod{P}
    jp::P
    name::Symbol
end

show(io::IO, m::JProxyMethod) = print(io, "JProxyMethod(", getfield(m, :name), ")")

const _RESOLVE_CACHE = Dict{Tuple{DataType, Symbol, Tuple}, JMethod}()
const _RESOLVE_LOCK = ReentrantLock()

function (m::JProxyMethod)(args...)
    jp = getfield(m, :jp)
    name = getfield(m, :name)
    w = unwrap(jp)
    argtypes = map(typeof, args)
    key = (typeof(w), name, argtypes)
    method = lock(_RESOLVE_LOCK) do
        get!(_RESOLVE_CACHE, key) do
            _resolve_overload(w, name, args)
        end
    end
    # jcall(ref, method::JMethod, args...) derives rettype/argtypes from the
    # reflected method itself, and _jcallable(ref) routes static vs instance.
    return _juliafy(jcall(w, method, args...))
end

# --- overload resolution: quality-score ladder ---------------------------------
# Tiers (lower = better): 0 exact, 1 derived (subclass), 2 implicit (box/widen),
# 3 not-reachable-without-explicit-convert => candidate rejected.
const _TIER_EXACT, _TIER_DERIVED, _TIER_IMPLICIT, _TIER_NONE = 0, 1, 2, 3

const _PRIM_BY_NAME = Dict{String, DataType}(
    "boolean" => jboolean, "byte" => jbyte, "char" => jchar, "short" => jshort,
    "int" => jint, "long" => jlong, "float" => jfloat, "double" => jdouble,
)

function _arg_tier(arg, paramcls::JClass)
    pn = getname(paramcls)
    # primitive parameter
    if haskey(_PRIM_BY_NAME, pn)
        pjt = _PRIM_BY_NAME[pn]
        # `boolean` is a special case: Julia `Bool` is its natural type, and a
        # non-Bool must never be silently routed through the integer-widening
        # branch below (jboolean === UInt8 in JavaCall).
        if pn == "boolean"
            return arg isa Bool ? _TIER_EXACT : _TIER_NONE
        end
        arg isa pjt && return _TIER_EXACT
        if pjt <: Integer && arg isa Integer
            (typemin(pjt) <= arg <= typemax(pjt)) && return _TIER_IMPLICIT
            return _TIER_NONE
        end
        if pjt <: AbstractFloat && arg isa Real && !(arg isa Bool)
            return _TIER_IMPLICIT
        end
        return _TIER_NONE
    end
    # reference parameter
    if arg isa AbstractString
        (pn == "java.lang.String" || pn == "java.lang.CharSequence" || pn == "java.lang.Object") && return _TIER_DERIVED
        return _TIER_NONE
    end
    if arg isa JavaObject
        actual = getname(getclass(arg))
        actual == pn && return _TIER_EXACT
        try
            JavaCall.isConvertible(JavaObject{Symbol(pn)}, arg) && return _TIER_DERIVED
        catch err
            @debug "isConvertible check failed in overload resolution" exception=err
        end
        return _TIER_NONE
    end
    if arg isa Bool
        (pn == "java.lang.Boolean" || pn == "java.lang.Object") && return _TIER_IMPLICIT
        return _TIER_NONE
    end
    if arg isa Integer
        (pn in ("java.lang.Long", "java.lang.Integer", "java.lang.Number", "java.lang.Object")) && return _TIER_IMPLICIT
        return _TIER_NONE
    end
    if arg isa AbstractFloat
        (pn in ("java.lang.Double", "java.lang.Float", "java.lang.Number", "java.lang.Object")) && return _TIER_IMPLICIT
        return _TIER_NONE
    end
    pn == "java.lang.Object" && return _TIER_IMPLICIT
    return _TIER_NONE
end

function _resolve_overload(w, name::Symbol, args)
    candidates = listmethods(w, String(name))
    isempty(candidates) && throw(ArgumentError("no method $(String(name)) on $(typeof(w))"))
    nargs = length(args)
    scored = Tuple{Vector{Int}, JMethod}[]
    for mth in candidates
        ptypes = getparametertypes(mth)
        length(ptypes) == nargs || continue
        tiers = Int[]
        ok = true
        for (a, pc) in zip(args, ptypes)
            t = _arg_tier(a, pc)
            if t == _TIER_NONE
                ok = false
                break
            end
            push!(tiers, t)
        end
        ok && push!(scored, (tiers, mth))
    end
    isempty(scored) && throw(ArgumentError(
        "no overload of $(String(name)) on $(typeof(w)) accepts argument types $(map(typeof, args))"))
    sort!(scored, by = first)
    best_score = first(scored[1])
    ties = filter(s -> first(s) == best_score, scored)
    length(ties) > 1 && throw(ArgumentError(
        "ambiguous call $(String(name))$(map(typeof, args)): $(length(ties)) overloads match equally well"))
    return scored[1][2]
end
