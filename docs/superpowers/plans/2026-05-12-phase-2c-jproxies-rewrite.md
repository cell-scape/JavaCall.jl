# Phase 2C — JProxies Rewrite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `eval`-heavy, precompile-hostile JProxies subpackage with a clean rewrite: dot-access on Java objects (`JProxy(obj).method(args)`) with overload resolution, and Julia-implements-Java-interface callbacks (`jproxy(value, iface)`) routed through the Phase 2A dispatch task — all precompile-friendly and thread-safe.

**Architecture:** Builds on the Phase 2A foundation (`with_env`, `_env_cache`, the dispatch task in `src/dispatch.jl`). Adds a `Callback` `DispatchMsg` so Java→Julia calls execute on the known-good dispatch thread. A small bundled Java class (`JavaCallInvocationHandler`) implements `java.lang.reflect.InvocationHandler`; its native `invokeNative` is wired via `JNI.RegisterNatives` to a Julia `@cfunction`. JProxies is rewritten with three concrete types — `JProxy{T,W}` (dot-access wrapper), `JProxyMethod{T}` (overload-resolving callable), `JProxyRef{T}` (lifetime owner for a registered callback handler) — plus a `@jproxy` macro that lowers to plain `Dict` assignments (no runtime `eval`).

**Tech Stack:** Julia 1.12+, JNI 1.8+ (`RegisterNatives`, `NewObjectA`, `CallObjectMethodA` already bound), `java.lang.reflect.Proxy` / `InvocationHandler`. `javac` only needed by maintainers to regenerate the bundled `.class`.

---

## File Structure

### Files modified

- `src/dispatch.jl` — add `Callback <: DispatchMsg` struct and its `_handle` method; export nothing new (internal).
- `src/JavaCall.jl` — no API change; `Callback` stays internal. (If a future caller needs it, export later.)
- `src/jvm.jl` — at the tail of `init()` / `init_current_vm()`, after the dispatch task starts, add the bundled JProxies `.class` directory to the classpath **before** classpath is frozen — actually classpath is frozen at JVM start, so this must happen via `addClassPath` *before* `init()`. Decision: the JProxies package adds its class dir in `JProxies.__init__()` via `JavaCall.addClassPath`, and the native registration happens lazily in `JProxies.init()` / first `jproxy` call. **No change to `src/jvm.jl`.** (Listed here only to record the decision.)
- `JProxies/Project.toml` — no dependency changes; bump version to `0.9.0` to match the main package release train (optional, cosmetic).
- `JProxies/src/JProxies.jl` — rewrite module body: new imports, new exports (`JProxy`, `jproxy`, `@jproxy`, `@jimport`), new `include`s, `__init__` that registers the bundled class dir on the classpath.
- `JProxies/test/runtests.jl` — rewrite for the new API; keep using `JProxies.init(...)`.
- `JProxies/test/Test.java` — add a callback-friendly interface + a method that accepts it (e.g. `runIt(Runnable)` returning the side effect), recompile `Test.class`.
- `README.md` — update the JProxies section: `JProxy(obj).method(args)` preserved with overload resolution; `jproxy(value, iface)` new; `@class` / `staticproxy` / magic widening removed.

### Files created

- `JProxies/java/org/juliainterop/JavaCallInvocationHandler.java` — source for the bundled helper class.
- `JProxies/java/org/juliainterop/JavaCallInvocationHandler.class` — compiled bytecode, committed (so users need no `javac`).
- `JProxies/src/native.jl` — `_proxy_invoke_native` `@cfunction` target, `RegisterNatives` wiring, marshalling helpers (`_unmarshal_args`, `_marshal_result`), the `_proxy_registry`, `JProxiesNativeError`. ~150 lines.
- `JProxies/src/dotaccess.jl` — `JProxy`, `JProxyMethod`, `getproperty`/`setproperty!`, the overload-resolution quality-score ladder, the resolution cache. ~180 lines.
- `JProxies/src/callbacks.jl` — `@jproxy` macro, `_proxy_method_table`, `jproxy(value, iface)`, `JProxyRef`, its `convert`/`Ptr` shims and finalizer. ~120 lines.
- `JProxies/src/JProxies.jl` is rewritten, not created (listed under "modified").

### Why this split

`native.jl` is the JNI-edge / unsafe layer (cfunction, RegisterNatives, raw object-array marshalling) — the part most likely to need careful review and the part that changes if the Java helper signature changes. `dotaccess.jl` and `callbacks.jl` are the two user-facing features and are independent of each other (you can use `JProxy` dot-access without ever touching callbacks). Keeping them apart means a reviewer can hold each in context at once. The old `proxy.jl` (60 KB) and `gen.jl` are deleted.

---

## Branch Organization

Same multi-branch workflow as Phase 2A/2B. Each milestone is one branch off `master`; each ends with a full test pass and a `--no-ff` merge to master. Order is ascending dependency: M1 (dispatch `Callback` — pure JavaCall, no JProxies) → M2 (`JProxy` dot-access — depends only on existing JavaCall) → M3 (callbacks — depends on M1's `Callback` and M2's resolution helpers) → M4 (cleanup, docs, deprecation removal).

1. `phase-2c/dispatch-callback` — `Callback` message type + `_handle` + tests (in main `test/`)
2. `phase-2c/jproxy-dotaccess` — JProxies rewrite skeleton + `JProxy`/`JProxyMethod` + overload resolution
3. `phase-2c/jproxy-callbacks` — Java helper class, `native.jl`, `@jproxy`, `jproxy()`, `JProxyRef`
4. `phase-2c/jproxies-cleanup` — delete `proxy.jl`/`gen.jl`, finalize exports, README, full subpackage test pass

---

## Milestone 1: phase-2c/dispatch-callback

**Branch:** `phase-2c/dispatch-callback`

Add the `Callback` `DispatchMsg` so an arbitrary nullary thunk can be run on the dispatch task's known-good OS thread and its result handed back through a one-shot `Channel`. This is the only change to the main `JavaCall` package in Phase 2C.

### Task 1.1: Create branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git pull origin master
git checkout -b phase-2c/dispatch-callback
```

### Task 1.2: Write the failing test

**Files:**
- Modify: `test/runtests.jl` (add a testset near the existing dispatch-task tests; if unsure where, append before the final `end`)

- [ ] **Step 1: Add the testset**

```julia
@testset "dispatch Callback message" begin
    # Callback runs the thunk and delivers the result via the result_box.
    box = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> 6 * 7, (), box))
    @test take!(box) == 42

    # An exception in the thunk is delivered to the box (not silently swallowed),
    # and the dispatch task keeps running afterwards.
    box2 = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> error("boom"), (), box2))
    @test_throws ErrorException take!(box2) isa Exception ? throw(take!(box2)) : nothing
end
```

Note: the second assertion is awkward because `take!` returns the exception object rather than throwing it. Replace with the cleaner form once you've decided the contract in Task 1.3 — see that task's note. For now, write it as:

```julia
@testset "dispatch Callback message" begin
    box = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> 6 * 7, (), box))
    @test take!(box) == 42

    box2 = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> error("boom"), (), box2))
    r = take!(box2)
    @test r isa Exception

    # dispatch task still alive
    box3 = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> :ok, (), box3))
    @test take!(box3) === :ok
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e '
  using JavaCall; JavaCall.init();
  box = Channel{Any}(1)
  push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> 1, (), box))
'
```

Expected: `UndefVarError: Callback` (or `type DispatchMsg has no subtype Callback`). Confirms the type doesn't exist yet.

### Task 1.3: Add the `Callback` type and handler

**Files:**
- Modify: `src/dispatch.jl` (add the struct next to `DeleteRef`/`Shutdown`; add the `_handle` method next to the others)

- [ ] **Step 1: Add the struct**

After the `Shutdown` struct definition, add:

```julia
"""
    Callback(handler, args, result_box) <: DispatchMsg

Run `handler(args...)` on the dispatch task's known-good (JVM-attached) OS thread
and deliver the result — or the exception, if it throws — by `put!`ing it into
`result_box::Channel{Any}`. Used by JProxies to execute Julia callbacks invoked
from Java on a thread that is guaranteed to have a valid `JNIEnv*`.

The poster is expected to `take!(result_box)` exactly once. If the handler throws,
the exception object itself is put into the box; the poster decides whether to
rethrow.
"""
struct Callback <: DispatchMsg
    handler
    args::Tuple
    result_box::Channel{Any}
end
```

- [ ] **Step 2: Add the `_handle` method**

Next to `_handle(::DeleteRef)` / `_handle(::Shutdown)`:

```julia
function _handle(msg::Callback)
    result = try
        msg.handler(msg.args...)
    catch err
        @error "JProxies callback handler threw" exception=(err, catch_backtrace())
        err
    end
    put!(msg.result_box, result)
    return nothing
end
```

Note on the contract: returning the exception object (rather than rethrowing on the dispatch task) is deliberate — the dispatch task must never die from a user callback bug. The Java-side caller (`_proxy_invoke_native`, Milestone 3) checks `result isa Exception` and raises a Java exception in response. The drain loop's own `try/catch` (already in `_drain_loop`) is a second safety net.

- [ ] **Step 3: Run the test to verify it passes**

```bash
JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()'
```

Expected: full suite passes, including the new `dispatch Callback message` testset.

- [ ] **Step 4: Commit**

```bash
git add src/dispatch.jl test/runtests.jl
git commit -m "Add Callback DispatchMsg for Java→Julia callback execution"
```

### Task 1.4: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2c/dispatch-callback -m "Merge branch 'phase-2c/dispatch-callback'"
```

---

## Milestone 2: phase-2c/jproxy-dotaccess

**Branch:** `phase-2c/jproxy-dotaccess`

Rewrite the JProxies module skeleton and ship `JProxy` dot-access with overload resolution. **No callbacks yet** — `proxy.jl` and `gen.jl` stay on disk until M4 so the package still loads, but the new code does not `include` them. We'll temporarily keep the old exports working by *not* deleting `proxy.jl` from the include list until M4? No — cleaner: this milestone fully replaces `JProxies.jl`'s body and drops `proxy.jl`/`gen.jl` from the includes immediately. The files remain in git until M4's commit deletes them.

### Task 2.1: Create branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git pull origin master
git checkout -b phase-2c/jproxy-dotaccess
```

### Task 2.2: Rewrite `JProxies/src/JProxies.jl`

**Files:**
- Modify: `JProxies/src/JProxies.jl` (full replacement)

- [ ] **Step 1: Replace the module body**

```julia
module JProxies

import JavaCall: JavaCall, JNI,
        JavaObject, JavaMetaClass, JavaLocalRef,
        JString, JObject, JClass, JMethod, JConstructor, JField,
        jint, jlong, jbyte, jboolean, jchar, jshort, jfloat, jdouble,
        @jimport, jcall, jnew, jfield, jfield!, isnull,
        getname, getclass, listmethods, listfields, getreturntype, getparametertypes,
        classforname, narrow, metaclass

# JavaCall does not currently export `jfield!` (the field setter). If it doesn't
# exist, drop it from the import and have setproperty! call the field-set path
# directly — verify in Task 2.7.

import Base: getproperty, setproperty!, convert, show

export JProxy, jproxy, @jproxy, @jimport

const _classdir = abspath(joinpath(@__DIR__, "..", "java"))

function __init__()
    # Register the bundled InvocationHandler class dir so `jproxy()` can find it.
    # Must run before JavaCall.init(); JavaCall's own __init__ only sets state, so
    # ordering across packages works as long as the user has not yet called init().
    isdir(_classdir) && JavaCall.addClassPath(_classdir)
end

"""
    JProxies.init(args...)

Convenience: forwards to `JavaCall.init`, then performs the one-time native
registration needed for `jproxy()` callbacks. Safe to call when you only need
`JProxy` dot-access (the native registration is lazy).
"""
function init(args...)
    JavaCall.init(args...)
    return nothing
end

include("dotaccess.jl")
include("native.jl")
include("callbacks.jl")

end # module
```

Note: `native.jl` and `callbacks.jl` don't exist yet. To keep this milestone self-contained, **temporarily** comment out those two `include` lines and the `jproxy`/`@jproxy` parts of `export`. The M3 tasks re-enable them. So for M2 the bottom of the file is:

```julia
export JProxy, @jimport          # jproxy, @jproxy added in M3

include("dotaccess.jl")
# include("native.jl")           # M3
# include("callbacks.jl")        # M3

end # module
```

### Task 2.3: Write the failing dot-access test

**Files:**
- Modify: `JProxies/test/runtests.jl` (full replacement is fine — old tests reference removed API)

- [ ] **Step 1: Replace the test file**

```julia
using JProxies
using Test

# Match the main package's required env (set by the test harness, but be explicit).
JProxies.init(JavaCall.JULIA_COPY_STACKS_DOC === nothing ? [] : []; )  # placeholder
# Actually just:
# JProxies.init()
```

Stop — keep it simple. The real first lines:

```julia
using JProxies
import JProxies: JavaCall
using Test

JProxies.init()

JArrayList = @jimport java.util.ArrayList
JSystem    = @jimport java.lang.System
JMath      = @jimport java.lang.Math

@testset "JProxy instance dot-access" begin
    a = JProxy(JArrayList(()))
    @test a.size() == 0
    a.add("one")
    a.add("two")
    @test a.size() == 2
    @test a.get(0) == "one"           # narrowed: returns a Julia String
    @test a.isEmpty() == false
    a.clear()
    @test a.isEmpty() == true
end

@testset "JProxy static dot-access" begin
    m = JProxy(JMath)
    @test m.abs(-3) == 3
    @test isapprox(m.sin(0.0), 0.0; atol=1e-12)
    s = JProxy(JSystem)
    # getProperty(String) -> String
    @test s.getProperty("java.version") isa AbstractString
end

@testset "JProxy field access" begin
    # java.lang.Integer.MAX_VALUE — static final field via the Type wrapper
    JInteger = @jimport java.lang.Integer
    @test JProxy(JInteger).MAX_VALUE == typemax(Int32)
end

@testset "overload resolution: tie throws" begin
    # If no candidate is reachable, error clearly.
    a = JProxy(JArrayList(()))
    @test_throws Exception a.thisMethodDoesNotExist(1, 2, 3)
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()'
```

Expected: fails — `dotaccess.jl` doesn't exist, `include` errors, or `JProxy` undefined.

### Task 2.4: Implement `dotaccess.jl` — `JProxy` and field access

**Files:**
- Create: `JProxies/src/dotaccess.jl`

- [ ] **Step 1: Create the file with the type and `getproperty`**

```julia
# Dot-access on Java objects: JProxy(obj).method(args...) and JProxy(obj).field.
# No runtime eval; overload resolution is a small quality-score ladder, cached.

"""
    JProxy(obj::JavaObject)        # instance methods + instance fields
    JProxy(::Type{JavaObject{T}})  # static methods + static fields

Ergonomic wrapper around a Java object (or class). `jp.name` is either a field
read (if `name` is a field) or a `JProxyMethod` that resolves overloads when
called. `jp.name = v` writes a field. Use the underlying `JavaObject` (via
`unwrap(jp)`) when you need explicit `jcall` control.
"""
struct JProxy{T, W}
    wrapped::W
end

JProxy(obj::JavaObject{T}) where {T} = JProxy{T, JavaObject{T}}(obj)
JProxy(::Type{JavaObject{T}}) where {T} = JProxy{T, Type{JavaObject{T}}}(JavaObject{T})

unwrap(jp::JProxy) = getfield(jp, :wrapped)

_is_static(::JProxy{T, Type{JavaObject{T}}}) where {T} = true
_is_static(::JProxy) = false

show(io::IO, jp::JProxy{T}) where {T} =
    print(io, _is_static(jp) ? "JProxy(", JavaObject{T}, ")" : "JProxy{$T}(…)")
# (fix the static-branch print — `print(io, "JProxy(", JavaObject{T}, ")")`)

function getproperty(jp::JProxy, name::Symbol)
    w = unwrap(jp)
    fields = listfields(w isa Type ? w : w, String(name))
    if !isempty(fields)
        return narrow(jfield(w, String(name), _objtype_or_prim(getreturntype_of_field(fields[1]))))
    end
    return JProxyMethod{typeof(jp)}(jp, name)
end
```

The field path above has two unknowns to resolve in Step 2/3: how `jfield` is actually called for a reflected `JField` (it may take `(receiver, JField)` directly rather than name+type), and the helper names. Replace the field branch with whatever matches `src/reflect.jl` + `src/core.jl`. Likely correct form, given `src/reflect.jl` `listfields` returns `JField`s and `src/core.jl` `jfield(obj, name, fieldType)`:

```julia
function getproperty(jp::JProxy, name::Symbol)
    w = unwrap(jp)
    flds = listfields(w, String(name))
    if !isempty(flds)
        ftype = _objtype_or_prim(getreturntype_of_field(flds[1]))
        return narrow(jfield(w, String(name), ftype))
    end
    return JProxyMethod{typeof(jp)}(jp, name)
end
```

If `jfield` requires the *Julia* representation type for primitives (e.g. `jint`), `_objtype_or_prim` returns that; for class-typed fields it returns `JavaObject{Symbol(getname(fieldClass))}`. Implement:

```julia
# Map a reflected Java class (the type of a field or a method parameter/return)
# to the Julia-side type jcall/jfield expect.
const _PRIM_BY_NAME = Dict(
    "boolean" => jboolean, "byte" => jbyte, "char" => jchar, "short" => jshort,
    "int" => jint, "long" => jlong, "float" => jfloat, "double" => jdouble,
    "void" => Nothing,
)

function _objtype_or_prim(cls::JClass)
    n = getname(cls)
    haskey(_PRIM_BY_NAME, n) && return _PRIM_BY_NAME[n]
    # Arrays: getName returns e.g. "[I" or "[Ljava.lang.String;". For v0.9.0 we
    # treat them as JObject and let convert/narrow sort it out (matches old behavior).
    startswith(n, "[") && return JavaObject{Symbol("java.lang.Object")}
    return JavaObject{Symbol(n)}
end

# `getreturntype` is for JMethod; a JField's type comes from `getType`.
getreturntype_of_field(f::JField) = jcall(f, "getType", JClass, ())
```

- [ ] **Step 2: Add `setproperty!`**

```julia
function setproperty!(jp::JProxy, name::Symbol, value)
    w = unwrap(jp)
    flds = listfields(w, String(name))
    isempty(flds) && throw(ArgumentError("$(typeof(jp)) has no field $name"))
    ftype = _objtype_or_prim(getreturntype_of_field(flds[1]))
    # JavaCall's field setter — verify the name in Task 2.7. Candidates:
    #   jfield!(w, String(name), ftype, value)   (if exported)
    #   or use the low-level Set*Field path.
    return JavaCall.jfield(w, String(name), ftype, convert(ftype, value))  # PLACEHOLDER — see Task 2.7
end
```

Mark this clearly: **the field-setter API must be confirmed against the current `src/core.jl` in Task 2.7.** If JavaCall has no public field setter, scope field *writes* out of v0.9.0 (the spec only firmly promises reads) and make `setproperty!` throw `"field writes not supported"` — and delete the corresponding test. Decide this in Task 2.7, don't guess now.

- [ ] **Step 3: Don't run yet** — `JProxyMethod` is undefined. Continue to Task 2.5.

### Task 2.5: Implement `JProxyMethod` and the overload resolver

**Files:**
- Modify: `JProxies/src/dotaccess.jl` (append)

- [ ] **Step 1: Append the callable and resolver**

```julia
"""
    JProxyMethod{P}(jp::P, name::Symbol)

A bound, not-yet-resolved Java method. Calling it picks the best overload for the
given argument types (cached), then dispatches via `jcall` (instance) or the
static path, and `narrow`s the result.
"""
struct JProxyMethod{P}
    jp::P
    name::Symbol
end

const _RESOLVE_CACHE = Dict{Tuple{DataType, Symbol, Tuple}, JMethod}()
const _RESOLVE_LOCK = ReentrantLock()

function (m::JProxyMethod)(args...)
    jp = getfield(m, :jp)
    w = unwrap(jp)
    argtypes = map(typeof, args)
    key = (typeof(w), m.name, argtypes)
    method = lock(_RESOLVE_LOCK) do
        get!(_RESOLVE_CACHE, key) do
            _resolve_overload(w, m.name, args)
        end
    end
    rettype = _objtype_or_prim(getreturntype(method))
    paramtypes = Tuple(_objtype_or_prim(c) for c in getparametertypes(method))
    return narrow(jcall(w, String(m.name), rettype, paramtypes, args...))
end

# --- overload resolution: quality-score ladder ---------------------------------
# Tiers (lower = better): 0 exact, 1 derived (subclass), 2 implicit (box/widen),
# 3 not-reachable-without-explicit-convert => candidate rejected.
const _TIER_EXACT, _TIER_DERIVED, _TIER_IMPLICIT, _TIER_NONE = 0, 1, 2, 3

function _arg_tier(arg, paramcls::JClass)
    pn = getname(paramcls)
    # primitive parameter
    if haskey(_PRIM_BY_NAME, pn)
        pjt = _PRIM_BY_NAME[pn]
        arg isa pjt && return _TIER_EXACT
        # widening / boxing: a Julia Integer/AbstractFloat that fits
        (arg isa Integer && pjt <: Integer && typemin(pjt) <= arg <= typemax(pjt)) && return _TIER_IMPLICIT
        (arg isa Real && pjt <: AbstractFloat) && return _TIER_IMPLICIT
        return _TIER_NONE
    end
    # reference parameter
    if arg isa AbstractString
        (pn == "java.lang.String" || pn == "java.lang.CharSequence" || pn == "java.lang.Object") && return _TIER_DERIVED
        return _TIER_NONE
    end
    if arg isa JavaObject
        actual = JavaCall.getname(JavaCall.getclass(arg))
        actual == pn && return _TIER_EXACT
        # subclass / interface check via JNI.IsAssignableFrom (JavaCall has isConvertible)
        try
            JavaCall.isConvertible(JavaObject{Symbol(pn)}, arg) && return _TIER_DERIVED
        catch
        end
        return _TIER_NONE
    end
    if arg isa Bool
        (pn == "java.lang.Boolean" || pn == "java.lang.Object") && return _TIER_IMPLICIT
        return _TIER_NONE
    end
    if arg isa Integer
        (pn in ("java.lang.Long","java.lang.Integer","java.lang.Number","java.lang.Object")) && return _TIER_IMPLICIT
        return _TIER_NONE
    end
    if arg isa AbstractFloat
        (pn in ("java.lang.Double","java.lang.Float","java.lang.Number","java.lang.Object")) && return _TIER_IMPLICIT
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
            t == _TIER_NONE && (ok = false; break)
            push!(tiers, t)
        end
        ok && push!(scored, (tiers, mth))
    end
    isempty(scored) && throw(ArgumentError(
        "no overload of $(String(name)) on $(typeof(w)) accepts argument types $(map(typeof, args))"))
    # lexicographic minimum over the per-arg tier vectors
    sort!(scored, by = first)
    best_score = first(scored[1])
    ties = filter(s -> first(s) == best_score, scored)
    length(ties) > 1 && throw(ArgumentError(
        "ambiguous call $(String(name))$(map(typeof, args)): $(length(ties)) overloads match equally well"))
    return scored[1][2]
end
```

Notes for the implementer:
- `listmethods`, `getparametertypes`, `getreturntype`, `getname`, `getclass`, `narrow`, `isConvertible` are all already in JavaCall (`src/reflect.jl` / `src/convert.jl`). Confirm exact spellings and whether `listmethods` accepts a `Type{JavaObject{T}}` for the static case (it does — it reflects on the class either way).
- The static call path: `jcall(w, name, rettype, argtypes, args...)` where `w` is `Type{JavaObject{T}}` already routes to the static `_jcall` methods in `src/core.jl`. So `JProxyMethod` does **not** need a separate static branch — `jcall` dispatches on `w`. Verify with the static testset.
- The tier table is intentionally conservative for v0.9.0. It's correct for the common cases; refine in review if a real test exposes a gap. Do **not** expand it speculatively.

- [ ] **Step 2: Run the dot-access tests**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()'
```

Expected: `JProxy instance dot-access`, `JProxy static dot-access`, `JProxy field access`, `overload resolution: tie throws` all pass. Iterate on `_objtype_or_prim` / `_arg_tier` until green. If the field-write test is in the file and the setter API turns out unavailable, handle per Task 2.7 (likely: remove that part of the test, make `setproperty!` throw).

### Task 2.6: Add `unwrap` to exports (optional escape hatch)

**Files:**
- Modify: `JProxies/src/JProxies.jl`

- [ ] **Step 1**

Add `unwrap` to the `export` line so users can drop back to raw `jcall` when overload resolution can't help. One-line change. Add a one-line test: `@test JProxies.unwrap(JProxy(JArrayList(()))) isa JavaObject`.

### Task 2.7: Confirm the field API and finalize

- [ ] **Step 1: Grep the real field API**

```bash
cd /Users/brad/Projects/JavaCall.jl
grep -n "jfield\|SetObjectField\|Set.*Field\|jfield!" src/core.jl
```

- [ ] **Step 2: Make `getproperty`/`setproperty!` match what's actually there.** If there's no public field *setter*, change `setproperty!` to `throw(ArgumentError("JProxy does not support field writes (v0.9.0); use the low-level setter"))` and delete the field-write test. Update the README note accordingly in M4.

- [ ] **Step 3: Run the full subpackage test suite once more**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()'
```

Expected: all green.

- [ ] **Step 4: Commit**

```bash
cd /Users/brad/Projects/JavaCall.jl
git add JProxies/src/JProxies.jl JProxies/src/dotaccess.jl JProxies/test/runtests.jl
git commit -m "Rewrite JProxies: JProxy dot-access with overload resolution"
```

### Task 2.8: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2c/jproxy-dotaccess -m "Merge branch 'phase-2c/jproxy-dotaccess'"
```

---

## Milestone 3: phase-2c/jproxy-callbacks

**Branch:** `phase-2c/jproxy-callbacks`

The hard one. Ship `jproxy(value, iface)` — a Java object that, when its interface methods are called, invokes a Julia function on the dispatch task. Pieces: (a) the bundled Java `JavaCallInvocationHandler`; (b) `RegisterNatives` wiring of its `invokeNative` to a Julia `@cfunction`; (c) `@jproxy` macro + method table; (d) `JProxyRef` lifetime; (e) argument/result marshalling.

> **Investigation step first.** Before writing code, read `src/core.jl`'s static-call path and `src/convert.jl`'s `convert_result` / `convert_arg`, and skim how `@cfunction` is used elsewhere in the Julia/JNI ecosystem (the old `JProxies/src/proxy.jl` has a `@cfunction` precedent — read it for the calling convention even though we're not keeping the code). The marshalling helpers below are a *starting point*; adjust signatures to what JNI actually hands you.

### Task 3.1: Create branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git pull origin master
git checkout -b phase-2c/jproxy-callbacks
```

### Task 3.2: Add the bundled Java helper class

**Files:**
- Create: `JProxies/java/org/juliainterop/JavaCallInvocationHandler.java`
- Create: `JProxies/java/org/juliainterop/JavaCallInvocationHandler.class` (compiled)

- [ ] **Step 1: Write the source**

```java
package org.juliainterop;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

public final class JavaCallInvocationHandler implements InvocationHandler {
    private final long handlerId;

    public JavaCallInvocationHandler(long handlerId) {
        this.handlerId = handlerId;
    }

    @Override
    public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
        // toString/hashCode/equals on the proxy itself should not call back into Julia.
        String name = method.getName();
        if (args == null) args = new Object[0];
        if (name.equals("toString") && args.length == 0) {
            return "JuliaProxy@" + Long.toHexString(handlerId);
        }
        if (name.equals("hashCode") && args.length == 0) {
            return System.identityHashCode(proxy);
        }
        if (name.equals("equals") && args.length == 1) {
            return proxy == args[0];
        }
        Object result = invokeNative(handlerId, name, args);
        if (result instanceof Throwable) {
            throw (Throwable) result;
        }
        return result;
    }

    private static native Object invokeNative(long handlerId, String name, Object[] args);

    /** Helper invoked from Julia to build the proxy in one JNI call. */
    public static Object newProxy(long handlerId, ClassLoader loader, Class<?>[] interfaces) {
        return Proxy.newProxyInstance(loader, interfaces, new JavaCallInvocationHandler(handlerId));
    }
}
```

- [ ] **Step 2: Compile and verify**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies/java
javac org/juliainterop/JavaCallInvocationHandler.java
ls -l org/juliainterop/JavaCallInvocationHandler.class
javap -p org/juliainterop/JavaCallInvocationHandler.class | head -20
```

Expected: `.class` exists; `javap` shows `native java.lang.Object invokeNative(long, java.lang.String, java.lang.Object[])` and the constructor/`newProxy`. Commit both files.

### Task 3.3: Write the failing callback test

**Files:**
- Modify: `JProxies/test/Test.java` — add an interface and a method that takes it
- Modify: `JProxies/test/runtests.jl` — add a callback testset

- [ ] **Step 1: Extend `Test.java`**

Add (inside the existing public class `Test`, or as a sibling) something exercising a `Runnable` and a custom one-method interface returning a value:

```java
    public interface IntSupplierLike { int supply(int x); }

    public static int callSupplier(IntSupplierLike s, int x) { return s.supply(x); }

    public static String runAndReport(Runnable r) { r.run(); return "ran"; }
```

Recompile:

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies/test
javac Test.java
```

- [ ] **Step 2: Add the testset to `runtests.jl`**

```julia
@testset "jproxy callbacks" begin
    JTest = @jimport Test
    JRunnable = @jimport java.lang.Runnable

    # --- value-returning one-method interface ---
    mutable struct Doubler; calls::Int; end
    @jproxy Doubler "Test$IntSupplierLike" begin
        function supply(self, x::Integer)
            self.calls += 1
            return Int32(2x)
        end
    end
    d = Doubler(0)
    jd = jproxy(d, "Test\$IntSupplierLike")
    @test jcall(JTest, "callSupplier", jint, (@jimport("Test\$IntSupplierLike"), jint), jd, 21) == 42
    @test d.calls == 1

    # --- void Runnable ---
    flag = Ref(false)
    struct Flip; r::typeof(flag); end
    @jproxy Flip "java.lang.Runnable" begin
        run(self) = (self.r[] = true; nothing)
    end
    jr = jproxy(Flip(flag), "java.lang.Runnable")
    @test jcall(JTest, "runAndReport", JString, (JRunnable,), jr) == "ran"
    @test flag[] == true

    # --- exception in handler surfaces as a Java exception (caught by jcall as JavaCallError) ---
    struct Boom end
    @jproxy Boom "java.lang.Runnable" begin
        run(self) = error("intentional")
    end
    jb = jproxy(Boom(), "java.lang.Runnable")
    @test_throws Exception jcall(JTest, "runAndReport", JString, (JRunnable,), jb)
end
```

Note: defining a `struct` inside a `@testset` works; if `@jproxy` needs the type at macro-expansion top level, hoist the struct + `@jproxy` above the `@testset`. Decide based on how the macro is written (Task 3.5).

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()'
```

Expected: fails — `@jproxy` / `jproxy` undefined (still commented out in `JProxies.jl`).

### Task 3.4: Implement `native.jl` — registry, cfunction, marshalling, native registration

**Files:**
- Create: `JProxies/src/native.jl`

- [ ] **Step 1: Create the file**

```julia
# JNI edge for JProxies callbacks: the @cfunction Java calls into, RegisterNatives
# wiring, and object-array marshalling. Everything here runs either on a Java
# thread (the cfunction entry) or on the dispatch task (the actual handler).

struct JProxiesError <: Exception
    msg::String
end

# handler_id -> (julia_value, julia_type)
const _proxy_registry = Dict{Int64, Tuple{Any, DataType}}()
const _proxy_registry_lock = ReentrantLock()
const _next_handler_id = Ref{Int64}(1)

function _register_handler!(value)
    lock(_proxy_registry_lock) do
        id = _next_handler_id[]
        _next_handler_id[] += 1
        _proxy_registry[id] = (value, typeof(value))
        id
    end
end

_unregister_handler!(id::Int64) = lock(_proxy_registry_lock) do
    delete!(_proxy_registry, id)
end

# (julia_type, :methodName) -> handler function(self, args...)
const _proxy_method_table = Dict{Tuple{DataType, Symbol}, Function}()

# --- the native function Java's `invokeNative` is bound to --------------------
# Signature mirrors: static native Object invokeNative(long id, String name, Object[] args)
# JNI calling convention for a `static native`: (JNIEnv*, jclass, jlong, jstring, jobjectArray) -> jobject
function _proxy_invoke_native(penv::Ptr{JavaCall.JNI.JNIEnv}, _jclass::Ptr{Cvoid},
                              handler_id::Int64, jname::Ptr{Cvoid},
                              jargs::Ptr{Cvoid})::Ptr{Cvoid}
    try
        name = _jstring_to_julia(penv, jname)
        entry = lock(_proxy_registry_lock) do
            get(_proxy_registry, handler_id, nothing)
        end
        entry === nothing && return _throw_to_java(penv, "no Julia handler for id $handler_id")
        value, vtype = entry
        fn = get(_proxy_method_table, (vtype, Symbol(name)), nothing)
        fn === nothing && return _throw_to_java(penv, "$vtype does not implement $name")

        julia_args = _unmarshal_object_array(penv, jargs)

        box = Channel{Any}(1)
        push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> fn(value, julia_args...), (), box))
        result = take!(box)
        result isa Exception && return _throw_to_java(penv, sprint(showerror, result))
        return _marshal_result(penv, result)
    catch err
        # Never let a Julia exception unwind into the JVM.
        return _throw_to_java(penv, "JProxies callback failed: $(sprint(showerror, err))")
    end
end

# --- marshalling helpers (adjust to actual JNI signatures during impl) --------
function _jstring_to_julia(penv, jstr::Ptr{Cvoid})
    jstr == C_NULL && return ""
    chars = JavaCall.JNI.GetStringUTFChars(jstr, C_NULL, penv)
    s = unsafe_string(Ptr{UInt8}(chars))
    JavaCall.JNI.ReleaseStringUTFChars(jstr, chars, penv)
    return s
end

# Object[] -> Vector{Any} of JavaObjects (boxed primitives stay boxed; the handler
# can `convert` if it wants). Wrap each element as a local-ref JavaObject so the
# normal finalizer machinery applies.
function _unmarshal_object_array(penv, jarr::Ptr{Cvoid})
    jarr == C_NULL && return Any[]
    n = JavaCall.JNI.GetArrayLength(jarr, penv)
    out = Vector{Any}(undef, n)
    for i in 0:(n-1)
        elt = JavaCall.JNI.GetObjectArrayElement(jarr, i, penv)
        out[i+1] = _wrap_localref(elt)   # JavaObject{:java.lang.Object}, narrowed
    end
    return out
end

# Build a JavaObject{:java.lang.Object} from a raw local ref pointer, then narrow.
function _wrap_localref(ptr::Ptr{Cvoid})
    ptr == C_NULL && return nothing
    obj = JavaObject{Symbol("java.lang.Object")}(JavaLocalRef(ptr))   # verify constructor shape
    return narrow(obj)
end

# result -> jobject. nothing -> null. Julia primitives -> boxed (Integer->Long, etc.).
# JavaObject -> its ptr. AbstractString -> Java String.
function _marshal_result(penv, result)
    result === nothing && return Ptr{Cvoid}(C_NULL)
    if result isa JavaObject
        return Ptr{Cvoid}(JavaCall.Ptr(result))   # the raw jobject
    end
    # Convert via JavaCall's boxing converters, then take the ptr.
    boxed = if result isa AbstractString
        convert(JString, String(result))
    elseif result isa Bool
        JavaCall.box(result)            # PLACEHOLDER — use whatever convert.jl exposes
    elseif result isa Integer
        JavaCall.box(Int64(result))
    elseif result isa AbstractFloat
        JavaCall.box(Float64(result))
    else
        throw(JProxiesError("cannot marshal callback result of type $(typeof(result))"))
    end
    return Ptr{Cvoid}(JavaCall.Ptr(boxed))
end

function _throw_to_java(penv, msg::AbstractString)
    cls = JavaCall.JNI.FindClass("java/lang/RuntimeException", penv)
    JavaCall.JNI.ThrowNew(cls, msg, penv)
    return Ptr{Cvoid}(C_NULL)
end

# --- one-time native registration --------------------------------------------
const _native_registered = Ref(false)

function _ensure_native_registered()
    _native_registered[] && return
    JavaCall.assertloaded()   # JVM up — verify the actual guard name
    handlercls = JavaCall.JNI.FindClass("org/juliainterop/JavaCallInvocationHandler",
                                        JavaCall._env_cache[])
    handlercls == C_NULL && throw(JProxiesError(
        "JavaCallInvocationHandler not on classpath — did JProxies.__init__ run before JavaCall.init()?"))
    cfn = @cfunction(_proxy_invoke_native, Ptr{Cvoid},
                     (Ptr{JavaCall.JNI.JNIEnv}, Ptr{Cvoid}, Int64, Ptr{Cvoid}, Ptr{Cvoid}))
    method = JavaCall.JNI.JNINativeMethod(
        pointer(Base.unsafe_convert(Cstring, "invokeNative")),         # name
        pointer(Base.unsafe_convert(Cstring, "(JLjava/lang/String;[Ljava/lang/Object;)Ljava/lang/Object;")),  # sig
        cfn)
    # Keep the cfunction and the cstrings alive for the process lifetime.
    push!(_REGISTERED_KEEPALIVE, cfn)
    JavaCall.JNI.RegisterNatives(handlercls, [method], jint(1), JavaCall._env_cache[])
    JavaCall.geterror()
    _native_registered[] = true
    return
end

const _REGISTERED_KEEPALIVE = Any[]
```

**Implementer warnings — this is the riskiest task:**
- Every `JNI.*` call signature above (`GetStringUTFChars`, `GetObjectArrayElement`, `FindClass`, `ThrowNew`, `RegisterNatives`, `JNINativeMethod`) must be checked against `src/JNI.jl` — they take a trailing `penv::Ptr{JNIEnv}` in this codebase; the field/argument order may differ from what's written.
- `JavaCall.box` is a placeholder for whatever `src/convert.jl` provides for primitive→`java.lang.X` boxing (look for `convert(::Type{@jimport(java.lang.Integer)}, ...)` etc.). If there's no single `box`, write a tiny local helper that calls the right `convert`.
- `JNINativeMethod` construction: in this codebase it's a Julia struct mirroring the C `JNINativeMethod {char* name; char* signature; void* fnPtr;}`. The cstrings must stay rooted for the duration of the `RegisterNatives` call at minimum (and the `@cfunction` for the whole process). Using `Base.cconvert`/manual `Cstring` pointers is fidduly — prefer building them with `pointer(name_bytes)` where `name_bytes = Vector{UInt8}(codeunits("invokeNative")*"\0")` kept alive in `_REGISTERED_KEEPALIVE`.
- `assertloaded` / `_env_cache` / `geterror` / `Ptr(::JavaObject)` — confirm exact exported names; some are internal (`JavaCall._env_cache`).
- `JavaLocalRef(ptr)` constructor shape — check `src/core.jl`. A wrapped local ref from inside a JNI upcall is valid only for the duration of the upcall; since we immediately `narrow` (which may allocate a new ref) and then hand to the dispatch task synchronously while the Java thread blocks, the local ref stays valid. Document this.

- [ ] **Step 2: Don't run yet** — `callbacks.jl` and the `include`s are still off. Continue.

### Task 3.5: Implement `callbacks.jl` — `@jproxy`, `jproxy()`, `JProxyRef`

**Files:**
- Create: `JProxies/src/callbacks.jl`

- [ ] **Step 1: Create the file**

```julia
# Julia-implements-a-Java-interface. @jproxy fills _proxy_method_table at module
# load time (no eval). jproxy(value, iface) builds the Java Proxy and returns a
# JProxyRef that keeps the handler registration alive.

"""
    @jproxy YourType "java.fully.qualified.Interface" begin
        function methodName(self, args...) ... end
        otherMethod(self) = ...
    end

Registers each `function`/short-form definition in the block as the implementation
of the like-named interface method for `YourType`. Lowers to plain assignments into
`_proxy_method_table` — fully precompilable, no runtime `eval`. `self` is the Julia
value you later pass to `jproxy(self, iface)`.
"""
macro jproxy(T, iface, block)
    @assert block isa Expr && block.head === :block "@jproxy: third argument must be a begin…end block"
    assigns = Expr[]
    for stmt in block.args
        stmt isa LineNumberNode && continue
        # accept `function name(...) ... end` and `name(...) = ...`
        local fname, fexpr
        if stmt isa Expr && stmt.head === :function
            fname = stmt.args[1].args[1]
            fexpr = stmt
        elseif stmt isa Expr && stmt.head === :(=) && stmt.args[1] isa Expr && stmt.args[1].head === :call
            fname = stmt.args[1].args[1]
            fexpr = stmt
        else
            error("@jproxy: each entry must be a method definition, got: $(stmt)")
        end
        push!(assigns, quote
            local _f = $(esc(fexpr))
            $_proxy_method_table[($(esc(T)), $(QuoteNode(fname)))] = _f
        end)
    end
    quote
        $(assigns...)
        nothing
    end
end

"""
    JProxyRef{T}

Owns a registered callback handler. While alive, the Julia `value` is reachable
from `_proxy_registry` (so it won't be GC'd) and the Java `Proxy` object is held.
Substitutable for the underlying `JavaObject` anywhere `jcall`/`jnew` expect one.
On finalization it unregisters the handler; the wrapped `JavaObject`'s own
finalizer routes the ref delete through the dispatch task.
"""
mutable struct JProxyRef{T}
    obj::JavaObject{T}
    handler_id::Int64
    function JProxyRef{T}(obj::JavaObject{T}, hid::Int64) where {T}
        j = new{T}(obj, hid)
        finalizer(x -> _unregister_handler!(x.handler_id), j)
        return j
    end
end

convert(::Type{JavaObject{T}}, jp::JProxyRef{T}) where {T} = jp.obj
Base.unsafe_convert(::Type{Ptr{Cvoid}}, jp::JProxyRef) = JavaCall.Ptr(jp.obj)
JavaCall.Ptr(jp::JProxyRef) = JavaCall.Ptr(jp.obj)
show(io::IO, jp::JProxyRef{T}) where {T} = print(io, "JProxyRef{$T}(handler=", jp.handler_id, ")")

"""
    jproxy(value, interface::AbstractString) -> JProxyRef

Create a Java object implementing `interface` (a fully-qualified name, possibly
nested with `\$`) whose methods invoke the `@jproxy`-registered implementations
for `typeof(value)`, executed on the dispatch task.
"""
function jproxy(value, interface::AbstractString)
    _ensure_native_registered()
    haskey_any = any(k -> k[1] === typeof(value), keys(_proxy_method_table))
    haskey_any || throw(JProxiesError("no @jproxy methods registered for $(typeof(value))"))
    id = _register_handler!(value)
    try
        ifacecls = classforname(interface)
        # ClassLoader: use the interface's own loader (or the system loader).
        loader = jcall(ifacecls, "getClassLoader", @jimport(java.lang.ClassLoader), ())
        handlercls = @jimport "org.juliainterop.JavaCallInvocationHandler"
        ifaces = [ifacecls]   # Class<?>[] of length 1
        proxyobj = jcall(handlercls, "newProxy", JObject,
                         (jlong, @jimport(java.lang.ClassLoader), Vector{JClass}),
                         id, loader, ifaces)
        # Cast/wrap proxyobj as JavaObject{Symbol(interface)} so it dispatches right.
        typedobj = convert(JavaObject{Symbol(replace(interface, "\$" => "\$"))}, proxyobj)  # see note
        ref = JProxyRef{Symbol(interface)}(typedobj, id)
        return ref
    catch err
        _unregister_handler!(id)
        rethrow(err)
    end
end
```

**Implementer notes:**
- `jcall(handlercls, "newProxy", JObject, (jlong, ..., Vector{JClass}), id, loader, ifaces)` — the `Class<?>[]` parameter: JavaCall represents `Class[]` arguments as a Julia `Vector` of `JClass`. Confirm the array-arg convention in `src/core.jl`/`src/convert.jl`. If it can't pass a `Class[]` directly, add a one-interface-only path: have `JavaCallInvocationHandler.newProxy` take a single `Class<?>` and build `new Class[]{iface}` in Java. That's simpler and covers the spec (single-interface proxies). **Prefer this** — change the Java `newProxy` signature to `(long, ClassLoader, Class)` and recompile.
- The `JavaObject{Symbol(interface)}` "cast" is just a reinterpretation of the same ref under a different `T`; JavaCall doesn't checkcast. If there's a helper (`narrow` won't help — it picks the *runtime* class, which is `$Proxy0`). Simplest: construct directly: `JavaObject{Symbol(interface)}(proxyobj.ref)` after `proxyobj` (a `JObject`). Verify the field name (`.ref`).
- Symbols containing `$` are fine in Julia (`Symbol("Test\$IntSupplierLike")`). The `replace` line above is a no-op — delete it; just use `Symbol(interface)`.
- `classforname` is imported from JavaCall; it returns a `JClass`.

- [ ] **Step 2: Re-enable the includes and exports in `JProxies.jl`**

```julia
export JProxy, jproxy, @jproxy, @jimport, unwrap

include("dotaccess.jl")
include("native.jl")
include("callbacks.jl")
```

- [ ] **Step 3: Run the callback tests**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()'
```

Expected: `jproxy callbacks` testset passes (Doubler returns 42, Flip flips, Boom throws). Iterate on the marshalling helpers and the `newProxy` call until green. Expect this step to take the most iteration — the JNI signatures are the usual suspects. Also expect the dispatch-task error log line on the Boom case (that's correct — it's logged, not silent).

- [ ] **Step 4: Commit**

```bash
cd /Users/brad/Projects/JavaCall.jl
git add JProxies/java JProxies/src/native.jl JProxies/src/callbacks.jl JProxies/src/JProxies.jl JProxies/test/Test.java JProxies/test/Test.class JProxies/test/'Test$IntSupplierLike.class' JProxies/test/runtests.jl
git commit -m "Add jproxy() callbacks via bundled InvocationHandler and dispatch task"
```

### Task 3.6: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2c/jproxy-callbacks -m "Merge branch 'phase-2c/jproxy-callbacks'"
```

---

## Milestone 4: phase-2c/jproxies-cleanup

**Branch:** `phase-2c/jproxies-cleanup`

Delete the dead old implementation, finalize the public surface, update docs.

### Task 4.1: Create branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git pull origin master
git checkout -b phase-2c/jproxies-cleanup
```

### Task 4.2: Delete the old implementation

**Files:**
- Delete: `JProxies/src/proxy.jl`, `JProxies/src/gen.jl`

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git rm JProxies/src/proxy.jl JProxies/src/gen.jl
grep -rn "proxy.jl\|gen.jl\|@class\|staticproxy\|interfacehas" JProxies/ --include='*.jl'
```

Expected: no remaining references (the new `JProxies.jl` from M2/M3 already doesn't include them). If `grep` finds anything, fix it.

- [ ] **Step 2: Confirm no stale exports**

Open `JProxies/src/JProxies.jl`; the `export` line should be exactly `export JProxy, jproxy, @jproxy, @jimport, unwrap`. Remove any leftover `@class`, `staticproxy`, `interfacehas`.

### Task 4.3: Bump version (cosmetic)

**Files:**
- Modify: `JProxies/Project.toml`

- [ ] **Step 1**

Set `version = "0.9.0"` to match the main package's Phase 2 release train. (Main `Project.toml` may already be at `0.9.0-rc` — match its major.minor.)

### Task 4.4: Update the README

**Files:**
- Modify: `README.md` (the JProxies section)

- [ ] **Step 1: Rewrite the JProxies section**

Replace the old JProxies docs with:

```markdown
### JProxies — ergonomic Java objects and Julia callbacks

`JProxies` is a companion package (its own `Project.toml`).

**Dot-access with overload resolution:**

```julia
using JProxies
JProxies.init()
a = JProxy(@jimport(java.util.ArrayList)(()))
a.add("one"); a.add("two")
a.size()        # 2
a.get(0)        # "one"
JProxy(@jimport java.lang.Math).sin(0.0)   # static methods too
```

`jp.field` reads a field; `jp.method(args...)` resolves the best Java overload for
the Julia argument types (exact > subclass > boxing/widening; ties throw) and
returns the result `narrow`ed to its runtime class. Use `unwrap(jp)` to fall back
to raw `jcall`.

**Implementing a Java interface in Julia:**

```julia
mutable struct Counter; n::Int; end
@jproxy Counter "java.lang.Runnable" begin
    run(self) = (self.n += 1; nothing)
end
c = Counter(0)
r = jproxy(c, "java.lang.Runnable")   # pass `r` wherever Java wants a Runnable
```

Callbacks execute on JavaCall's dispatch task (a known JVM-attached thread), so
they're safe regardless of which thread Java calls from. The macro lowers to plain
table assignments — no runtime `eval`, precompile-friendly.

**Removed in 0.9.0:** the `@class` macro, `staticproxy`, and implicit
String↔JString / Vector↔JList widening. Use explicit `convert` and the low-level
`jcall` for those cases.
```

(Adjust the `init()` env note if the main README mentions required env vars — keep it consistent.)

### Task 4.5: Full test pass — both packages

- [ ] **Step 1: Main package**

```bash
cd /Users/brad/Projects/JavaCall.jl
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()'
```

Expected: all green (the only main-package change in Phase 2C was M1's `Callback`).

- [ ] **Step 2: JProxies**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()'
```

Expected: all green — dot-access, static, fields, overload tie, and callbacks.

- [ ] **Step 3: Precompile sanity (the whole point of the rewrite)**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path="..")' \
  && JULIA_NUM_THREADS=1 julia --project=. -e 'using JProxies; println("precompiled & loaded ok")'
```

Expected: no `eval`/world-age warnings, prints the ok line. (The old code emitted precompile warnings; the new code should not.)

- [ ] **Step 4: Commit**

```bash
cd /Users/brad/Projects/JavaCall.jl
git add -A
git commit -m "Remove legacy JProxies (@class/staticproxy/magic widening); update README"
```

### Task 4.6: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2c/jproxies-cleanup -m "Merge branch 'phase-2c/jproxies-cleanup'"
```

---

## Out of scope for Phase 2C (matches the spec)

- `@class` macro (define a Java class from Julia bytecode at runtime) — removed, not replaced.
- Magic auto-conversion (Julia `String`→`JString`, `Vector`→`JList` without explicit `convert`) — removed.
- Iteration over Java `Iterable`s (`for x in JProxy(jiterable)`) — separable; decide in a follow-up (Phase 2D or later).
- Multi-interface proxies — `jproxy(value, iface)` takes one interface; multi-interface can be added later if asked.
- Pre-allocated callback result boxes — premature optimization; revisit only if callbacks become a hot path.

---

## Self-Review notes (carried into execution)

- **Spec coverage:** dispatch `Callback` (M1) ✔; bundled `JavaCallInvocationHandler.{java,class}` + `RegisterNatives` + `_proxy_invoke_native` (M3) ✔; `jproxy(value, iface)` + `@jproxy` lowering to a table, no `eval` (M3) ✔; `JProxy(jobj)` instance + static dot-access (M2) ✔; overload quality-score ladder with tie-throws + cache (M2) ✔; `JProxyRef` lifetime + `convert`/`Ptr` shims + finalizer (M3) ✔; out-of-scope list ✔; v0.9.0 API line in README (M4) ✔.
- **Known soft spots (flagged inline, expect iteration during execution, not blockers):** exact `JNI.*` argument order in `native.jl`; the field *setter* API existence (M2 Task 2.7 decides — may downgrade `setproperty!` to throw); the `Class[]`-vs-single-`Class` shape of `newProxy` (recommendation: single `Class`, simpler); the precise `JavaObject`/`JavaLocalRef` constructor used to wrap raw refs; the boxing helper name in `convert.jl`.
- **Type-name consistency:** `JProxy{T,W}`, `JProxyMethod{P}`, `JProxyRef{T}`, `_proxy_method_table`, `_proxy_registry`, `_proxy_invoke_native`, `_ensure_native_registered`, `JProxiesError` used consistently across M2/M3/M4.
