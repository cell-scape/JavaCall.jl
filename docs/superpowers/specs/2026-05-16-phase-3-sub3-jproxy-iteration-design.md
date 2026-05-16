# Phase 3 sub-project 3 — `JProxy` Iteration — Design

**Status:** approved 2026-05-16. Third (and final) sub-project of Phase 3 ("API ergonomics"). Sub-project 1 (`jcall`/`@jcall`/`jnew` overload resolution) and sub-project 2 (`@jimport` multi-import + built-in `J*` aliases) are already shipped.

## Problem

A `JProxy` wrapping a `java.util.ArrayList` (or any `Iterable`/`Collection`/`Set`/`Map`/Java array) is not iterable today:

```julia
list = jnew(JArrayList); jcall(list, "add", "a"); jcall(list, "add", "b")
for x in JProxy(list)           # MethodError: no method matching iterate(::JProxy{…})
    …
end
```

Users currently have to drop back to manual `iterator()` / `hasNext()` / `next()` calls (`src/convert.jl` exports `iterator(obj)` and `has_next(itr)` and even defines `Base.iterate(::JavaObject, …)`, but only for the case where the receiver *is* an Iterator — `Iterable`s need an extra step). Maps are not iterable at all. Java arrays need yet another path (`JNIVector` for primitives; `JNI.GetObjectArrayElement` for object arrays).

Sub-project 3 makes `for x in JProxy(obj) … end` (and `collect`, `length`, and tuple destructuring of Map entries) work for the natural cases: `java.lang.Iterable` and subtypes, `java.util.Map`, Java arrays (primitive or object), and `java.util.Iterator` itself.

## Goals

- **`Base.iterate(jp::JProxy{T, <:JavaObject})`** detects the wrapped Java type's iteration kind at the first call and yields values via the right strategy.
- **Element decoding** matches the existing `JProxy` contract: every yielded value is run through `_juliafy` (narrow → `JString`→Julia `String` → boxed primitive→Julia primitive), so `for s in JProxy(jstringList) … end` yields Julia `String`s and `for n in JProxy(jintList) … end` yields `jint`s.
- **Map iteration** yields Julia `Pair{Any,Any}` so destructuring (`for (k, v) in JProxy(jmap) … end`) Just Works.
- **`Base.length(jp::JProxy)`** is defined for the cases where Java exposes a size: Collections, Maps, and arrays. Raw Iterators have no known length; calling `length` on them throws `ArgumentError` with a clear message.
- **`Base.eltype`** = `Any` (Java generics are erased at runtime).
- **`Base.IteratorSize`** = `Base.SizeUnknown()` (we can't dispatch the Java class hierarchy at the type-parameter level — see the trade-off note in "Non-goals").
- Existing behavior unchanged: the legacy `Base.iterate(::JavaObject, …)` in `src/convert.jl` and the `iterator(obj)` / `has_next(itr)` helpers stay byte-for-byte the same.

## Non-goals (out of scope)

- **`IteratorSize = HasLength()`** for sized cases. Would let `collect` pre-size its output. Trades a small perf win for either (a) parameterizing `JProxy` on a kind tag (breaking change) or (b) a separate `JIterableProxy`/`JMapProxy`/etc. type tree (scope creep). `SizeUnknown` is acceptable for v0.10; `length` is defined where it works.
- **Static `JProxy{T, Type{JavaObject{T}}}` iteration.** Class types aren't iterable; the no-method `MethodError` is the right error. No special-cased message.
- **Java `Stream`s** — users `.collect(Collectors.toList())` first.
- **Mutating iterators (`Iterator.remove()`)** — out of scope; rare in Julia idiom anyway.
- **`for x in jcall_result_directly`** without `JProxy` — `Base.iterate(::JavaObject, …)` already exists in `src/convert.jl` (and handles the iterator-as-receiver case). We don't change it; users opt into the new full behavior by wrapping in `JProxy`.
- **Deprecating the old `Base.iterate(::JavaObject, …)`** in `src/convert.jl` — separate decision; breaking change. Recorded as a follow-up.

---

## Public API surface

All additive. No existing method is changed.

### `Base.iterate(jp::JProxy{T, <:JavaObject})`

```julia
for s in JProxy(jstringList)             # Iterable → _juliafy each elem; yields Julia Strings
    println(s)
end
for (k, v) in JProxy(jmap)               # Map → entrySet → yield Pair{Any,Any}
    println("$k → $v")
end
for x in JProxy(jintArray)               # int[] → JNIVector{jint} view; yields jints
    @show x
end
for o in JProxy(jobjectArray)            # Object[] → GetObjectArrayElement; _juliafy
    @show o
end
for it in JProxy(jrawIterator)           # already an Iterator → step it directly
    @show it
end
```

On the first call (`state === nothing`), the iterator decides the strategy by reflecting on the wrapped object's runtime class:
1. `getclass(w).isArray()` → array strategy (sub-branched into primitive vs object array).
2. else `isConvertible(JIterator, w)` → step `w` itself as the iterator.
3. else `isConvertible(JMap, w)` → call `w.entrySet()`, then `.iterator()`, then iterate as a map-entry stream.
4. else `isConvertible(JIterable, w)` → call `w.iterator()`, then step the iterator.
5. else `throw(ArgumentError("JProxy iteration: <FQN> is neither an array, an Iterable, a Map, nor an Iterator"))`.

The strategy is encoded in the iteration `state` (a small tuple — see Implementation) so subsequent steps don't re-reflect.

### `Base.length(jp::JProxy)`

Defined when the wrapped object exposes a size:
- Array → `JNI.GetArrayLength(Ptr(w), env)` (inside `with_env`).
- `isConvertible(JCollection, w)` → `jcall(w, "size", jint, ())`.
- `isConvertible(JMap, w)` → `jcall(w, "size", jint, ())`.
- else → `throw(ArgumentError("JProxy: length not defined for $(class) (no .size() and not an array)"))`. Raw `Iterator`s and bare `Iterable`s that aren't `Collection`s fall here.

Returns `Int`.

### `Base.eltype(::Type{<:JProxy}) = Any`

Constant — Java generics are erased. Per-instance refinement is not attempted.

### `Base.IteratorSize(::Type{<:JProxy}) = Base.SizeUnknown()`

Always. See Non-goals for why we don't refine.

### What stays unchanged

- `src/convert.jl`'s `iterator(obj)`, `has_next(itr)`, and `Base.iterate(itr::JavaObject, state=nothing)` are untouched. The latter still works for the case where the receiver is itself an `Iterator`.
- `JProxy{T, Type{JavaObject{T}}}` (static, class-type) is *not* given an `iterate` method. Iterating a class throws `MethodError` — the right error.

---

## Implementation — `JProxies/src/iterate.jl` (new, ~120 lines)

A new file in JProxies, included from `JProxies/src/JProxies.jl` after `dotaccess.jl` (which defines `JProxy`, `unwrap`, `_juliafy`) and before `native.jl`. Owns one responsibility: iteration for `JProxy`.

### State shape

A discriminated tuple keyed by strategy. No new struct — tuples keep allocations minimal and match Julia's iteration convention:

- `(:iter, iter_obj::JavaObject)` — used by both the "we called `.iterator()` and got this back" path and the "wrapped object was already an Iterator" path. `_step(:iter, …)` calls `hasNext` + `next` on the inner `iter_obj` and yields `_juliafy(elem)`.
- `(:map_iter, iter_obj::JavaObject)` — `iter_obj` is the iterator of an `entrySet()`. `_step(:map_iter, …)` calls `hasNext` + `next` to get a `Map.Entry`, then `getKey()` and `getValue()` on it, returning `_juliafy(k) => _juliafy(v)` and the same state.
- `(:prim_array, jnivec::JNIVector{T}, len::Int, i::Int)` — `i` is the next 0-based index. `_step` returns `(jnivec[i+1], (:prim_array, jnivec, len, i+1))` until `i == len`. Reuses the existing `JNIVector` machinery; its existing finalizer handles ref cleanup.
- `(:obj_array, arr::JavaObject, len::Int, i::Int)` — for object arrays. `_step` uses `JNI.GetObjectArrayElement` inside `with_env`, wraps the returned `jobject` as a `JObject` (whose finalizer takes ownership), and returns `(_juliafy(JObject(ptr)), (:obj_array, arr, len, i+1))`.

### Detection (the `state === nothing` branch)

```julia
function Base.iterate(jp::JProxy{T, W}) where {T, W<:JavaObject}
    w = unwrap(jp)
    isnull(w) && throw(ArgumentError("JProxy iteration on a Java null reference"))
    cls = getclass(w)
    if isarray(cls)
        return _start_array(w, cls)
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

Base.iterate(jp::JProxy{T, <:JavaObject}, state) = _step(state)
```

`_start_array(w, cls)` peels the component type via `getComponentType` and dispatches on primitive-vs-object:

```julia
function _start_array(w::JavaObject, cls::JClass)
    component = jcall(cls, "getComponentType", JClass, ())
    len = with_env() do env; Int(JNI.GetArrayLength(Ptr(w), env)) end
    if isprimitive(component)
        eltype = primitive_names_to_types[Symbol(getname(component))]
        jnivec = JNIVector{eltype}(JavaLocalRef(Ptr(w)))   # verify constructor + lifetime — see Implementer Notes
        return _step((:prim_array, jnivec, len, 0))
    else
        return _step((:obj_array, w, len, 0))
    end
end
```

### `_step` — one method per strategy

```julia
function _step(state::Tuple{Symbol, JavaObject})
    iter = state[2]
    if jcall(iter, "hasNext", jboolean, ()) == JNI_TRUE
        if state[1] === :map_iter
            entry = jcall(iter, "next", JObject, ())
            k = _juliafy(jcall(entry, "getKey",   JObject, ()))
            v = _juliafy(jcall(entry, "getValue", JObject, ()))
            return (k => v, state)
        else  # :iter
            obj = jcall(iter, "next", JObject, ())
            return (_juliafy(obj), state)
        end
    else
        return nothing
    end
end

function _step(state::Tuple{Symbol, JNIVector, Int, Int})  # :prim_array
    (_, jnivec, len, i) = state
    i >= len && return nothing
    return (jnivec[i+1], (state[1], jnivec, len, i+1))
end

function _step(state::Tuple{Symbol, JavaObject, Int, Int})  # :obj_array
    (_, arr, len, i) = state
    i >= len && return nothing
    elem = with_env() do env
        ptr = JNI.GetObjectArrayElement(Ptr(arr), jint(i), env)
        ptr == C_NULL ? nothing : JObject(JavaLocalRef(ptr))
    end
    return (_juliafy(elem), (state[1], arr, len, i+1))
end
```

### `Base.length`

```julia
function Base.length(jp::JProxy{T, W}) where {T, W<:JavaObject}
    w = unwrap(jp)
    cls = getclass(w)
    if isarray(cls)
        return with_env() do env; Int(JNI.GetArrayLength(Ptr(w), env)) end
    elseif isConvertible(JCollection, w)
        return Int(jcall(w, "size", jint, ()))
    elseif isConvertible(JMap, w)
        return Int(jcall(w, "size", jint, ()))
    else
        throw(ArgumentError("JProxy: length not defined for $(getname(cls)) (no .size() and not an array)"))
    end
end
```

### `Base.eltype` / `Base.IteratorSize`

```julia
Base.eltype(::Type{<:JProxy}) = Any
Base.IteratorSize(::Type{<:JProxy}) = Base.SizeUnknown()
```

### Imports added to `JProxies/src/JProxies.jl`

Append to the existing `import JavaCall: …` block: `isarray, isprimitive, primitive_names_to_types, getComponentType` (if a helper exists; otherwise we use `jcall(component, "getName", …)` inline), `JCollection`, `JNIVector`, `JavaLocalRef`. `JIterable`, `JIterator`, `JMap`, `JSet`, `JObject`, `JClass` were already shipped in sub-2 M1 and may already be imported — verify and don't double-add.

### Implementer notes (carry into the plan)

- **`JNIVector{T}(JavaLocalRef(Ptr(w)))` constructor shape** — verify against `src/jniarray.jl`. The existing `JNIVector{T}(ptr::Ptr{Nothing})` constructor at `src/jniarray.jl:35` should accept the raw pointer. The wrapping `JavaLocalRef` may not be needed if the constructor takes a raw pointer directly. Adjust to match.
- **Local-ref lifetime on object-array iteration** — `JNI.GetObjectArrayElement` returns a local ref scoped to the calling thread's current native-method frame. JProxy iteration runs from regular Julia code (not inside a `RegisterNatives` upcall), so local refs persist until `DeleteLocalRef` is called. Wrapping each in a `JObject` whose finalizer routes the cleanup is the normal pattern (same as `narrow`'s internal refs). No special handling required, but document this assumption in the file's header comment so a future maintainer doesn't repeat the JProxies-callback investigation.
- **`getComponentType`** doesn't have a Julia-side helper in the current codebase; either add a tiny one to `JProxies/src/iterate.jl` (`_component_type(cls) = jcall(cls, "getComponentType", JClass, ())`) or call inline. Don't pollute `src/reflect.jl` with it unless it'd be useful elsewhere.

---

## Testing — `Phase 3 sub-3: JProxy iteration` testset in `JProxies/test/runtests.jl`

Cases:

- **Iterable / Collection / List of Strings** — `jl = jnew(JArrayList); jcall(jl, "add", "a"); jcall(jl, "add", "b"); @test collect(JProxy(jl)) == ["a", "b"]`.
- **List of boxed integers** — `jl = jnew(JArrayList); jcall(jl, "add", Int32(7)); jcall(jl, "add", Int32(11))`; assert `collect(JProxy(jl)) == [7, 11]` (the boxed `java.lang.Integer`s come back as `jint`s).
- **Set** — single-element `HashSet` (deterministic order); same shape.
- **Map (Pair yield + destructuring)** — `jm = jnew(JHashMap); jcall(jm, "put", "k1", "v1")`; assert `collect(JProxy(jm)) == ["k1" => "v1"]`; then `for (k, v) in JProxy(jm); …; end` correctly binds `k="k1", v="v1"`.
- **Primitive array (`int[]`)** — fixture: `static int[] intArray() { return new int[]{10, 20, 30}; }` in `JProxies/test/Test.java`; recompile. Call via the explicit `jcall(JTest, "intArray", JavaObject{Symbol("[I")}, ())` to get the raw array (the resolved-`jcall` path may auto-convert to `Vector{jint}` — sidestep that here so we test the JProxy-iteration path). Then `@test collect(JProxy(arr)) == [10, 20, 30]`.
- **Object array (`Object[]`)** — fixture: `static Object[] objArray() { return new Object[]{ "a", Integer.valueOf(7) }; }`; assert `collect(JProxy(arr)) == ["a", 7]` (`_juliafy` decodes both elements).
- **Raw Iterator** — `it = jcall(jl, "iterator", JIterator, ())` after `jl` has elements; `@test collect(JProxy(it)) == ["a", "b"]`.
- **`length`** — `@test length(JProxy(jl)) == 2`, `@test length(JProxy(jm)) == 1`, `@test length(JProxy(arr)) == 3`; raw-Iterator: `@test_throws ArgumentError length(JProxy(it))`.
- **Non-iterable rejection** — `jobj = jnew(@jimport(java.lang.Object)); @test_throws ArgumentError iterate(JProxy(jobj))`.
- **Empty containers** — `collect(JProxy(jnew(JArrayList))) == []`; `collect(JProxy(jnew(JHashMap))) == Pair{Any,Any}[]`.
- **Existing JProxies tests** stay green (dot-access, callbacks, GC-pressure stress, etc.).

The main JavaCall suite is untouched and should remain green.

---

## Docs

- `JProxies/src/dotaccess.jl`'s `JProxy` docstring gets a short "Iteration" subsection: lists the four supported shapes (Iterable / Map / array / Iterator), the `Pair{Any,Any}` semantics for Maps, the `length`-where-defined contract, and the `_juliafy`-decoded element shape.
- `README.md`'s JProxies section gets a one-paragraph note about iteration with one concrete example (Map destructuring is the most striking).
- `NEWS.md`'s existing `## Unreleased` section gains one bullet: "`for x in JProxy(jobj) … end` now works for `Iterable`/`Collection`/`Set`/`List`/`Map`/Java arrays/`Iterator`. Maps yield `Pair{Any,Any}` so `for (k, v) in JProxy(jmap) … end` destructures. `Base.length` is defined where Java exposes a size."

## Compatibility

Strictly additive. The only consumer-visible new behavior is: `for … in JProxy(obj)` and `length(JProxy(obj))` now succeed where they previously errored. No existing code path changes.

## Risks

- **Performance:** every iteration step makes 1–2 JNI calls (`hasNext` + `next`, or `GetObjectArrayElement`). Acceptable — the consumer is asking for ergonomics, not raw throughput. Hot inner loops should keep using the low-level forms.
- **Local-ref accumulation:** under a long iteration (millions of elements), JNI local refs from each `next()` accumulate until Julia GC finalizes the `JObject` wrappers. The `_juliafy` decode often drops the wrapper immediately (for boxed primitives and Strings, the `JavaObject` is short-lived after `_juliafy` converts it). For object-array iteration over very large arrays, callers wanting deterministic cleanup can wrap the loop in `jlocalframe`. Document in the implementer-notes section of the plan; not a code change for v1.
- **Map ordering:** `HashMap` doesn't guarantee iteration order; tests use single-element maps or `LinkedHashMap` for determinism. Same constraint Java users live with.

---

## The rest of Phase 3 (closes the sub-project tree)

This is the last sub-project. With it merged, Phase 3 "API ergonomics" is fully delivered:
- Sub-project 1 ✔ `jcall`/`@jcall`/`jnew` overload resolution.
- Sub-project 2 ✔ `@jimport` multi-import + 31 built-in `J*` aliases.
- Sub-project 3 (this) — `JProxy` iteration.

Post-merge, the natural follow-ups are the deferred items recorded in earlier specs: `src/convert.jl` cleanup onto the new multi-import grammar; a v0.10.0 release (versioning + NEWS rename from `Unreleased` to `0.10.0`); revisit `IteratorSize = HasLength()` if real-world `collect` performance demands it. None are part of this sub-project.
