# Shared overload resolution for jcall / jnew / @jcall / JProxy.
# Given a receiver (or imported class type), a method name (or the constructor
# sentinel), and a tuple of Julia argument values, pick the Java overload and the
# Julia-side return type for the existing _jcall / jnew machinery. Cached.

"""
    ResolvedCall

The outcome of [`resolve_call`](@ref): the chosen Java `member` (a [`JMethod`](@ref)
or `JConstructor`), `paramtypes` (the Julia-side types of the *fixed* parameters —
for a non-varargs match that's every parameter; for a varargs match it's the
leading fixed ones, excluding the trailing array parameter), the Julia return type
`rettype` (`Nothing` for `void`; unused for constructors), and varargs info —
`varargs` is true when the match used the member's `T...` form, in which case
`n_fixed` is the number of leading fixed parameters and `vararg_eltype` is the
Julia element type of the trailing array.
"""
struct ResolvedCall
    member::Union{JMethod, JConstructor}
    paramtypes::Tuple
    rettype::Type
    varargs::Bool
    n_fixed::Int
    vararg_eltype::Union{Type,Nothing}
end

const _CONSTRUCTOR = :new       # used in place of a method name to mean "a constructor"

const _OVERLOAD_CACHE = Dict{Tuple{DataType,Symbol,Tuple}, ResolvedCall}()
const _OVERLOAD_LOCK  = ReentrantLock()

"""
    resolve_call(receiver, name, args::Tuple) -> ResolvedCall

Pick the best-matching Java method (`name::AbstractString`) or constructor
(`name === :new`) on `receiver` for the Julia argument values `args`, by a
quality-score ladder (exact > assignable/subclass > boxing/widening > varargs >
`nothing`→null). `receiver` may be a `JavaObject{T}` (instance) or a
`Type{JavaObject{T}}` (static / for constructors). Throws `JavaCallError` on an
ambiguous match (with the candidate signatures) or no match. Results are cached.
"""
function resolve_call(receiver, name, args::Tuple)
    key = (typeof(receiver), name isa Symbol ? name : Symbol(name), map(typeof, args))
    lock(_OVERLOAD_LOCK) do
        get!(_OVERLOAD_CACHE, key) do
            _resolve_call_uncached(receiver, name, args)
        end
    end
end

# --- candidate gathering ---------------------------------------------------

_candidates(receiver, name::AbstractString) = listmethods(receiver, String(name))
_candidates(receiver, name::Symbol) = name === _CONSTRUCTOR ? listconstructors(receiver) :
                                                              listmethods(receiver, String(name))

# Julia-side types for a member's declared parameters and (for methods) return.
_param_jtypes(member) = Type[jimport(c) for c in getparametertypes(member)]
_ret_jtype(member::JMethod) = jimport(getreturntype(member))
_ret_jtype(::JConstructor) = Nothing
_is_varargs(member) =
    try
        jcall(member, "isVarArgs", jboolean, ()) == 0x01
    catch
        false
    end

# --- scoring ladder --------------------------------------------------------

# Per-argument match tiers: lower is better. The per-candidate score is a *tier
# vector* whose position 0 is a phase marker (0 = fixed-arity match, 1 = varargs
# match) so any fixed-arity match lexicographically beats any varargs match
# (mirroring Java); the remaining entries are the per-argument tiers below.
# Differing-arity vectors are padded to equal length with `_T_REJECT + 1` (worse
# than any real tier) before comparison, so identical vectors register as a tie.
const _T_EXACT, _T_ASSIGN, _T_IMPLICIT, _T_NULL, _T_REJECT = 0, 1, 2, 3, 4

_classname(::Type{JavaObject{S}}) where {S} = String(S)
_classname(::Type{<:AbstractVector}) = ""          # arrays handled before this is called
_is_reference(ptype::Type) = ptype <: JavaObject || ptype <: AbstractVector

# For object element types we only have TYPES, not values, so we can't call
# isConvertible (which needs an object). Treat E === E' as exact and any
# JavaObject element against an Object[] element as assignable; otherwise reject.
_vec_assignable(E, E′) = E === E′ || (E <: JavaObject && E′ === JObject)

# Score one Julia arg value against one declared Julia param type. Returns a tier.
function _arg_tier(arg, ptype::Type)
    # primitives
    if ptype === jboolean
        return arg isa Bool ? _T_EXACT : _T_REJECT
    elseif ptype === jchar                                      # char (Julia Char is the natural analog)
        arg isa jchar && return _T_EXACT
        arg isa Char && return _T_EXACT
        return (arg isa Integer && !(arg isa Bool) && typemin(jchar) <= arg <= typemax(jchar)) ? _T_IMPLICIT : _T_REJECT
    elseif ptype <: Union{jbyte,jchar,jshort,jint,jlong}        # integer primitives
        arg isa Bool && return _T_REJECT
        arg isa Integer || return _T_REJECT
        return arg isa ptype ? _T_EXACT :
               (typemin(ptype) <= arg <= typemax(ptype)) ? _T_IMPLICIT : _T_REJECT
    elseif ptype <: Union{jfloat,jdouble}                       # float primitives
        return arg isa ptype ? _T_EXACT : (arg isa Real && !(arg isa Bool) ? _T_IMPLICIT : _T_REJECT)
    end
    # null
    arg === nothing && return ptype === Nothing ? _T_EXACT : (_is_reference(ptype) ? _T_NULL : _T_REJECT)
    # arrays (Vector{E} / JNIVector{E}  <->  E'[])
    if ptype <: AbstractVector
        arg isa AbstractVector || return _T_REJECT
        E′ = eltype(ptype)
        E  = eltype(arg)
        E === E′ && return _T_EXACT
        return _vec_assignable(E, E′) ? _T_ASSIGN : _T_REJECT
    end
    # reference types (ptype <: JavaObject)
    if ptype <: JavaObject
        pn = _classname(ptype)
        if arg isa AbstractString
            pn == "java.lang.String" && return _T_EXACT
            pn in ("java.lang.CharSequence", "java.lang.Object", "java.io.Serializable", "java.lang.Comparable") && return _T_ASSIGN
            return _T_REJECT
        elseif arg isa JavaObject
            _classname(typeof(arg)) == pn && return _T_EXACT
            try
                isConvertible(JavaObject{Symbol(pn)}, arg) && return _T_ASSIGN
            catch err
                @debug "isConvertible failed in overload resolution" exception=err
            end
            return _T_REJECT
        elseif arg isa Bool
            pn in ("java.lang.Boolean", "java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        elseif arg isa Char
            pn in ("java.lang.Character", "java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        elseif arg isa Integer
            pn in ("java.lang.Long", "java.lang.Integer", "java.lang.Short", "java.lang.Byte", "java.lang.Number", "java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        elseif arg isa AbstractFloat
            pn in ("java.lang.Double", "java.lang.Float", "java.lang.Number", "java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        end
        pn == "java.lang.Object" && return _T_IMPLICIT
        return _T_REJECT
    end
    return _T_REJECT
end

# Score a whole candidate. Returns (tier_vector::Vector{Int}, varargs::Bool, n_fixed, vararg_eltype)
# or `nothing` if the candidate can't take these args at all.
#
# Tier vector layout (so vectors of differing arity compare consistently):
#   fixed-arity match:  [0, t1, t2, ..., t_nargs]
#   varargs match:      [1, ft1, ..., ft_nfix, vt1, vt2, ...]
# The leading 0/1 phase marker guarantees any fixed-arity match beats any
# varargs match (mirroring Java), and within each phase the per-arg tiers break
# ties lexicographically. Vectors are padded to equal length with _T_REJECT+1
# (worse than anything) before comparison in `_resolve_call_uncached`.
function _score_candidate(member, args)
    ptypes = _param_jtypes(member)
    nargs  = length(args)
    isva   = _is_varargs(member)
    # --- plain fixed-arity attempt ---
    if length(ptypes) == nargs && !(isva && nargs >= 1)
        tiers = Int[0]
        for (a, p) in zip(args, ptypes)
            t = _arg_tier(a, p)
            t == _T_REJECT && return nothing
            push!(tiers, t)
        end
        return (tiers, false, nargs, nothing)
    end
    # --- varargs form ---
    if isva
        nfix = length(ptypes) - 1
        nargs >= nfix || return nothing
        E = eltype(ptypes[end])                          # ptypes[end] is Vector{E}
        tiers = Int[1]
        for i in 1:nfix
            t = _arg_tier(args[i], ptypes[i])
            t == _T_REJECT && return nothing
            push!(tiers, t)
        end
        if nargs == nfix + 1 && args[nfix+1] isa AbstractVector && _vec_assignable(eltype(args[nfix+1]), E)
            # case A: the single trailing arg is already an array assignable to E[]
            t = _arg_tier(args[nfix+1], ptypes[end])
            t == _T_REJECT && return nothing
            push!(tiers, t)
        else
            # case B: spread — each remaining arg must match E
            for i in (nfix+1):nargs
                t = _arg_tier(args[i], E)
                t == _T_REJECT && return nothing
                push!(tiers, t)
            end
        end
        return (tiers, true, nfix, E)
    end
    return nothing
end

function _subject_name(::Type{JavaObject{S}}) where {S}
    String(S)
end
_subject_name(o::JavaObject) = getname(getclass(o))
_subject_name(x) = string(x)

_membername(name) = name === _CONSTRUCTOR ? "<init>" : string(name)

function _resolve_call_uncached(receiver, name, args)
    cands = _candidates(receiver, name)
    if isempty(cands)
        throw(JavaCallError("jcall: no method/constructor `$(_membername(name))` on $(_subject_name(receiver))"))
    end
    scored = Tuple{Vector{Int}, Any, Bool, Int, Union{Type,Nothing}}[]
    for m in cands
        s = _score_candidate(m, args)
        s === nothing && continue
        push!(scored, (s[1], m, s[2], s[3], s[4]))
    end
    if isempty(scored)
        throw(JavaCallError("jcall: no overload of `$(_membername(name))` on $(_subject_name(receiver)) accepts argument types $(map(typeof, args)). Candidates: $(join(string.(cands), "; ")). Use the explicit jcall form to pick one."))
    end
    L = maximum(length(s[1]) for s in scored)
    pad(v) = length(v) == L ? v : vcat(v, fill(_T_REJECT + 1, L - length(v)))
    sort!(scored, by = s -> pad(s[1]))
    best = pad(scored[1][1])
    ties = filter(s -> pad(s[1]) == best, scored)
    if length(ties) > 1
        throw(JavaCallError("jcall: ambiguous call `$(_membername(name))` on $(_subject_name(receiver)) with $(map(typeof, args)) — $(length(ties)) overloads match equally well: $(join(string.(t[2] for t in ties), "; ")). Use the explicit jcall form to disambiguate."))
    end
    (_, member, isva, nfix, veltype) = scored[1]
    pj = _param_jtypes(member)
    paramtypes = Tuple(isva ? pj[1:end-1] : pj)
    return ResolvedCall(member, paramtypes, _ret_jtype(member), isva, nfix, veltype)
end
