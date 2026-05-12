# Phase 3 — `jcall` / `@jcall` / `jnew` Overload Resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add purely-additive call forms — `jcall(receiver, "method", args...)`, `jnew(T, args...)`, and an annotation-free `@jcall receiver.method(args...)` — that resolve the Java overload and return type from reflection, backed by one shared resolver (`src/overload.jl`) that JProxies also uses (its duplicate resolver is then deleted).

**Architecture:** A new `src/overload.jl` exposes `resolve_call(receiver, name, args) -> ResolvedCall` (quality-score ladder: exact > subclass/assignable > boxing/widening > Java varargs > `nothing`→null; ambiguous → throw), cached behind a lock. The new `jcall`/`jnew` methods are thin wrappers that call `resolve_call`, pack varargs if needed, dispatch through the *existing* `jcall(receiver, ::JMethod, args...)` / `jnew(T::Symbol, argtypes, args...)` machinery, and narrow the result. `@jcall` gains an annotation-free branch in its macro lowering. `JProxies/src/dotaccess.jl` is rewired onto `JavaCall.resolve_call` and its private resolver deleted.

**Tech Stack:** Julia 1.12+, JavaCall's existing reflection (`listmethods`, `getparametertypes`, `getreturntype`, `jimport(::JClass)`) and JNI dispatch (`_jcall`, `jcall(_, ::JMethod, _...)`), `isConvertible`/`IsAssignableFrom`, `narrow`/`convert`.

**Spec:** `docs/superpowers/specs/2026-05-12-phase-3-jcall-overload-resolution-design.md`. Read it first.

---

## File Structure

### Created
- `src/overload.jl` — the shared resolver. `ResolvedCall` struct; `resolve_call`; the scoring ladder (`_arg_tier`, `_score_candidate`); the cache (`_OVERLOAD_CACHE` + `_OVERLOAD_LOCK`); the `_CONSTRUCTOR` sentinel; error helpers. ~180 lines. Included from `JavaCall.jl` *after* `reflect.jl` and `convert.jl` (it uses `listmethods`/`getparametertypes`/`jimport`/`isConvertible`).

### Modified
- `src/JavaCall.jl` — `include("overload.jl")` (after `convert.jl`/`reflect.jl`); `export listconstructors`.
- `src/reflect.jl` — add `listconstructors(::JClass)` / `listconstructors(::Type{JavaObject{C}})` / `listconstructors(::JavaObject)`; add `Base.show(::IO, ::JConstructor)` (for error messages).
- `src/core.jl` — add `jcall(ref, method::AbstractString, args...)` (resolved form) and `jnew(::Type{JavaObject{T}}, args...) where T` (resolved form); a `_pack_varargs` helper and a `_resolved_result` helper (both `module`-internal). Nothing existing is changed.
- `src/jcall_macro.jl` — `jcall_macro_parse` returns enough info to detect "all-annotated" vs "none-annotated" vs "mixed"; `jcall_macro_lower` gains the annotation-free branch and the mixed-form error.
- `JProxies/src/dotaccess.jl` — delete `_resolve_overload`, `_arg_tier`, `_PRIM_BY_NAME`, `_RESOLVE_CACHE`, `_RESOLVE_LOCK`; rewrite `JProxyMethod`'s call operator and the `getproperty` method-dispatch path to call `JavaCall.resolve_call` + the core `jcall(_, ::JMethod, _...)`.
- `JProxies/src/JProxies.jl` — add `resolve_call` (and any new helpers it needs) to the `import JavaCall: ...` list.
- `test/Test.java` — add overloaded + varargs test methods; recompile `test/Test.class`.
- `test/runtests.jl`, `test/jcall_macro.jl` — new testsets.

### Why a new file for the resolver
The resolver is one cohesive responsibility (reflection-driven overload selection) that three callers share (`jcall`, `jnew`/`@jcall`, `JProxy`). Keeping it in its own file makes it reviewable in one screen and keeps `core.jl` (already large) from growing further. It can't live in `reflect.jl` (it needs `convert.jl`'s `isConvertible`) or `convert.jl` (it needs `reflect.jl`'s `listmethods`), so it's its own include after both.

---

## Branch Organization

Same multi-branch workflow as Phase 2. Each milestone is one branch off `master`, ends with a full test pass, then `git merge --no-ff` to master. Fixups get `phase-3/<name>-fixup` branches. Don't push to any remote.

1. `phase-3/overload-resolver` — `src/overload.jl` + `listconstructors` + `Test.java` fixtures + direct `resolve_call` tests. (No `jcall`/`@jcall` change yet.)
2. `phase-3/jcall-resolved` — the resolved `jcall(...)` / `jnew(...)` forms wired onto the resolver, with narrowing + vararg packing.
3. `phase-3/jcall-macro-resolved` — the annotation-free `@jcall` form + the mixed-form error.
4. `phase-3/jproxies-on-core-resolver` — JProxies delegates to the core resolver; the duplicate is deleted.

Order matters: 2 depends on 1; 3 depends on 2 (lowers to the resolved `jcall`); 4 depends on 1 (and is cleanest after 2/3 land).

---

## Milestone 1: phase-3/overload-resolver

**Branch:** `phase-3/overload-resolver`

### Task 1.1: Create branch

- [ ] **Step 1**
```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master && git pull origin master
git checkout -b phase-3/overload-resolver
```

### Task 1.2: Add Java test fixtures and recompile

**Files:**
- Modify: `test/Test.java` (add static methods inside `public class Test { ... }`, before the closing brace)

- [ ] **Step 1: Add the methods**

Add to `test/Test.java`:

```java
  // --- Phase 3 overload-resolution fixtures ---

  public static int sumVarargs(int... xs) {
    int s = 0;
    for (int x : xs) s += x;
    return s;
  }

  public static String joinVarargs(String sep, Object... parts) {
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < parts.length; i++) { if (i > 0) b.append(sep); b.append(parts[i]); }
    return b.toString();
  }

  public static String overloaded(int x)    { return "int"; }
  public static String overloaded(String x) { return "String"; }
  public static String overloaded(Object x) { return "Object"; }

  // Genuinely ambiguous under a conservative (no most-specific) ladder:
  public static String widen(long x)   { return "long"; }
  public static String widen(double x) { return "double"; }
```

- [ ] **Step 2: Recompile**
```bash
cd /Users/brad/Projects/JavaCall.jl
javac test/Test.java
git add test/Test.java test/Test.class test/Test\$TestInner.class
```
(`javac` may also touch `Test$TestInner.class` — include it if `git status` shows it changed.)

### Task 1.3: Add `listconstructors` and `JConstructor` show to `reflect.jl`

**Files:**
- Modify: `src/reflect.jl` (near `listmethods`)
- Modify: `src/JavaCall.jl` (export)

- [ ] **Step 1: Write a failing test**

In `test/runtests.jl`, add (you'll grow this testset over the milestone):

```julia
@testset "Phase 3: listconstructors" begin
    JArrayList = @jimport java.util.ArrayList
    ctors = listconstructors(JArrayList)
    @test ctors isa Vector
    @test !isempty(ctors)
    @test eltype(ctors) <: JavaObject   # they're JConstructor === JavaObject{Symbol("java.lang.reflect.Constructor")}
    # at least one no-arg and one int-arg ctor:
    nparams = [length(getparametertypes(c)) for c in ctors]
    @test 0 in nparams
    @test 1 in nparams
end
```

- [ ] **Step 2: Run it, expect failure**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using JavaCall; JavaCall.init(); println(listconstructors)'
```
Expected: `UndefVarError: listconstructors`.

- [ ] **Step 3: Implement**

In `src/reflect.jl`, after the `listmethods(cls::JClass)` method, add:

```julia
"""
    listconstructors(c) -> Vector{JConstructor}

The public constructors of the class denoted by `c` (a [`JClass`](@ref), a
`JavaObject{T}` instance, or a `Type{JavaObject{T}}`). Mirrors [`listmethods`](@ref);
used by the overload resolver for `jnew`.
"""
listconstructors(cls::JClass) = jcall(cls, "getConstructors", Vector{JConstructor}, ())
listconstructors(::Type{JavaObject{C}}) where {C} = listconstructors(classforname(string(C)))
listconstructors(obj::JavaObject) = listconstructors(getclass(obj))
```

Also add a `show` for `JConstructor` (next to the `Base.show(::IO, ::JMethod)`):

```julia
function Base.show(io::IO, ctor::JConstructor)
    ptypes = [getname(c) for c in getparametertypes(ctor)]
    print(io, "<init>(", join(ptypes, ", "), ")")
end
```

In `src/JavaCall.jl`, add `listconstructors` to the `export` line (next to `listmethods`).

- [ ] **Step 4: Run the test**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "Phase 3: listconstructors|JavaCall tests"
```
Expected: the testset passes, suite passes.

- [ ] **Step 5: Commit**
```bash
git add src/reflect.jl src/JavaCall.jl test/runtests.jl test/Test.java test/Test.class test/Test\$TestInner.class
git commit -m "Add listconstructors + JConstructor show; Phase 3 Java test fixtures"
```

### Task 1.4: Implement `src/overload.jl` — `ResolvedCall`, cache, candidate gathering

**Files:**
- Create: `src/overload.jl`
- Modify: `src/JavaCall.jl` (`include`)

- [ ] **Step 1: Create the file skeleton**

```julia
# Shared overload resolution for jcall / jnew / @jcall / JProxy.
# Given a receiver (or imported class type), a method name (or the constructor
# sentinel), and a tuple of Julia argument values, pick the Java overload and the
# Julia-side return type for the existing _jcall / jnew machinery. Cached.

"""
    ResolvedCall

The outcome of [`resolve_call`](@ref): the chosen Java `member` (a [`JMethod`](@ref)
or `JConstructor`), the Julia return type `rettype` (`Nothing` for `void`; unused
for constructors), and varargs info — `varargs` is true when the match used the
member's `T...` form, in which case `n_fixed` is the number of leading fixed
parameters and `vararg_eltype` is the Julia element type of the trailing array.
"""
struct ResolvedCall
    member::JavaObject          # JMethod or JConstructor (both are JavaObject aliases)
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
_candidates(receiver, ::typeof(_CONSTRUCTOR)) = listconstructors(receiver)
# allow passing the Symbol :new too
_candidates(receiver, name::Symbol) = name === _CONSTRUCTOR ? listconstructors(receiver) :
                                                              listmethods(receiver, String(name))

# Julia-side types for a member's declared parameters and (for methods) return.
_param_jtypes(member) = Type[jimport(c) for c in getparametertypes(member)]
_ret_jtype(member::JMethod) = jimport(getreturntype(member))
_ret_jtype(::Any) = Nothing            # constructors: no return type slot used
_is_varargs(member) = jcall(member, "isVarArgs", jboolean, ()) == 0x01
```

Notes for the implementer:
- `JMethod`/`JConstructor` are both `JavaObject{Symbol("…reflect.Method/Constructor")}`, so the `member` field is typed `JavaObject` (concrete enough; don't over-specialize). `_ret_jtype(::Any)` covers the constructor case — verify a cleaner dispatch (`_ret_jtype(::JMethod)` / a fallback) if you prefer.
- `jimport(::JClass)` already maps primitive classes to `jint`/etc., array classes to `Vector{...}`, and reference classes to `JavaObject{...}` — reuse it, don't reinvent a primitive table.
- `isVarArgs` is a `java.lang.reflect.Method`/`Constructor` instance method; if `jcall(member, "isVarArgs", jboolean, ())` ever fails (some JDK weirdness), fall back to `false` — but it shouldn't.

- [ ] **Step 2: Wire the include**

In `src/JavaCall.jl`, add `include("overload.jl")` *after* `include("convert.jl")` and `include("reflect.jl")` (so `isConvertible`, `listmethods`, `jimport`, `narrow` are all defined). Don't export anything from it yet beyond what `core.jl` will use internally (`resolve_call` is module-internal; `JProxies` reaches it via `JavaCall.resolve_call`).

- [ ] **Step 3: Smoke-load**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using JavaCall; JavaCall.init(); println(JavaCall.resolve_call)'
```
Expected: prints `resolve_call` (no syntax/order errors).

### Task 1.5: Implement the scoring ladder and `_resolve_call_uncached`

**Files:**
- Modify: `src/overload.jl` (append)

- [ ] **Step 1: Write failing tests**

In `test/runtests.jl`:

```julia
@testset "Phase 3: resolve_call" begin
    JTest = @jimport Test
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    rc(recv, name, args...) = JavaCall.resolve_call(recv, name, args)

    # exact primitive
    @test JavaCall.getname(JavaCall.getreturntype(rc(JTest, "testInt", Int32(3)).member)) == "int"
    # static String overload picked over Object overload
    @test JavaCall.getname(rc(JTest, "overloaded", "x").member) == "overloaded"  # name
    pt(m) = [JavaCall.getname(c) for c in JavaCall.getparametertypes(m)]
    @test pt(rc(JTest, "overloaded", "x").member) == ["java.lang.String"]
    @test pt(rc(JTest, "overloaded", Int32(1)).member) == ["int"]
    # boxing/widening: Julia Int -> int (or long); just assert it resolves to a numeric primitive
    @test pt(rc(JMath, "abs", -3).member)[1] in ("int", "long")
    # instance, no-arg
    al = jcall(JArrayList, (), )  # explicit empty-ctor — actually: JArrayList(()) ; use that:
end
```

Hmm — fix that last line: constructing an empty `ArrayList` via the explicit form is `JArrayList((),)` or `JavaObject{Symbol("java.util.ArrayList")}((),)`. Use:

```julia
@testset "Phase 3: resolve_call" begin
    JTest = @jimport Test
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    rc(recv, name, args...) = JavaCall.resolve_call(recv, name, args)
    pn(c) = JavaCall.getname(c)
    pt(m) = String[pn(c) for c in JavaCall.getparametertypes(m)]

    # exact primitive return-type pulled from reflection
    @test pn(JavaCall.getreturntype(rc(JTest, "testInt", Int32(3)).member)) == "int"
    # static overload set: String > Object for a Julia String; exact int for Int32
    @test pt(rc(JTest, "overloaded", "x").member)     == ["java.lang.String"]
    @test pt(rc(JTest, "overloaded", Int32(1)).member) == ["int"]
    # numeric widening: Int -> a numeric primitive (we don't promise which)
    @test pt(rc(JMath, "abs", -3).member)[1] in ("int", "long")
    # instance method on an actual object
    al = JArrayList((),)                                # explicit empty-ctor
    @test pt(rc(al, "add", "one").member) == ["java.lang.Object"]
    # varargs: sumVarargs(int...) — member is the varargs method, marked varargs
    r = rc(JTest, "sumVarargs", Int32(1), Int32(2), Int32(3))
    @test r.varargs == true
    @test r.vararg_eltype === JavaCall.jint
    @test r.n_fixed == 0
    # passing the array directly to a varargs method
    r2 = rc(JTest, "sumVarargs", JavaCall.jint[1,2,3])
    @test r2.varargs == true   # still the varargs member; packing decided at call site
    # array-parameter overload: Vector{jint} -> int[]
    @test pt(rc(JTest, "testArrayArgs", JavaCall.jint[1,2]).member) == ["int"]   # NOTE: getName of int[] is "[I"
    # nothing -> null reference param
    @test pt(rc(JTest, "testString", nothing).member) == ["java.lang.String"]
    # ambiguity: widen(long) vs widen(double) with a Julia Int -> throw
    @test_throws JavaCall.JavaCallError rc(JTest, "widen", 3)
    # no match
    @test_throws JavaCall.JavaCallError rc(al, "add", 1, 2, 3)
end
```

(The `testArrayArgs` assertion: `getName()` of `int[]` is `"[I"`, not `"int"` — adjust the expected string after you see what `getname(JClass)` returns for an array class; the point is it picks the `int[]` overload, not `int[][]`/`Object[]`/`int`.)

- [ ] **Step 2: Run, expect failure** (`_resolve_call_uncached` undefined).

- [ ] **Step 3: Implement the ladder**

Append to `src/overload.jl`:

```julia
# Tiers: lower is better. 3 is the *summarizing* tier for a varargs match (so any
# fixed-arity match beats any varargs match, mirroring Java). 4 = nothing->null.
const _T_EXACT, _T_ASSIGN, _T_IMPLICIT, _T_VARARG, _T_NULL, _T_REJECT = 0, 1, 2, 3, 4, 5

# Score one Julia arg value against one declared Julia param type.
function _arg_tier(arg, ptype::Type)
    # primitives
    if ptype === jboolean
        return arg isa Bool ? _T_EXACT : _T_REJECT
    elseif ptype <: Union{jbyte,jchar,jshort,jint,jlong}        # integer primitives
        arg isa Bool && return _T_REJECT
        arg isa Integer || return _T_REJECT
        return arg isa ptype ? _T_EXACT :
               (typemin(ptype) <= arg <= typemax(ptype)) ? _T_IMPLICIT : _T_REJECT
    elseif ptype <: Union{jfloat,jdouble}                       # float primitives
        return arg isa ptype ? _T_EXACT : (arg isa Real ? _T_IMPLICIT : _T_REJECT)
    end
    # null
    arg === nothing && return ptype === Nothing ? _T_EXACT : (_is_reference(ptype) ? _T_NULL : _T_REJECT)
    # arrays (Vector{E} / JNIVector{E}  <->  E'[])
    if ptype <: AbstractVector
        E′ = eltype(ptype)
        arg isa AbstractVector || return _T_REJECT
        E = eltype(arg)
        E === E′ && return _T_EXACT
        return _vec_assignable(E, E′) ? _T_ASSIGN : _T_REJECT
    end
    # reference types (ptype <: JavaObject)
    if ptype <: JavaObject
        pn = _classname(ptype)                 # the fully-qualified name from the type param
        if arg isa AbstractString
            pn == "java.lang.String"      && return _T_EXACT
            pn in ("java.lang.CharSequence","java.lang.Object","java.io.Serializable","java.lang.Comparable") && return _T_ASSIGN
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
            pn in ("java.lang.Boolean","java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        elseif arg isa Integer
            pn in ("java.lang.Long","java.lang.Integer","java.lang.Short","java.lang.Byte","java.lang.Number","java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        elseif arg isa AbstractFloat
            pn in ("java.lang.Double","java.lang.Float","java.lang.Number","java.lang.Object") && return _T_IMPLICIT
            return _T_REJECT
        end
        pn == "java.lang.Object" && return _T_IMPLICIT
        return _T_REJECT
    end
    return _T_REJECT
end

_is_reference(ptype::Type) = ptype <: JavaObject || ptype <: AbstractVector
_classname(::Type{JavaObject{S}}) where {S} = String(S)
_classname(::Type{<:AbstractVector}) = ""          # arrays handled before this is called
_vec_assignable(E, E′) = E === E′ ||
    (E <: JavaObject && E′ <: JavaObject && isConvertible(JavaObject{Symbol(_classname(E′))}, ...))   # see note

# NOTE on _vec_assignable for object element types: a clean implementation needs an
# *object* (not a type) to call isConvertible — but here we only have element TYPES.
# For v1: treat E === E′ as exact; treat (E <: JavaObject, E′ === JObject) as ASSIGN
# (anything[] -> Object[] is the common case); otherwise REJECT. Refine if a real
# test needs more. So:
#   _vec_assignable(E, E′) = E === E′ ? true : (E <: JavaObject && E′ === JObject)

# Score a whole candidate. Returns (tier_vector::Vector{Int}, varargs::Bool, n_fixed, vararg_eltype)
# or `nothing` if the candidate can't take these args at all.
function _score_candidate(member, args)
    ptypes = _param_jtypes(member)
    nargs  = length(args)
    isva   = _is_varargs(member)
    # --- fixed-arity attempt ---
    if length(ptypes) == nargs && !(isva && nargs >= 1)   # plain fixed match (a varargs member can also match fixed-arity by passing the array as the last arg — handled below)
        tiers = Int[]
        for (a, p) in zip(args, ptypes)
            t = _arg_tier(a, p); t == _T_REJECT && return nothing
            push!(tiers, t)
        end
        return (tiers, false, nargs, nothing)
    end
    # --- if this member is varargs, try the vararg form ---
    if isva
        nfix = length(ptypes) - 1
        nargs >= nfix || return nothing
        E = eltype(ptypes[end])                          # ptypes[end] is Vector{E}
        tiers = Int[]
        for i in 1:nfix
            t = _arg_tier(args[i], ptypes[i]); t == _T_REJECT && return nothing
            push!(tiers, t)
        end
        # case A: exactly one extra arg and it's already an array assignable to E[]
        if nargs == nfix + 1 && args[nfix+1] isa AbstractVector && _vec_assignable(eltype(args[nfix+1]), E)
            push!(tiers, _arg_tier(args[nfix+1], ptypes[end]))
        else
            # case B: spread — each remaining arg must match E
            for i in (nfix+1):nargs
                t = _arg_tier(args[i], E); t == _T_REJECT && return nothing
                push!(tiers, t)
            end
            isempty((nfix+1):nargs) || nothing            # empty varargs is fine
        end
        # summarize: a varargs match is never better than _T_VARARG (=3)
        summarized = Int[min(t, _T_VARARG) for t in tiers]   # actually: keep fixed tiers, clamp the vararg-portion floor — see note
        return (summarized, true, nfix, E)
    end
    return nothing
end
```

**Implementer notes (this is the fiddliest task — read carefully):**
- The "summarize" step needs to make tier vectors *comparable across candidates of different arity*. Simplest correct scheme: a vararg candidate's vector = `[fixed tiers...,  _T_VARARG]` (one trailing entry, not one-per-vararg-arg), and a fixed candidate's vector keeps its per-arg tiers; pad the shorter vector with `_T_REJECT+1` (i.e. "worst") so lexicographic compare is well-defined. Re-derive this so it's *consistent* — the exact padding doesn't matter as long as (a) fixed beats vararg when both match, (b) within fixed matches the per-arg lexicographic order holds, (c) ties (identical vectors) are detected. Write a couple of unit tests for the comparator itself if it helps.
- `_vec_assignable` for object element types: go with the simple `E === E′ ? true : (E <: JavaObject && E′ === JObject)` (don't try `isConvertible` on types). The `JObject` here is `JavaCall.JObject` = `JavaObject{Symbol("java.lang.Object")}`.
- `isConvertible(JavaObject{Symbol(pn)}, arg)` — `isConvertible` is in `convert.jl`, takes a *target type* and a *value*; backed by `IsAssignableFrom`. Confirm the arg order against `convert.jl`.
- Don't worry about Java generics — erasure means `getParameterTypes` already gives you raw types.

- [ ] **Step 4: Implement `_resolve_call_uncached`**

Append:

```julia
function _resolve_call_uncached(receiver, name, args)
    cands = _candidates(receiver, name)
    if isempty(cands)
        throw(JavaCallError("jcall: no method/constructor `$(name === _CONSTRUCTOR ? "<init>" : name)` on $(_subject_name(receiver))"))
    end
    scored = Tuple{Vector{Int}, Any, Bool, Int, Union{Type,Nothing}}[]   # (vec, member, varargs, n_fixed, vararg_eltype)
    for m in cands
        s = _score_candidate(m, args)
        s === nothing && continue
        push!(scored, (s[1], m, s[2], s[3], s[4]))
    end
    if isempty(scored)
        throw(JavaCallError("jcall: no overload of `$(name === _CONSTRUCTOR ? "<init>" : name)` on $(_subject_name(receiver)) accepts argument types $(map(typeof, args)). Candidates: $(join(string.(cands), "; ")). Use the explicit jcall form to pick one."))
    end
    # lexicographic min over the tier vectors, with vectors padded to equal length
    L = maximum(length(s[1]) for s in scored)
    pad(v) = vcat(v, fill(_T_REJECT + 1, L - length(v)))
    sort!(scored, by = s -> pad(s[1]))
    best = pad(scored[1][1])
    ties = filter(s -> pad(s[1]) == best, scored)
    if length(ties) > 1
        throw(JavaCallError("jcall: ambiguous call `$(name === _CONSTRUCTOR ? "<init>" : name)` on $(_subject_name(receiver)) with $(map(typeof, args)) — $(length(ties)) overloads match equally well: $(join(string.(t[2] for t in ties), "; ")). Use the explicit jcall form to disambiguate."))
    end
    (_, member, isva, nfix, veltype) = scored[1]
    return ResolvedCall(member, _ret_jtype(member), isva, nfix, veltype)
end

_subject_name(t::Type{JavaObject{S}}) where {S} = String(S)
_subject_name(o::JavaObject) = getname(getclass(o))
```

- [ ] **Step 5: Run the tests**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "Phase 3: resolve_call|JavaCall tests|Test Summary"
```
Expected: the `Phase 3: resolve_call` and `Phase 3: listconstructors` testsets pass; suite passes. Iterate on `_arg_tier` / `_score_candidate` / the comparator until green. (Adjust the `testArrayArgs` expected string once you see `getname` of an array class.)

- [ ] **Step 6: Commit**
```bash
git add src/overload.jl src/JavaCall.jl test/runtests.jl
git commit -m "Add src/overload.jl: shared overload resolver (resolve_call)"
```

### Task 1.6: Merge to master
```bash
git checkout master && git merge --no-ff phase-3/overload-resolver -m "Merge branch 'phase-3/overload-resolver'"
```

---

## Milestone 2: phase-3/jcall-resolved

**Branch:** `phase-3/jcall-resolved`

Wire the new resolved `jcall` / `jnew` forms onto `resolve_call`, with varargs packing and result narrowing.

### Task 2.1: Create branch
```bash
git checkout master && git pull origin master && git checkout -b phase-3/jcall-resolved
```

### Task 2.2: Add the resolved `jcall` form

**Files:**
- Modify: `src/core.jl` (add a new `jcall` method + two helpers; do NOT touch the existing methods)

- [ ] **Step 1: Write failing tests** — in `test/runtests.jl`:

```julia
@testset "Phase 3: jcall resolved form" begin
    JTest = @jimport Test
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    JSystem = @jimport java.lang.System

    # static, exact + widening
    @test jcall(JMath, "abs", Int32(-3)) == 3
    @test jcall(JTest, "testInt", 7) == 7                     # Int -> int (widening with range OK)
    @test jcall(JTest, "testString", "hi") == "hi"            # String return -> Julia String
    # static overload selection
    @test jcall(JTest, "overloaded", "x")    == "String"
    @test jcall(JTest, "overloaded", Int32(1)) == "int"
    # instance
    al = JArrayList((),)
    @test jcall(al, "add", "one") == true
    @test jcall(al, "size") == 1
    @test jcall(al, "get", 0) == "one"                        # narrowed/converted to Julia String
    @test jcall(al, "isEmpty") == false
    # static with a system property (String return)
    @test jcall(JSystem, "getProperty", "java.version") isa AbstractString
    # varargs: spread and array forms
    @test jcall(JTest, "sumVarargs", 1, 2, 3, 4) == 10
    @test jcall(JTest, "sumVarargs") == 0
    @test jcall(JTest, "sumVarargs", JavaCall.jint[5, 6]) == 11
    @test jcall(JTest, "joinVarargs", "-", "a", "b", "c") == "a-b-c"
    # nothing -> null
    @test jcall(JTest, "testString", nothing) === nothing || jcall(JTest, "testString", nothing) == ""  # Java returns the arg, which is null; convert(String, null) -> ? — see note
    # ambiguity & no-match
    @test_throws JavaCall.JavaCallError jcall(JTest, "widen", 3)
    @test_throws JavaCall.JavaCallError jcall(al, "add", 1, 2, 3)
    # explicit form unchanged (regression)
    @test jcall(JTest, "testInt", jint, (jint,), Int32(9)) == 9
end
```

(The `testString(nothing)` line: `testString(String)` returns its argument; passing `null` returns `null`; the resolved form's return type is `JString`; converting a null `JString` back to Julia — decide the contract in Step 3. If it's awkward, replace this assertion with one against a method that takes `Object` and returns `void`, e.g. `jcall(JTest_obj, "setObject", nothing)` then read it back.)

- [ ] **Step 2: Run, expect failure** — the resolved `jcall` method doesn't exist; `jcall(JMath, "abs", Int32(-3))` will error with no matching method (the existing `jcall(ref, method::AbstractString, rettype::Type, ...)` needs a `Type` 3rd arg).

- [ ] **Step 3: Implement** — in `src/core.jl`, near the other `jcall` methods, add:

```julia
"""
    jcall(receiver, method::AbstractString, args...)

Resolved-overload form of [`jcall`](@ref): picks the Java overload of `method` on
`receiver` (instance or `@jimport`ed class type) that best matches the Julia types
of `args` — see [`resolve_call`](@ref) — dispatches it, and narrows the result
(a returned object to its runtime class; a `java.lang.String` to a Julia `String`;
`void` to `nothing`). Throws `JavaCallError` on an ambiguous match. For a specific
overload / return type, or in a hot loop, use the explicit
`jcall(receiver, method, RetType, (ArgTypes...,), args...)` form.
"""
function jcall(receiver, method::AbstractString, args...)
    assertloaded()
    r = resolve_call(receiver, method, args)
    callargs = r.varargs ? _pack_varargs(r, args) : args
    result = jcall(receiver, r.member::JMethod, callargs...)   # reuse the existing JMethod-dispatch path
    return _resolved_result(r.rettype, result)
end

# Pack the trailing args of a varargs call into a Vector of the declared element type.
function _pack_varargs(r::ResolvedCall, args)
    fixed = args[1:r.n_fixed]
    rest  = args[(r.n_fixed+1):end]
    arr = (length(rest) == 1 && rest[1] isa AbstractVector) ? rest[1] : collect(r.vararg_eltype, rest)
    # collect(T, xs) builds a Vector{T}; for the empty case collect(T, ()) === T[]
    return (fixed..., arr)
end

# Convert a resolved call's result for the ergonomic form: narrow objects, decode Strings.
function _resolved_result(rettype::Type, x)
    rettype === Nothing && return nothing
    if rettype === JString
        isnull(x) && return nothing            # null String -> nothing (decide: nothing vs "")
        return convert(String, x)
    end
    rettype <: JavaObject && return narrow(x)
    return x
end
```

**Implementer notes:**
- Verify `jcall(receiver, ::JMethod, args...)` exists and does *not* narrow its result (it doesn't, as of this writing — it calls `_jcall` directly). If it ever starts narrowing, drop the extra `narrow` here. Also verify it handles a `Vector{E}` arg for a `E[]` Java param (it should — `_jcall` → `convert_args` → `convert(::Type{JNIVector{E}}, ::Vector{E})`). If `JNIVector` is required instead of `Vector`, have `_pack_varargs` build `JNIVector{r.vararg_eltype}` — adjust after testing.
- `collect(T, itr)` — for an empty `itr`, `collect(jint, ())` returns `jint[]`. Confirm; if not, special-case `isempty(rest) && return (fixed..., r.vararg_eltype[])`.
- `convert(String, ::JString)` — confirm it exists and works; if a null-handling helper is needed, the `isnull` guard above covers it. If you'd rather *not* decode `String` returns in core (keeping it strictly `narrow`), drop the `JString` branch — but the spec promises Julia `String`, and JProxies already does this, so keep it for consistency.
- The `r.member::JMethod` assertion: for `jcall`, `resolve_call` is always called with a method name, so `member` is a `JMethod`. The `::JMethod` makes the dispatch to `jcall(_, ::JMethod, _...)` unambiguous.

- [ ] **Step 4: Run tests** — iterate until the `Phase 3: jcall resolved form` testset passes. (Settle the `testString(nothing)` contract.)

- [ ] **Step 5: Commit**
```bash
git add src/core.jl test/runtests.jl
git commit -m "Add resolved jcall(receiver, \"method\", args...) form"
```

### Task 2.3: Add the resolved `jnew` form

**Files:**
- Modify: `src/core.jl` (add `jnew(::Type{JavaObject{T}}, args...)`; do NOT change the existing `jnew(T::Symbol, ...)`)

- [ ] **Step 1: Failing tests** — in `test/runtests.jl`:

```julia
@testset "Phase 3: jnew resolved form" begin
    JArrayList = @jimport java.util.ArrayList
    a = jnew(JArrayList)
    @test a isa JavaObject
    @test jcall(a, "size") == 0
    b = jnew(JArrayList, 16)                       # ArrayList(int initialCapacity)
    @test b isa JavaObject
    @test jcall(b, "size") == 0
    jcall(a, "add", "x")
    c = jnew(JArrayList, a)                        # ArrayList(Collection)
    @test jcall(c, "size") == 1
    # explicit form unchanged (regression)
    @test JArrayList((jint,), 8) isa JavaObject
    @test_throws JavaCall.JavaCallError jnew(JArrayList, "not a valid ctor arg shape", 1, 2)
end
```

- [ ] **Step 2: Run, expect failure** — `jnew(JArrayList)` will hit... actually check: is there an existing `jnew(::Type{JavaObject{T}})`? Grep `git grep -n "jnew(" src/`. There is `JavaObject{T}(argtypes::Tuple, args...) = jnew(T, argtypes, args...)` and `jnew(T::Symbol, ...)` — but `jnew(JArrayList)` passes a `Type`, not a `Symbol`, and not a `Tuple` first-arg, so it should currently error with no matching method. Confirm.

- [ ] **Step 3: Implement** — in `src/core.jl`, after the existing `jnew`:

```julia
"""
    jnew(T::Type{<:JavaObject}, args...)

Resolved-overload form of [`jnew`](@ref): constructs a `T` by picking the
constructor that best matches the Julia types of `args` (see [`resolve_call`](@ref)).
Throws `JavaCallError` on an ambiguous match. For a specific constructor, use
`T(argtypes::Tuple, args...)` / `jnew(:fqn, (ArgTypes...,), args...)`.
"""
function jnew(::Type{JavaObject{T}}, args...) where {T}
    assertloaded()
    r = resolve_call(JavaObject{T}, _CONSTRUCTOR, args)
    callargs = r.varargs ? _pack_varargs(r, args) : args
    paramtypes = Tuple(jimport(c) for c in getparametertypes(r.member))   # the FIXED + (if varargs) trailing-array param types
    return jnew(T, paramtypes, callargs...)                                # delegate to the existing explicit form
end
```

Note: `getparametertypes(r.member)` for a varargs constructor returns `[..., E[]]`, so `paramtypes` already has `Vector{E}` as the last entry, matching the packed `callargs`. Good. The `jnew(T, paramtypes, callargs...)` call goes to the existing `jnew(T::Symbol, argtypes::Tuple, args...)` (note `T` here is the `Symbol` type-parameter, which is exactly what that method wants).

- [ ] **Step 4: Run tests** — iterate to green.

- [ ] **Step 5: Commit**
```bash
git add src/core.jl test/runtests.jl
git commit -m "Add resolved jnew(T, args...) form"
```

### Task 2.4: Full suite + merge

- [ ] **Step 1**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5
cd JProxies && JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -5; cd ..
```
Expected: both green (JProxies still uses its own resolver — untouched until M4).

- [ ] **Step 2**
```bash
git checkout master && git merge --no-ff phase-3/jcall-resolved -m "Merge branch 'phase-3/jcall-resolved'"
```

---

## Milestone 3: phase-3/jcall-macro-resolved

**Branch:** `phase-3/jcall-macro-resolved`

Add the annotation-free `@jcall` form and the mixed-form error.

### Task 3.1: Create branch
```bash
git checkout master && git pull origin master && git checkout -b phase-3/jcall-macro-resolved
```

### Task 3.2: Teach `@jcall` the annotation-free form

**Files:**
- Modify: `src/jcall_macro.jl` (`jcall_macro_parse` / `jcall_macro_lower`)
- Modify: `test/jcall_macro.jl` (new cases)

- [ ] **Step 1: Read the macro internals** — `cat src/jcall_macro.jl` and `cat test/jcall_macro.jl`. Understand how `jcall_macro_parse(expr)` currently returns `(func, rettype, types, args)` and where the `::T` annotations and `::RetType` come from (it's modelled on `Base.@ccall`). Determine how to detect "this expression has no `::RetType`" and "no arg has a `::T`".

- [ ] **Step 2: Failing tests** — in `test/jcall_macro.jl`:

```julia
@testset "Phase 3: @jcall annotation-free" begin
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    JSystem = @jimport java.lang.System
    al = JArrayList((),)

    @test (@jcall al.add("one")) == true
    @test (@jcall al.size()) == 1
    @test (@jcall al.get(0)) == "one"
    @test (@jcall JMath.abs(Int32(-5))) == 5
    @test (@jcall JSystem.getProperty("java.version")) isa AbstractString
    # dotted receiver still works (resolved through jfield) in annotation-free mode
    # (use a static field chain that exists; if none handy, skip)

    # fully-annotated form still works (regression)
    @test (@jcall al.contains("one"::JObject)::jboolean) == true

    # mixed form errors at macro-expansion time
    @test_throws Exception (@eval @jcall al.add("one"::JObject))      # arg annotated, no rettype
    @test_throws Exception (@eval @jcall al.size()::jint)            # rettype only, but here there are no args so this is actually "all annotated" with 0 args — pick a real mixed case:
    @test_throws Exception (@eval @jcall al.indexOf("one"))          # ...no: that's annotation-free, valid. Construct a true mixed case with >=1 arg:
    @test_throws Exception (@eval @jcall al.set(0, "x"::JObject))    # one arg annotated, one not -> mixed
end
```

Clean that up — a *true* mixed case needs ≥1 arg where some-but-not-all are annotated, or any-args-annotated-without-a-rettype, or a rettype-without-annotating-the-args(≥1). Use:
- `@jcall al.add("one"::JObject)` — arg annotated, no `::RetType` → **mixed** → error.
- `@jcall al.get(0)::JString` — `::RetType` present but the arg `0` is not annotated → **mixed** → error.
- `@jcall al.add("x")` — neither → **annotation-free** → OK.
- `@jcall al.contains("x"::JObject)::jboolean` — both → **explicit** → OK.

So:

```julia
    @test_throws LoadError (@eval @jcall al.add("one"::JObject))     # arg annotated, no rettype
    @test_throws LoadError (@eval @jcall al.get(0)::JString)         # rettype, arg not annotated
```
(`@eval` of a macro that throws during expansion surfaces as `LoadError` wrapping the `error(...)`; adjust the exception type after you see what's actually thrown — could be a bare `ErrorException`. Use `@test_throws Exception` if unsure.)

- [ ] **Step 3: Implement** — modify `jcall_macro_lower` (and `jcall_macro_parse` if needed to surface "was each arg annotated / was a rettype given"):

The change in shape: after parsing, you know `func`, `rettype` (or a sentinel for "none"), `types` (the per-arg `::T`s, or `nothing`s for un-annotated args), `args`. Classify:
- **all-annotated**: a `rettype` was given AND every arg has a `::T`. → emit the current `jcall(receiver, "m", rettype, (types...,), args...)` (or the static `Receiver.method(...)` shape — keep the existing `QuoteNode` branch).
- **none-annotated**: no `rettype` AND no arg has a `::T`. → emit `jcall(receiver, "m", args...)` (or `Receiver.method` static shape → `jcall(Receiver, "m", args...)`).
- **mixed**: anything else. → `return :(throw(ArgumentError("@jcall: annotate all arguments and the return type, or none — use jcall(...) directly for partial cases.")))` — or, better, raise at expansion time so it's caught early: just `error("@jcall: ...")` inside `jcall_macro_lower`.

Concretely, the new `jcall_macro_lower` (sketch — adapt to the actual parse output):

```julia
function jcall_macro_lower(func, rettype, types, args)
    has_ret  = rettype !== nothing && rettype !== :Any   # however "no rettype" is represented after parsing
    n        = length(args)
    n_typed  = count(t -> t !== nothing && t !== :Any, types)   # however un-annotated args are represented
    if n == 0
        # zero-arg call: "annotation-free" iff no rettype; "explicit" iff rettype given. Never "mixed".
        mode = has_ret ? :explicit : :resolved
    elseif has_ret && n_typed == n
        mode = :explicit
    elseif !has_ret && n_typed == 0
        mode = :resolved
    else
        error("@jcall: annotate all arguments and the return type, or none — use jcall(...) directly for partial cases.")
    end

    jargs = Expr(:tuple, esc.(args)...)
    if func isa Expr            # receiver.method(...)
        obj = resolve_dots(func.args[2])
        f = string(func.args[1].value)
        if mode === :explicit
            jtypes = Expr(:tuple, esc.(types)...)
            return :(jcall($(esc(obj)), $f, $(esc(rettype)), $jtypes, ($jargs)...))
        else
            return :(jcall($(esc(obj)), $f, ($jargs)...))
        end
    elseif func isa QuoteNode   # static-ish bare-call shape (existing behavior)
        if mode === :explicit
            jtypes = Expr(:tuple, esc.(types)...)
            return :($(esc(func.value))($jtypes, ($jargs)...))
        else
            return :($(esc(func.value))(($jargs)...))   # NOTE: verify this is still meaningful; if the QuoteNode branch only ever meant the explicit static form, you may keep it explicit-only and route static calls through the `func isa Expr` path instead.
        end
    end
end
```

**Implementer notes:**
- The exact representation of "no return type" and "this arg is un-annotated" depends on how `jcall_macro_parse` (based on `@ccall`) builds its output. `@ccall foo()::Cvoid` always *has* a rettype; `@jcall` may currently *require* one and error otherwise. You may need to relax `jcall_macro_parse` to *allow* a missing `::RetType` and missing `::T`s (returning sentinels) rather than erroring — that's the real work here. Read `Base.@ccall`'s lowering for the pattern (`Base.Expr` walking), but keep changes minimal.
- Static calls: `@jcall System.getProperty("os.name"::JString)::JString` — `System` here is parsed as part of the dotted receiver chain (`func.args[2]` resolved via `resolve_dots`/`jfield`), NOT the `QuoteNode` branch. So `@jcall JMath.abs(x)` (annotation-free static) flows through `func isa Expr` → `jcall(JMath, "abs", x)` — which dispatches to our resolved `jcall` (since `JMath` is a `Type{JavaObject{...}}`). Good — no special static handling needed in the macro.
- Don't break any existing `test/jcall_macro.jl` cases — run them.

- [ ] **Step 4: Run** — `JULIA_NUM_THREADS=1 julia --project=. test/jcall_macro.jl` and the full `Pkg.test()`. Iterate to green.

- [ ] **Step 5: Commit**
```bash
git add src/jcall_macro.jl test/jcall_macro.jl
git commit -m "Add annotation-free @jcall form; error on mixed annotations"
```

### Task 3.3: Merge
```bash
git checkout master && git merge --no-ff phase-3/jcall-macro-resolved -m "Merge branch 'phase-3/jcall-macro-resolved'"
```

---

## Milestone 4: phase-3/jproxies-on-core-resolver

**Branch:** `phase-3/jproxies-on-core-resolver`

Make `JProxies` delegate to `JavaCall.resolve_call`; delete its private resolver.

### Task 4.1: Create branch
```bash
git checkout master && git pull origin master && git checkout -b phase-3/jproxies-on-core-resolver
```

### Task 4.2: Rewire `dotaccess.jl`

**Files:**
- Modify: `JProxies/src/dotaccess.jl`
- Modify: `JProxies/src/JProxies.jl` (import)

- [ ] **Step 1: Read the current `dotaccess.jl`** — note exactly what `JProxyMethod`'s call operator and `getproperty`'s method-dispatch branch do today, and what `_juliafy` does (it narrows + decodes `JString` + unboxes boxed primitives). Keep `_juliafy` (or fold its logic into a call to `JavaCall._resolved_result` + extra unboxing — but simplest: keep `_juliafy` as-is in JProxies).

- [ ] **Step 2: Replace the resolver usage** — in `JProxies/src/dotaccess.jl`:

Delete: `_resolve_overload`, `_arg_tier`, `_PRIM_BY_NAME`, `_RESOLVE_CACHE`, `_RESOLVE_LOCK` (and `_objtype_or_prim` if it's now unused — check).

Rewrite `JProxyMethod`'s call operator (currently something like `function (m::JProxyMethod)(args...) ... _resolve_overload ... jcall(w, method::JMethod, args...) ... _juliafy ... end`) to:

```julia
function (m::JProxyMethod)(args...)
    w = unwrap(getfield(m, :jp))
    r = JavaCall.resolve_call(w, String(m.name), args)
    callargs = r.varargs ?
        (args[1:r.n_fixed]..., (length(args) - r.n_fixed == 1 && args[r.n_fixed+1] isa AbstractVector ? args[r.n_fixed+1] : collect(r.vararg_eltype, args[(r.n_fixed+1):end]))) :
        args
    return _juliafy(jcall(w, r.member::JavaCall.JMethod, callargs...))
end
```

(That vararg-packing inline duplicates `JavaCall._pack_varargs` — better: export/use `JavaCall._pack_varargs(r, args)` from JProxies. Add `_pack_varargs` to the `import JavaCall: ...` list and call it. Cleaner. Do that.)

If `getproperty` has its own method-dispatch construction, route it through the same path (it likely just returns a `JProxyMethod`, in which case nothing else changes).

In `JProxies/src/JProxies.jl`, add `resolve_call`, `_pack_varargs`, `JMethod` (if not already), `ResolvedCall` (if you reference the type) to the `import JavaCall: ...` list. (Or just use `JavaCall.resolve_call` etc. fully-qualified — but match the file's existing style, which imports names.)

- [ ] **Step 3: Run JProxies tests**
```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -10
```
Expected: ALL JProxies testsets still pass (dot-access, static, fields, overload-throws, unwrap, callbacks, GC-pressure). The "overload resolution: no such method throws" testset now exercises the core resolver's error — verify the message still triggers the `@test_throws`. If the existing JProxies overload tests assumed a behavior the core resolver does differently (e.g. the old `Bool`/`boolean` quirk), update the *test* to the (more correct) core behavior, not the resolver.

- [ ] **Step 4: Run the main suite too** (nothing should have changed there, but confirm):
```bash
cd /Users/brad/Projects/JavaCall.jl
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -5
```

- [ ] **Step 5: Commit**
```bash
git add JProxies/src/dotaccess.jl JProxies/src/JProxies.jl JProxies/test/runtests.jl
git commit -m "JProxies: delegate overload resolution to JavaCall.resolve_call; delete the duplicate"
```

### Task 4.3: Merge
```bash
git checkout master && git merge --no-ff phase-3/jproxies-on-core-resolver -m "Merge branch 'phase-3/jproxies-on-core-resolver'"
```

---

## After all milestones

- A final review pass over the whole Phase 3 sub-project 1 (spec coverage + a holistic code review).
- Use `superpowers:finishing-a-development-branch` to wrap up.
- NEWS.md / README updates for the new call forms are a release-time task (note it; not part of this plan's milestones — the existing NEWS.md has a `0.9.0` section; a follow-up `0.9.x`/`0.10.0` entry will cover this).
- The other Phase 3 sub-projects (import ergonomics, `JProxy` iteration) get their own brainstorm → spec → plan.

---

## Self-Review notes (carried into execution)

- **Spec coverage:** resolved `jcall(receiver,"m",args...)` (M2) ✔; `jnew(T,args...)` (M2) ✔; annotation-free `@jcall` + mixed-form error (M3) ✔; shared `src/overload.jl` resolver with the quality-score ladder incl. varargs / array params / `nothing`→null (M1) ✔; ambiguity & no-match throw with candidate signatures (M1) ✔; caching behind a lock (M1) ✔; result narrowing (M2) ✔; `JProxies` delegates, duplicate deleted (M4) ✔; `listconstructors` added (M1) ✔; additive — existing forms untouched, regression-tested in M2 ✔; out-of-scope items recorded in the spec ✔.
- **Known soft spots (flagged inline, expect iteration during execution):** the tier-vector comparator across differing arities (M1 Task 1.5 — get it *consistent*, with unit tests if needed); whether `jcall(_,::JMethod,_...)` already narrows / handles `Vector{E}` args (M2 Task 2.2 — verify, adjust); the `JString`-return → Julia-`String` decode and the null-`String` contract (M2 Task 2.2 — pick `nothing` and stick to it); the `@jcall` parser's representation of "missing rettype / un-annotated arg" (M3 Task 3.2 — read `@ccall`'s lowering); `_vec_assignable` for object element types (M1 — keep the simple `E===E′ || E<:JavaObject && E′===JObject` rule); the `getname`-of-an-array-class string in the M1 array test (adjust the expected literal after observing it).
- **Type/name consistency:** `ResolvedCall{member, rettype, varargs, n_fixed, vararg_eltype}`, `resolve_call`, `_resolve_call_uncached`, `_arg_tier`, `_score_candidate`, `_pack_varargs`, `_resolved_result`, `_CONSTRUCTOR = :new`, `listconstructors` — used consistently across M1–M4. The new `jcall`/`jnew` methods are additive overloads, never edits to existing ones.
