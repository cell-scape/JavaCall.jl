# Phase 3 — `jcall` / `@jcall` / `jnew` Overload Resolution — Design

**Status:** approved 2026-05-12. This is sub-project 1 of Phase 3 ("API ergonomics"). The other Phase 3 sub-projects — import ergonomics, `JProxy` iteration — get their own specs (see "The rest of Phase 3" at the end).

## Problem

Today every JavaCall invocation spells out the Java method signature by hand:

```julia
jcall(list, "add", jboolean, (JObject,), "one")
jcall(JArrayList, "of", JList, (Vector{JObject},), items)   # static
jnew(JArrayList, (jint,), 16)
@jcall list.add("one"::JObject)::jboolean
```

That is precise and fast, but verbose and error-prone — the caller has to know the exact erased parameter types and the return type. The `JProxies` subpackage already proves the ergonomic alternative works (`JProxy(list).add("one")` resolves the overload by argument type and narrows the result), but that machinery lives in `JProxies/src/dotaccess.jl` and only `JProxy` benefits. Phase 3 lifts it into core JavaCall so `jcall`, `@jcall`, `jnew`, *and* `JProxy` all share one resolver — and adds the gaps that real Java APIs hit constantly (varargs, array parameters, `null`).

## Goals

- New, **purely additive** call forms that need no `(ArgTypes,)` tuple and no return type:
  - `jcall(receiver, "method", args...)`
  - `jnew(T, args...)`
  - `@jcall receiver.method(args...)` (annotation-free macro form)
- One shared overload-resolution engine in core (`src/overload.jl`), used by the above and by `JProxies` (whose duplicate resolver is deleted).
- Cover the common Java cases: exact, subclass/assignable, boxing/widening, **Java varargs**, **array parameters**, **`nothing` → `null`**.
- Ambiguous matches **throw a clear, actionable error** pointing at the explicit form — never guess.
- Zero behavior change for the existing explicit `jcall`/`@jcall`/`jnew` forms; they remain the fast, unambiguous escape hatch.

## Non-goals (out of scope)

- **Breaking changes** to the existing `jcall`/`@jcall`/`jnew` signatures. Additive only.
- **Full JLS-conformant overload resolution** — no most-specific-method tiebreak; ties throw.
- **Partial `@jcall` forms** (annotate args but not return, or vice versa) — strict either/or grammar; partial cases use `jcall(...)` directly.
- **Configurable dispatch-channel size** — moot; the dispatch channel is `Channel{DispatchMsg}(typemax(Int))` and only allocates as items arrive.
- **Pre-allocated callback result boxes** — a performance idea, not ergonomics, and premature.
- The other Phase 3 sub-projects (import ergonomics, `JProxy` iteration) — separate specs.

---

## Public API surface

All additive. The existing explicit forms (`jcall(receiver, "m", RetType, (ArgTypes...,), args...)`, `jcall(receiver, ::JMethod, args...)`, `jnew(T, (ArgTypes...,), args...)`, fully-annotated `@jcall`) are **unchanged**.

### `jcall(receiver, "method", args...)`

```julia
jcall(list, "add", "one")          # instance; resolves add(Object)->boolean; narrows result
jcall(JMath, "abs", -3)            # static; resolves abs(int)->int
jcall(JString, "format", "%d", 42) # static varargs: format(String, Object...)
```

- `receiver` is a `JavaObject{T}` (instance call) or a `Type{JavaObject{T}}` from `@jimport` (static call). The two are distinguished automatically (it's just `typeof(receiver)`).
- Reflects on the class, gathers the candidate overloads named `"method"`, scores each against `map(typeof, args)`, picks the unique best, dispatches via the existing `_jcall` machinery, and `narrow`s the result.
- Ambiguous → `JavaCallError` (see "Errors"). No candidate → `JavaCallError`.
- Result narrowing: a returned `JavaObject` is `narrow`ed to its runtime class (so `list.get(0)` yields a Julia `String` once `convert`/`narrow` apply); `void` returns yield `nothing`; primitive returns are unchanged.

### `jnew(T, args...)`

```julia
jnew(JArrayList)            # ArrayList()
jnew(JArrayList, 16)        # ArrayList(int)
jnew(JArrayList, someList)  # ArrayList(Collection)
```

Same engine, but the candidates come from `getConstructors()` instead of `getMethods()`. Returns a `JavaObject{T}` (constructors don't get narrowed — `T` is already exact).

### `@jcall receiver.method(args...)` — annotation-free

```julia
@jcall list.add("one")                       # -> jcall(list, "add", "one")
@jcall System.getProperty("os.name")         # dotted receiver still resolved via jfield
@jcall JMath.max(a, b)                        # static
```

- If the `@jcall` expression has **no** `::RetType` annotation **and** **no** `arg::Type` annotations, it lowers to the resolved `jcall(receiver, "method", args...)` form (or `jcall(Receiver, "method", args...)` for the static `Receiver.method(...)` shape).
- If it has the **full** annotations (every arg annotated *and* a return type), it behaves exactly as today.
- **Mixed** (some args annotated, or only a return type, or only arg types) → a macro-expansion-time `error("@jcall: annotate all arguments and the return type, or none — use jcall(...) directly for partial cases.")`.
- Dotted receiver chains and `$`-interpolated method names work in both modes (unchanged).

### `jfield`

No new form — `jfield(obj, "name")` (type-inferring) already exists. Out of scope here.

---

## The shared resolver — `src/overload.jl`

A new module-internal file with one responsibility: *given a receiver (or imported class type), a target name (a method name, or the constructor sentinel), and a tuple of Julia argument values, choose the Java overload and the Julia-side parameter & return types to feed the existing `_jcall` / `_jnew` machinery.*

### Data

```julia
struct ResolvedCall
    member::Union{JMethod, JConstructor}   # the chosen overload
    paramtypes::Tuple                      # Julia types for the FIXED params (Type{...} each)
    rettype::Type                          # Julia return type (Nothing for void / constructors n/a)
    varargs::Bool                          # member.isVarArgs() AND we matched via the vararg form
    vararg_eltype::Union{Type, Nothing}    # element type of the trailing T[] when varargs
end

const _OVERLOAD_CACHE = Dict{Tuple{DataType, Any, Tuple}, ResolvedCall}()
const _OVERLOAD_LOCK  = ReentrantLock()
const _CONSTRUCTOR    = :new   # sentinel used in place of a method name for jnew
```

Cache key: `(typeof(receiver), name, map(typeof, args))`. `typeof(receiver)` being `Type{JavaObject{T}}` vs. `JavaObject{T}` is what distinguishes static from instance, so the key needs no extra flag.

### Entry point

```julia
resolve_call(receiver, name, args::Tuple) -> ResolvedCall
```

`lock(_OVERLOAD_LOCK) do; get!(_OVERLOAD_CACHE, key) do; _resolve_call_uncached(receiver, name, args); end; end`.

### Candidate gathering

- Methods: `listmethods(receiver, String(name))` (already exists; works for both `JavaObject` and `Type{JavaObject{T}}`).
- Constructors: `listconstructors(receiver)` — a small new helper in `reflect.jl` mirroring `listmethods`, returning `Vector{JConstructor}` via `getclass(...).getConstructors()`. (If an internal equivalent already backs `jnew`, reuse it.)
- For each candidate: param classes from `getparametertypes`; map each `JClass` to its Julia type with the existing `jimport(::JClass)` (handles primitives, arrays, reference types). Return type from `getreturntype` (methods only) likewise via `jimport`.
- Record `isVarArgs()` per candidate.

### Scoring — quality-score ladder

For a candidate with fixed param Julia types `P = (p₁, …, pₙ)` (for a vararg candidate, `n` excludes the trailing array param) and call args `A = (a₁, …, aₘ)`:

**Fixed-arity match** (`m == n`): score each `(aᵢ, pᵢ)` to a tier; reject the candidate if any pair is unmatchable.

| Tier | Name | When |
|---|---|---|
| 0 | exact | `aᵢ isa pᵢ` for a JNI primitive `pᵢ`; or `aᵢ` is a `JavaObject` whose runtime class name equals the param class name; or `aᵢ isa Bool` and `pᵢ === jboolean`; or `aᵢ isa AbstractString` and `pᵢ === JString` |
| 1 | assignable | `aᵢ` is a `JavaObject` and `isConvertible(JavaObject{Symbol(paramclassname)}, aᵢ)` (i.e. `IsAssignableFrom`); or `aᵢ isa AbstractVector{E}` (incl. `JNIVector{E}`) and `pᵢ === Vector{E′}` with `E` assignable to `E′`; or `aᵢ isa AbstractString` and `pᵢ` is `CharSequence`/`Object` |
| 2 | implicit | `aᵢ isa Integer` and `pᵢ` is a wider integer primitive or a numeric box, with a range check (`typemin(pᵢ) ≤ aᵢ ≤ typemax(pᵢ)` for primitives); `aᵢ isa Real` and `pᵢ` is a float primitive/box; `aᵢ isa Integer/AbstractFloat/Bool` and `pᵢ` is `java.lang.Number`/`Object`/the matching box |
| 4 | null | `aᵢ === nothing` and `pᵢ` is a reference type (any `JavaObject{...}`/`Vector{...}`). `nothing` against a primitive `pᵢ` → reject |
| — | reject | none of the above |

**Vararg match** (candidate has `isVarArgs()`, trailing param is `E[]` after `n` fixed params, and `m ≥ n`): score `a₁…aₙ` against `p₁…pₙ` as above; then either (a) `m == n+1` and `aₘ` is an `AbstractVector` assignable to `E[]` → that arg scores at its normal tier (the "pass the array directly" case), or (b) every `aₙ₊₁…aₘ` scores against element type `E` as above. The candidate's overall vararg tier is `max(per-arg tiers, 3)` — i.e. a vararg match is never better than tier 3, so a fixed-arity candidate that matches always wins over a vararg one, mirroring Java.

**Selection:** build a per-argument tier vector for each surviving candidate (for vararg matches, pad/clamp as just described so vectors are comparable: prepend the fixed-param tiers, then a single summarizing tier ≥3 for the vararg portion). Compare vectors lexicographically. The unique minimum wins. If two or more candidates tie on the minimum vector → throw (ambiguous). If no candidate survives → throw (no match). **No JLS most-specific tiebreak.**

> Note: this fixes the JProxies quirk where `Bool` against a primitive `boolean` scored tier 2 (implicit) — here it's tier 0.

### Producing the `ResolvedCall`

- Non-vararg winner: `paramtypes = (p₁…pₙ)`, `rettype = jimport(getreturntype(member))` (or `Nothing` for void), `varargs = false`.
- Vararg winner: `paramtypes = (p₁…pₙ, Vector{E})`, `vararg_eltype = E`, `varargs = true`, `rettype` as above.

### Errors

`JavaCallError` (the existing exception type) with messages like:

- ambiguous: `"jcall: ambiguous call $cls.$name($(map(typeof,args))) — $(k) overloads match equally well: $(sigs). Use the explicit jcall(receiver, \"$name\", RetType, (ArgTypes...,), args...) form."`
- no match: `"jcall: no overload of $cls.$name accepts argument types $(map(typeof,args)). Candidates: $(sigs)."`

`$cls` = the receiver's class name; `$sigs` = the candidate Java signatures considered.

---

## Wiring the call sites

### `jcall(receiver, "method", args...)`

A new method that doesn't collide with the explicit form (it has no `::Type` 3rd positional and no tuple):

```julia
function jcall(receiver, method::AbstractString, args...)
    assertloaded()
    r = resolve_call(receiver, method, args)
    callargs = r.varargs ? (args[1:length(r.paramtypes)-1]..., _pack_varargs(r.vararg_eltype, args[length(r.paramtypes):end])) : args
    result = _dispatch_resolved(receiver, r.member, r.rettype, r.paramtypes, callargs)   # routes through existing _jcall by (rettype, instance/static)
    return r.rettype <: JavaObject ? narrow(result) : result
end
```

`_pack_varargs(E, xs)`: if `xs` is a single `AbstractVector` already assignable to `E[]`, return it as-is (don't double-wrap — Java's own "array or spread" ambiguity, resolved toward "looks like the array → it is the array"); else `convert(Vector{E}, collect(xs))`; empty `xs` → `E[]`. `_dispatch_resolved` is a thin shim onto the existing `_jcall(...)`/`jcall(receiver, ::JMethod, args...)` path (the latter already exists and infers types from a `JMethod` — the new code can reuse it, just supplying the *resolved* `JMethod` and pre-packed args).

> Implementation note for the plan: `jcall(receiver, ::JMethod, args...)` already exists and does most of `_dispatch_resolved`'s job (it derives `rettype`/`argtypes` from the reflected method). The cleanest implementation is: `resolve_call` returns the `JMethod`; `jcall(receiver, "m", args...)` packs varargs then calls `jcall(receiver, member, callargs...)`; and `narrow`ing is layered on top. Verify the existing `jcall(_, ::JMethod, _...)` already `narrow`s or not, and make the resolved string form narrow regardless.

### `jnew(T, args...)`

```julia
function jnew(::Type{JavaObject{T}}, args...) where {T}
    assertloaded()
    r = resolve_call(JavaObject{T}, _CONSTRUCTOR, args)
    callargs = r.varargs ? (...) : args
    return _jnew(JavaObject{T}, r.paramtypes, callargs...)   # existing _jnew machinery
end
```

(Confirm the new method doesn't shadow `jnew(T, (ArgTypes...,), args...)` — it won't, because that form's 2nd positional is a `Tuple`; a `Tuple` passed as the first vararg here would be interpreted as a single Java argument, which is the correct disambiguation: if you pass a tuple you meant the explicit form, but a Java method rarely takes a Julia `Tuple` — acceptable, document it.)

### `@jcall`

`jcall_macro_parse` already separates the receiver, method name, args, arg-types, and return type. The change in `jcall_macro_lower`:

- All-annotated (every arg has `::T` *and* there's a `::RetType`) → emit the existing `jcall(receiver, "m", RetType, (T...,), args...)`.
- None-annotated (no `::T` on any arg, no `::RetType`) → emit `jcall(receiver, "m", args...)` (or `jcall(Receiver, "m", args...)` for the `QuoteNode`/static shape).
- Anything in between → `return :(error("@jcall: annotate all arguments and the return type, or none — use jcall(...) directly for partial cases."))` (or raise at macro-expansion time directly).

### `reflect.jl`

Add `listconstructors(::Union{JavaObject{T}, Type{JavaObject{T}}}) where {T}` → `Vector{JConstructor}`, mirroring `listmethods`. Exported alongside the other `list*`/`get*` reflection helpers. Docstring in the doc-first style.

### `JProxies` consolidation

`JProxies/src/dotaccess.jl`: delete `_resolve_overload`, `_arg_tier`, `_PRIM_BY_NAME`, `_RESOLVE_CACHE`, `_RESOLVE_LOCK`. `JProxyMethod`'s call operator becomes: `r = JavaCall.resolve_call(unwrap(m.jp), String(m.name), args); narrow(jcall(unwrap(m.jp), r.member, _pack(...)...))` — i.e. it delegates to the core resolver and the core `jcall(_, ::JMethod, _...)` path. `JProxy`'s existing dot-access / overload / static / field tests in `JProxies/test/runtests.jl` become the integration test for `resolve_call` from the JProxies side. (`JProxies` will need `import JavaCall: resolve_call` — or just `JavaCall.resolve_call`.)

---

## Performance

Resolution does reflection (`getMethods`/`getConstructors` + per-candidate `getParameterTypes`/`getReturnType`) **once per `(receiver type, name, arg-typetuple)`**, then the result is cached behind `_OVERLOAD_LOCK`. Steady-state cost is a `Dict` lookup. Callers in tight loops who can't tolerate even that, or who need a specific overload the resolver wouldn't pick, use the explicit `jcall(receiver, "m", RetType, (ArgTypes...,), args...)` form — which is documented as the escape hatch.

## Testing

New testsets in `test/runtests.jl` and `test/jcall_macro.jl`:

- **Resolution coverage** — exact (`jcall(JArrayList(()), "add", "x") == true`), boxing/widening (`jcall(JMath, "abs", Int32(-3)) == 3`; `Int64`→`long`), subclass/assignable (pass a narrowed `JString` where `Object`/`CharSequence` is expected), array param (`Vector{jint}` → `int[]`), `nothing`→null (a method taking `Object` accepts `nothing`).
- **Varargs** — add to `JProxies/test/Test.java` an overloaded method and a varargs method (e.g. `int sum(int...)`, plus a `String join(String, Object...)`); test spread args, an empty vararg, and passing the array directly; recompile `Test.class` / `Test$*.class`.
- **Ambiguity** — a class with two overloads that tie under the ladder → `@test_throws JavaCallError`; the message names the candidates.
- **No match** — `@test_throws JavaCallError jcall(JArrayList(()), "add", 1, 2, 3)`.
- **`jnew`** — `jnew(JArrayList) isa JavaObject`; `jnew(JArrayList, 16)` (int ctor); `jnew(JArrayList, someCollection)`.
- **Narrowing** — `jcall(list, "get", 0)` returns a Julia `String`.
- **`@jcall`** — annotation-free form (`@jcall list.add("x")`, `@jcall JMath.max(a,b)`, dotted receiver) works; mixed-annotation form errors at macro expansion (`@test_throws` around an `@eval`/`Meta.lower`).
- **Regression** — every existing explicit `jcall`/`@jcall`/`jnew` test still passes unchanged; the resolution cache returns the same `JMethod` object on a repeated call.
- **JProxies** — its suite stays green after the `dotaccess.jl` rewire (proves `resolve_call` is the single source of truth).

Canonical run: `JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()'` and the JProxies suite with `Pkg.develop(path="..")`.

## Migration / compatibility

Strictly additive — no downstream package or user code changes behavior. `jcall`/`@jcall`/`jnew`/`jfield` keep their existing signatures and semantics. The new forms are documented in the README and `NEWS.md` (a `0.10.0` or `0.9.x` entry, TBD at release time — not part of this sub-project). `JProxies` API is unchanged; only its internals move.

---

## The rest of Phase 3 (separate sub-projects)

- **(2) Import ergonomics** — to be scoped in its own brainstorm. Candidates: nested-class sugar (`@jimport Outer.Inner` accepting the `Outer$Inner` JVM name); importing several classes in one macro invocation; `@jimport`-into-a-`module`. Underspecified today.
- **(3) `JProxy` iteration** — `Base.iterate` on a `JProxy` wrapping `java.lang.Iterable` (plus friendly handling of `Collection`/`Map`/Java arrays), so `for x in JProxy(jlist) … end` works. Builds on `resolve_call` from sub-project 1. Its own spec.
- **(4) Misc** — `init(...; dispatch_channel_size)` and pre-allocated callback result boxes: recorded as out of scope (see Non-goals) unless revived.

**Sequencing:** sub-project (1) first (the resolver underpins the rest), then (3), then (2).
