# Phase 2 — Threading rebuild

**Date:** 2026-05-05
**Status:** Design — pending implementation plan
**Predecessor:** Phase 1 latent-bug fixes (merged to master 91945f4)

## Motivation

Phase 1 fixed eleven concrete latent bugs identified in an audit of JavaCall.jl, but four constraints remain that block the package from working correctly under Julia's modern threading runtime:

1. `JULIA_COPY_STACKS=1` is required on Linux/macOS but forbidden on Windows. Both demands stem from a single underlying issue (HotSpot's stack-walking on copied Julia task stacks); the workaround was applied as Unix vs Windows special cases.
2. `JULIA_NUM_THREADS=1` is recommended because finalizers running on Julia GC threads can call JNI from contexts the JVM does not expect.
3. JNI calls today index a per-thread `JNIEnv*` array via `Threads.threadid()`, which is not safe under Julia 1.7+ task migration: a task can yield mid-flight and resume on a different OS thread with a stale env pointer.
4. Java→Julia callbacks (the JProxies subpackage) use runtime `eval` and unguarded module-level globals, breaking precompilation and creating thread-safety hazards.

Phase 2 rebuilds the threading and callback layers on Julia 1.12+ primitives (`OncePerThread`, `@ccall foo() gc_safe = true`) and on JNI's `AttachCurrentThreadAsDaemon` per-thread attachment model. The result is a single unified codebase across Linux, macOS, and Windows; full multithreaded JNI support; and a precompile-friendly callback mechanism.

## Constraints and decisions

| Decision | Choice |
|----------|--------|
| Minimum Julia | **1.12** (gets `OncePerThread`, `OncePerTask`, `gc_safe = true ccall`) |
| Minimum JDK | **11** (drops `jre/` subdir handling; modern lib layout) |
| Public API | **Strictly compatible** — no breaking changes; downstream packages keep working |
| Java→Julia callbacks | **Kept**, redesigned on a dispatch task |
| Windows | **Unified** with Linux/macOS — no special-case threading code |
| Architecture | **β: dispatch-routed cleanup** — outbound calls attach-on-demand; finalization and callbacks route through one dedicated dispatch task |
| Dot-access (`JProxy(obj).method(args)`) | **Preserved in Phase 2** with overload resolution |

## Architecture overview

### Five top-level invariants

1. Every JNI call runs on a JVM-attached OS thread. Attachment is lazy via `AttachCurrentThreadAsDaemon`, cached per OS thread via `OncePerThread{Ptr{JNIEnv}}`.
2. No yielding between env-fetch and JNI-return. Long-running Java methods are wrapped in `gc_safe = true ccall` so Julia GC can proceed concurrently.
3. Java→Julia callbacks land on a single dedicated dispatch task — sticky in the `:interactive` pool, owns one OS thread that's pre-attached to the JVM.
4. `DeleteLocalRef` / `DeleteGlobalRef` cleanup routes through the dispatch task. Finalizers post messages; Julia GC threads never touch the JVM.
5. One unified codebase across platforms. No `JULIA_COPY_STACKS` dependency. No root-task constraint. No Windows-specific threading paths.

### Module structure

| File | Change |
|------|--------|
| `src/Threads.jl` | **delete** (Windows shim no longer needed) |
| `src/env.jl` | **new** — `OncePerThread{Ptr{JNIEnv}}` cache, `attach_current_thread()`, `with_env(f)` helper |
| `src/dispatch.jl` | **new** — dispatch task lifecycle, `Channel{DispatchMsg}`, drain loop, `DeleteRef`/`Callback` message types |
| `src/JavaCall.jl` | drop `JULIA_COPY_STACKS` global; wire `__init__` for dispatch task spawn and `atexit` shutdown |
| `src/JNI.jl` | parameterize wrappers on env (drop the default `ppenv[Threads.threadid()]`); regenerate via `make_jni2.jl` |
| `src/jvm.jl` | drop `assertroottask_or_goodenv`, `isgoodenv`, `isroottask`, `attach_threads`, related constants |
| `src/core.jl` | rewrite `jcall`/`jnew`/`jfield` on `with_env`; add `gc_safe = true` annotations; `deleteref` posts to dispatch channel |
| `src/convert.jl`, `src/reflect.jl`, `src/jniarray.jl`, `src/jcall_macro.jl` | route through `with_env` where they hit JNI directly |
| `JProxies/` | **rewritten** — new `Proxy` and `JProxy` types; precompile-friendly; bundled `JavaCallInvocationHandler.class` |
| `src/make_jni2.jl` | emit env as required arg (no default) and `gc_safe = true` for slow JNI methods |

### Public-API additions (zero breaking)

- `JDirectBuffer{T}` — wraps NIO direct ByteBuffer for zero-copy Julia↔Java numeric exchange.
- `JavaCall.dispatch_task()` accessor — exposes the dispatch task handle for advanced inspection.
- `JavaCall.init(opts...; gc_safe = true)` — keyword to disable `gc_safe` ccall annotations as an escape hatch (defaults on).
- `with_critical_array(f, arr)` — explicit JNI critical-section helper.

### What goes away

`JULIA_COPY_STACKS` env-var detection · `assertroottask_or_goodenv` / `isgoodenv` / `isroottask` · `ROOT_TASK_ERROR` and the two `*_WINDOWS_ERROR` constants · `Threads.jl` (Windows stub) · `attach_threads()` (broken init-time multi-attach) · per-thread `ppenv` array · README sections about `JULIA_COPY_STACKS` and Windows pinning.

## Outbound call lifecycle

### `with_env`: the foundational primitive

```julia
const _env_cache = OncePerThread{Ptr{JNIEnv}}() do
    pp = Ref{Ptr{JNIEnv}}(C_NULL)
    res = ccall(jvmfunc[].AttachCurrentThreadAsDaemon, Cint,
                (Ptr{Nothing}, Ptr{Ptr{JNIEnv}}, Ptr{Nothing}),
                ppjvm[], pp, C_NULL)
    res < 0 && throw(JavaCallError("Failed to attach OS thread to JVM"))
    pp[]
end

@inline with_env(f::Function) = f(_env_cache[])
```

`OncePerThread` is keyed on the *current* OS thread at evaluation time, not on a stale `threadid()` snapshot, which makes it safe under task migration. Daemon attach is the right semantic — non-daemon attached threads block `DestroyJavaVM`, but Julia worker threads are reused indefinitely.

### `gc_safe = true` annotation

Every long-running JNI ccall (the audit table is in §"Bonus modernizations") gets `gc_safe = true`:

```julia
result = @ccall jniref[].CallObjectMethodA(
    env::Ptr{JNIEnv}, obj::Ptr{Nothing}, mid::Ptr{Nothing},
    args::Ref{NTuple{N,JValue}}
)::Ptr{Nothing} gc_safe = true
```

This lets Julia GC proceed concurrently while a task is blocked inside a slow Java method. Without it, multi-threaded Julia tasks would deadlock at safepoints whenever any one task is mid-JNI-call.

### Method-ID caching

Phase 1 made `metaclass()` cache class handles. Phase 2 extends with method-ID caching, since method IDs are valid for the JVM's lifetime per the JNI spec:

```julia
struct MethodKey
    class::Symbol
    name::Symbol
    signature::String
end
const _method_cache = Dict{MethodKey, Ptr{Nothing}}()
const _method_cache_lock = ReentrantLock()
```

After warmup, `jcall` hits a cached `jmethodID` rather than a per-call `GetMethodID` JNI roundtrip.

### End-to-end `jcall` flow

1. `assertloaded()` — JVM up?
2. `metaclass(receiver)` — Phase 1 cache, returns global ref.
3. `get_method_id(...)` — Phase 2 cache, returns `jmethodID`.
4. `convert_args(argtypes, args...)` — produces savedArgs and convertedArgs.
5. `with_env do env ...; @ccall ... gc_safe=true end`.
6. `cleanup_arg.(convertedArgs)` — may post `DeleteRef` to dispatch task.
7. `geterror()` — checks pending Java exception, throws `JavaCallError` if any.
8. `convert_result(RetType, result)` — allocates the Julia return value.

Nothing yields between step 5's `with_env` and the ccall return. The env pointer is fetched, used immediately, never stored across a yield point.

## Dispatch task

### Lifecycle

The dispatch task is spawned from `JavaCall.__init__()` after the JVM is created. Sticky task in the `:interactive` pool, pinned to one OS thread that is pre-attached to the JVM. Lives until `JavaCall.destroy()` or process exit.

```julia
const _dispatch_task = Ref{Task}()
const _dispatch_channel = Channel{DispatchMsg}(1024)

function _start_dispatch_task()
    t = Threads.@spawn :interactive begin
        _env_cache[]   # eager attach
        _drain_loop()
    end
    t.sticky = true
    _dispatch_task[] = t
    errormonitor(t)
end
```

### Message types

```julia
abstract type DispatchMsg end

struct DeleteRef <: DispatchMsg
    ptr::Ptr{Nothing}
    kind::Symbol            # :local or :global
end

struct Callback <: DispatchMsg
    handler::Function
    args::Tuple
    result_box::Channel{Any}
end

struct Shutdown <: DispatchMsg end
```

### Drain loop

```julia
function _drain_loop()
    while true
        msg = take!(_dispatch_channel)
        try
            _handle(msg)
        catch err
            @error "Dispatch task error" exception=(err, catch_backtrace())
        end
        msg isa Shutdown && break
    end
end

_handle(msg::DeleteRef) = msg.kind === :local ?
    JNI.DeleteLocalRef(_env_cache[], msg.ptr) :
    JNI.DeleteGlobalRef(_env_cache[], msg.ptr)

_handle(msg::Callback) = put!(msg.result_box, msg.handler(msg.args...))

_handle(msg::Shutdown) = nothing
```

### Finalizer flow

Phase 2 replaces the Phase 1 `deleteref` (with its `isgoodenv` guard) with a non-blocking post:

```julia
function deleteref(x::JavaRef)
    x.ptr == C_NULL && return
    JNI.is_env_loaded() || return
    kind = x isa JavaLocalRef ? :local :
           x isa JavaGlobalRef ? :global : :null
    kind === :null && return
    try
        push!(_dispatch_channel, DeleteRef(x.ptr, kind))
    catch err
        @debug "Dispatch channel full, leaking ref" exception=err
    end
end
```

The Phase 1 `isgoodenv()` guard goes away because the dispatch task is the only thread that calls JNI for cleanup — there's no longer a "bad context" to defend against.

### Callback flow

Java side calls a `Proxy.newProxyInstance` whose `InvocationHandler` calls back to a Julia `@cfunction`:

```julia
function _proxy_invoke_native(env::Ptr{JNIEnv}, jclass, handler_id::Int64,
                              method_name::Ptr{Nothing}, args::Ptr{Nothing})::Ptr{Nothing}
    name = unsafe_string(JNI.GetStringUTFChars(env, method_name, C_NULL))
    value, type, _ = _proxy_registry[handler_id]
    julia_args = _unmarshal_object_array(env, args)
    dispatch_fn = _proxy_method_table[(type, Symbol(name))]

    result_box = Channel{Any}(1)
    push!(_dispatch_channel, Callback(() -> dispatch_fn(value, julia_args...), (), result_box))
    result = take!(result_box)
    return _marshal_result(env, result)
end
```

The Java thread blocks on `take!(result_box)`. This is safe under daemon attach: the thread has been registered with both the JVM (via the attach) and Julia (via Julia 1.10+'s foreign-thread adoption machinery). Julia 1.12's threading runtime handles this case correctly.

### Channel sizing

`Channel{DispatchMsg}(1024)` — bounded. The size is sufficient for typical finalizer bursts. Failed posts are logged at debug level and the ref is leaked rather than crashing the finalizer.

### Shutdown

`JavaCall.destroy()` posts a `Shutdown` message, waits for the dispatch task to drain pending messages, then calls `DestroyJavaVM`. Daemon attachments don't block shutdown.

## JProxies redesign

### Goals

The JProxies subpackage gets a clean rewrite that:

- Implements Java interfaces in Julia (the callback case) without runtime `eval`.
- Provides dot-access on Java objects (`JProxy(obj).method(args)`) with overload resolution.
- Routes all callbacks through the dispatch task (Section "Dispatch task").
- Is precompile-friendly and thread-safe.

### Java helper class

A small Java class shipped with the package, with both source and compiled bytecode committed to the repo at `JProxies/java/org/juliainterop/JavaCallInvocationHandler.{java,class}`. The `.class` file is checked in so users do not need a `javac` toolchain at package install time. Maintainers regenerate it via the existing `test/Test.class` pattern.

```java
package org.juliainterop;
public class JavaCallInvocationHandler implements java.lang.reflect.InvocationHandler {
    private final long handlerId;
    public JavaCallInvocationHandler(long handlerId) { this.handlerId = handlerId; }
    public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args) {
        return invokeNative(handlerId, method.getName(), args);
    }
    private static native Object invokeNative(long id, String name, Object[] args);
}
```

At `JavaCall.init()`:

1. The bundled `.class` directory is added to the classpath.
2. `JNI.RegisterNatives` points `invokeNative` at `_proxy_invoke_native` (the Julia `@cfunction`).
3. The dispatch task is started.

### `jproxy(value, interface)` — Julia-implements-Java-interface

```julia
@jproxy ProgressLogger "java.lang.Runnable" begin
    function run(self)
        println("[\$(self.label)] tick at \$(time())")
    end
end

logger = ProgressLogger("worker")
jrunnable = jproxy(logger, "java.lang.Runnable")
# Pass jrunnable wherever Java wants a Runnable
```

The `@jproxy` macro lowers to assignments into `_proxy_method_table[(YourType, :methodName)]` — no `eval`, fully precompilable.

### `JProxy(jobj)` — dot-access on Java objects

The wrapped value is either a `JavaObject{T}` (instance methods + fields) or a `Type{<:JavaObject{T}}` (static methods + fields). One struct handles both via a union:

```julia
struct JProxy{T,W<:Union{JavaObject,Type{<:JavaObject}}}
    wrapped::W
end

JProxy(obj::JavaObject{T}) where T = JProxy{T, JavaObject{T}}(obj)
JProxy(::Type{JavaObject{T}}) where T = JProxy{T, Type{JavaObject{T}}}(JavaObject{T})

function Base.getproperty(jp::JProxy, name::Symbol)
    w = getfield(jp, :wrapped)
    fields = listfields(w, String(name))
    !isempty(fields) && return jfield(w, fields[1])
    return JProxyMethod(w, name)
end
```

`JProxyMethod` resolves overloads on call:

```julia
struct JProxyMethod{T}
    obj::JavaObject{T}
    name::Symbol
end

function (m::JProxyMethod)(args...)
    method = _resolve_overload(m.obj, m.name, args)   # cached
    rettype = jimport(getreturntype(method))
    argtypes = Tuple(jimport.(getparametertypes(method)))
    return narrow(jcall(m.obj, m.name, rettype, argtypes, args...))
end
```

### Overload resolution: quality-score ladder

Match each Julia argument to each candidate Java parameter at one of four quality tiers (highest match wins):

| Tier | Match | Example |
|------|-------|---------|
| Exact | Same JNI primitive / class | `Int32` → `jint` |
| Derived | Subclass conversion | `Vector{jdouble}` → `Object[]` |
| Implicit | Boxing / widening | `Int64` → `jlong → java.lang.Long` |
| Explicit | Required `convert(T, x)` | (not auto-resolved) |

Throw on tied tiers. Cache `(JavaObject{T}, method_name, arg_typetuple) → JMethod` in a `Dict + ReentrantLock`.

### Static-method dot-access

`JProxy(@jimport "java.lang.Math").sin(pi)` works the same way: `getproperty` branches on whether the wrapped value is a `JavaObject` instance or a `Type{<:JavaObject}`, using `metaclass(T)` and `CallStatic*MethodA` for the static path.

### Lifetime and cleanup

```julia
mutable struct JProxyRef{T}
    obj::JavaObject{T}
    handler_id::Int64
    function JProxyRef{T}(obj, hid) where T
        j = new{T}(obj, hid)
        finalizer(j) do x
            delete!(_proxy_registry, x.handler_id)
            # x.obj's own finalizer routes DeleteGlobalRef through dispatch task
        end
        return j
    end
end

# Make JProxyRef substitutable for the underlying JavaObject in jcall etc.
Base.convert(::Type{JavaObject{T}}, jp::JProxyRef{T}) where T = jp.obj
Base.unsafe_convert(::Type{Ptr{Nothing}}, jp::JProxyRef) = Ptr(jp.obj)
Ptr(jp::JProxyRef) = Ptr(jp.obj)
```

When the `JProxyRef` is GC'd, its finalizer removes the handler from `_proxy_registry` (allowing `value` to be GC'd by Julia) and the wrapped `JavaObject`'s finalizer posts the `DeleteGlobalRef` to the dispatch task.

### Out of scope for the JProxies rewrite

- `@class` macro (define a Java class from Julia at runtime via bytecode).
- Magic auto-conversion (Julia String to JString, Vector to JList) — keep `convert` explicit.
- Iteration over Java `Iterable`s — separable, decide independently in a follow-up.

## Bonus modernizations

All additive — no breaking changes.

### JNI version bump to 21

`JavaVMInitArgs` requests `JNI_VERSION_21` instead of `JNI_VERSION_1_8`. JNI versions are forward-compatible; this doesn't change behaviour on JDK 11 but unlocks newer JNI methods.

### Real `JValue` primitive type

Phase 1 zero-extended Float32 into Int64 — correct on little-endian, sketchy as a contract. Phase 2:

```julia
primitive type JValue 64 end

jvalue(v::jint)::JValue    = JValue(Int64(v))
jvalue(v::jlong)::JValue   = JValue(v)
jvalue(v::Float32)::JValue = JValue(Int64(reinterpret(UInt32, v)))
jvalue(v::Float64)::JValue = JValue(reinterpret(Int64, v))
jvalue(v::Ptr)::JValue     = JValue(Int64(UInt(v)))
```

ccalls take `Ref{NTuple{N,JValue}}` instead of `Array{Int64}`.

### `IsVirtualThread` defensive check

JEP 444 (JDK 21) added `IsVirtualThread(env, thread)`. Phase 2 wraps it as `is_virtual_thread(::JavaObject{Symbol("java.lang.Thread")})` with a JNI-version guard so it's a no-op on JDK <21.

### `JDirectBuffer{T}` — zero-copy numeric exchange

```julia
struct JDirectBuffer{T}
    obj::JavaObject{Symbol("java.nio.ByteBuffer")}
    data::Vector{T}
end

function JDirectBuffer{T}(n::Integer) where T
    bytes = n * sizeof(T)
    julia_buf = Vector{T}(undef, n)
    with_env() do env
        ptr = pointer(julia_buf)
        jbb = JNI.NewDirectByteBuffer(env, ptr, bytes)
        return JDirectBuffer{T}(JavaObject{Symbol("java.nio.ByteBuffer")}(jbb), julia_buf)
    end
end
```

The `JDirectBuffer` holds both sides; neither can free the memory while it's reachable.

### `with_critical_array`

Explicit critical-section helper; the no-allocate / no-callback constraint is the user's responsibility:

```julia
function with_critical_array(f, arr::JavaObject{V}) where V <: AbstractVector
    with_env() do env
        ptr = JNI.GetPrimitiveArrayCritical(env, Ptr(arr), C_NULL)
        try
            jl_view = unsafe_wrap(Array, ptr, length(arr); own = false)
            return f(jl_view)
        finally
            JNI.ReleasePrimitiveArrayCritical(env, Ptr(arr), ptr, jint(0))
        end
    end
end
```

### `gc_safe = true` audit

| ccall | gc_safe? | Reason |
|-------|----------|--------|
| `Call*Method`, `CallStatic*Method`, `CallNonvirtual*Method` | yes | May execute arbitrary Java code |
| `Get*Field`, `Set*Field` (instance and static) | yes | Field accessors may trigger class init or proxy hooks |
| `Get*ArrayElements`, `Release*ArrayElements` | yes | May trigger GC pin / unpin |
| `GetPrimitiveArrayCritical`, `ReleasePrimitiveArrayCritical` | **no** | Critical section — Julia GC must NOT proceed |
| `FindClass`, `GetMethodID`, `GetFieldID` | yes | May trigger class loading |
| `NewObject*` | yes | Constructor may run arbitrary code |
| `DeleteLocalRef`, `DeleteGlobalRef`, `NewLocalRef`, `NewGlobalRef` | no | Trivial bookkeeping |
| `ExceptionCheck`, `ExceptionOccurred`, `ExceptionClear`, `ExceptionDescribe` | no | Trivial inspection |
| `NewStringUTF`, `GetStringUTFChars`, `ReleaseStringUTFChars` | no | Bounded allocation |
| `IsVirtualThread`, `IsAssignableFrom`, `GetObjectClass`, `GetObjectRefType` | no | Trivial inspection |

Implemented by extending `make_jni2.jl` to emit `gc_safe = true` for the high-cost operations.

## Testing strategy

### Existing test suite

All 261 tests (255 baseline + 6 metaclass-cache from Phase 1) must continue passing. The Phase 1 metaclass-cache test in particular validates that the cache survives `PopLocalFrame` cycles — also load-bearing for Phase 2.

### New tests

**Threading correctness**: parallel `jcall` from many tasks; task-migration safety (yield mid-flight, verify correct results); `OncePerThread` cache disambiguation across worker threads.

**Finalizer routing**: create many JavaObjects across tasks, force GC, verify the dispatch task's processed-message counter advances by the expected amount.

**Dispatch task survival**: inject an error in a callback handler; verify the drain loop logs and continues; subsequent calls still work.

**Shutdown ordering**: post a wave of `DeleteRef` messages; verify `destroy()` drains them before `DestroyJavaVM` (run in a subprocess so the test JVM isn't actually destroyed).

**`JDirectBuffer` round-trip**: allocate, fill from Julia, mutate from Java, verify Julia sees the change (zero-copy).

**`JProxy` dot-access**: instance fields read/write, instance methods, static methods on classes, overload resolution by argument type.

### CI matrix changes

```yaml
env:
  JULIA_COPY_STACKS: ''   # explicitly unset; not needed
strategy:
  matrix:
    version: ['1.12', 'lts', '1']
    os: [ubuntu-latest, windows-latest, macos-latest, macos-15-intel]
    threads: ['1', '4']
    arch: [x64, aarch64]
```

Drops the `julia_copy_stacks` matrix dimension entirely. Adds `JULIA_NUM_THREADS` with values `1` and `4` to validate both threading scenarios. Bumps Julia minimum from 1.6 to 1.12 in the matrix.

### Downstream smoke tests

A separate workflow `.github/workflows/downstream.yml` pulls JDBC.jl, Spark.jl, and BioformatsLoader.jl from their HEADs, points them at our master, and runs their test suites. Failures aren't gating but are useful tripwires for unintended API breakage.

### What's NOT tested

- Inner workings of `OncePerThread` and `gc_safe = true` — Julia stdlib responsibilities.
- Performance microbenchmarks — deferred to v0.9.1 when the architecture is stable.

## Migration plan

- **v0.9.0** — full Phase 2: threading rebuild, dispatch task, JProxies rewrite, JNI 21, `JValue`, `JDirectBuffer`, critical arrays, `gc_safe` audit. Public API unchanged for `jcall`/`@jcall`/`@jimport`/`jfield`/`JavaObject`. JProxies API: existing `JProxy(obj).method(args)` preserved with overload resolution; `jproxy(value, iface)` is new for callbacks; `@class`, `staticproxy`, magic widening are removed.
- **v0.9.1** — performance benchmarks, optional auto-application of critical arrays for large primitive arrays.
- **v1.0.0** — stable architecture; reserved for future API ergonomics work (Phase 3).

## Future work (deferred)

- **Configurable dispatch channel size** via `JavaCall.init(...; dispatch_channel_size = N)` if a workload warrants. Default 1024 for v0.9.0.
- **Pre-allocated callback result boxes** instead of per-callback `Channel{Any}(1)` allocation. Premature optimization for v0.9.0; revisit if callbacks become a hot path.
- **Iteration over Java `Iterable`s** (`for x in JProxy(jiterable)`). Separable from dot-access; decide in a follow-up.
- **`jcall` overload resolution** (no `(ArgTypes,)` tuple required) — JPype-style. Phase 3 ergonomics work.
- **Auto-application of critical arrays** above a length threshold. Performance tuning, v0.9.1.
- **FFM-on-Java-side architecture** as a v2 alternative. JDK 22+ baseline; defer until Phase 2 is stable.

## Out of scope (explicit)

- Public API redesign (`jcall` signature changes, `@jimport` ergonomics) — Phase 3.
- `@class` macro (define a Java class from Julia at runtime via bytecode).
- Magic auto-conversion of Julia values to Java types beyond what `convert` already provides.
- Multi-JVM / re-init support — fundamental JNI limit, not Phase 2's concern.
- GraalVM polyglot integration.
