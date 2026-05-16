# Phase 3 sub-project 3 — `JProxy` Iteration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `for x in JProxy(obj) … end`, `length(JProxy(obj))`, and `for (k, v) in JProxy(jmap) … end` work for `Iterable`/`Collection`/`Set`/`List`, `Map` (via `entrySet`, yielded as `Pair{Any,Any}`), Java arrays (primitive and object), and raw `Iterator` — with every yielded value passed through JProxy's existing `_juliafy` decoder.

**Architecture:** A new `JProxies/src/iterate.jl` defines `Base.iterate(jp::JProxy{T, <:JavaObject})` (and an `(jp, state)` overload), `Base.length`, `Base.eltype`, and `Base.IteratorSize`. On the first call, the iterator reflects on the wrapped object's runtime class to pick one of four strategies (`:iter` / `:map_iter` / `:prim_array` / `:obj_array`); the strategy + handle are encoded in the iteration `state` as a small discriminated tuple. Per-step methods dispatch on the tuple shape and yield `_juliafy`'d values. Reuses `JNIVector{T}` for primitive arrays and `JNI.GetObjectArrayElement` for object arrays. No changes to `src/`; everything new is in the JProxies subpackage.

**Tech Stack:** Julia 1.12+, JavaCall's existing `with_env`, `isConvertible` (`IsAssignableFrom`), `getclass`/`isarray`/`isprimitive`, `_juliafy`, `JNIVector`, and the built-in `J*` aliases (`JIterator`, `JIterable`, `JMap`, `JCollection`, `JSet`, `JObject`, `JClass`) shipped in Phase 3 sub-project 2.

**Spec:** `docs/superpowers/specs/2026-05-16-phase-3-sub3-jproxy-iteration-design.md`. Read it first.

---

## File Structure

### Created
- `JProxies/src/iterate.jl` (~140 lines) — owns `Base.iterate(jp::JProxy{T, <:JavaObject})`, `Base.iterate(jp, state)`, the `_step` dispatch (4 methods), the `_start_array` helper, `Base.length(::JProxy)`, `Base.eltype`, `Base.IteratorSize`. Header comment documents the local-ref-lifetime assumption.

### Modified
- `JProxies/src/JProxies.jl` — add `include("iterate.jl")` after `include("dotaccess.jl")` and before `include("native.jl")`. Extend the `import JavaCall: …` list with any names not already present that iterate.jl needs (`isarray`, `isprimitive`, `primitive_names_to_types`, `JCollection`, `JNIVector`, `JavaLocalRef`, `JIterable`, `JIterator`, `JMap`, `JSet`, `JObject`, `JClass`).
- `JProxies/test/Test.java` — add two static fixtures (`intArray()`, `objArray()`). Recompile `Test.class` + any companion `Test$*.class`.
- `JProxies/test/runtests.jl` — new `Phase 3 sub-3: JProxy iteration` testset covering all 10 spec test cases.
- `JProxies/src/dotaccess.jl` — append a short "Iteration" subsection to the `JProxy` docstring (docs only; no code change).
- `README.md` — one paragraph in the existing JProxies section.
- `NEWS.md` — one bullet under the existing `## Unreleased` heading.

### Not changed
- `src/` (the main JavaCall package). The existing `Base.iterate(::JavaObject, state=nothing)` in `src/convert.jl` stays byte-for-byte — it handles the iterator-as-receiver case for non-JProxy callers and is independent.
- `JProxies/src/dotaccess.jl`'s `JProxy` struct, `unwrap`, `_juliafy`, `getproperty`, `setproperty!`, `JProxyMethod` — all reused as-is.

### Why this layout
Iteration is a cohesive concept that doesn't belong in `dotaccess.jl` (which is about field/method dot-access). Keeping it in its own file lets a reviewer see the entire iteration story in one screen, and lets a future maintainer evolve iteration semantics without touching the JProxy core.

---

## Branch Organization

Same per-milestone `--no-ff` workflow as the previous sub-projects. Don't push.

1. `phase-3/sub3-iterate` — the whole iteration implementation: `iterate.jl`, Test.java fixtures, tests. One cohesive code change; tasks within it are TDD-staged.
2. `phase-3/sub3-docs` — docstring update + README paragraph + NEWS bullet. Tiny.

Sub-divided into two branches (not one) so the docs round can be reviewed and merged as a clean prose-only diff.

---

## Milestone 1: phase-3/sub3-iterate

**Branch:** `phase-3/sub3-iterate`

### Task 1.1: Create branch + Test.java fixtures + recompile

**Files:**
- Modify: `JProxies/test/Test.java`

- [ ] **Step 1: Create branch**
```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master && git pull origin master
git checkout -b phase-3/sub3-iterate
```

- [ ] **Step 2: Add the two static methods**

In `JProxies/test/Test.java`, inside the `public class Test { … }` body (after the existing methods, before the closing brace — find a sensible spot like just before the `// --- callback (jproxy) test fixtures ---` block or at the end):

```java
  // --- Phase 3 sub-3: iteration fixtures ---
  public static int[]    intArray()  { return new int[]{ 10, 20, 30 }; }
  public static Object[] objArray()  { return new Object[]{ "a", Integer.valueOf(7) }; }
```

- [ ] **Step 3: Recompile**
```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies/test
javac Test.java
ls -la Test*.class
cd ../..
```
Confirm `Test.class` rebuilt (mtime updated); `Test$TestInner.class` and `Test$IntSupplierLike.class` may also be touched.

### Task 1.2: Write the failing iteration testset

**Files:**
- Modify: `JProxies/test/runtests.jl` (append after the existing `Phase 3` testsets, before any final cleanup block / `JavaCall.destroy()`)

- [ ] **Step 1: Add the testset**

```julia
@testset "Phase 3 sub-3: JProxy iteration" begin
    JTest = @jimport Test

    # --- Iterable / Collection / List of Strings -----------------------------
    jl_strs = jnew(JArrayList)
    jcall(jl_strs, "add", "a")
    jcall(jl_strs, "add", "b")
    @test collect(JProxy(jl_strs)) == ["a", "b"]

    # --- List of boxed integers --------------------------------------------
    jl_ints = jnew(JArrayList)
    jcall(jl_ints, "add", Int32(7))
    jcall(jl_ints, "add", Int32(11))
    @test collect(JProxy(jl_ints)) == [7, 11]

    # --- Set (single element for deterministic order) -----------------------
    js = jnew(@jimport(java.util.HashSet))
    jcall(js, "add", "x")
    @test collect(JProxy(js)) == ["x"]

    # --- Map: Pair yield + destructuring ------------------------------------
    jm = jnew(JHashMap)
    jcall(jm, "put", "k1", "v1")
    @test collect(JProxy(jm)) == ["k1" => "v1"]
    let captured = nothing
        for (k, v) in JProxy(jm)
            captured = (k, v)
        end
        @test captured == ("k1", "v1")
    end

    # --- Primitive int[] (use the explicit jcall form so we get the
    #     raw JavaObject, not an auto-converted Vector{jint}) ----------------
    JIntArr = JavaObject{Symbol("[I")}
    arr_i = jcall(JTest, "intArray", JIntArr, ())
    @test collect(JProxy(arr_i)) == [10, 20, 30]

    # --- Object[] of mixed elements ----------------------------------------
    JObjArr = JavaObject{Symbol("[Ljava.lang.Object;")}
    arr_o = jcall(JTest, "objArray", JObjArr, ())
    @test collect(JProxy(arr_o)) == ["a", 7]

    # --- Raw Iterator (already an Iterator, no .iterator() call needed) -----
    it = jcall(jl_strs, "iterator", JIterator, ())
    @test collect(JProxy(it)) == ["a", "b"]

    # --- length() where defined --------------------------------------------
    @test length(JProxy(jl_strs)) == 2
    @test length(JProxy(jm)) == 1
    @test length(JProxy(arr_i)) == 3
    # raw Iterator has no length
    it2 = jcall(jl_strs, "iterator", JIterator, ())
    @test_throws ArgumentError length(JProxy(it2))

    # --- Non-iterable rejection --------------------------------------------
    jobj = jnew(@jimport(java.lang.Object))
    @test_throws ArgumentError iterate(JProxy(jobj))

    # --- Empty containers ---------------------------------------------------
    @test isempty(collect(JProxy(jnew(JArrayList))))
    @test isempty(collect(JProxy(jnew(JHashMap))))
end
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -25
```

Expected: failure on the first `collect(JProxy(jl_strs))` call — `MethodError: no method matching iterate(::JProxy{...})`. The Phase 3 sub-3 testset fails; all others pass.

### Task 1.3: Implement the file skeleton, imports, and the Iterable/Iterator/Map paths

**Files:**
- Create: `JProxies/src/iterate.jl`
- Modify: `JProxies/src/JProxies.jl`

- [ ] **Step 1: Create `iterate.jl` with the header, state-shape docs, and the Iterable/Iterator/Map paths**

```julia
# JProxy iteration — Base.iterate / length / eltype / IteratorSize.
#
# Strategy is decided once on the first iteration call (state === nothing) by
# reflecting on the wrapped Java object's runtime class:
#   1. array         → :prim_array or :obj_array (handled in Task 1.4)
#   2. Iterator      → step `w` directly as the iterator
#   3. Map           → call w.entrySet().iterator(), step it, yield Pair{Any,Any}
#   4. Iterable      → call w.iterator(), step it, yield each elem
#   5. otherwise     → ArgumentError
#
# State shape encodes the strategy + the live handle:
#   (:iter,       iter::JavaObject)                           # Iterable & raw-Iterator paths
#   (:map_iter,   iter::JavaObject)                           # iterator of an entrySet()
#   (:prim_array, jnivec::JNIVector, len::Int, i::Int)        # i is the next 0-based index
#   (:obj_array,  arr::JavaObject,    len::Int, i::Int)
#
# Local-ref lifetime: this code runs from regular Julia tasks, NOT from a
# RegisterNatives upcall — so JNI local refs created by next() / GetObjectArrayElement
# persist past the call and are freed when the wrapping JavaObject is finalized.
# For very large iterations callers can wrap the loop in jlocalframe.

"""
    Base.iterate(jp::JProxy)
    Base.iterate(jp::JProxy, state)

Iterate a `JProxy` wrapping a Java `Iterable`, `Collection`, `Set`, `List`, `Map`,
Java array, or raw `Iterator`. Each yielded element is run through
[`_juliafy`](@ref): narrowed to its runtime class, then `JString`s decode to Julia
`String`s and boxed primitives unbox to `jint`/`jdouble`/etc. For `Map`, yields
Julia `Pair{Any,Any}` so `for (k, v) in JProxy(jmap) … end` destructures cleanly.
Throws `ArgumentError` if the wrapped object isn't one of the supported shapes.
"""
function Base.iterate(jp::JProxy{T, W}) where {T, W<:JavaObject}
    w = unwrap(jp)
    isnull(w) && throw(ArgumentError("JProxy iteration on a Java null reference"))
    cls = getclass(w)
    if isarray(cls)
        return _start_array(w, cls)        # defined in Task 1.4
    elseif isConvertible(JIterator, w)
        return _step((:iter, w))
    elseif isConvertible(JMap, w)
        entrySet = jcall(w, "entrySet", JSet, ())
        return _step((:map_iter, jcall(entrySet, "iterator", JIterator, ())))
    elseif isConvertible(JIterable, w)
        return _step((:iter, jcall(w, "iterator", JIterator, ())))
    else
        throw(ArgumentError("JProxy iteration: $(getname(cls)) is neither an array, an Iterable, a Map, nor an Iterator"))
    end
end

Base.iterate(jp::JProxy{T, W}, state) where {T, W<:JavaObject} = _step(state)

# :iter and :map_iter share the (Symbol, JavaObject) shape.
function _step(state::Tuple{Symbol, JavaObject})
    iter = state[2]
    if jcall(iter, "hasNext", jboolean, ()) == 0x01
        if state[1] === :map_iter
            entry = jcall(iter, "next", JObject, ())
            k = _juliafy(jcall(entry, "getKey",   JObject, ()))
            v = _juliafy(jcall(entry, "getValue", JObject, ()))
            return (k => v, state)
        else
            obj = jcall(iter, "next", JObject, ())
            return (_juliafy(obj), state)
        end
    else
        return nothing
    end
end
```

Notes:
- `JNI_TRUE` is `0x01` (a `jboolean` literal). The spec used `JNI_TRUE`; using the literal `0x01` here avoids an extra import if `JNI_TRUE` isn't already imported into `JProxies`. Either form works — verify with the existing code's idiom (e.g. `JProxies/src/dotaccess.jl` and `JProxies/src/native.jl` both use `== 0x01` directly).
- `entrySet` returns a `JSet` (since `Map.entrySet()` is declared to return `Set<Map.Entry>`). `JSet` exists from sub-2 M1.
- The `(state[1], …)` re-bundling in `_step` for array cases keeps the symbol — see Task 1.4.

- [ ] **Step 2: Wire the include**

In `JProxies/src/JProxies.jl`, add `include("iterate.jl")` after `include("dotaccess.jl")` and before `include("native.jl")`:

```julia
include("dotaccess.jl")
include("iterate.jl")
include("native.jl")
include("callbacks.jl")
```

- [ ] **Step 3: Update the imports**

In the same file, the `import JavaCall: …` block needs the names `iterate.jl` will use. Some are already imported (verify the current list first via `grep "^import JavaCall" JProxies/src/JProxies.jl`). Add any that aren't already there: `isarray`, `isConvertible`, `getclass`, `getname`, `JIterable`, `JIterator`, `JMap`, `JSet`, `JObject`, `JClass`, `JCollection`, `isnull`, `narrow`, `unsafe_string`, `jcall`, `jboolean`, `JString`. (Most are already in the block from earlier milestones — only add what's missing.)

- [ ] **Step 4: Run tests — expect the array cases to fail (not yet implemented)**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -30
```

Expected: the Iterable/Iterator/Map cases AND the rejection case pass. The array, length, and `length`-on-Iterator cases fail (`_start_array` undefined, `length` undefined). Specifically: a `MethodError` or `UndefVarError` on the `arr_i` line, plus the `length` assertions error.

### Task 1.4: Implement the array paths

**Files:**
- Modify: `JProxies/src/iterate.jl` (append)

- [ ] **Step 1: Append `_start_array` and the array `_step` methods**

```julia
# Array detection — dispatch on the component type's primitive-vs-reference.
function _start_array(w::JavaObject, cls::JClass)
    component = jcall(cls, "getComponentType", JClass, ())
    len = with_env() do env
        Int(JNI.GetArrayLength(Ptr(w), env))
    end
    if isprimitive(component)
        # The component's getName() returns "int" / "double" / etc. — map to the
        # JNI primitive Julia type via JavaCall's primitive_names_to_types table.
        comp_name = getname(component)
        eltype = primitive_names_to_types[Symbol(comp_name)]
        # JNIVector{T}(ref) takes a JavaLocalRef wrapping the raw jarray pointer.
        # The constructor at src/jniarray.jl owns the ref; we don't need to
        # promote to JavaGlobalRef because iteration happens synchronously from
        # the calling task — the array stays live for the loop's duration.
        jnivec = JNIVector{eltype}(JavaLocalRef(Ptr(w)))
        return _step((:prim_array, jnivec, len, 0))
    else
        return _step((:obj_array, w, len, 0))
    end
end

# :prim_array — index a JNIVector{T}; T elements come out already-unboxed.
function _step(state::Tuple{Symbol, JNIVector, Int, Int})
    sym, jnivec, len, i = state
    i >= len && return nothing
    return (jnivec[i+1], (sym, jnivec, len, i+1))
end

# :obj_array — JNI.GetObjectArrayElement per index; wrap + _juliafy.
function _step(state::Tuple{Symbol, JavaObject, Int, Int})
    sym, arr, len, i = state
    i >= len && return nothing
    elem = with_env() do env
        ptr = JNI.GetObjectArrayElement(Ptr(arr), jint(i), env)
        ptr == C_NULL ? nothing : JObject(JavaLocalRef(ptr))
    end
    return (_juliafy(elem), (sym, arr, len, i+1))
end
```

**Implementer notes:**
- `JNIVector{T}(JavaLocalRef(Ptr(w)))` — verify against `src/jniarray.jl:35`'s constructor `JNIVector{T}(ptr::Ptr{Nothing})`. If that constructor accepts a raw `Ptr{Nothing}` directly, simpler: `JNIVector{eltype}(Ptr(w))`. Adjust to whichever the existing constructor exposes; the `JavaLocalRef` wrap may not be necessary. The goal is the same: take ownership of the array ref enough to index into it.
- **Critical lifetime concern:** the `JNIVector{T}(ptr)` constructor wraps the SAME underlying ref as `w` (the user-facing `JProxy`'s JavaObject). Both have finalizers that call `DeleteLocalRef`. If both fire, you double-free. Verify how `src/jniarray.jl`'s `JNIVector{T}(ptr)` handles ref ownership — if it claims ownership (its own `deleteref` will fire when GC'd, and `w`'s `deleteref` will also fire), you have a problem. Two safe options: (a) construct `JNIVector` with a *new* local ref via `JNI.NewLocalRef(Ptr(w), env)` so each wrapper owns its own ref; (b) construct via a special constructor that doesn't own the ref. Read `jniarray.jl`'s implementation and pick the right pattern. **If unclear, ESCALATE rather than guessing — double-free corrupts the JVM.**
- `getname(component)` for a primitive returns `"int"`, `"long"`, `"boolean"`, etc. (matches `primitive_names_to_types` keys).
- `JNI.GetObjectArrayElement` returns a new local ref each call. `JObject(JavaLocalRef(ptr))` takes ownership; its finalizer (eventually) calls `DeleteLocalRef`. Fine.

- [ ] **Step 2: Run tests — array cases should now pass**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -20
```

Expected: the `arr_i` and `arr_o` assertions pass. `length` assertions still fail (next task).

### Task 1.5: Implement `length`, `eltype`, `IteratorSize`

**Files:**
- Modify: `JProxies/src/iterate.jl` (append)

- [ ] **Step 1: Append**

```julia
function Base.length(jp::JProxy{T, W}) where {T, W<:JavaObject}
    w = unwrap(jp)
    cls = getclass(w)
    if isarray(cls)
        return with_env() do env
            Int(JNI.GetArrayLength(Ptr(w), env))
        end
    elseif isConvertible(JCollection, w)
        return Int(jcall(w, "size", jint, ()))
    elseif isConvertible(JMap, w)
        return Int(jcall(w, "size", jint, ()))
    else
        throw(ArgumentError("JProxy: length not defined for $(getname(cls)) (no .size() and not an array)"))
    end
end

Base.eltype(::Type{<:JProxy}) = Any
Base.IteratorSize(::Type{<:JProxy}) = Base.SizeUnknown()
```

- [ ] **Step 2: Run the full JProxies suite**

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -15
```

Expected: every testset green — dot-access, static, fields, callbacks, GC-pressure, AND the new `Phase 3 sub-3: JProxy iteration` testset (all ~14 assertions). The expected `@error "JProxies callback handler threw"` from the Boom callback test is unrelated noise.

- [ ] **Step 3: Also run the main JavaCall suite (regression check)**

```bash
cd /Users/brad/Projects/JavaCall.jl
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10
```

Expected: `Testing JavaCall tests passed` (no JavaCall code changed; this is paranoia).

### Task 1.6: Commit & merge

- [ ] **Step 1: Commit**

```bash
git add JProxies/src/iterate.jl JProxies/src/JProxies.jl JProxies/test/Test.java JProxies/test/Test*.class JProxies/test/runtests.jl
git commit -m "Add Base.iterate / length for JProxy: Iterable/Map/array/Iterator"
```

- [ ] **Step 2: Merge to master**

```bash
git checkout master
git merge --no-ff phase-3/sub3-iterate -m "Merge branch 'phase-3/sub3-iterate'"
```

---

## Milestone 2: phase-3/sub3-docs

**Branch:** `phase-3/sub3-docs`

Tiny milestone: a docstring subsection, a README paragraph, and a NEWS bullet.

### Task 2.1: Create branch
```bash
git checkout master && git pull origin master && git checkout -b phase-3/sub3-docs
```

### Task 2.2: Append "Iteration" subsection to the `JProxy` docstring

**Files:**
- Modify: `JProxies/src/dotaccess.jl` (the docstring on `struct JProxy{T, W}`)

- [ ] **Step 1**

The existing `JProxy` docstring (at the top of `dotaccess.jl`) ends with a paragraph about `unwrap(jp)`. Append a new "Iteration" paragraph immediately after it (before the closing `"""`):

```markdown

# Iteration

A `JProxy` wrapping a Java `Iterable`, `Collection`, `Set`, `List`, `Map`, Java
array, or raw `Iterator` is iterable. Each yielded value is passed through the
same Java→Julia decoding used for `JProxy.method(...)` results — so
`for s in JProxy(jstringList) … end` yields Julia `String`s, and
`for n in JProxy(jintList) … end` yields `jint`s. Map iteration yields Julia
`Pair{Any,Any}`, so `for (k, v) in JProxy(jmap) … end` destructures cleanly.
`length(JProxy(jp))` works for `Collection`, `Map`, and arrays; raw `Iterator`s
throw `ArgumentError` (no known size).
```

### Task 2.3: Update README

**Files:**
- Modify: `README.md` (the JProxies-area section added in Phase 2C M4 / extended in sub-2 M3)

- [ ] **Step 1: Find the JProxies section**

```bash
grep -n "JProxy\|## " README.md | head -20
```

Locate the existing JProxies section that introduces `JProxy(obj).method(...)`.

- [ ] **Step 2: Add an "Iteration" paragraph at the end of that section**

```markdown
**Iteration.** `for x in JProxy(obj) … end` works on Java `Iterable`/`Collection`/`Set`/`List`, `Map`,
Java arrays (primitive and object), and raw `Iterator`. Maps yield `Pair{Any,Any}` so destructuring
works: `for (k, v) in JProxy(jmap); println("$k → $v"); end`. Each element is decoded the same way
JProxy method-call results are (narrowed; `JString` → `String`; boxed primitives unboxed). Use
`length(JProxy(obj))` for sized containers (`Collection`/`Map`/array); raw `Iterator`s have no
known length and `length` on them throws.
```

### Task 2.4: Update NEWS.md

**Files:**
- Modify: `NEWS.md` (the existing `## Unreleased` section at the top)

- [ ] **Step 1: Add a bullet under `### Added`**

```markdown
- `for x in JProxy(jobj) … end` now works for Java `Iterable`/`Collection`/`Set`/`List`,
  `Map`, Java arrays, and raw `Iterator`. Maps yield `Pair{Any,Any}` so
  `for (k, v) in JProxy(jmap) … end` destructures. `Base.length` is defined for
  `Collection`/`Map`/array (raw `Iterator`s throw `ArgumentError`). Each yielded
  element is decoded the same way `JProxy(obj).method(...)` results are
  (`narrow` + `JString`→`String` + boxed-primitive→Julia).
```

### Task 2.5: Sanity-check tests

- [ ] **Step 1**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
```

Expected: green. (Docs don't run tests, but confirm nothing broke.)

### Task 2.6: Commit & merge

- [ ] **Step 1**
```bash
git add JProxies/src/dotaccess.jl README.md NEWS.md
git commit -m "Doc Phase 3 sub-3: JProxy iteration in JProxy docstring + README + NEWS"
```

- [ ] **Step 2**
```bash
git checkout master && git merge --no-ff phase-3/sub3-docs -m "Merge branch 'phase-3/sub3-docs'"
```

---

## After all milestones

- A final review pass over the whole Phase 3 sub-project 3 (spec coverage + holistic code review subagent).
- This is the last sub-project in Phase 3. With it merged, the natural next steps (separate from this plan):
  - The deferred `src/convert.jl` cleanup onto sub-2's multi-import grammar.
  - A v0.10.0 release: bump `Project.toml`/`JProxies/Project.toml` versions; rename `NEWS.md`'s `## Unreleased` heading to `## v0.10.0`; tag.
  - Revisit `IteratorSize = HasLength()` if real-world `collect` performance demands it (Phase 4 ergonomics tweak).

---

## Self-Review notes (carried into execution)

- **Spec coverage:** Iterable/Iterator/Map/array detection (M1.3 + M1.4) ✔; `_juliafy` decoding of yielded values (M1.3 `_step` + M1.4 obj-array) ✔; Map yields `Pair{Any,Any}` for destructuring (M1.3 `:map_iter` branch) ✔; `length` for Collection/Map/array, raw-Iterator throws (M1.5) ✔; `eltype = Any`, `IteratorSize = SizeUnknown` (M1.5) ✔; rejection error for unsupported types (M1.3 fallback) ✔; tests for every spec case (M1.2) ✔; docstring/README/NEWS (M2) ✔; static `JProxy` not iterable — natural `MethodError`, no special-case ✔; `src/` untouched ✔.

- **Known soft spots (flagged inline, expect iteration during execution):**
  - The `JNIVector{T}(JavaLocalRef(Ptr(w)))` ref-ownership question is the genuine hazard (M1.4 implementer note). If the existing `JNIVector` constructor takes ownership of the ref, double-free will crash the JVM the first time GC fires on either the JProxy-wrapped array or the JNIVector view. Verify against `src/jniarray.jl` — and if unclear, escalate.
  - `entrySet` returns a `JSet`; confirm `JSet` is reachable in JProxies' import list (sub-2 M1 shipped it; verify).
  - The `JIntArr = JavaObject{Symbol("[I")}` / `JObjArr = JavaObject{Symbol("[Ljava.lang.Object;")}` type literals are the JNI internal class signatures for `int[]` and `Object[]` — verify they parse and dispatch correctly through `jcall`'s explicit-form path. If they don't, fall back to fetching the raw return via the reflected JMethod path (`r = listmethods(JTest, "intArray")[1]; arr = jcall(JTest, r)`).
  - `jboolean` literal compare — the file uses `== 0x01` directly because the existing JProxies code (`dotaccess.jl:79`, `native.jl`) does. If the project's style prefers `== JNI_TRUE`, import `JNI_TRUE` and use that. Pick consistency over preference.

- **Type/name consistency:** state symbols `:iter` / `:map_iter` / `:prim_array` / `:obj_array` used identically in `_start_array`, `Base.iterate`, and the three `_step` methods. `_juliafy`, `unwrap`, `getproperty` etc. reused from `dotaccess.jl` without modification. `JCollection`, `JMap`, `JSet`, `JIterable`, `JIterator`, `JObject`, `JClass` all come from sub-2 M1's broader alias set — confirm they're imported into JProxies before relying on them.
