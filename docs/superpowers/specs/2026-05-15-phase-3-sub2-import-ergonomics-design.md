# Phase 3 sub-project 2 — `@jimport` Import Ergonomics — Design

**Status:** approved 2026-05-15. Second sub-project of Phase 3 ("API ergonomics"). The headline sub-project 1 (`jcall`/`@jcall`/`jnew` overload resolution) is already shipped; sub-project 3 (`JProxy` iteration) is a separate spec.

## Problem

Every JavaCall caller binds the same handful of Java class types over and over:

```julia
JArrayList = @jimport java.util.ArrayList
JHashMap   = @jimport java.util.HashMap
JMap       = @jimport java.util.Map
JList      = @jimport java.util.List
JIterator  = @jimport java.util.Iterator
# ... and so on, in every file
```

`src/convert.jl` repeats `@jimport(java.util.X)` ~10 times in a few hundred lines. JProxies, `src/jvm.jl`, the test suite, and every downstream package (`JDBC.jl`, `Spark.jl`, `Taro.jl`) do the same. The library already ships a small fixed set of pre-bound aliases — `JObject`, `JClass`, `JString`, `JMethod`, `JConstructor`, `JField`, `JThread`, `JClassLoader` — but the set is small and the per-call rebinding pattern is just visual noise.

Sub-project 2 reduces that friction with two purely-additive changes: a `using`-style multi-import grammar for `@jimport`, and a broader set of ready-to-use `J*` aliases for the most-common standard-library classes.

## Goals

- New `@jimport` grammars that bind multiple class types in one statement:
  - Colon (`using`-style): `@jimport java.util: ArrayList, HashMap, Map` plus rename `@jimport java.util: ArrayList => JArrayList, HashMap => JHashMap`.
  - Tuple (cross-package): `@jimport (java.util.ArrayList, java.lang.System)` plus rename `@jimport (java.util.ArrayList => JArrayList, java.lang.System => JSystem)`.

  *Rename syntax note:* `=>` (the `Pair` operator) is used for rename rather than the `as` keyword. Julia's `as` is a soft keyword recognised only inside `using/import` clauses; outside those contexts, `ArrayList as JArrayList` is a parse error, so the macro would never see it. `=>` parses cleanly anywhere as a binary operator expression (`Expr(:call, :(=>), short, target)`) and reads naturally as "ArrayList becomes JArrayList".
- Ship 31 additional `J*` `const` aliases in `src/core.jl` (full list below), exported from `JavaCall`, so the common cases need no `@jimport` at all.
- Existing single-class forms (`@jimport java.util.ArrayList`, `@jimport "java.util.ArrayList"`, `@jimport(Outer$Inner)`) and the existing `JObject`/`JClass`/`JString`/`JMethod`/`JConstructor`/`JField`/`JThread`/`JClassLoader` aliases are unchanged byte-for-byte.

## Non-goals (out of scope)

- **Breaking changes** to the existing `@jimport` forms or aliases. Additive only.
- **Nested-class dotted sugar** (`@jimport java.util.Map.Entry`) — `.` is ambiguous between packages and nested classes; the existing `@jimport(Outer$Inner)` escape stays.
- **`@jimport`-into-a-module / `@javapackage`** — recorded as deferred for a possible future sub-project; the multi-import + broader aliases cover the majority of the friction.
- **Cross-package colon syntax** (`@jimport java.util: A, java.lang: B`) — split into two statements.
- **Classpath validation at macro-expansion time** — `@jimport` does no JNI work; an unresolvable class fails at first use, same as today.
- **The post-merge clean-up pass** that condenses `src/convert.jl`'s repeated `@jimport(...)` calls onto the new grammar — valuable but mechanical and separable; filed as a follow-up after this sub-project lands so the diff stays purely additive.

---

## Public API surface

### Colon form

```julia
@jimport java.util: ArrayList                                    # one name
@jimport java.util: ArrayList, HashMap, Map                      # several
@jimport java.util: ArrayList => JArrayList, HashMap => JHashMap # with rename
```

- The prefix (`java.util` here) is the package; everything after the `:` is the comma-separated import list.
- Each entry is either a bare class Symbol (`ArrayList`) or a rename pair (`ArrayList => JArrayList`).
- Lowers to `Expr(:block, target1 = JavaObject{Symbol("java.util.ArrayList")}, target2 = ..., ...)`. With no `=>`, the target is the bare short name (`ArrayList`); with `=> JX`, it's `JX`.
- One package per statement. Two packages = two statements.

### Tuple form

```julia
@jimport (java.util.ArrayList, java.lang.System)
@jimport (java.util.ArrayList => JArrayList, java.lang.System => JSystem)
@jimport (java.util.ArrayList,)                                  # single-element tuple == multi-import of 1
```

- Each tuple entry is a fully-qualified dotted FQN (`Expr` of `:.`) or a rename pair (`FQN => target`) where the left-hand side is such an FQN.
- Default target name is the FQN's last segment (`ArrayList` for `java.util.ArrayList`); `=>` overrides.
- Lowers to the same `Expr(:block, ...)` of assignments.

### Existing forms (unchanged)

```julia
@jimport java.util.ArrayList         # returns JavaObject{Symbol("java.util.ArrayList")} (a Type)
@jimport "java.util.ArrayList"
@jimport ArrayList                   # bare Symbol — no package, returns JavaObject{:ArrayList}
@jimport(Outer$Inner)                # nested-class escape, unchanged
```

These continue to *return* the type (suitable for inline use: `convert(@jimport(java.util.Date), x)`). The new multi-import forms *emit assignments* (not a returned value); attempting to use a multi-import form as an expression value is a macro-expansion error.

### New built-in `J*` aliases (31)

Added to `src/core.jl` directly below the existing alias block (currently `core.jl:308-315`), grouped by package with one-line comments. Each is exported from `JavaCall`.

```julia
# Collections / util
const JList       = JavaObject{Symbol("java.util.List")}
const JArrayList  = JavaObject{Symbol("java.util.ArrayList")}
const JMap        = JavaObject{Symbol("java.util.Map")}
const JHashMap    = JavaObject{Symbol("java.util.HashMap")}
const JSet        = JavaObject{Symbol("java.util.Set")}
const JHashSet    = JavaObject{Symbol("java.util.HashSet")}
const JCollection = JavaObject{Symbol("java.util.Collection")}
const JIterator   = JavaObject{Symbol("java.util.Iterator")}
const JIterable   = JavaObject{Symbol("java.lang.Iterable")}
const JComparator = JavaObject{Symbol("java.util.Comparator")}

# Boxed primitives
const JNumber    = JavaObject{Symbol("java.lang.Number")}
const JBoolean   = JavaObject{Symbol("java.lang.Boolean")}
const JByte      = JavaObject{Symbol("java.lang.Byte")}
const JCharacter = JavaObject{Symbol("java.lang.Character")}
const JShort     = JavaObject{Symbol("java.lang.Short")}
const JInteger   = JavaObject{Symbol("java.lang.Integer")}
const JLong      = JavaObject{Symbol("java.lang.Long")}
const JFloat     = JavaObject{Symbol("java.lang.Float")}
const JDouble    = JavaObject{Symbol("java.lang.Double")}

# java.lang misc
const JCharSequence = JavaObject{Symbol("java.lang.CharSequence")}
const JThrowable    = JavaObject{Symbol("java.lang.Throwable")}
const JException    = JavaObject{Symbol("java.lang.Exception")}
const JRunnable     = JavaObject{Symbol("java.lang.Runnable")}

# IO
const JFile         = JavaObject{Symbol("java.io.File")}
const JInputStream  = JavaObject{Symbol("java.io.InputStream")}
const JOutputStream = JavaObject{Symbol("java.io.OutputStream")}
const JReader       = JavaObject{Symbol("java.io.Reader")}
const JWriter       = JavaObject{Symbol("java.io.Writer")}

# Util extras
const JDate       = JavaObject{Symbol("java.util.Date")}
const JCalendar   = JavaObject{Symbol("java.util.Calendar")}
const JProperties = JavaObject{Symbol("java.util.Properties")}
```

Existing 8 aliases (`JObject`, `JClass`, `JString`, `JMethod`, `JConstructor`, `JField`, `JThread`, `JClassLoader`) are unchanged. Total: 39 `J*` exported aliases.

---

## Macro implementation (`src/core.jl`)

The current `@jimport` is three small methods (Expr / Symbol / AbstractString) dispatching to a private `_jimport(juliaclass::AbstractString)` that returns the `:(JavaObject{Symbol($juliaclass)})` expression. The new shapes plug in by detecting their AST shape *before* the existing dispatch.

### Detecting the new shapes

- **Colon form**: the input parses as `Expr(:call, :(:), prefix, body)` where `prefix` is a dotted expression and `body` is either a single Symbol or `Expr(:tuple, entry1, entry2, ...)`. The macro:
  1. Renders the prefix with `sprint(Base.show_unquoted, prefix)` → `"java.util"`.
  2. Walks the body: each entry is either a Symbol (`:ArrayList`) → `short=target=:ArrayList`, or `Expr(:call, :(=>), short::Symbol, target::Symbol)` → `(short, target)`.
  3. Emits `Expr(:block, [Expr(:(=), esc(target), :(JavaObject{Symbol($("$prefix.$short"))})) for each]...)`.
- **Tuple form**: the input parses as `Expr(:tuple, entry1, entry2, ...)`. Each entry is either a dotted FQN Expr → render it, take the last `.`-segment as the default short name, OR an `Expr(:call, :(=>), fqn, target::Symbol)` → render `fqn`, use `target` as the target. Emits the same `Expr(:block, ...)` shape.
- **Anything else** falls through to the existing Expr/Symbol/AbstractString dispatch, which is byte-for-byte unchanged.

### Hygiene

- Each emitted assignment target is `esc(target)` so the binding lands in the caller's scope (module-top-level → module-global; inside a function → local; matches Julia's macro-expansion rules).
- The RHS is a constant `Type` expression (`JavaObject{Symbol(literal_string)}`) — no escape needed.

### Error handling

A clear macro-expansion-time error for unparseable shapes. Suggested wording, raised from a single `error(...)` call inside the macro:

- `"@jimport: expected `short` or `short => target` after `:`, got `$bad`."`
- `"@jimport: tuple entries must be fully-qualified class expressions (e.g. `java.util.ArrayList`) or `FQN => Target`, got `$bad`."`
- `"@jimport: empty colon-form import list."`
- `"@jimport: rename target (right-hand side of `=>`) must be a Symbol, got `$bad`."`

`@test_throws LoadError (@eval @jimport ...)` is the safe catch for these in tests (a macro-expansion `error(...)` surfaces as `LoadError` through `@eval`, matching the convention established in Phase 3 sub-project 1).

### Bare-Symbol classification edge

Today `@jimport ArrayList` (a Symbol, no package) returns `JavaObject{:ArrayList}` — useful only for the very rare unpackaged class. The colon form's `prefix : body` shape never collides with this because a bare Symbol can't be a `:call` of `:`. Confirmed by reading the `@jimport(class::Symbol)` method at `src/core.jl:359-362`.

### Built-in aliases — placement

Added as new `const` lines directly below `src/core.jl:315` (after the existing `JString` line). Grouped by package with one-line comments, in the order listed above. Each new name is appended to the `export` line in `src/JavaCall.jl` (the existing block containing `JObject, JClass, JMethod, ...`). The docstring on the existing alias block expands to mention the broader set; a single docstring above the whole group is sufficient (Julia attaches the docstring to the first `const` and a doc on the group reads naturally).

---

## Testing

Two new testsets in `test/jcall_macro.jl`:

### `Phase 3 sub-2: @jimport multi-import`

- **Regression** — every existing `@jimport ...` form still works: bind `@jimport java.util.ArrayList`, `@jimport "java.util.ArrayList"`, `@jimport(Test$TestInner)` and assert the returned type. (Copy/adapt assertions from the existing `inner_classes_1` and similar testsets if they're not already covered there.)
- **Colon form** — `@jimport java.util: ArrayList`, then `@test ArrayList === JavaObject{Symbol("java.util.ArrayList")}`. `@jimport java.util: ArrayList, HashMap, Map` binds three locals; each is the expected type.
- **Colon form with renames** — `@jimport java.util: ArrayList => JAL, HashMap => JHM`; assert `JAL` / `JHM` are the expected types. Mix: `@jimport java.util: ArrayList => JAL, HashMap` binds both `JAL` and `HashMap`.
- **Tuple form** — `@jimport (java.util.ArrayList, java.lang.System)`. Single-element tuple: `@jimport (java.util.ArrayList,)`.
- **Tuple form with renames** — `@jimport (java.util.ArrayList => JAL, java.lang.System => JSys)`.
- **Nested classes** in the new forms — `@jimport (Test$TestInner,)` and the colon-form equivalent if it parses (Julia's parser may not accept a `$` Symbol in this position; if it doesn't, document the limitation and verify the tuple form covers it).
- **Macro-expansion errors** — `@test_throws LoadError (@eval @jimport java.util:)` (empty list), `@test_throws LoadError (@eval @jimport java.util: 42)` (non-Symbol entry), `@test_throws LoadError (@eval @jimport (java.util.ArrayList => 5,))` (non-Symbol rename target).
- **Scope** — inside a `let` block, a colon-form binding stays local (asserted via a top-level-scope check that the names aren't in `Main` after the let).

### `Phase 3 sub-2: built-in J* aliases`

- Spot-check ~6 aliases across the categories: `JList === JavaObject{Symbol("java.util.List")}`, `JArrayList`, `JInteger`, `JRunnable`, `JFile`, `JDate`. Assert each is exported (`@test :JList in names(JavaCall)` or via `JavaCall.JList === JList`).
- A "smoke" call exercising one in real code: `a = jnew(JArrayList); jcall(a, "size") == 0` (uses the resolved `jcall` and `jnew` from sub-project 1, so this is also an integration test that the alias is usable as a class type).

The full suite (`Pkg.test()`) must remain green; JProxies suite likewise — no JProxies code changes.

---

## Docs & migration

- The `@jimport` docstring in `src/core.jl` gains a "Multi-import" subsection with one concrete example per shape (colon + rename, tuple + rename). Existing single-class examples stay first.
- The README's "Calling Java" section gets a short paragraph: "If you need several classes from one package, use the `using`-style colon syntax: `@jimport java.util: ArrayList, HashMap`. For cross-package imports, use a tuple: `@jimport (java.util.ArrayList, java.lang.System)`. Both forms accept `=>` renames (`@jimport java.util: ArrayList => JArrayList`). JavaCall already ships built-in aliases for the standard-library's most-common classes — `JList`, `JArrayList`, `JMap`, `JHashMap`, `JInteger`, `JRunnable`, `JFile`, and others — so the common cases need no `@jimport` at all."
- A short `NEWS.md` entry under the next minor-version heading. The actual version (`0.10.0` vs `0.9.x`) is decided at release; this sub-project doesn't bump `Project.toml`.
- No deprecation of existing forms — they're equally idiomatic.

## Compatibility

Strictly additive. No downstream package or user code changes behavior. The new aliases shadow nothing in `Base` (`JList`/`JMap`/etc. don't exist in `Base`); they could in theory collide with user-defined module-global names of the same identifier, but `using JavaCall` always warns on import-conflicts and the existing `JObject`/`JString`/etc. set hasn't caused issues. The multi-import macro forms don't affect the single-class forms.

## The rest of Phase 3 (separate sub-projects)

- **Sub-project 3 — `JProxy` iteration** (`Base.iterate` on `JProxy` wrapping `java.lang.Iterable`/`Collection`/`Map`/Java arrays). Builds on sub-project 1's `resolve_call`. Own spec.
- **Misc** (configurable dispatch-channel size; pre-allocated callback boxes) — recorded as deferred / dropped per the Phase 3 sub-project 1 design.
