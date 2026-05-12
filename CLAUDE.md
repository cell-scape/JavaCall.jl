# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

JavaCall.jl is a Julia package that calls Java from Julia by embedding a JVM in-process and dispatching through the Java Native Interface (JNI). The public API is modeled on Julia's `ccall`: `jcall(receiver, "method", ReturnType, (ArgTypes...,), args...)`.

## Common commands

Tests run via the standard Julia package test workflow. There is no separate build step; the JVM is loaded at runtime when `JavaCall.init()` is called.

```bash
# Run the full test suite (compiles test/Test.java if needed via the Pkg test harness)
julia --project=. -e 'using Pkg; Pkg.test()'

# Run a single test file directly (after activating the project)
julia --project=. test/runtests.jl
julia --project=. test/jcall_macro.jl

# Run JProxies subpackage tests (develop the working-tree JavaCall into its env first)
julia --project=JProxies -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'

# Recompile the bundled Test.class files if Test.java is edited
javac test/Test.java          # main package
javac JProxies/test/Test.java # JProxies (also regenerates Test$*.class)
```

Required environment when invoking Julia directly (matches CI and README guidance):

- **All platforms:** set `JULIA_NUM_THREADS=1` for the canonical config. CI also tests `JULIA_NUM_THREADS=4`; multithreaded JNI works on every platform now. Do **not** set `JULIA_COPY_STACKS` — the old threading workaround was removed in the Phase 2 rebuild and the variable is no longer consulted.
- `JAVA_HOME` is auto-detected from `which java` / `/usr/libexec/java_home` / Windows registry, but can be set explicitly. As a last resort set `JAVA_LIB` to the path of `libjvm.{so,dylib,dll}`.

CI matrix (`.github/workflows/CI.yml`): Julia `1.12` (the minimum) / `lts` / `1` × `JULIA_NUM_THREADS` ∈ {1, 4} on ubuntu + windows (x64), plus macOS aarch64 and macOS x64 (`macos-15-intel`); Zulu JDK 25. A separate non-gating `.github/workflows/downstream.yml` runs JDBC.jl / Spark.jl / BioformatsLoader.jl against `master` as an API-breakage tripwire.

## Architecture

The module is layered from the C ABI upward — read in this order when tracing behavior:

1. **`src/JNI.jl`** (submodule `JavaCall.JNI`) — typed `ccall` wrappers for every JNI function. **Most of this file is generated** by `src/make_jni2.jl`, which parses C-style comment signatures in `src/jnienv.jl` (e.g. `# jclass (*GetSuperclass)(JNIEnv *env, jclass sub);`) and emits Julia stubs that pull the function pointer out of `jniref[]`. Long-running JNI calls are annotated `gc_safe = true` so they don't block Julia GC. The startup `JavaVMInitArgs` requests `JNI_VERSION_21`. `JValue` is a primitive type matching the C `jvalue` union. To add or fix a binding, edit the comment in `jnienv.jl` and regenerate, or edit the generated body inside the `# === Below Generated ===` block — but be aware future regenerations will overwrite it.
2. **`src/jvm.jl`** — JVM discovery (`findjvm`) and lifecycle (`init`, `init_current_vm`, `destroy`), classpath/opts state (`cp`, `opts` `OrderedSet`s, `addClassPath`, `addOpts`), `isloaded`/`assertloaded`. Only one JVM can ever be initialized per process; `init()` must come *after* all `addClassPath`/`addOpts` calls. `init()` also spawns the dispatch task; `destroy()` stops it.
3. **`src/env.jl`** — the env-cache layer. `with_env(f)` runs `f(env::Ptr{JNIEnv})` with a per-OS-thread `JNIEnv*` fetched from `_env_cache` (indexed by `Threads.threadid()`), attaching the calling thread to the JVM as a daemon on first touch. Every outbound JNI call goes through `with_env`.
4. **`src/dispatch.jl`** — the dispatch task: a sticky task in the `:interactive` pool that owns one pre-attached OS thread and drains a `Channel{DispatchMsg}`. Message types: `DeleteRef`, `Shutdown`, and `Callback` (Java→Julia callbacks, used by JProxies). `start_dispatch_task!` / `stop_dispatch_task!` are driven by `JavaCall.init` / `destroy`. (Finalizer-driven ref cleanup is *not* routed here — see Memory model.)
5. **`src/core.jl`** — the public type system and dispatch:
   - `JavaRef` hierarchy: `JavaLocalRef` (default, finalized via `JNI.DeleteLocalRef`), `JavaGlobalRef` (long-lived, `JNI.DeleteGlobalRef`), `JavaNullRef` (`J_NULL` sentinel).
   - `JavaObject{T}` — mutable struct wrapping a `JavaRef`, where `T` is a `Symbol` of the fully-qualified Java class name. Constructed via `@jimport`. Finalizer auto-calls `deleteref`.
   - `JavaMetaClass{T}` — cached class handles. The cache is `_jmc_cache_v2::Dict{Symbol,JavaMetaClass}` guarded by `_jmc_cache_lock::ReentrantLock`; `metaclass(env, class::Symbol)` does `lock(...) do; get!(_jmc_cache_v2, class) do; _metaclass(env, class) end; end`.
   - `jcall`, `jnew`, `jfield`, `jlocalframe`, `jglobal`, `metaclass`, plus the JNI signature builder `signature` / `method_signature`. Each of `jcall`/`jnew`/`jfield` starts with `assertloaded()` and does its JNI work inside a `with_env` block.
   - `jcall` dispatches to a giant set of `_jcall(...)` / `_jfield(...)` methods generated by a nested `for` loop near the bottom of the file — one combination per (primitive return type) × (instance vs static call). When changing call semantics, edit the loop body, not individual methods.
6. **`src/convert.jl`** — `Base.convert` overloads moving between Julia and Java (e.g. `String` ↔ `JString`, primitive boxing into `java.lang.Integer`/`Double`/etc.), `convert_args`/`convert_arg`/`cleanup_arg`/`convert_result` used by `_jcall`, the `narrow` helper, and the polymorphism helper `isConvertible` backed by `JNI.IsAssignableFrom`. Note: `cleanup_arg` deletes *and nulls* a converted argument's ref — relevant if you write a wrapper type meant to be passed to `jcall` more than once.
7. **`src/reflect.jl`** — `getclass`, `listmethods`, `listfields`, `getname`, `getreturntype`, `getparametertypes`, `classforname`, plus pretty-printing (`Base.show`) for `JMethod`/`JField`. Useful for both end-users and internal type lookup.
8. **`src/jniarray.jl`** — `JNIVector{T}`, the array-pinning bridge. A `for primitive in [...]` loop generates one set of accessors per JNI primitive type using `eval`; touching array semantics means editing inside that loop.
9. **`src/buffer.jl`** (Phase 2B) — `JDirectBuffer{T}` (zero-copy numeric exchange via a Java direct `ByteBuffer`) and `with_critical_array(f, arr, T)` (pinned access to a Java primitive array via the JNI critical APIs). `is_virtual_thread(thread)` (JDK 21+) lives in `core.jl` with the other reflection-style helpers.
10. **`src/jcall_macro.jl`** — `@jcall` macro that parses Julia call syntax (`@jcall System.getProperty("foo"::JString)::JString`) into the underlying `jcall(...)` form. See `test/jcall_macro.jl` for the full grammar.

### Threading model

There is one unified codebase across Linux, macOS, and Windows — no `JULIA_COPY_STACKS`, no root-task constraint, no Windows thread-1 pinning, no `Threads.jl` shim (all removed in the Phase 2 rebuild). Multithreaded JNI access is supported everywhere.

- **Outbound calls** (`jcall`/`jnew`/`jfield` and everything under them) fetch a per-OS-thread `JNIEnv*` lazily via `with_env`; the calling thread is daemon-attached to the JVM on first use. Nothing yields between fetching the env pointer and the JNI call returning — the env pointer is never stored across a yield point.
- **Java→Julia callbacks** (the JProxies `jproxy()` path) route through the dispatch task as `Callback` messages, so the handler runs on a known JVM-attached thread. Callbacks are designed for the supported `JULIA_NUM_THREADS=1` configuration; a callback handler must do pure-Julia work (re-entering JNI from the dispatch task while the Java thread is parked mid-upcall corrupts JVM per-thread state). See `JProxies/src/native.jl`'s header comment.
- The only entry-guard left is `assertloaded()` (throws if `init()` hasn't run).

### Memory model

- Every `JavaObject` has a finalizer that deletes its underlying JNI ref (via `deleteref`, which attaches the calling OS thread on demand and calls `DeleteLocalRef`/`DeleteGlobalRef` *synchronously* through `with_env` — finalizer cleanup is deliberately **not** routed through the dispatch task, because async cleanup couldn't keep up with tight-loop allocation throughput). Java GC won't free objects while a Julia `JavaObject` exists.
- Local refs accumulate inside long-running Julia loops; use `jlocalframe(f, [returntype]; capacity=16)` (wraps `PushLocalFrame`/`PopLocalFrame`) to scope them. Specify `returntype` for type stability; `Nothing` discards the result.
- For long-lived references promote with `jglobal(x)` (replaces the inner `JavaRef` with a `JavaGlobalRef`).
- JNI **local** references are scoped to the native-method frame that created them when JNI is called from a JVM-invoked native method (the JProxies callback path) — such refs must never escape into finalizer-bearing `JavaObject`s. From an ordinary attached thread (the common case), local refs live until explicitly deleted.
- `JNIVector{T}` pins/unpins primitive Java arrays via `Get*ArrayElements`/`Release*ArrayElements`; `release_elements` is called automatically before re-passing one to JNI and on finalization. When wrapping new array operations, mirror the existing `GC.@preserve` patterns (see `_jcall` and `release_elements`) — those preserves prevent segfaults from Julia GC moving the backing buffer mid-call.

### Subpackage: `JProxies/`

`JProxies` is a separate package (its own `Project.toml`, currently versioned in lockstep with the main package) layered on top of JavaCall. It depends on JavaCall but is not part of the main `JavaCall` package's API. It provides:
- `JProxy(obj)` / `JProxy(@jimport X)` for ergonomic dot-access — `jp.method(args...)` resolves Java overloads by argument type (quality-score ladder: exact > subclass > boxing/widening, ties throw) and `narrow`s the result; `jp.field` reads a field (writes throw — unsupported); `unwrap(jp)` returns the underlying `JavaObject`. Code in `JProxies/src/dotaccess.jl`.
- `@jproxy YourType "java.fqn.Interface" begin ...method defs... end` + `jproxy(value, "java.fqn.Interface")` for implementing a Java interface in Julia. The macro lowers to plain `_proxy_method_table` assignments (no runtime `eval`, so JProxies precompiles cleanly). Callbacks run on the dispatch task. Code in `JProxies/src/callbacks.jl` and the JNI edge in `JProxies/src/native.jl`; a bundled `org.juliainterop.JavaCallInvocationHandler.{java,class}` (under `JProxies/java/`) is wired via `JNI.RegisterNatives` — regenerate the `.class` with `javac` like `test/Test.class`.
- Removed in the 0.9.0 rewrite: the `@class` macro, `staticproxy`, `interfacehas`, and implicit Julia↔Java widening. The old `proxy.jl`/`gen.jl` are gone.

Tests are independent (`JProxies/test/runtests.jl`); run with `JProxies.init(...)` and `Pkg.develop(path="..")` so the working-tree JavaCall is used.

## Things to be careful about

- **Don't restructure `JNI.jl` by hand without checking `make_jni2.jl`** — most of it is generated, and reformatting will be lost on next regen. The hand-edited bits (e.g. the commented-out alternative `ReleaseStringUTFChars`) must be re-applied after a regen; see the Phase 2B plan for the exact splice procedure.
- **`init()` is a one-shot, and it spawns the dispatch task.** Don't call `JavaCall.init()` from a package's `__init__()` — it would prevent downstream packages from contributing classpath/options before JVM startup. JavaCall's own `__init__` is a no-op; the JVM lifecycle (and the dispatch task) is owned by `JavaCall.init()` / `JavaCall.destroy()`.
- **JNI function-table layout is positional** — when adding a binding via a comment in `jnienv.jl`, put the new slot in the correct position relative to the C `JNINativeInterface` struct and bump the field count in the `JNINativeInterface()` constructor. A wrong position silently corrupts every function pointer after it.
- **`Pkg.test` brings in `Taro` and `DataFrames` as test-only deps** (declared in `[targets].test`); the test suite touches them in some paths. JProxies' own tests are run separately and only need `Test` + a `Pkg.develop(path="..")` of JavaCall.
