# Phase 3 sub-project 2 — `@jimport` Import Ergonomics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add purely-additive ergonomics to `@jimport`: a `using`-style colon multi-import grammar (`@jimport java.util: ArrayList, HashMap => JHashMap`), a tuple multi-import grammar (`@jimport (java.util.ArrayList, java.lang.System)`), and 31 built-in `J*` aliases for the most-common Java standard-library classes.

**Architecture:** The existing `@jimport(class::Expr)` method dispatches on AST shape *before* falling back to its current FQN-render behavior — detecting `Expr(:call, :(:), prefix, body)` (colon form) and `Expr(:tuple, ...)` (tuple form), each lowered to an `Expr(:block, ...)` of assignments. The 31 new aliases are one-line `const`s in the existing alias block in `src/core.jl`, exported from `JavaCall`. Strictly additive — existing single-class forms (`@jimport java.util.ArrayList`, `"…"`, `Outer$Inner`) are byte-for-byte unchanged.

**Tech Stack:** Julia 1.12+, the existing `_jimport(::AbstractString)` helper, `sprint(Base.show_unquoted, ...)` for FQN rendering.

**Spec:** `docs/superpowers/specs/2026-05-15-phase-3-sub2-import-ergonomics-design.md`. Read it first.

---

## File Structure

### Modified
- `src/core.jl` — three changes:
  1. The `@jimport(class::Expr)` method gains a leading dispatch on `class.head` (colon → multi-import; tuple → multi-import; anything else → existing FQN path, unchanged).
  2. New private helpers `_jimport_colon(prefix, body)`, `_jimport_tuple(entries)`, and `_parse_short_entry(entry)` / `_parse_tuple_entry(entry)` emit the assignment blocks.
  3. 31 new `const J* = JavaObject{Symbol("...")}` lines added directly below the existing alias block (after `const JString = ...` on what's currently `src/core.jl:315`), grouped by package with one-line comments.
- `src/JavaCall.jl` — `export` line gains the 31 new alias names.
- `test/jcall_macro.jl` — new testsets `Phase 3 sub-2: @jimport multi-import` and `Phase 3 sub-2: built-in J* aliases`.
- `README.md` — the "Calling Java" section gains one paragraph about the new forms + built-in aliases.
- `NEWS.md` — an entry under the next unreleased-minor heading.

### Not changed in this plan (deferred)
- `src/convert.jl` — its 10+ repeated `@jimport(java.util.X)` calls *could* be condensed to one colon-form block, but the spec explicitly puts that refactor in a follow-up to keep this plan's diff purely additive.
- `JProxies/` — no changes.
- `Project.toml` versions — bumped at release time, not here.

### Why this layout
The macro additions and the alias additions are independent enough that they could land on separate branches and still build/test cleanly; they share only `src/core.jl` and the export list. Splitting them into two small milestones makes each diff one-screen and isolates the rollback unit if either side regresses. The docs/NEWS milestone is tiny but kept separate so the implementation merges aren't gated on writing prose.

---

## Branch Organization

Same multi-branch workflow as Phase 2 / Phase 3 sub-project 1. Each milestone is one branch off `master`, full test pass at the end, then `git merge --no-ff` to master. Fixups get `phase-3/sub2-<name>-fixup` branches, also `--no-ff` merged. Don't push.

1. `phase-3/sub2-aliases` — 31 new `J*` consts + exports + a small testset asserting they're bound right and exported.
2. `phase-3/sub2-multi-import` — the colon and tuple multi-import grammars + their testset + an updated `@jimport` docstring.
3. `phase-3/sub2-docs` — README JProxies-area paragraph + NEWS.md entry.

Order matters lightly: M2's testset benefits from M1's aliases being present (the smoke-test uses `JArrayList`), but it doesn't strictly depend on them. M3 depends on both being merged so the README references work code.

---

## Milestone 1: phase-3/sub2-aliases

**Branch:** `phase-3/sub2-aliases`

Ship the 31 built-in aliases plus their exports and a verification testset. No macro changes here.

### Task 1.1: Create branch

- [ ] **Step 1**
```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master && git pull origin master
git checkout -b phase-3/sub2-aliases
```

### Task 1.2: Write the failing aliases testset

**Files:**
- Modify: `test/runtests.jl` (append a testset near the existing Phase 3 testsets; if unsure where, append before the final `end`)

- [ ] **Step 1: Add the testset**

```julia
@testset "Phase 3 sub-2: built-in J* aliases" begin
    # Spot-check one alias from each category — they should all be:
    #   - exported by JavaCall
    #   - bound to JavaObject{Symbol("<the fully-qualified name>")}
    spot = [
        (:JList,       "java.util.List"),
        (:JArrayList,  "java.util.ArrayList"),
        (:JHashMap,    "java.util.HashMap"),
        (:JInteger,    "java.lang.Integer"),
        (:JLong,       "java.lang.Long"),
        (:JRunnable,   "java.lang.Runnable"),
        (:JFile,       "java.io.File"),
        (:JDate,       "java.util.Date"),
    ]
    exported = Set(names(JavaCall))
    for (name, fqn) in spot
        @test name in exported
        @test getfield(JavaCall, name) === JavaObject{Symbol(fqn)}
    end
    # End-to-end smoke test using the resolved jcall/jnew forms (from sub-project 1):
    a = jnew(JArrayList)
    @test jcall(a, "size") == 0
    jcall(a, "add", "one")
    @test jcall(a, "size") == 1
    # Integer alias usable as a class type — a quick reflection probe:
    @test JavaCall.getname(classforname("java.lang.Integer")) == "java.lang.Integer"
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "Phase 3 sub-2: built-in|UndefVarError|JavaCall tests"
```

Expected: the testset errors with `UndefVarError: JList` (or the first absent alias) — the names aren't defined yet.

### Task 1.3: Add the 31 const aliases

**Files:**
- Modify: `src/core.jl` (insert immediately after `const JString = JavaObject{Symbol("java.lang.String")}` — currently line 315)

- [ ] **Step 1: Insert the alias block**

Insert the following block right after the existing `const JString = ...` line:

```julia

# Phase 3 sub-2: broader set of built-in JavaObject{Symbol("…")} aliases for the
# most-common Java standard-library classes. Each is exported from JavaCall.

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

(31 new `const` lines.)

- [ ] **Step 2: Extend the existing alias-block docstring**

The existing alias block has a docstring above `const JClass = ...` (currently `src/core.jl:337-344`) that names `JObject, JClass, JMethod, JConstructor, JField, JThread, JClassLoader, JString`. Update it to mention the broader set without enumerating all 31 names — keep it readable:

Replace the existing docstring body:

```julia
"""
    JObject, JClass, JMethod, JConstructor, JField, JThread, JClassLoader, JString

Convenience aliases for [`JavaObject{T}`](@ref) over commonly-used Java classes —
`JObject === JavaObject{Symbol("java.lang.Object")}`, `JString ===
JavaObject{Symbol("java.lang.String")}`, etc. They are used pervasively as
return-type / argument-type arguments to [`jcall`](@ref).
"""
```

with:

```julia
"""
    JObject, JClass, JString, JMethod, JConstructor, JField, JThread, JClassLoader,
    JList, JArrayList, JMap, JHashMap, JSet, JHashSet, JCollection, JIterator,
    JIterable, JComparator, JNumber, JBoolean, JByte, JCharacter, JShort, JInteger,
    JLong, JFloat, JDouble, JCharSequence, JThrowable, JException, JRunnable, JFile,
    JInputStream, JOutputStream, JReader, JWriter, JDate, JCalendar, JProperties

Convenience aliases for [`JavaObject{T}`](@ref) over commonly-used Java classes —
e.g. `JString === JavaObject{Symbol("java.lang.String")}`, `JArrayList ===
JavaObject{Symbol("java.util.ArrayList")}`. They are used pervasively as
return-type / argument-type arguments to [`jcall`](@ref) and as the first
argument to [`jnew`](@ref).
"""
```

### Task 1.4: Export the new aliases

**Files:**
- Modify: `src/JavaCall.jl` (the `export` block — currently the line beginning `export JavaObject, JavaMetaClass, JNIVector, ...`)

- [ ] **Step 1: Append the new names**

The existing export block (around `src/JavaCall.jl:10-21`) currently contains, on its `JObject, JClass, ...` line:

```julia
       JObject, JClass, JMethod, JConstructor, JField, JString,
```

Replace that line with the same eight names followed by all 31 new aliases, on as many lines as fits the file's existing wrapping style. Concretely:

```julia
       JObject, JClass, JMethod, JConstructor, JField, JString,
       JList, JArrayList, JMap, JHashMap, JSet, JHashSet, JCollection, JIterator,
       JIterable, JComparator, JNumber, JBoolean, JByte, JCharacter, JShort,
       JInteger, JLong, JFloat, JDouble, JCharSequence, JThrowable, JException,
       JRunnable, JFile, JInputStream, JOutputStream, JReader, JWriter, JDate,
       JCalendar, JProperties,
```

Leave the rest of the export block untouched.

### Task 1.5: Run the suite green

- [ ] **Step 1**

```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10
```

Expected: `Testing JavaCall tests passed`. The new `Phase 3 sub-2: built-in J* aliases` testset passes. Pre-existing `@error "JProxies callback handler threw"` (from the M1 `dispatch Callback message` testset) and `@warn "Taro.jl testing failed"` are noise, not failures.

### Task 1.6: Commit & merge

- [ ] **Step 1**
```bash
git add src/core.jl src/JavaCall.jl test/runtests.jl
git commit -m "Add 31 built-in J* aliases for common java.{lang,util,io} classes"
```

- [ ] **Step 2**
```bash
git checkout master && git merge --no-ff phase-3/sub2-aliases -m "Merge branch 'phase-3/sub2-aliases'"
```

---

## Milestone 2: phase-3/sub2-multi-import

**Branch:** `phase-3/sub2-multi-import`

Add the colon and tuple multi-import grammars to `@jimport`. Existing single-class forms unchanged.

### Task 2.1: Create branch

- [ ] **Step 1**
```bash
git checkout master && git pull origin master
git checkout -b phase-3/sub2-multi-import
```

### Task 2.2: Update the `@jimport` docstring first (doc-driven TDD)

**Files:**
- Modify: `src/core.jl` (the docstring above `macro jimport(class::Expr)`, currently around line 387)

- [ ] **Step 1: Rewrite the docstring**

Replace the existing `@jimport` docstring (currently:

```julia
"""
    @jimport class

Return the [`JavaObject{T}`](@ref) type for the named Java class — the handle you
pass to [`jnew`](@ref) / [`jcall`](@ref) / [`jfield`](@ref). `class` may be a
dotted expression, a symbol, or a string: `@jimport java.util.ArrayList`,
`@jimport "java.util.ArrayList"`.
"""
```

) with:

```julia
"""
    @jimport class                                # returns the JavaObject{Symbol(class)} type
    @jimport package: Class                       # binds `Class = JavaObject{Symbol("package.Class")}`
    @jimport package: A, B => JB, C               # multi-bind with optional `=>` rename
    @jimport (pkg1.A, pkg2.B => JB)               # tuple form (cross-package), `=>` rename optional

Bring Java class types into the local / module scope.

**Single-class form** (the original): `@jimport java.util.ArrayList` returns the
type `JavaObject{Symbol("java.util.ArrayList")}` as an expression value. `class`
may be a dotted expression, a symbol, a string, or the nested-class escape
`@jimport(Outer\$Inner)`.

**Multi-import (colon form):** `@jimport java.util: ArrayList, HashMap, Map`
binds three locals at the expansion site — equivalent to three single-class
`@jimport` statements. Use `=>` to rename: `@jimport java.util: ArrayList =>
JArrayList`. (`=>` is the standard `Pair` operator; `as` would not parse outside
of `using/import` clauses.)

**Multi-import (tuple form):** `@jimport (java.util.ArrayList, java.lang.System)`
binds each by the FQN's last segment; cross-package is allowed in one call.
Renames work the same way: `@jimport (java.util.ArrayList => JArrayList)`.
A one-element tuple `@jimport (java.util.ArrayList,)` is a multi-import of one
(binds `ArrayList`); the un-tupled `@jimport java.util.ArrayList` (no trailing
comma) keeps the single-class semantics of returning the type.

In every form, JavaCall already ships built-in aliases for the standard
library's most-common classes (`JList`, `JArrayList`, `JMap`, `JHashMap`,
`JInteger`, `JRunnable`, `JFile`, and more — see the [`JObject`](@ref) block) so
the common cases need no `@jimport` at all.

A macro-expansion-time `error(...)` is raised on a malformed multi-import:
non-Symbol rename target, empty colon-form import list, non-FQN tuple entry,
etc.
"""
```

(One unicode/escape nit: the `Outer\$Inner` `$` needs to be a literal `$` in the rendered docstring, so escape it in the Julia source as shown.)

### Task 2.3: Write the failing macro tests

**Files:**
- Modify: `test/jcall_macro.jl` (append a testset at the end, after the existing Phase 3 `@jcall annotation-free` testset)

- [ ] **Step 1: Add the testset**

```julia
@testset "Phase 3 sub-2: @jimport multi-import" begin
    # --- regression: single-class forms still return a Type ---
    @test (@jimport java.util.ArrayList) === JavaObject{Symbol("java.util.ArrayList")}
    @test (@jimport "java.util.HashMap") === JavaObject{Symbol("java.util.HashMap")}
    @test (@jimport ArrayList)           === JavaObject{Symbol("ArrayList")}  # bare-Symbol path

    # --- colon form: single name ---
    let
        @jimport java.util: ArrayList
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
    end

    # --- colon form: multi-bind ---
    let
        @jimport java.util: ArrayList, HashMap, Map
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
        @test HashMap   === JavaObject{Symbol("java.util.HashMap")}
        @test Map       === JavaObject{Symbol("java.util.Map")}
    end

    # --- colon form with `=>` rename ---
    let
        @jimport java.util: ArrayList => JAL, HashMap => JHM
        @test JAL === JavaObject{Symbol("java.util.ArrayList")}
        @test JHM === JavaObject{Symbol("java.util.HashMap")}
    end

    # --- colon form: mixed rename + bare ---
    let
        @jimport java.util: ArrayList => JAL, HashMap
        @test JAL     === JavaObject{Symbol("java.util.ArrayList")}
        @test HashMap === JavaObject{Symbol("java.util.HashMap")}
    end

    # --- tuple form (cross-package) ---
    let
        @jimport (java.util.ArrayList, java.lang.System)
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
        @test System    === JavaObject{Symbol("java.lang.System")}
    end

    # --- tuple form with renames ---
    let
        @jimport (java.util.ArrayList => JAL, java.lang.System => JSys)
        @test JAL  === JavaObject{Symbol("java.util.ArrayList")}
        @test JSys === JavaObject{Symbol("java.lang.System")}
    end

    # --- single-element tuple == multi-import of 1 ---
    let
        @jimport (java.util.ArrayList,)
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
    end

    # --- scope: colon-form binding inside a let stays local ---
    let
        @jimport java.util: HashSet
        @test @isdefined(HashSet)
    end
    @test !@isdefined(HashSet)   # let-scoped, not leaked to the testset's enclosing scope

    # --- macro-expansion errors ---
    @test_throws LoadError (@eval @jimport java.util:)                            # empty list
    @test_throws LoadError (@eval @jimport java.util: 42)                          # non-Symbol entry
    @test_throws LoadError (@eval @jimport (java.util.ArrayList => 5,))            # non-Symbol rename target
    @test_throws LoadError (@eval @jimport java.util: ArrayList => HashMap => X)   # malformed rename chain
end
```

Note on the let-scope test: a name bound inside `let ... end` is local to that block, so `@isdefined(HashSet)` is `true` inside but `false` outside. If the macro accidentally escaped to module scope, the outside `@isdefined` would be `true` and the test fails.

- [ ] **Step 2: Run to verify failures**

```bash
JULIA_NUM_THREADS=1 julia --project=. test/jcall_macro.jl 2>&1 | head -30
```

Expected: the new testset's `@jimport java.util: ArrayList` line errors with a `MethodError` or expansion failure — the colon form isn't recognized yet.

### Task 2.4: Implement the macro dispatch on AST shape

**Files:**
- Modify: `src/core.jl` (the `macro jimport(class::Expr)` method — currently around lines 396-399)

- [ ] **Step 1: Replace the existing Expr method with the dispatch wrapper**

Replace:

```julia
macro jimport(class::Expr)
    juliaclass = sprint(Base.show_unquoted, class)
    _jimport(juliaclass)
end
```

with:

```julia
macro jimport(class::Expr)
    # Colon form: `@jimport package: name(s)`  =>  Expr(:call, :(:), prefix, body)
    if class.head === :call && length(class.args) == 3 && class.args[1] === :(:)
        return _jimport_colon(class.args[2], class.args[3])
    end
    # Tuple form: `@jimport (FQN1, FQN2 => Target, ...)`  =>  Expr(:tuple, entries...)
    if class.head === :tuple
        return _jimport_tuple(class.args)
    end
    # Single-class form (unchanged): a dotted FQN expression.
    juliaclass = sprint(Base.show_unquoted, class)
    _jimport(juliaclass)
end
```

- [ ] **Step 2: Add the colon-form helper**

Immediately above `macro jimport(class::Expr)` (or below `_jimport`, wherever fits — keep helpers near their caller), add:

```julia
function _jimport_colon(prefix, body)
    pkg = sprint(Base.show_unquoted, prefix)
    entries = (body isa Expr && body.head === :tuple) ? body.args : Any[body]
    isempty(entries) && error("@jimport: empty colon-form import list.")
    assignments = Expr[]
    for entry in entries
        short, target = _parse_short_entry(entry)
        fqn = string(pkg, ".", short)
        push!(assignments, :($(esc(target)) = JavaObject{Symbol($fqn)}))
    end
    push!(assignments, :(nothing))   # the block evaluates to `nothing`
    return Expr(:block, assignments...)
end

# Parse one entry of a colon-form body — either `Name` or `Name => Target`.
# Returns (short::Symbol, target::Symbol). Errors on anything else.
function _parse_short_entry(entry)
    if entry isa Symbol
        return (entry, entry)
    end
    if entry isa Expr && entry.head === :call && length(entry.args) == 3 &&
       entry.args[1] === :(=>) && entry.args[2] isa Symbol && entry.args[3] isa Symbol
        return (entry.args[2], entry.args[3])
    end
    error("@jimport: expected `Name` or `Name => Target` after `:`, got `$entry`.")
end
```

- [ ] **Step 3: Add the tuple-form helper**

Below `_parse_short_entry`, add:

```julia
function _jimport_tuple(entries)
    isempty(entries) && error("@jimport: empty tuple-form import list.")
    assignments = Expr[]
    for entry in entries
        fqn_expr, target = _parse_tuple_entry(entry)
        fqn = sprint(Base.show_unquoted, fqn_expr)
        push!(assignments, :($(esc(target)) = JavaObject{Symbol($fqn)}))
    end
    push!(assignments, :(nothing))
    return Expr(:block, assignments...)
end

# Parse one entry of a tuple-form import — either a dotted FQN Expr (or bare
# Symbol for an unpackaged class), or `FQN => Target`. Returns
# `(fqn_expression, target::Symbol)`. Errors otherwise.
function _parse_tuple_entry(entry)
    if entry isa Symbol
        return (entry, entry)
    end
    if entry isa Expr && entry.head === :.
        # Default target = last segment of the dotted FQN.
        target = _last_dotted_segment(entry)
        return (entry, target)
    end
    if entry isa Expr && entry.head === :call && length(entry.args) == 3 &&
       entry.args[1] === :(=>) && entry.args[3] isa Symbol
        lhs = entry.args[2]
        (lhs isa Symbol || (lhs isa Expr && lhs.head === :.)) ||
            error("@jimport: rename source must be a fully-qualified class expression, got `$lhs`.")
        return (lhs, entry.args[3])
    end
    error("@jimport: tuple entries must be `FQN` or `FQN => Target`, got `$entry`.")
end

# `Expr(:., :(java.util), QuoteNode(:ArrayList))` -> `:ArrayList`.
function _last_dotted_segment(expr::Expr)
    expr.head === :. || error("@jimport: expected a dotted expression, got `$expr`.")
    last = expr.args[2]
    last isa QuoteNode && (last = last.value)
    last isa Symbol || error("@jimport: cannot derive a short name from `$expr`.")
    return last
end
```

**Implementer notes:**
- The Julia parser produces `Expr(:., :(java.util), QuoteNode(:ArrayList))` for `java.util.ArrayList`. `_last_dotted_segment` peels off the `QuoteNode` wrapper. Verify with a quick `dump(:(java.util.ArrayList))` if uncertain.
- `_parse_short_entry`'s check `entry.args[2] isa Symbol && entry.args[3] isa Symbol` rejects nested `=>` (the test `@jimport java.util: ArrayList => HashMap => X` exercises that — Julia parses `HashMap => X` first because `=>` is right-associative, so the outer is `ArrayList => (HashMap => X)`, where `entry.args[3]` is an `Expr`, not a Symbol → error).
- `nothing` is pushed as the trailing expression so the `Expr(:block, ...)` evaluates to `nothing` rather than the last assignment's RHS — clearer "this is a side-effect form" semantics. (Doesn't change correctness; the user shouldn't be using the multi-import as an expression value.)
- Don't worry about thread-safety of the macro — macros run at parse time, single-threaded by Julia.

### Task 2.5: Run the suite green

- [ ] **Step 1**
```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -10
```

Expected: `Testing JavaCall tests passed`. The new `Phase 3 sub-2: @jimport multi-import` testset (~14 assertions) passes. Pre-existing noise lines OK.

Also re-run the JProxies suite to confirm no fallout (JProxies uses `@jimport` heavily):

```bash
cd /Users/brad/Projects/JavaCall.jl/JProxies
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.test()' 2>&1 | tail -10
cd ..
```

Expected: `Testing JProxies tests passed`.

### Task 2.6: Commit & merge

- [ ] **Step 1**
```bash
git add src/core.jl test/jcall_macro.jl
git commit -m "Add @jimport multi-import grammars: colon form, tuple form, => rename"
```

- [ ] **Step 2**
```bash
git checkout master && git merge --no-ff phase-3/sub2-multi-import -m "Merge branch 'phase-3/sub2-multi-import'"
```

---

## Milestone 3: phase-3/sub2-docs

**Branch:** `phase-3/sub2-docs`

Tiny milestone: a paragraph in README.md and a NEWS.md entry.

### Task 3.1: Create branch
```bash
git checkout master && git pull origin master && git checkout -b phase-3/sub2-docs
```

### Task 3.2: Update README

**Files:**
- Modify: `README.md` (find the "Calling Java" section or the closest equivalent; insert a paragraph near the existing `@jimport` mentions)

- [ ] **Step 1: Identify the right insertion point**

```bash
grep -n "@jimport\|## " README.md | head -20
```

Find the first README section that introduces `@jimport`. Insert a new paragraph at the end of that section.

- [ ] **Step 2: Add the paragraph**

Append (verbatim — adapt headings if the existing section uses different prose flow):

```markdown
If you need several classes from one package, use the `using`-style colon
syntax: `@jimport java.util: ArrayList, HashMap`. For cross-package imports,
use a tuple: `@jimport (java.util.ArrayList, java.lang.System)`. Both forms
accept `=>` renames (`@jimport java.util: ArrayList => JArrayList`). JavaCall
already ships built-in aliases for the standard library's most-common classes
— `JList`, `JArrayList`, `JMap`, `JHashMap`, `JInteger`, `JRunnable`, `JFile`,
and others — so the common cases need no `@jimport` at all.
```

### Task 3.3: Update NEWS.md

**Files:**
- Modify: `NEWS.md` (the top of the file; add an entry under the next unreleased version heading, or create one if none exists)

- [ ] **Step 1: Add the entry**

If `NEWS.md`'s top section already names an unreleased minor (e.g. `## v0.10.0`), append the bullets there. Otherwise, insert a new section above the existing `## v0.9.0`:

```markdown
## Unreleased

### Added

- `@jimport` gained `using`-style multi-import grammars: `@jimport java.util:
  ArrayList, HashMap, Map => JMap` binds three locals from one package, and
  `@jimport (java.util.ArrayList, java.lang.System)` binds across packages.
  `=>` renames are supported in both forms. Existing single-class forms
  (`@jimport java.util.ArrayList`, `"java.util.ArrayList"`, `@jimport(Outer$Inner)`)
  are unchanged.
- 31 new built-in `J*` aliases for common Java standard-library classes —
  `JList`, `JArrayList`, `JMap`, `JHashMap`, `JSet`, `JHashSet`, `JCollection`,
  `JIterator`, `JIterable`, `JComparator`, all the boxed primitives
  (`JNumber`/`JBoolean`/`JByte`/`JCharacter`/`JShort`/`JInteger`/`JLong`/
  `JFloat`/`JDouble`), `JCharSequence`, `JThrowable`, `JException`, `JRunnable`,
  the basic `java.io` types (`JFile`/`JInputStream`/`JOutputStream`/`JReader`/
  `JWriter`), and a few `java.util` extras (`JDate`/`JCalendar`/`JProperties`).
  All exported alongside the existing `JObject`/`JClass`/`JString`/etc.
```

(If the project's release version is decided at this point, rename `Unreleased` to that version.)

### Task 3.4: Run the test suite one more time as a sanity check

```bash
JULIA_NUM_THREADS=1 julia --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tail -3
```

Expected: still green. (Docs don't run tests, but cheap to confirm nothing got broken.)

### Task 3.5: Commit & merge

- [ ] **Step 1**
```bash
git add README.md NEWS.md
git commit -m "Doc Phase 3 sub-2: multi-import + built-in aliases in README + NEWS"
```

- [ ] **Step 2**
```bash
git checkout master && git merge --no-ff phase-3/sub2-docs -m "Merge branch 'phase-3/sub2-docs'"
```

---

## After all milestones

- A final review pass over the whole Phase 3 sub-project 2 (spec coverage + a holistic code review subagent). Use `superpowers:finishing-a-development-branch` to wrap up.
- The deferred-by-spec `src/convert.jl` clean-up (condense its repeated `@jimport(java.util.X)` calls onto the new colon form) is a one-PR follow-up — not part of this plan.

---

## Self-Review notes (carried into execution)

- **Spec coverage:** colon form (M2) ✔; tuple form (M2) ✔; `=>` rename in both (M2) ✔; existing single-class forms unchanged (M2 regression assertions) ✔; 31 built-in `J*` aliases added + exported (M1) ✔; macro-expansion-time error path with specific messages (M2) ✔; README + NEWS docs (M3) ✔; out-of-scope items not touched (no nested-class dotted sugar, no into-a-module, no Project.toml bump, no convert.jl cleanup) ✔.
- **Known soft spots (expect iteration):** the `dump(:(java.util.ArrayList))` confirmation in M2 Task 2.4 — verify the actual Expr shape Julia produces for a dotted FQN before relying on `_last_dotted_segment`'s `QuoteNode` peel; the let-scope test in M2 Task 2.3 (line `@test !@isdefined(HashSet)`) relies on the macro emitting plain `=` assignments at expansion site, which respect Julia's normal block-scoping rules — if the macro accidentally used `global` or didn't `esc` properly, this test would fail and pinpoint the leak; the README insertion point depends on the existing structure — the implementer should grep before inserting to avoid duplicating a paragraph if one already mentions multi-import (it shouldn't).
- **Type/name consistency:** `_jimport_colon`, `_jimport_tuple`, `_parse_short_entry`, `_parse_tuple_entry`, `_last_dotted_segment` used consistently across the tasks; the alias names in M1's testset (`JList`, `JArrayList`, `JHashMap`, `JInteger`, `JLong`, `JRunnable`, `JFile`, `JDate`) match the spec's list verbatim; the `=>` rename syntax used everywhere (no stray `as`).
