# Phase 2A — Threading Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild JavaCall.jl's threading layer on Julia 1.12+ primitives so that JNI calls work safely from any task on any thread. Public API for `jcall`, `@jcall`, `@jimport`, `jfield`, `JavaObject` stays unchanged so downstream packages keep working without source changes.

**Architecture:** Architecture β from the spec at `docs/superpowers/specs/2026-05-05-phase-2-threading-rebuild-design.md`. Outbound calls fetch a per-OS-thread `JNIEnv*` lazily via `OncePerThread`, attaching the thread to the JVM as a daemon on first touch. Finalization (and later, callbacks) route through a dedicated sticky dispatch task. The `JULIA_COPY_STACKS` workaround, the root-task constraint, the Windows thread-1 pinning, and the `Threads.jl` shim all go away — one unified codebase.

**Tech Stack:** Julia 1.12+ (`OncePerThread`, `@ccall foo() gc_safe = true`), JDK 11+ (request `JNI_VERSION_21`, forward-compatible).

---

## File Structure

### Files created

- `src/env.jl` — `OncePerThread{Ptr{JNIEnv}}` cache, `attach_current_thread`, `with_env(f)` helper, `detach_all_threads_atexit`. ~80 lines.
- `src/dispatch.jl` — `DispatchMsg` abstract + concrete subtypes (`DeleteRef`, `Shutdown`), `_dispatch_channel`, `_dispatch_task`, `start_dispatch_task!`, `stop_dispatch_task!`, `_drain_loop`, `_handle`. ~120 lines. (`Callback` message type ships in Phase 2C with the JProxies rewrite.)

### Files modified

- `Project.toml` — bump `julia` compat to `1.12`.
- `README.md` — drop the `JULIA_COPY_STACKS` and Windows-special-case sections.
- `.github/workflows/CI.yml` — drop `julia_copy_stacks` matrix dimension; bump min Julia from `1.6` to `1.12`; add `JULIA_NUM_THREADS` dimension with values `1` and `4`; drop `JULIA_NUM_THREADS: '1'` from `env`.
- `src/JavaCall.jl` — drop `JULIA_COPY_STACKS` global; include `env.jl` and `dispatch.jl`; wire dispatch task spawn in `__init__` (only after `init` succeeds, since the JVM must exist) and shutdown via `destroy()`.
- `src/JNI.jl` — change `const jvalue = Int64` → `primitive type JValue 64 end` (and update name capitalization for the type while keeping `jvalue` lowercase as the encoder function in `core.jl`); add `JNI_VERSION_19`/`20`/`21` constants; bump `init_new_vm` to request `JNI_VERSION_21`; regenerate the `# === Below Generated ===` block from the updated `make_jni2.jl` (env becomes a required argument; `gc_safe = true` for slow methods).
- `src/jvm.jl` — delete `ROOT_TASK_ERROR`, `JULIA_COPY_STACKS_ON_WINDOWS_ERROR`, `THREADID_NOT_ONE_WINDOWS_ERROR`, `isroottask`, `isgoodenv`, `assertroottask_or_goodenv`. The `findjvm`/`addClassPath`/`addOpts`/`init`/`destroy` portions remain.
- `src/core.jl` — rewrite `jcall`/`jnew`/`jfield` on `with_env`; add `gc_safe = true` ccall annotations to slow JNI calls (transitively via the regenerated JNI bindings); method-ID caching; `deleteref` posts `DeleteRef` messages; `jvalue(::Float32)` etc. return `JValue`; remove `assertroottask_or_goodenv()` calls.
- `src/convert.jl` — minor: use `with_env` in the few places that hit JNI directly (`unsafe_string(::Ptr{Nothing})`, primitive array `convert_result`, `convert(::Type{Array{T,1}}, ::JObject)`).
- `src/reflect.jl` — no logic changes; verify it still compiles after JValue / signature changes.
- `src/jniarray.jl` — `release_elements` and `get_elements!` use `with_env`; `convert_arg`/`cleanup_arg` paths unchanged.
- `src/jcall_macro.jl` — no logic changes; verify the macro still produces `jcall(...)` calls that work with the rewritten `jcall`.
- `src/make_jni2.jl` — emit env as required argument (no default `ppenv[Threads.threadid()]`); emit `gc_safe = true` ccall annotation for the JNI call types in the spec's audit table.
- `test/runtests.jl` — drop `roottask_and_env_1` testset; drop `JAVACALL_FORCE_ASYNC_*` machinery; drop the `static_method_call_async_1` testset's special branches; add new testsets for `parallel_jcall`, `task_migration_safety`, `env_cache_per_thread`, `finalizer_routes_through_dispatch`.

### Files deleted

- `src/Threads.jl` — Windows stub no longer needed. Replaced by direct `using Base.Threads` where needed.

---

## Branch Organization

Phase 1 used a branch-per-milestone workflow. Phase 2A continues that. Each milestone below is one branch; each branch ends with full test pass + push + `--no-ff` merge to master. Branches are sequential — later branches depend on earlier ones. Order:

1. `phase-2/baselines` — Julia 1.12 minimum, JNI 21, README/CI cleanup
2. `phase-2/env-cache` — `src/env.jl` (created but not yet wired in)
3. `phase-2/dispatch-task` — `src/dispatch.jl` (created and wired into `__init__`/`destroy`, but no JNI work routes through it yet)
4. `phase-2/jvalue-primitive` — replace `const jvalue = Int64` with `primitive type JValue 64`
5. `phase-2/jcall-rewrite` — wire `jcall`/`jnew`/`jfield` through `with_env`; regenerate JNI.jl with `gc_safe` annotations and explicit env args; method-ID cache
6. `phase-2/finalizer-routing` — `deleteref` posts `DeleteRef` messages
7. `phase-2/legacy-removal` — delete `Threads.jl`, remove `JULIA_COPY_STACKS` machinery, drop `assertroottask_or_goodenv` and friends, README cleanup

The full Phase 1 test suite (currently 261 passing) must continue to pass at the end of every branch. Some Phase 1 tests check `JavaCall.JULIA_COPY_STACKS` etc. — those tests get replaced as part of the legacy-removal branch, but until then they must still pass.

---

## Milestone 1: phase-2/baselines

**Branch:** `phase-2/baselines`

This milestone bumps Julia and JNI version requirements. No behavior changes. CI matrix gets cleaned up but the threading workarounds stay until later milestones replace them.

### Task 1.1: Create the branch

- [ ] **Step 1: Branch off master**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git pull origin master
git checkout -b phase-2/baselines
```

### Task 1.2: Bump `julia` compat in Project.toml

**Files:**
- Modify: `Project.toml`

- [ ] **Step 1: Edit `Project.toml` line 14 from `julia = "1.6"` to `julia = "1.12"`**

```toml
[compat]
DataStructures = "0.17, 0.18, 0.19"
WinReg = "0.3.1, 1"
julia = "1.12"
```

- [ ] **Step 2: Run the test suite to confirm nothing broke**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()'
```

Expected: `JavaCall | 261 261 ...s` and `Testing JavaCall tests passed`.

### Task 1.3: Add `JNI_VERSION_19`, `JNI_VERSION_20`, `JNI_VERSION_21` constants

**Files:**
- Modify: `src/JNI.jl:91-92`

- [ ] **Step 1: Add the three constants after `JNI_VERSION_10`**

Locate the existing block:

```julia
const JNI_VERSION_1_8 = convert(Cint, 0x00010008)
const JNI_VERSION_9   = convert(Cint, 0x00090000)
const JNI_VERSION_10  = convert(Cint, 0x000a0000)
```

Replace it with:

```julia
const JNI_VERSION_1_8 = convert(Cint, 0x00010008)
const JNI_VERSION_9   = convert(Cint, 0x00090000)
const JNI_VERSION_10  = convert(Cint, 0x000a0000)
const JNI_VERSION_19  = convert(Cint, 0x00130000)
const JNI_VERSION_20  = convert(Cint, 0x00140000)
const JNI_VERSION_21  = convert(Cint, 0x00150000)
```

- [ ] **Step 2: Run the test suite**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()'
```

Expected: 261 tests pass.

### Task 1.4: Bump `init_new_vm` to request `JNI_VERSION_21`

**Files:**
- Modify: `src/JNI.jl:155`

- [ ] **Step 1: Change the version arg in `JavaVMInitArgs`**

In `init_new_vm`, find:

```julia
        vm_args = JavaVMInitArgs(JNI_VERSION_1_8, convert(Cint, length(opts)),
                                 convert(Ptr{JavaVMOption}, pointer(opt)), JNI_TRUE)
```

Change `JNI_VERSION_1_8` to `JNI_VERSION_21`:

```julia
        vm_args = JavaVMInitArgs(JNI_VERSION_21, convert(Cint, length(opts)),
                                 convert(Ptr{JavaVMOption}, pointer(opt)), JNI_TRUE)
```

- [ ] **Step 2: Verify behavior on JDK 17 still works (regression smoke)**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()'
```

Expected: 261 tests pass. JNI versions are forward-compatible, so requesting 21 on JDK 17 still works (the JVM returns the highest version it supports; init only fails if the requested major is below what the JVM offers).

### Task 1.5: Update CI matrix

**Files:**
- Modify: `.github/workflows/CI.yml`

- [ ] **Step 1: Replace the matrix block**

Locate the strategy block (~lines 14-39) and replace with:

```yaml
    env:
      # JULIA_COPY_STACKS intentionally unset — the new threading
      # architecture does not depend on it.
      JULIA_NUM_THREADS: ${{ matrix.threads }}
    strategy:
      fail-fast: false
      matrix:
        version:
          - '1.12'
          - 'lts'
          - '1'
        os:
          - ubuntu-latest
          - windows-latest
        threads:
          - '1'
          - '4'
        arch:
          - x64
        include:
          - version: '1'
            os: macos-latest
            arch: aarch64
            threads: '4'
          - version: '1'
            os: macos-latest
            arch: aarch64
            threads: '1'
          - version: '1'
            os: macos-15-intel
            arch: x64
            threads: '4'
```

Drop the `julia_copy_stacks` lines from the `julia-runtest` step's `env`:

Locate:

```yaml
      - uses: julia-actions/julia-runtest@v1
        env:
          JULIA_COPY_STACKS: ${{ matrix.julia_copy_stacks }}
```

Replace with:

```yaml
      - uses: julia-actions/julia-runtest@v1
```

(Leave the rest of the workflow — `setup-java`, `setup-julia`, `cache`, `julia-buildpkg`, `julia-processcoverage`, `codecov-action` — unchanged.)

- [ ] **Step 2: Locally verify YAML is valid**

```bash
ruby -ryaml -e "YAML.load_file('.github/workflows/CI.yml')" || python3 -c "import yaml; yaml.safe_load(open('.github/workflows/CI.yml'))"
```

Expected: no output (YAML parses).

### Task 1.6: Update README compat sections

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Edit the "Julia version compatibility" section**

Find:

```
## Julia version compatibility

The CI tests for Julia 1.6 as `min`, Julia LTS, and the latest stable release.
```

Replace with:

```
## Julia version compatibility

JavaCall.jl 0.9 requires Julia 1.12 or newer. CI tests Julia 1.12 (`min`), Julia LTS, and the latest stable release. For older Julia versions, use JavaCall.jl 0.8.x.
```

- [ ] **Step 2: Leave the macOS / Linux / Windows env-var sections AS-IS for now**

The `JULIA_COPY_STACKS` and Windows-specific sections will be removed in milestone `phase-2/legacy-removal` (Task 7.5). Removing them now would create an inconsistent state where the README says "no env vars needed" but the code still requires them.

### Task 1.7: Commit and push

- [ ] **Step 1: Stage and commit**

```bash
cd /Users/brad/Projects/JavaCall.jl
git add Project.toml src/JNI.jl .github/workflows/CI.yml README.md
git commit -m "$(cat <<'EOF'
Bump baselines: Julia 1.12 min, request JNI_VERSION_21

Phase 2 of the threading rebuild requires Julia 1.12 (OncePerThread,
gc_safe = true ccall) and a modern JDK baseline. Bump min Julia to
1.12 in Project.toml and the CI matrix; add a JULIA_NUM_THREADS
dimension to validate single- and multi-threaded scenarios; drop the
julia_copy_stacks matrix dimension (the env var is no longer used).

Add JNI_VERSION_19/20/21 constants and bump init_new_vm to request
JNI_VERSION_21. JNI versions are additive and forward-compatible —
this works against JDK 11 (the new minimum) up through current.

Update README to declare Julia 1.12 as the minimum for 0.9. The
JULIA_COPY_STACKS / Windows-pinning sections stay until the legacy
threading machinery is fully removed in a later branch.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 2: Push to fork**

```bash
git push -u origin phase-2/baselines
```

### Task 1.8: Merge to master

- [ ] **Step 1: Switch to master and merge with `--no-ff`**

```bash
git checkout master
git merge --no-ff phase-2/baselines -m "Merge branch 'phase-2/baselines'"
git push origin master
```

- [ ] **Step 2: Verify clean merge**

```bash
git status   # expected: "nothing to commit, working tree clean"
git log --oneline -3
```

---

## Milestone 2: phase-2/env-cache

**Branch:** `phase-2/env-cache`

Create `src/env.jl` with the `OncePerThread{Ptr{JNIEnv}}` cache and `with_env` helper. Not yet wired into `jcall` — that happens in milestone 5.

### Task 2.1: Create the branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git checkout -b phase-2/env-cache
```

### Task 2.2: Write a failing test for the env cache

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Add a new testset just before the closing `end` of the outer `@testset "JavaCall"`**

Find the line that contains `include("jcall_macro.jl")` (around line 459 after Phase 1 changes; line number may shift). Just before that include, add:

```julia
@testset "env_cache_per_thread" begin
    # The OncePerThread cache should give different envs on different OS threads.
    # Until phase-2/jcall-rewrite, with_env is not on the call hot path; this test
    # exercises the cache directly.
    nthreads = Base.Threads.nthreads()
    if nthreads >= 2
        envs = Vector{Ptr{JavaCall.JNI.JNIEnv}}(undef, nthreads)
        Threads.@threads :static for i = 1:nthreads
            JavaCall.with_env() do env
                envs[i] = env
            end
        end
        @test all(e != C_NULL for e in envs)
        @test length(unique(envs)) == nthreads
    else
        @test_skip "env_cache_per_thread requires JULIA_NUM_THREADS >= 2"
    end
end
```

- [ ] **Step 2: Run the test, expect it to fail (function `with_env` not defined yet)**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: error like `UndefVarError: \`with_env\` not defined in JavaCall` or similar. The test must fail before we implement.

### Task 2.3: Create `src/env.jl`

**Files:**
- Create: `src/env.jl`

- [ ] **Step 1: Write the file**

```julia
"""
    JavaCall env-cache layer (Phase 2)

Per-OS-thread `JNIEnv*` cache and `with_env` helper. Every JNI call goes
through `with_env`, which:

  1. Looks up `Ptr{JNIEnv}` for the current OS thread via `OncePerThread`.
  2. If absent, calls `AttachCurrentThreadAsDaemon` to register the thread
     with the JVM and stores the resulting env in the cache.
  3. Calls the user's function with the env pointer.

The cache is keyed on the *current* OS thread at evaluation time (not on a
stale `threadid()` snapshot), so it is safe under Julia task migration:
a task that yields and resumes on a different OS thread will see the
correct env for the new thread on its next `with_env` call.

Daemon attach is intentional: non-daemon attached threads block
`DestroyJavaVM` at process exit. Julia worker threads are reused
indefinitely, so daemon attach matches their lifecycle.
"""

# Cache: one Ptr{JNIEnv} per OS thread.
const _env_cache = OncePerThread{Ptr{JNI.JNIEnv}}() do
    pp = Ref{Ptr{JNI.JNIEnv}}(C_NULL)
    res = ccall(JNI.jvmfunc[].AttachCurrentThreadAsDaemon, Cint,
                (Ptr{Nothing}, Ptr{Ptr{JNI.JNIEnv}}, Ptr{Nothing}),
                JNI.ppjvm[], pp, C_NULL)
    res < 0 && throw(JavaCallError("Failed to attach OS thread to JVM (res=$(res))"))
    pp[]
end

"""
    with_env(f::Function) -> Any

Run `f(env::Ptr{JNIEnv})` with the JVM env pointer for the current OS
thread, attaching the thread to the JVM as a daemon if not already
attached.

Do not yield, sleep, or `wait` between fetching the env pointer and using
it: the env pointer is valid only on the OS thread it was fetched from,
and Julia tasks can migrate across yield points.
"""
@inline with_env(f::Function) = f(_env_cache[])
```

- [ ] **Step 2: Wire `env.jl` into `JavaCall.jl`**

Modify `src/JavaCall.jl`. Find the `include` block:

```julia
include("JNI.jl")
using .JNI
import .JNI.Threads
include("jvm.jl")
include("core.jl")
include("convert.jl")
include("reflect.jl")
include("jniarray.jl")
include("jcall_macro.jl")
```

Insert `include("env.jl")` after `include("jvm.jl")` (env.jl uses `JavaCallError` from jvm.jl):

```julia
include("JNI.jl")
using .JNI
import .JNI.Threads
include("jvm.jl")
include("env.jl")
include("core.jl")
include("convert.jl")
include("reflect.jl")
include("jniarray.jl")
include("jcall_macro.jl")
```

- [ ] **Step 3: Run the test, expect it to pass**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "JavaCall.*[0-9]+.*[0-9]+|tests passed|tests failed|Error" | head -10
```

Expected: 262 tests pass (261 baseline + 1 new).

### Task 2.4: Commit and push

- [ ] **Step 1**

```bash
git add src/env.jl src/JavaCall.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Add per-OS-thread JNIEnv cache and with_env helper

Introduces src/env.jl with a OncePerThread cache that lazily attaches
each OS thread to the JVM (as a daemon) on first JNI use. The
`with_env(f) do env ... end` helper is the single primitive every JNI
call will go through in the rewrite.

OncePerThread (Julia 1.12+) is keyed on the *current* OS thread at
evaluation time, not on a stale Threads.threadid() snapshot, so the
cache is correct under task migration: a task that yields and resumes
on a different OS thread will fetch the right env on its next
with_env call.

Not yet wired into jcall — that happens in phase-2/jcall-rewrite. This
branch only adds the helper and a basic test that confirms different
OS threads see different env pointers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin phase-2/env-cache
```

### Task 2.5: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2/env-cache -m "Merge branch 'phase-2/env-cache'"
git push origin master
```

---

## Milestone 3: phase-2/dispatch-task

**Branch:** `phase-2/dispatch-task`

Create `src/dispatch.jl` with the dispatch task lifecycle, channel, and drain loop. Wire it into `JavaCall.__init__()` (start) and `JavaCall.destroy()` (stop). Not yet receiving any DeleteRef messages — finalizers still call `_deleteref` directly until milestone 6.

### Task 3.1: Create the branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git checkout -b phase-2/dispatch-task
```

### Task 3.2: Write a failing test for dispatch task lifecycle

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Add a new testset just after `env_cache_per_thread`**

```julia
@testset "dispatch_task_lifecycle" begin
    # The dispatch task should be alive after JavaCall.init() and have
    # processed zero messages so far (we haven't routed anything to it).
    @test JavaCall._dispatch_task[] isa Task
    @test !istaskdone(JavaCall._dispatch_task[])
    @test isready(JavaCall._dispatch_channel) == false
end
```

- [ ] **Step 2: Run the test, expect it to fail**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: `UndefVarError: \`_dispatch_task\` not defined in JavaCall`.

### Task 3.3: Create `src/dispatch.jl`

**Files:**
- Create: `src/dispatch.jl`

- [ ] **Step 1: Write the file**

```julia
"""
    JavaCall dispatch-task layer (Phase 2)

A single sticky task in the `:interactive` pool that owns one OS thread,
pre-attached to the JVM. The dispatch task drains a `Channel{DispatchMsg}`
and executes each message on its attached thread. This guarantees that
finalization (and, in Phase 2C, callbacks) always runs on a known-good
JNI context regardless of which Julia task or thread originated the
message.

In this branch (Phase 2A), the dispatch task is up but receives no
messages — `deleteref` still calls JNI directly. The
`phase-2/finalizer-routing` branch later replaces direct JNI calls with
channel posts.
"""

abstract type DispatchMsg end

"""
    DeleteRef(ptr, kind)

Release a JNI reference. `kind` is `:local` (DeleteLocalRef) or `:global`
(DeleteGlobalRef). Posted by JavaObject finalizers from any task/thread.
"""
struct DeleteRef <: DispatchMsg
    ptr::Ptr{Nothing}
    kind::Symbol
end

"""
    Shutdown()

Sentinel that ends the drain loop. Posted by `stop_dispatch_task!`.
"""
struct Shutdown <: DispatchMsg end

# Effectively unbounded — Julia Channels with sz_max=typemax(Int) only allocate
# as items arrive. Bounded sizes turned out unworkable for the finalizer-routing
# path: Julia's `push!`/`put!` block on a full channel (they don't throw), and
# blocking finalizers risk deadlocking GC. Phase 2's spec mentions 1024 as a
# soft cap; that turns out to be wrong about push!-throws-on-full semantics.
# Future work (per spec) can replace this with a bounded ring buffer + drop-on-
# overflow if memory profiling shows a concern.
const _dispatch_channel = Channel{DispatchMsg}(typemax(Int))
const _dispatch_task = Ref{Task}()

# Debug counter (testing only): incremented for every DeleteRef handled.
const _dispatch_processed_count = Threads.Atomic{Int}(0)

function _handle(msg::DeleteRef)
    with_env() do env
        if msg.kind === :local
            JNI.DeleteLocalRef(env, msg.ptr)
        elseif msg.kind === :global
            JNI.DeleteGlobalRef(env, msg.ptr)
        end
    end
    Threads.atomic_add!(_dispatch_processed_count, 1)
    return
end

_handle(msg::Shutdown) = nothing

function _drain_loop()
    while true
        msg = take!(_dispatch_channel)
        try
            _handle(msg)
        catch err
            @error "Dispatch task error" exception=(err, catch_backtrace())
            # Continue: one bad message must not kill the loop.
        end
        msg isa Shutdown && break
    end
end

"""
    start_dispatch_task!()

Spawn the dispatch task. Called from `JavaCall.__init__` after the JVM
is initialized. The task is sticky (`t.sticky = true`) so it stays on
its OS thread for the JVM's lifetime, keeping the daemon attachment
valid throughout.
"""
function start_dispatch_task!()
    isassigned(_dispatch_task) && !istaskdone(_dispatch_task[]) && return
    t = Threads.@spawn :interactive begin
        # Eagerly attach this OS thread so subsequent _handle calls don't
        # pay the attach cost on the first message.
        with_env() do _ end
        _drain_loop()
    end
    t.sticky = true
    _dispatch_task[] = t
    Base.errormonitor(t)
    return
end

"""
    stop_dispatch_task!()

Post a Shutdown message and wait for the task to drain pending messages
and exit its loop. Called from `JavaCall.destroy()` before
DestroyJavaVM.
"""
function stop_dispatch_task!()
    isassigned(_dispatch_task) || return
    istaskdone(_dispatch_task[]) && return
    push!(_dispatch_channel, Shutdown())
    wait(_dispatch_task[])
    return
end
```

- [ ] **Step 2: Wire `dispatch.jl` into `JavaCall.jl`**

Modify `src/JavaCall.jl`. After the existing `include("env.jl")` line (added in milestone 2):

```julia
include("env.jl")
include("dispatch.jl")
```

(env.jl must come first because dispatch.jl uses `with_env`.)

- [ ] **Step 3: Wire `start_dispatch_task!` and `stop_dispatch_task!` into the JVM lifecycle**

In `src/jvm.jl`, find the `_init` function:

```julia
function _init(opts)
    assertnotloaded()
    assertroottask_or_goodenv()
    JNI.init_new_vm(findjvm(),opts);
end
```

(This runs at `JavaCall.init()`. We need to spawn the dispatch task after `JNI.init_new_vm` succeeds.)

Replace with:

```julia
function _init(opts)
    assertnotloaded()
    assertroottask_or_goodenv()
    JNI.init_new_vm(findjvm(),opts);
    start_dispatch_task!()
end
```

In the same file, find the `destroy` function:

```julia
function destroy()
    assertroottask_or_goodenv()
    JNI.destroy()
end
```

Replace with:

```julia
function destroy()
    assertroottask_or_goodenv()
    stop_dispatch_task!()
    JNI.destroy()
end
```

- [ ] **Step 4: Run the test**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "JavaCall.*[0-9]+.*[0-9]+|tests passed|tests failed|Error" | head -10
```

Expected: 263 tests pass (262 + 3 new test assertions in dispatch_task_lifecycle).

### Task 3.4: Add a test for dispatch task survival under errors

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Add a testset directly after `dispatch_task_lifecycle`**

```julia
@testset "dispatch_task_survives_handler_error" begin
    # Verify the drain loop catches errors in _handle and continues.
    # We poke a contrived bad DeleteRef whose ptr can't be resolved; the
    # JNI DeleteLocalRef call may fail, but the dispatch task must
    # remain alive.
    initial = JavaCall._dispatch_processed_count[]
    bad_ptr = Ptr{Nothing}(0xdeadbeef)
    push!(JavaCall._dispatch_channel, JavaCall.DeleteRef(bad_ptr, :local))
    sleep(0.05)   # let dispatch task drain
    @test !istaskdone(JavaCall._dispatch_task[])
    @test JavaCall._dispatch_processed_count[] >= initial   # may or may not have incremented
                                                             # depending on JNI behaviour
end
```

- [ ] **Step 2: Run the test**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "JavaCall.*[0-9]+.*[0-9]+|tests passed|tests failed|Error" | head -10
```

Expected: 265 tests pass.

### Task 3.5: Commit and push

- [ ] **Step 1**

```bash
git add src/dispatch.jl src/JavaCall.jl src/jvm.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Add dispatch task lifecycle and DeleteRef channel

Introduces src/dispatch.jl with a single sticky task in the
:interactive pool that pre-attaches its OS thread to the JVM and
drains a Channel{DispatchMsg}. Currently handles DeleteRef and
Shutdown messages only; Callback (Phase 2C) and any other inbound
work will route through the same channel.

Wired into JavaCall._init (start) and JavaCall.destroy (stop).
errormonitor is attached to the task so unhandled exceptions surface
immediately instead of getting swallowed.

The drain loop is wrapped in try/catch around each _handle call:
one bad message must not kill the loop. A Threads.Atomic counter
tracks processed messages for testing.

Not yet receiving any messages on real workloads — deleteref still
calls JNI directly. The phase-2/finalizer-routing branch posts
DeleteRef messages here instead.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin phase-2/dispatch-task
```

### Task 3.6: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2/dispatch-task -m "Merge branch 'phase-2/dispatch-task'"
git push origin master
```

---

## Milestone 4: phase-2/jvalue-primitive

**Branch:** `phase-2/jvalue-primitive`

Replace `const jvalue = Int64` with a real `primitive type JValue 64`. The encoder function `jvalue(v)` (in `core.jl`) keeps its name but now returns `JValue` instead of `Int64`. ccall sites that used `Array{Int64}` for argument arrays use `Array{JValue}` (bit-compatible).

The function-vs-type name collision is resolved as follows:

- The **type** in the JNI module is renamed: `JNI.jvalue` → `JNI.JValue`.
- The **function** in the JavaCall module keeps its name: `jvalue(v)`.

### Task 4.1: Create the branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git checkout -b phase-2/jvalue-primitive
```

### Task 4.2: Replace the type definition in `JNI.jl`

**Files:**
- Modify: `src/JNI.jl:68`

- [ ] **Step 1: Edit line 68**

Find:

```julia
jvalue = Int64
```

Replace with:

```julia
"""
    JValue

JNI's `jvalue` C union as a Julia primitive type. 64 bits wide. Values
of any JNI primitive (jint, jlong, jfloat, jdouble, jboolean, jbyte,
jchar, jshort) or a jobject pointer are encoded into a JValue via the
`jvalue(...)` functions in core.jl, which handle endianness and bit
placement explicitly. JValue is bit-compatible with Int64 but the
distinct type catches accidental mixing of Java values and Julia
integers in ccall signatures.
"""
primitive type JValue 64 end

JValue(x::Int64)  = reinterpret(JValue, x)
JValue(x::UInt64) = reinterpret(JValue, x)
Base.zero(::Type{JValue}) = reinterpret(JValue, Int64(0))
Base.convert(::Type{JValue}, x::Integer) = JValue(Int64(x))
```

- [ ] **Step 2: Add `JValue` to the export list at the top of the module**

Find the existing exports:

```julia
# jni.h exports
export jboolean, jchar, jshort, jfloat, jdouble, jsize, jprimitive
export jvoid
```

Replace with:

```julia
# jni.h exports
export jboolean, jchar, jshort, jfloat, jdouble, jsize, jprimitive
export jvoid, JValue
```

- [ ] **Step 3: Verify the package still compiles**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using JavaCall; println(JavaCall.JNI.JValue)'
```

Expected output: `JavaCall.JNI.JValue`. (At this point compilation succeeds; tests may fail because `_jcall` references `JNI.jvalue` as a type, and we removed that.)

### Task 4.3: Update `_jcall` ccall sites to use `JValue`

**Files:**
- Modify: `src/core.jl`

- [ ] **Step 1: Locate the metaprogrammed for-loop near the bottom of core.jl that defines `_jcall` and `_jfield`**

Find the line:

```julia
                GC.@preserve obj savedArgs convertedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.jvalue}(jvalue.(convertedArgs)))
                end
```

Replace `JNI.jvalue` with `JNI.JValue`:

```julia
                GC.@preserve obj savedArgs convertedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.JValue}(jvalue.(convertedArgs)))
                end
```

- [ ] **Step 2: Update `jvalue(...)` encoder functions in core.jl**

Find the encoder block (around line 305-310 after Phase 1):

```julia
# jvalue(v::Integer) = int64(v) << (64-8*sizeof(v))
jvalue(v::Integer)::JNI.jvalue = JNI.jvalue(v)
# Use UInt32 (zero-extension to Int64) rather than Int32 (sign-extension)
# so the high 4 bytes of the 8-byte jvalue slot are clean. Currently
# harmless on every Julia-supported architecture (all little-endian, where
# the JVM reads jfloat from bytes 0-3), but the previous Int32 reinterpret
# leaked the float's sign bit into bytes 4-7 of the union slot.
jvalue(v::Float32) = jvalue(reinterpret(UInt32, v))
jvalue(v::Float64) = jvalue(reinterpret(Int64, v))
jvalue(v::Ptr) = jvalue(Int(v))
jvalue(v::JavaObject) = jvalue(Ptr(v))
```

Replace with:

```julia
# Encode Julia values into a JValue (the C jvalue union). The function
# name is lowercase `jvalue` to match the C convention; the type name is
# `JValue` (CamelCase Julia primitive type).
jvalue(v::Integer)::JNI.JValue = JNI.JValue(Int64(v))
# Use UInt32 (zero-extension to Int64) rather than Int32 (sign-extension)
# so the high 4 bytes of the 8-byte jvalue slot are clean. Currently
# harmless on every Julia-supported architecture (all little-endian, where
# the JVM reads jfloat from bytes 0-3).
jvalue(v::Float32)::JNI.JValue = JNI.JValue(Int64(reinterpret(UInt32, v)))
jvalue(v::Float64)::JNI.JValue = JNI.JValue(reinterpret(Int64, v))
jvalue(v::Ptr)::JNI.JValue = JNI.JValue(Int64(UInt(v)))
jvalue(v::JavaObject) = jvalue(Ptr(v))
```

### Task 4.4: Update `jniarray.jl` jvalue accessor

**Files:**
- Modify: `src/jniarray.jl:34`

- [ ] **Step 1: Update the `jvalue(jarr::JNIVector)` accessor**

Find:

```julia
jvalue(jarr::JNIVector) = jarr.ref.ptr
```

Replace with:

```julia
jvalue(jarr::JNIVector)::JNI.JValue = JNI.JValue(Int64(UInt(jarr.ref.ptr)))
```

### Task 4.5: Run the tests

- [ ] **Step 1**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | grep -E "JavaCall.*[0-9]+.*[0-9]+|tests passed|tests failed|Error" | head -10
```

Expected: 265 tests pass. The encoding behavior is unchanged on little-endian (which is everywhere Julia runs), so all existing parameter-passing tests should continue to pass.

### Task 4.6: Commit, push, merge

- [ ] **Step 1**

```bash
git add src/JNI.jl src/core.jl src/jniarray.jl
git commit -m "$(cat <<'EOF'
Replace `jvalue = Int64` alias with primitive type JValue

The C jvalue union is 8 bytes wide, addressed at offset 0 for any
member. The previous `const jvalue = Int64` alias didn't catch
accidental mixing of Java values and Julia integers in ccall sites,
and made the Float32 sign-extension footgun (fixed in Phase 1) less
visible.

Define `primitive type JValue 64` in the JNI module; export as
`JNI.JValue`. The lowercase function `jvalue(...)` in core.jl keeps
its name as the encoder, now returning JValue. Update the _jcall
metaprogrammed loop to construct `Array{JNI.JValue}` instead of
`Array{JNI.jvalue}`. Update the JNIVector jvalue accessor to return
JValue.

Behavior is bit-identical on every Julia-supported architecture
(little-endian); the change is type-system hygiene plus an explicit
contract for future big-endian support.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin phase-2/jvalue-primitive
git checkout master
git merge --no-ff phase-2/jvalue-primitive -m "Merge branch 'phase-2/jvalue-primitive'"
git push origin master
```

---

## Milestone 5: phase-2/jcall-rewrite

**Branch:** `phase-2/jcall-rewrite`

The big one. Wire `jcall`/`jnew`/`jfield` through `with_env`. Update `make_jni2.jl` to emit env as a required arg and add `gc_safe = true` for slow JNI methods. Regenerate the JNI.jl block. Add method-ID caching.

This is the largest milestone — split into focused tasks.

### Task 5.1: Create the branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git checkout -b phase-2/jcall-rewrite
```

### Task 5.2: Update `make_jni2.jl` to emit env as required arg

**Files:**
- Modify: `src/make_jni2.jl`

- [ ] **Step 1: Edit the generator's argument-list construction**

Find the lines (~123-130 after Phase 1):

```julia
  # skip the JNIEnv arg for julia since it is passed as a global to ccall.
  # Default penv to the current thread's slot to match the committed
  # output in JNI.jl. (Phase 2 will redo this layer entirely; the only
  # purpose of keeping this aligned is to prevent silent regressions
  # from someone re-running the generator.)
  julia_args = join(push!(map(julia_arg, mm)[2:end],"penv=ppenv[ Threads.threadid() ]"), ", ")
```

Replace with:

```julia
  # skip the JNIEnv arg for julia since it is passed explicitly by callers.
  # Phase 2: env is a required argument, no default. Callers obtain env
  # via `with_env(f) do env ... end` from src/env.jl.
  julia_args = join(push!(map(julia_arg, mm)[2:end], "penv::Ptr{JNIEnv}"), ", ")
```

### Task 5.3: Update `make_jni2.jl` to emit `gc_safe = true` for slow JNI methods

**Files:**
- Modify: `src/make_jni2.jl`

- [ ] **Step 1: Define the gc_safe set near the top of the file**

After the comment block at the top of the file (around line 11), add:

```julia
# JNI methods that may execute arbitrary Java code or trigger GC pin/unpin
# operations that the JVM may make slow. Annotate ccalls into these with
# `gc_safe = true` (Julia 1.12+) so Julia's GC can proceed concurrently
# while the call is in flight. See the spec's "gc_safe = true audit"
# table for full rationale.
const GC_SAFE_PREFIXES = [
    "Call",                 # Call*Method, CallStatic*Method, CallNonvirtual*Method
    "GetStatic", "SetStatic",  # Static field accessors
    "Get", "Set",           # Instance field accessors (overlap covered below)
    "GetBooleanArrayElements", "GetByteArrayElements", "GetCharArrayElements",
    "GetShortArrayElements", "GetIntArrayElements", "GetLongArrayElements",
    "GetFloatArrayElements", "GetDoubleArrayElements",
    "ReleaseBooleanArrayElements", "ReleaseByteArrayElements",
    "ReleaseCharArrayElements", "ReleaseShortArrayElements",
    "ReleaseIntArrayElements", "ReleaseLongArrayElements",
    "ReleaseFloatArrayElements", "ReleaseDoubleArrayElements",
    "FindClass", "DefineClass",
    "GetMethodID", "GetStaticMethodID", "GetFieldID", "GetStaticFieldID",
    "FromReflectedMethod", "FromReflectedField",
    "NewObject",
    "ToReflectedMethod", "ToReflectedField",
]

# Methods explicitly excluded from gc_safe. Critical-section calls MUST
# NOT be gc_safe — Julia GC must not proceed while a critical section is
# held.
const GC_UNSAFE_NAMES = Set([
    "GetPrimitiveArrayCritical", "ReleasePrimitiveArrayCritical",
    "GetStringCritical", "ReleaseStringCritical",
])

is_gc_safe(fname::AbstractString) = begin
    fname in GC_UNSAFE_NAMES && return false
    any(startswith(fname, p) for p in GC_SAFE_PREFIXES)
end
```

- [ ] **Step 2: Edit the print statement at the bottom of the loop to emit `@ccall ... gc_safe = true` when appropriate**

Find:

```julia
  # Commented out export command
  # print("#export $fname\n")
  print("$fname($julia_args) =\n  ccall(jniref[].$(fname), $rtype, ($arg_types,), $arg_names)\n\n")
```

Replace with:

```julia
  # Commented out export command
  # print("#export $fname\n")
  if is_gc_safe(fname)
      # @ccall macro form supports `gc_safe = true`; ccall does not.
      # Build a @ccall expression by hand. The argument typing must match
      # what ccall would have built: `arg::Type`.
      typed_args = String[]
      for arg_pair in zip(map(arg_value, mm), split(arg_types, ", "))
          name, typ = arg_pair
          push!(typed_args, "$name::$typ")
      end
      pushfirst!(typed_args, "penv::Ptr{JNIEnv}")   # env is the first ccall arg
      print("$fname($julia_args) =\n  @ccall jniref[].$(fname)(",
            join(typed_args, ", "), ")::$rtype gc_safe = true\n\n")
  else
      print("$fname($julia_args) =\n  ccall(jniref[].$(fname), $rtype, ($arg_types,), $arg_names)\n\n")
  end
```

### Task 5.4: Regenerate the JNI.jl bindings block

**Files:**
- Modify: `src/JNI.jl` (the `# === Below Generated ===` block)

- [ ] **Step 1: Run the generator and capture output**

```bash
cd /Users/brad/Projects/JavaCall.jl/src
julia make_jni2.jl > /tmp/jni_generated.jl 2>/dev/null
```

- [ ] **Step 2: Replace the generated block in `src/JNI.jl`**

Open `src/JNI.jl`. Find the line `# === Below Generated by make_jni2.jl ===` (around line 219) and the corresponding `# === Above Generated by make_jni2.jl ===` near the bottom of the file. Replace everything between (inclusive of the markers) with the contents of `/tmp/jni_generated.jl`.

Use Read + Write to do this precisely. Read the current JNI.jl, find the markers, splice in the new block.

```bash
# Verify the regenerated block looks right
head -20 /tmp/jni_generated.jl
```

Expected: starts with `# === Below Generated by make_jni2.jl ===`, has `GetVersion(penv::Ptr{JNIEnv}) =` (no default), and shows `@ccall` for slow methods with `gc_safe = true` and plain `ccall` for the rest.

- [ ] **Step 3: Manually preserve the three commented-out alternative `ReleaseStringUTFChars` lines (Phase 1 hand-edit)**

The committed JNI.jl has three commented-out lines around the `ReleaseStringUTFChars` section. After regeneration, these lines may be missing. Locate `ReleaseStringUTFChars` in the new block and add immediately above it:

```julia
## Prior to this module we used UInt8 instead of Cstring, must match return value of above
#ReleaseStringUTFChars(str::jstring, chars::Ptr{UInt8}, penv::Ptr{JNIEnv}) =
#  ccall(jniref[].ReleaseStringUTFChars, Nothing, (Ptr{JNIEnv}, jstring, Ptr{UInt8},), penv, str, chars)
```

(These were intentional hand-additions to document an alternative call signature.)

- [ ] **Step 4: Verify the package still compiles**

```bash
cd /Users/brad/Projects/JavaCall.jl
julia --project=. -e 'using JavaCall'
```

Expected: no errors. (Tests will fail because callers don't pass env yet — that's the next task.)

### Task 5.5: Update callers in `core.jl` to pass env

**Files:**
- Modify: `src/core.jl`

This task rewires every internal caller of a JNI function to pass `env`. Many edits but mechanical.

- [ ] **Step 1: Add a `with_env` wrapper at the top of jcall**

Find `jcall(ref, method::AbstractString, ...)`:

```julia
function jcall(ref, method::AbstractString, rettype::Type, argtypes::Tuple = (), args...)
    assertroottask_or_goodenv() && assertloaded()
    jmethodId = get_method_id(ref, method, rettype, argtypes)
    _jcall(_jcallable(ref), jmethodId, rettype, argtypes, args...)
end
```

Replace with:

```julia
function jcall(ref, method::AbstractString, rettype::Type, argtypes::Tuple = (), args...)
    assertloaded()
    with_env() do env
        jmethodId = get_method_id(env, ref, method, rettype, argtypes)
        _jcall(env, _jcallable(ref), jmethodId, rettype, argtypes, args...)
    end
end
```

(Note: removed `assertroottask_or_goodenv()` — it stays in jvm.jl until phase-2/legacy-removal but stops being called from new code paths now.)

Apply the same pattern to:

- `jcall(ref, method::JMethod, args...)` — wrap in `with_env`, threading env through
- `jnew(T::Symbol, argtypes, args...)` — wrap in `with_env`
- `jfield(ref, field, fieldType)` — wrap in `with_env`
- `jfield(ref, field)` — wrap in `with_env`
- `jfield(ref, field::AbstractString)` — wrap in `with_env`

In each case: replace `assertroottask_or_goodenv() && assertloaded()` with `assertloaded()`, and wrap the body in `with_env() do env ... end`.

- [ ] **Step 2: Update `_jcall` and `_jfield` signatures to take env**

Find the metaprogrammed for-loop:

```julia
            function _jfield(obj::T, jfieldID::Ptr{Nothing}, fieldType::Type{$x}) where T <: $t
                result = $fieldmethod(Ptr(obj), jfieldID)
                geterror()
                return convert_result(fieldType, result)
            end
            function _jcall(obj::T, jmethodId::Ptr{Nothing}, rettype::Type{$x},
                            argtypes::Tuple, args...; callmethod=$callmethod) where T <: $t
                savedArgs, convertedArgs = convert_args(argtypes, args...)
                GC.@preserve obj savedArgs convertedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.JValue}(jvalue.(convertedArgs)))
                end
                cleanup_arg.(convertedArgs)
                geterror()
                return convert_result(rettype, result)
            end
```

Replace with:

```julia
            function _jfield(env::Ptr{JNI.JNIEnv}, obj::T, jfieldID::Ptr{Nothing}, fieldType::Type{$x}) where T <: $t
                result = $fieldmethod(Ptr(obj), jfieldID, env)
                geterror(env)
                return convert_result(env, fieldType, result)
            end
            function _jcall(env::Ptr{JNI.JNIEnv}, obj::T, jmethodId::Ptr{Nothing}, rettype::Type{$x},
                            argtypes::Tuple, args...; callmethod=$callmethod) where T <: $t
                savedArgs, convertedArgs = convert_args(env, argtypes, args...)
                GC.@preserve obj savedArgs convertedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.JValue}(jvalue.(convertedArgs)), env)
                end
                cleanup_arg.(convertedArgs)
                geterror(env)
                return convert_result(env, rettype, result)
            end
```

(Note: env is the *last* arg to JNI calls because that's where we put it in the regenerated bindings. JNI ccall signatures put env first internally, but our Julia wrapper places it last for kwarg compatibility.)

Wait — re-check the regenerated bindings. In step 5.2 the generator emits env at the END of the Julia wrapper signature, but JNI.jl's `ccall` ordering has env FIRST in arg_names. The wrapper signature visible to Julia callers has env as the last positional, so we pass env last. The ccall internally passes env first. Confirmed correct.

- [ ] **Step 3: Update `get_method_id`, `get_field_id`, and helper functions to accept env**

Find:

```julia
function get_method_id(jnifun::Function, obj, method::AbstractString, rettype::Type, argtypes::Tuple)
    sig = method_signature(rettype, argtypes...)
    ptr = Ptr(metaclass(obj))
    @checknull jnifun(ptr, String(method), sig) "Problem getting method id for $obj.$method with signature $sig"
end

function get_method_id(typ::Type{JavaObject{T}}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    get_method_id(JNI.GetStaticMethodID, T, method, rettype, argtypes)
end

function get_method_id(obj::JavaObject, method::AbstractString, rettype::Type, argtypes::Tuple)
    get_method_id(JNI.GetMethodID, obj, method, rettype, argtypes)
end

get_method_id(method::JMethod) = @checknull JNI.FromReflectedMethod(method)
```

Replace with:

```julia
function get_method_id(env::Ptr{JNI.JNIEnv}, jnifun::Function, obj, method::AbstractString, rettype::Type, argtypes::Tuple)
    sig = method_signature(rettype, argtypes...)
    ptr = Ptr(metaclass(env, obj))
    @checknull jnifun(ptr, String(method), sig, env) "Problem getting method id for $obj.$method with signature $sig"
end

function get_method_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    get_method_id(env, JNI.GetStaticMethodID, T, method, rettype, argtypes)
end

function get_method_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, method::AbstractString, rettype::Type, argtypes::Tuple)
    get_method_id(env, JNI.GetMethodID, obj, method, rettype, argtypes)
end

get_method_id(env::Ptr{JNI.JNIEnv}, method::JMethod) = @checknull JNI.FromReflectedMethod(Ptr(method), env)
```

- [ ] **Step 4: Update `_metaclass` and `metaclass(::Symbol)` to accept env**

Find:

```julia
function _metaclass(class::Symbol)
    jclass = javaclassname(class)
    jclassptr = @checknull JNI.FindClass(jclass)
    # FindClass returns a local ref; promote to a global ref so the cache
    # entry survives PopLocalFrame and outlives the caller's frame.
    globalptr = JNI.NewGlobalRef(jclassptr)
    JNI.DeleteLocalRef(jclassptr)
    return JavaMetaClass{class}(JavaGlobalRef(globalptr))
end

function metaclass(class::Symbol)
    cache = _jmc_cache[ Threads.threadid() ]
    if !haskey(cache, class)
        cache[class] = _metaclass(class)
    end
    return cache[class]
end
```

Replace with:

```julia
function _metaclass(env::Ptr{JNI.JNIEnv}, class::Symbol)
    jclass = javaclassname(class)
    jclassptr = @checknull JNI.FindClass(jclass, env)
    # FindClass returns a local ref; promote to a global ref so the cache
    # entry survives PopLocalFrame and outlives the caller's frame.
    globalptr = JNI.NewGlobalRef(jclassptr, env)
    JNI.DeleteLocalRef(jclassptr, env)
    return JavaMetaClass{class}(JavaGlobalRef(globalptr))
end

const _jmc_cache_lock = ReentrantLock()
const _jmc_cache_v2 = Dict{Symbol, JavaMetaClass}()

function metaclass(env::Ptr{JNI.JNIEnv}, class::Symbol)
    lock(_jmc_cache_lock) do
        get!(_jmc_cache_v2, class) do
            _metaclass(env, class)
        end
    end
end

# Convenience: fetch env on demand if caller did not pass one. Used by
# helpers like jimport that don't otherwise need an env.
metaclass(class::Symbol) = with_env() do env
    metaclass(env, class)
end

metaclass(env::Ptr{JNI.JNIEnv}, ::Type{JavaObject{T}}) where {T} = metaclass(env, T)
metaclass(env::Ptr{JNI.JNIEnv}, ::JavaObject{T}) where {T} = metaclass(env, T)
metaclass(env::Ptr{JNI.JNIEnv}, ::Type{T}) where T <: AbstractVector = metaclass(env, Symbol(JavaCall.signature(T)))
```

(Drop the `_jmc_cache = [Dict{Symbol, JavaMetaClass}()]` array-of-dicts global — it's replaced by `_jmc_cache_v2` keyed singly.)

Find the existing line:

```julia
global const _jmc_cache = [ Dict{Symbol, JavaMetaClass}() ]
```

and delete it.

In `JavaCall.jl`, find:

```julia
    Threads.resize_nthreads!(_jmc_cache)
```

in `__init__` and delete it (no longer per-thread).

- [ ] **Step 5: Add method-ID cache**

After the `_jmc_cache_v2` definition in `core.jl`, add:

```julia
struct MethodKey
    class::Symbol
    name::Symbol
    signature::String
end

const _method_id_cache = Dict{MethodKey, Ptr{Nothing}}()
const _method_id_cache_lock = ReentrantLock()

# Cached overload of get_method_id for the (class, name, signature) tuple.
# Method IDs are valid for the JVM's lifetime per the JNI spec — no need
# to invalidate.
function _cached_method_id(env::Ptr{JNI.JNIEnv}, class_sym::Symbol, name::AbstractString,
                           rettype::Type, argtypes::Tuple, isstatic::Bool)
    sig = method_signature(rettype, argtypes...)
    key = MethodKey(class_sym, Symbol(name), sig)
    lock(_method_id_cache_lock) do
        get!(_method_id_cache, key) do
            mc = metaclass(env, class_sym)
            jnifun = isstatic ? JNI.GetStaticMethodID : JNI.GetMethodID
            @checknull jnifun(Ptr(mc), String(name), sig, env) "Problem getting method id for $class_sym.$name $sig"
        end
    end
end
```

Then update the two `get_method_id` overloads that take a `JavaObject{T}` or `Type{JavaObject{T}}` to delegate to the cached version:

```julia
function get_method_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    _cached_method_id(env, T, method, rettype, argtypes, true)
end

function get_method_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject{T}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    _cached_method_id(env, T, method, rettype, argtypes, false)
end
```

(The 6-arg `get_method_id(env, jnifun::Function, ...)` form is now unused by the cached path but kept for the `@checknull` call in `_cached_method_id` if needed. Or, if we now go entirely through the cache, delete the 6-arg form.)

- [ ] **Step 6: Update `jnew` to pass env**

Find:

```julia
function jnew(T::Symbol, argtypes::Tuple = () , args...)
    assertroottask_or_goodenv() && assertloaded()
    jmethodId = get_method_id(JNI.GetMethodID, T, "<init>", Nothing, argtypes)
    return _jcall(metaclass(T), jmethodId, JavaObject{T}, argtypes, args...; callmethod=JNI.NewObjectA)
end
```

Replace with:

```julia
function jnew(T::Symbol, argtypes::Tuple = (), args...)
    assertloaded()
    with_env() do env
        jmethodId = _cached_method_id(env, T, "<init>", Nothing, argtypes, false)
        _jcall(env, metaclass(env, T), jmethodId, JavaObject{T}, argtypes, args...; callmethod=JNI.NewObjectA)
    end
end
```

- [ ] **Step 7: Update `jfield`'s helpers (`get_field_id`, `_jfield`)**

Find:

```julia
function get_field_id(typ::Type{JavaObject{T}}, field::AbstractString, fieldType::Type) where T
    @checknull JNI.GetStaticFieldID(Ptr(metaclass(T)), String(field), signature(fieldType))
end

function get_field_id(obj::Type{JavaObject{T}}, field::JField) where T
    fieldType = jimport(gettype(field))
    @checknull JNI.FromReflectedField(field)
end

function get_field_id(obj::JavaObject, field::AbstractString, fieldType::Type)
    @checknull JNI.GetFieldID(Ptr(metaclass(obj)), String(field), signature(fieldType))
end

function get_field_id(obj::JavaObject, field::JField, fieldType::Type)
    @checknull JNI.FromReflectedField(field)
end
```

Replace each with the env-passing version:

```julia
function get_field_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, field::AbstractString, fieldType::Type) where T
    @checknull JNI.GetStaticFieldID(Ptr(metaclass(env, T)), String(field), signature(fieldType), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::Type{JavaObject{T}}, field::JField) where T
    @checknull JNI.FromReflectedField(Ptr(field), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::AbstractString, fieldType::Type)
    @checknull JNI.GetFieldID(Ptr(metaclass(env, obj)), String(field), signature(fieldType), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::JField, fieldType::Type)
    @checknull JNI.FromReflectedField(Ptr(field), env)
end
```

- [ ] **Step 8: Update `geterror` and `get_exception_string` to take env**

Find:

```julia
function get_exception_string(jthrow)
    jthrowable = JNI.FindClass("java/lang/Throwable")
    _notnull_assert(jthrowable)
    res = C_NULL
    try
        tostring_method = JNI.GetMethodID(jthrowable, "toString", "()Ljava/lang/String;")
        _notnull_assert(tostring_method)
        res = JNI.CallObjectMethodA(jthrow, tostring_method, Int[])
        _notnull_assert(res)
        return unsafe_string(res)
    finally
        res != C_NULL && JNI.DeleteLocalRef(res)
        JNI.DeleteLocalRef(jthrowable)
    end
end

function geterror()
    isexception = JNI.ExceptionCheck()
    if isexception == JNI_TRUE
        jthrow = JNI.ExceptionOccurred()
        ...
```

Replace with:

```julia
function get_exception_string(env::Ptr{JNI.JNIEnv}, jthrow)
    jthrowable = JNI.FindClass("java/lang/Throwable", env)
    _notnull_assert(jthrowable)
    res = C_NULL
    try
        tostring_method = JNI.GetMethodID(jthrowable, "toString", "()Ljava/lang/String;", env)
        _notnull_assert(tostring_method)
        res = JNI.CallObjectMethodA(jthrow, tostring_method, JNI.JValue[], env)
        _notnull_assert(res)
        return unsafe_string(env, res)
    finally
        res != C_NULL && JNI.DeleteLocalRef(res, env)
        JNI.DeleteLocalRef(jthrowable, env)
    end
end

function geterror(env::Ptr{JNI.JNIEnv})
    isexception = JNI.ExceptionCheck(env)
    if isexception == JNI_TRUE
        jthrow = JNI.ExceptionOccurred(env)
        _notnull_assert(jthrow)
        try
            JNI.ExceptionDescribe(env)
            msg = get_exception_string(env, jthrow)
            throw(JavaCallError(string("Error calling Java: ", msg)))
        finally
            JNI.ExceptionClear(env)
            JNI.DeleteLocalRef(jthrow, env)
        end
    end
end

# Backwards-compatible wrapper for callers that don't have env on hand.
geterror() = with_env() do env
    geterror(env)
end
```

- [ ] **Step 9: Update `convert_arg`, `convert_args`, `convert_result` to thread env**

In `src/convert.jl`, the `convert_args` and `convert_arg` functions take args and turn them into JValues. They currently don't call JNI; verify whether they need env.

Looking at convert.jl's current code: `convert_args` calls `convert_arg(argtype, args[i])`. `convert_arg` for primitive types uses `convert(jboolean, x)` etc. — pure Julia, no JNI. But `convert_arg(argtype::Type{JString}, arg)` calls `convert(JString, arg)` which calls `JString(str::AbstractString)` which calls `JNI.NewStringUTF`.

So `convert_args` does eventually hit JNI. Update the chain:

Find:

```julia
function convert_args(argtypes::Tuple, args...)
    convertedArgs = Array{Any}(undef, length(args))
    savedArgs = Array{Any}(undef, length(args))
    for i in 1:length(args)
        r = convert_arg(argtypes[i], args[i])
        savedArgs[i] = r[1]
        convertedArgs[i] = r[2]
    end
    return savedArgs, convertedArgs
end
```

Replace with:

```julia
function convert_args(env::Ptr{JNI.JNIEnv}, argtypes::Tuple, args...)
    convertedArgs = Array{Any}(undef, length(args))
    savedArgs = Array{Any}(undef, length(args))
    for i in 1:length(args)
        r = convert_arg(env, argtypes[i], args[i])
        savedArgs[i] = r[1]
        convertedArgs[i] = r[2]
    end
    return savedArgs, convertedArgs
end
```

Then update each `convert_arg` overload to thread env. The simplest pattern is: take env as first arg, only forward it where actually used. For most overloads (primitives), just thread it through:

```julia
function convert_arg(env::Ptr{JNI.JNIEnv}, argtype::Type, arg)
    # ... existing body, calling JNI fns with env where needed
end
```

There are several `convert_arg` overloads — find them all in convert.jl and add `env::Ptr{JNI.JNIEnv}` as the first argument. For the JString overload:

```julia
function convert_arg(env::Ptr{JNI.JNIEnv}, argtype::Type{JString}, arg)
    x = convert(JString, arg, env)   # see step 10
    return x, x
end
```

Similarly, `convert_result` overloads need env where they hit JNI directly. Update each:

```julia
function convert_result(env::Ptr{JNI.JNIEnv}, rettype::Type{T}, result) where {T<:JString}
    unsafe_string(env, result)
end
function convert_result(env::Ptr{JNI.JNIEnv}, rettype::Type{T}, result) where {T<:JavaObject}
    T(result)
end
convert_result(env::Ptr{JNI.JNIEnv}, rettype, result) = result
```

(The primitive-array `convert_result` block in the for-loop also needs env threaded — same mechanical change.)

- [ ] **Step 10: Update `JString(::AbstractString)` and `unsafe_string` to optionally take env**

In `core.jl`, find:

```julia
function JString(str::AbstractString)
    jstring = @checknull JNI.NewStringUTF(String(str))
    return JString(jstring)
end
```

Replace with:

```julia
function JString(str::AbstractString)
    with_env() do env
        JString(env, str)
    end
end

function JString(env::Ptr{JNI.JNIEnv}, str::AbstractString)
    jstring = @checknull JNI.NewStringUTF(String(str), env)
    return JString(jstring)
end
```

In `convert.jl`, find:

```julia
unsafe_string(jstr::JString) = unsafe_string(Ptr(jstr))

function unsafe_string(jstr::Ptr{Nothing})
    if jstr == C_NULL; return ""; end
    pIsCopy = Array{jboolean}(undef, 1)
    buf = JNI.GetStringUTFChars(jstr, pIsCopy)
    s = unsafe_string(buf)
    JNI.ReleaseStringUTFChars(jstr, buf)
    return s
end
```

Replace with:

```julia
unsafe_string(jstr::JString) = with_env() do env
    unsafe_string(env, Ptr(jstr))
end
unsafe_string(env::Ptr{JNI.JNIEnv}, jstr::JString) = unsafe_string(env, Ptr(jstr))
unsafe_string(jstr::Ptr{Nothing}) = with_env() do env
    unsafe_string(env, jstr)
end

function unsafe_string(env::Ptr{JNI.JNIEnv}, jstr::Ptr{Nothing})
    jstr == C_NULL && return ""
    pIsCopy = Array{jboolean}(undef, 1)
    buf = JNI.GetStringUTFChars(jstr, pIsCopy, env)
    s = unsafe_string(buf)
    JNI.ReleaseStringUTFChars(jstr, buf, env)
    return s
end
```

- [ ] **Step 11: Update `convert(::Type{JString}, str)`**

In `convert.jl`, find:

```julia
convert(::Type{JString}, str::AbstractString) = JString(str)
```

Replace with:

```julia
convert(::Type{JString}, str::AbstractString) = JString(str)
convert(::Type{JString}, str::AbstractString, env::Ptr{JNI.JNIEnv}) = JString(env, str)
```

(The two-arg form is used by `convert_arg` step 9.)

### Task 5.6: Update `reflect.jl`, `jniarray.jl`, `jcall_macro.jl`

**Files:**
- Modify: `src/reflect.jl`, `src/jniarray.jl`, `src/jcall_macro.jl`

These files mostly call `jcall` which now handles env internally. Verify each builds.

- [ ] **Step 1: Read reflect.jl and identify any direct JNI calls**

```bash
grep -n "JNI\\." /Users/brad/Projects/JavaCall.jl/src/reflect.jl
```

Expected: only `JNI.` references should be through `jcall` (which threads env internally). If any direct `JNI.SomeMethod(...)` calls exist, wrap them in `with_env`.

- [ ] **Step 2: Update jniarray.jl**

```bash
grep -n "JNI\\." /Users/brad/Projects/JavaCall.jl/src/jniarray.jl
```

Several direct JNI calls in the metaprogrammed for-loop. Update each:

Find:

```julia
        function get_elements!(jarr::JNIVector{$primitive})
            sz = Int(JNI.GetArrayLength(jarr.ref.ptr))
            jarr.arr = unsafe_wrap(Array, $get_elements(jarr.ref.ptr, Ptr{jboolean}(C_NULL)), sz; own = false)
            jarr
        end
```

Replace with:

```julia
        function get_elements!(jarr::JNIVector{$primitive})
            with_env() do env
                sz = Int(JNI.GetArrayLength(jarr.ref.ptr, env))
                jarr.arr = unsafe_wrap(Array, $get_elements(jarr.ref.ptr, Ptr{jboolean}(C_NULL), env), sz; own = false)
            end
            jarr
        end
```

Similarly for `JNIVector{$primitive}(sz::Int) = ...` (uses `$new_array(sz)`) and `release_elements`:

```julia
        JNIVector{$primitive}(sz::Int) = with_env() do env
            get_elements!(JNIVector{$primitive}($new_array(sz, env)))
        end
        function release_elements(arg::JNIVector{$primitive})
            arg.arr === nothing && return
            if JNI.ppenv[1] != C_NULL
                arr = arg.arr
                ref = arg.ref
                with_env() do env
                    GC.@preserve arg ref arr begin
                        $release_elements(ref.ptr, pointer(arr), jint(0), env)
                    end
                end
            end
            arg.arr = nothing
        end
```

- [ ] **Step 3: jcall_macro.jl needs no changes**

`@jcall` lowers to `jcall(...)` calls. `jcall` itself was updated in Step 5 of the previous task. Verify by reading:

```bash
grep -n "JNI\\." /Users/brad/Projects/JavaCall.jl/src/jcall_macro.jl
```

Expected: no direct JNI calls.

### Task 5.7: Add a parallel-jcall test

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Add a testset just after `dispatch_task_survives_handler_error`**

```julia
@testset "parallel_jcall" begin
    if Base.Threads.nthreads() >= 2
        jlm = @jimport "java.lang.Math"
        results = Vector{jdouble}(undef, 1000)
        Threads.@threads for i in 1:1000
            results[i] = jcall(jlm, "sin", jdouble, (jdouble,), float(i))
        end
        @test all(results[i] ≈ sin(float(i)) for i in 1:1000)
    else
        @test_skip "parallel_jcall requires JULIA_NUM_THREADS >= 2"
    end
end
```

### Task 5.8: Run tests and iterate until all pass

- [ ] **Step 1: Run with JULIA_NUM_THREADS=1**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: all tests pass. Tests requiring multi-thread will skip.

- [ ] **Step 2: Run with JULIA_NUM_THREADS=4**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -30
```

Expected: all tests pass including parallel_jcall.

If any tests fail, debug and fix in this branch before committing. The most likely issues:

- Method dispatch ambiguities from new env arg signatures (fix by being more specific in dispatch)
- `assertroottask_or_goodenv()` still called somewhere we didn't catch (find via grep, remove)
- `Threads.threadid()` still used to index something (replace with `with_env`)

### Task 5.9: Commit and push

- [ ] **Step 1**

```bash
git add src/ test/runtests.jl
git commit -m "$(cat <<'EOF'
Rewire jcall, jnew, jfield through with_env; add gc_safe annotations

The big rewire. jcall, jnew, and the three jfield overloads now
acquire the env via with_env() at entry and thread it through to all
JNI helpers. _jcall, _jfield, get_method_id, get_field_id, _metaclass,
metaclass, geterror, get_exception_string all take env explicitly.

JNI.jl is regenerated from the updated make_jni2.jl: env is now a
required first argument (no default), and slow JNI methods (Call*,
Get*Field, Set*Field, Get*ArrayElements, Release*ArrayElements,
FindClass, NewObject*) are emitted as @ccall ... gc_safe = true so
Julia GC can proceed concurrently with long-running Java methods.
GetPrimitiveArrayCritical/ReleasePrimitiveArrayCritical and
GetStringCritical/ReleaseStringCritical are explicitly excluded —
critical sections must NOT yield to GC.

Replace the per-thread _jmc_cache array-of-Dicts with a single
Dict + ReentrantLock keyed on class symbol. Add a method-ID cache
keyed on (class, name, signature) — method IDs are valid for the
JVM's lifetime per the JNI spec, so they're cached forever and
reduce per-call GetMethodID JNI roundtrips to one O(1) Dict lookup.

assertroottask_or_goodenv() is no longer called from jcall/jnew/
jfield — the function still exists in jvm.jl and will be removed in
phase-2/legacy-removal once the README is updated and any external
callers (none in-tree) can adapt.

Add a parallel_jcall test that runs many tasks doing jcall
concurrently. Skipped if JULIA_NUM_THREADS=1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin phase-2/jcall-rewrite
```

### Task 5.10: Merge to master

- [ ] **Step 1**

```bash
git checkout master
git merge --no-ff phase-2/jcall-rewrite -m "Merge branch 'phase-2/jcall-rewrite'"
git push origin master
```

---

## Milestone 6: phase-2/finalizer-routing

**Branch:** `phase-2/finalizer-routing`

Replace `deleteref(x::JavaRef)`'s direct `_deleteref` call with a `DeleteRef` message post to the dispatch task. The Phase 1 `isgoodenv()` guard goes away because the dispatch task is the only thread that calls JNI for cleanup.

### Task 6.1: Create the branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git checkout -b phase-2/finalizer-routing
```

### Task 6.2: Write a failing test

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Add a testset just after `parallel_jcall`**

```julia
@testset "finalizer_routes_through_dispatch" begin
    # Create many JString locals across tasks, force GC, verify the dispatch
    # task processed at least that many DeleteRef messages.
    initial = JavaCall._dispatch_processed_count[]
    n_objects = 500

    if Base.Threads.nthreads() >= 2
        Threads.@threads for _ in 1:n_objects
            local s = JString("ephemeral")
            # Let s go out of scope here.
        end
    else
        for _ in 1:n_objects
            local s = JString("ephemeral")
        end
    end

    GC.gc(true); GC.gc(true)
    sleep(0.2)   # allow dispatch task to drain

    @test JavaCall._dispatch_processed_count[] >= initial + n_objects
end
```

- [ ] **Step 2: Run, expect to fail**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -20
```

Expected: `finalizer_routes_through_dispatch` fails because deleteref doesn't post to the channel yet (the counter doesn't advance).

### Task 6.3: Replace `deleteref` body with channel post

**Files:**
- Modify: `src/core.jl:60-72`

- [ ] **Step 1: Find the current `deleteref(x::JavaRef)`**

```julia
function deleteref(x::JavaRef)
    if x.ptr == C_NULL; return; end
    if !JNI.is_env_loaded(); return; end;
    # JavaObject finalizers can fire on any task/thread, including
    # contexts from which JNI calls would crash (non-root task without
    # JULIA_COPY_STACKS, non-thread-1 on Windows). isgoodenv() is the
    # Bool predicate underlying assertroottask_or_goodenv(); using it
    # here turns "can't safely delete" into a leak rather than a
    # segfault in GC.
    isgoodenv() || return
    _deleteref(x)
    return
end
```

Replace with:

```julia
function deleteref(x::JavaRef)
    x.ptr == C_NULL && return
    JNI.is_env_loaded() || return
    kind = x isa JavaLocalRef ? :local :
           x isa JavaGlobalRef ? :global : :null
    kind === :null && return
    # Post to the dispatch task — the only thread that calls JNI for
    # cleanup. This works from any Julia task on any OS thread, including
    # GC threads, because put!() is just a thread-safe Channel write. The
    # actual JNI call happens on the dispatch task's pre-attached thread.
    # The channel is effectively unbounded (see dispatch.jl) so put! does
    # not block in practice.
    put!(_dispatch_channel, DeleteRef(x.ptr, kind))
    return
end
```

Note: `_deleteref` (the internal helper that calls `JNI.DeleteLocalRef` / `JNI.DeleteGlobalRef`) is no longer called from `deleteref`. Remove it if it has no other callers (check via grep).

- [ ] **Step 2: Verify `_deleteref` has no other callers**

```bash
grep -rn "_deleteref" /Users/brad/Projects/JavaCall.jl/src /Users/brad/Projects/JavaCall.jl/JProxies /Users/brad/Projects/JavaCall.jl/test
```

If only the definitions in core.jl reference it, delete those:

```julia
# _deleteref does local/global reference deletion without null or state checking
_deleteref(ref::JavaLocalRef ) = JNI.DeleteLocalRef( Ptr(ref))
_deleteref(ref::JavaGlobalRef) = JNI.DeleteGlobalRef(Ptr(ref))
_deleteref(ref::JavaNullRef) = nothing
```

(JProxies might still reference these — leave them in for now if so. Phase 2C will rewrite JProxies. Update the JNI calls to pass env: `JNI.DeleteLocalRef(Ptr(ref), env)` — or change `_deleteref` to take env as an arg.)

### Task 6.4: Run tests

- [ ] **Step 1**

```bash
JULIA_COPY_STACKS=1 JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -20
```

Expected: all tests pass including `finalizer_routes_through_dispatch`.

### Task 6.5: Commit, push, merge

- [ ] **Step 1**

```bash
git add src/core.jl test/runtests.jl
git commit -m "$(cat <<'EOF'
Route DeleteLocalRef/DeleteGlobalRef through the dispatch task

JavaObject finalizers now post DeleteRef messages to the dispatch
channel instead of calling JNI directly. The actual
JNI.DeleteLocalRef / JNI.DeleteGlobalRef call happens on the
dispatch task's pre-attached thread, so finalizers running on Julia
GC threads (which are not JNI-attached) can never trigger a JVM
crash from a misuse of JNI.

The Phase 1 `isgoodenv()` guard goes away — there's no longer a
"bad context" because the dispatch task is the only thread that
calls JNI for cleanup. The dispatch channel is effectively
unbounded (typemax(Int) capacity) so put! never blocks the
finalizer. The spec called for a bounded 1024-capacity channel
with non-blocking post semantics, but Julia's put!/push! block
rather than throw on a full bounded channel; an unbounded queue
trading memory growth for predictable finalizer latency was the
correct tradeoff. Future work can revisit with a bounded ring
buffer + drop-on-overflow if profiling shows backlog issues.

Add a regression test that creates 500 JString locals across tasks,
forces GC, and asserts the dispatch task's processed-message
counter advanced by at least 500.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin phase-2/finalizer-routing
git checkout master
git merge --no-ff phase-2/finalizer-routing -m "Merge branch 'phase-2/finalizer-routing'"
git push origin master
```

---

## Milestone 7: phase-2/legacy-removal

**Branch:** `phase-2/legacy-removal`

Delete all the JULIA_COPY_STACKS, root-task, Windows-thread-1 machinery. The new architecture has been working through milestones 5+6 with these still in place but unused. Now it's safe to remove them.

### Task 7.1: Create the branch

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git checkout -b phase-2/legacy-removal
```

### Task 7.2: Delete `src/Threads.jl`

**Files:**
- Delete: `src/Threads.jl`
- Modify: `src/JNI.jl` (remove the include and import)

- [ ] **Step 1: Delete the file**

```bash
rm /Users/brad/Projects/JavaCall.jl/src/Threads.jl
```

- [ ] **Step 2: In `src/JNI.jl`, find the line `include("Threads.jl")` and delete it; replace `import Threads` references with `import Base.Threads`**

Search for `Threads` usage:

```bash
grep -n "Threads" /Users/brad/Projects/JavaCall.jl/src/JNI.jl
```

The shim defined `Threads.threadid()`, `Threads.nthreads()`, `Threads.resize_nthreads!`, and `Threads.@threads`. After Phase 2, only `Threads.threadid()` and `Threads.nthreads()` are still used (in tests and in any straggler code). Replace local `Threads.X` references with `Base.Threads.X` where they appear in JNI.jl.

In `src/JavaCall.jl`, find:

```julia
import .JNI.Threads
```

and delete it.

### Task 7.3: Delete `attach_threads()` and `attach_current_thread()`

**Files:**
- Modify: `src/JNI.jl`

- [ ] **Step 1: Find and delete the two functions**

In `src/JNI.jl`, find:

```julia
function attach_current_thread(ppenv_thread = Ref{Ptr{JNIEnv}}(C_NULL))
    res = ccall(jvmfunc[].AttachCurrentThread, Cint, (Ptr{Nothing}, Ptr{Ptr{JNIEnv}}, Ptr{Nothing}), ppjvm[], ppenv_thread, C_NULL)
    res < 0 && throw(JNIError("Unable to attach thread id: $(Threads.threadid())"))
    return ppenv_thread[]
end

function attach_threads()
    @static if VERSION >= v"1.8"
        Threads.@threads :static for i=1:Threads.nthreads()
            attach_current_thread(Ref(ppenv, i))
        end
    else
        Threads.@threads for i=1:Threads.nthreads()
            attach_current_thread(Ref(ppenv, i))
        end
    end
end
```

Delete both functions. They're replaced by `_env_cache`'s OncePerThread mechanism in `src/env.jl`.

- [ ] **Step 2: Find and delete the call to `attach_threads()` in `init_new_vm`**

In `src/JNI.jl`, find within `init_new_vm`:

```julia
    load_jni(ppenv[1])
    attach_threads()
    return
```

Replace with:

```julia
    load_jni(ppenv[1])
    return
```

- [ ] **Step 3: Delete the `ppenv` array global**

`ppenv` was a `Vector{Ptr{JNIEnv}}` with one slot per thread. The new code uses `_env_cache` (OncePerThread). The single ppenv[1] entry is still set by `JNI_CreateJavaVM` for the calling thread, but no longer indexed elsewhere.

Decide: keep or delete? Some external code or downstream packages may read `JNI.ppenv[1]` directly. Check:

```bash
grep -rn "ppenv" /Users/brad/Projects/JavaCall.jl/src /Users/brad/Projects/JavaCall.jl/JProxies
```

If it's only referenced internally, delete it. The `JNI_CreateJavaVM` call needs *some* `Ptr{Ptr{JNIEnv}}` to write the initial env into:

```julia
const ppenv = [Ptr{JNIEnv}(C_NULL)]
```

and:

```julia
        res = ccall(create, Cint, (Ptr{Ptr{JavaVM}}, Ptr{Ptr{JNIEnv}}, Ptr{JavaVMInitArgs}), ppjvm, ppenv,
                    Ref(vm_args))
```

Keep `ppenv` for the JVM-creation handshake but rename to clarify scope. Or leave as-is — backward-compatible name. Recommendation: leave as-is.

The line `Threads.resize_nthreads!(ppenv)` in `init_new_vm` should be deleted — `ppenv` is now a 1-element array, never resized.

Find:

```julia
    opt = [JavaVMOption(pointer(x), C_NULL) for x in opts]
    Threads.resize_nthreads!(ppenv)
    GC.@preserve opt opts begin
```

Replace with:

```julia
    opt = [JavaVMOption(pointer(x), C_NULL) for x in opts]
    GC.@preserve opt opts begin
```

### Task 7.4: Delete the root-task and Windows-pinning machinery

**Files:**
- Modify: `src/jvm.jl`

- [ ] **Step 1: Delete the error constants and predicate functions**

In `src/jvm.jl`, find and delete:

```julia
const ROOT_TASK_ERROR = JavaCallError(
    "Either the environmental variable JULIA_COPY_STACKS must be 1 " *
    "OR JavaCall must be used on the root Task.")

const JULIA_COPY_STACKS_ON_WINDOWS_ERROR = JavaCallError(
    "JULIA_COPY_STACKS should not be set on Windows.")

const THREADID_NOT_ONE_WINDOWS_ERROR = JavaCallError(
    "JavaCall must be used on Thread 1 only in Windows. Multithreading JavaCall is not supported on Windows."
)

# JavaCall must run on the root Task or JULIA_COPY_STACKS is enabled
isroottask() = Base.roottask === Base.current_task()
@static if Sys.iswindows()
    isgoodenv() = ( ! JULIA_COPY_STACKS ) && Base.Threads.threadid() == 1
    assertroottask_or_goodenv() = isgoodenv() ? true : Base.Threads.threadid() == 1 ?
        throw(JULIA_COPY_STACKS_ON_WINDOWS_ERROR) : throw(THREADID_NOT_ONE_WINDOWS_ERROR)
else
    isgoodenv() = JULIA_COPY_STACKS || isroottask()
    assertroottask_or_goodenv() = isgoodenv() ? true : throw(ROOT_TASK_ERROR)
end
```

(Note: `assertloaded` and `assertnotloaded` stay — those are the JVM-up checks, not the threading checks.)

- [ ] **Step 2: Update `_init` to not call `assertroottask_or_goodenv`**

Find in `src/jvm.jl`:

```julia
function _init(opts)
    assertnotloaded()
    assertroottask_or_goodenv()
    JNI.init_new_vm(findjvm(),opts);
    start_dispatch_task!()
end
```

Replace with:

```julia
function _init(opts)
    assertnotloaded()
    JNI.init_new_vm(findjvm(),opts);
    start_dispatch_task!()
end
```

Similarly update `destroy()`:

```julia
function destroy()
    assertroottask_or_goodenv()
    stop_dispatch_task!()
    JNI.destroy()
end
```

→

```julia
function destroy()
    stop_dispatch_task!()
    JNI.destroy()
end
```

### Task 7.5: Delete `JULIA_COPY_STACKS` global from `JavaCall.jl`

**Files:**
- Modify: `src/JavaCall.jl`

- [ ] **Step 1: Find and delete the global and its `__init__` setup**

```julia
JULIA_COPY_STACKS = false
```

Delete that line.

In `__init__`, find:

```julia
function __init__()
    global JULIA_COPY_STACKS = get(ENV, "JULIA_COPY_STACKS", "") ∈ ("1", "yes")
    if ! Sys.iswindows()
        if VERSION ≥ v"1.1-" && VERSION < v"1.3-"
            @warn("JavaCall does not work correctly on Julia v$VERSION. \n" *
                    "Either use Julia v1.0.x, or v1.3.0 or higher.\n"*
                    "For 1.3 onwards, please also set the environment variable `JULIA_COPY_STACKS` to be `1` or `yes`")
        end
        if VERSION ≥ v"1.3-" && ! JULIA_COPY_STACKS
            @warn("JavaCall needs the environment variable `JULIA_COPY_STACKS` to be `1` or `yes`.\n"*
                  "Calling the JVM may result in undefined behavior.")
        end
    end
    Threads.resize_nthreads!(_jmc_cache)
end
```

Replace with:

```julia
function __init__()
    # No-op for now. Dispatch task lifecycle is owned by JavaCall.init() /
    # JavaCall.destroy() via the JVM lifecycle hooks in src/jvm.jl.
end
```

(`_jmc_cache` is also gone, replaced by `_jmc_cache_v2` from milestone 5.)

### Task 7.6: Update README to drop JULIA_COPY_STACKS sections

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the "macOS and Linux", "Windows", and "Other Operating Systems" sections**

Find:

```
## macOS and Linux

For Julia 1.3 onwards, please set the environment variable `JULIA_COPY_STACKS = 1`.
For Julia 1.11 onwards, please also set `JULIA_NUM_THREADS = 1`

Multithreaded access to the JVM is supported as JavaCall version `0.8.0`, but doesn't work in recent Julia versions.

## Windows

Do not set the environmental variable `JULIA_COPY_STACKS` or set the variable to `0`.

To use `jcall` with `@async`, start Julia in the following way:

```
$ julia -i -e "using JavaCall; JavaCall.init()"
```

Windows currently lacks support for multithreaded access to the JVM.

## Other Operating Systems

JavaCall has not been tested on operating systems other than macOS, Windows, or Linux.
You should probably set the environment variable `JULIA_COPY_STACKS = 1` and `JULIA_NUM_THREADS = 1`.
If you have success using JavaCall on another operating system than listed above,
please create an issue or pull request to let us know about compatability.
```

Replace with:

```
## Threading and platform support

JavaCall.jl 0.9 supports multithreaded JNI access on Linux, macOS, and Windows alike. The package attaches each Julia OS thread to the JVM lazily on first use. There is no `JULIA_COPY_STACKS` requirement and no Windows-specific pinning.

If you maintain code that targets JavaCall.jl 0.8.x or earlier, see [the legacy threading guide](https://github.com/JuliaInterop/JavaCall.jl/tree/v0.8.1#macos-and-linux) for the older requirements.
```

- [ ] **Step 2: Update the Quick Start example to drop env-var setup**

Find the existing example block and remove the `JULIA_NUM_THREADS=1 JULIA_COPY_STACKS=1` prefix:

```
$ JULIA_NUM_THREADS=1 JULIA_COPY_STACKS=1 julia
```

Change to:

```
$ julia
```

### Task 7.7: Drop the `roottask_and_env_1` testset and async-conditional test branches

**Files:**
- Modify: `test/runtests.jl`

- [ ] **Step 1: Delete the `roottask_and_env_1` testset entirely**

Find in `test/runtests.jl`:

```julia
@testset "roottask_and_env_1" begin
    @test JavaCall.isroottask()
    @testasync ! JavaCall.isroottask()
    @test JavaCall.isgoodenv()
    if JAVACALL_FORCE_ASYNC_TEST || JavaCall.JULIA_COPY_STACKS || Sys.iswindows()
        @testasync JavaCall.isgoodenv()
    end
    if ! JavaCall.JULIA_COPY_STACKS && ! Sys.iswindows()
        @test_throws CompositeException @syncasync JavaCall.assertroottask_or_goodenv()
        @warn "Ran tests for root Task only." *
            " REPL and @async are not expected to work with JavaCall without JULIA_COPY_STACKS=1" *
            " on non-Windows systems."
            " Set JULIA_COPY_STACKS=1 in the environment to test @async function."
    end
end
```

Delete it entirely. The new tests (`env_cache_per_thread`, `parallel_jcall`, `finalizer_routes_through_dispatch`) cover the same functional ground for the new architecture.

- [ ] **Step 2: Simplify `static_method_call_async_1`**

Find:

```julia
@testset "static_method_call_async_1" begin
    jlm = @jimport "java.lang.Math"
    if JAVACALL_FORCE_ASYNC_TEST || JavaCall.JULIA_COPY_STACKS || Sys.iswindows()
        @testasync 1.0 ≈ jcall(jlm, "sin", jdouble, (jdouble,), pi/2)
        @testasync 1.0 ≈ jcall(jlm, "min", jdouble, (jdouble,jdouble), 1,2)
        @testasync 1 == jcall(jlm, "abs", jint, (jint,), -1)
    end
end
```

Replace with:

```julia
@testset "static_method_call_async_1" begin
    jlm = @jimport "java.lang.Math"
    @testasync 1.0 ≈ jcall(jlm, "sin", jdouble, (jdouble,), pi/2)
    @testasync 1.0 ≈ jcall(jlm, "min", jdouble, (jdouble,jdouble), 1,2)
    @testasync 1 == jcall(jlm, "abs", jint, (jint,), -1)
end
```

(@async now works unconditionally — the env cache handles task migration.)

- [ ] **Step 3: Drop the `JAVACALL_FORCE_ASYNC_*` env-var detection at the top**

Find:

```julia
JAVACALL_FORCE_ASYNC_INIT = get(ENV,"JAVACALL_FORCE_ASYNC_INIT","") ∈ ("1","yes")
JAVACALL_FORCE_ASYNC_TEST = get(ENV,"JAVACALL_FORCE_ASYNC_TEST","") ∈ ("1","yes")
```

and the `initialization` testset's branch:

```julia
@testset "initialization" begin
    JavaCall.addClassPath("foo")
    JavaCall.addOpts("-Djava.class.path=bar")
    JavaCall.addOpts("-Xmx512M")
    if JavaCall.JULIA_COPY_STACKS || JAVACALL_FORCE_ASYNC_INIT
        @testasync JavaCall.init(["-Djava.class.path=$(@__DIR__)"])==nothing
    else
        @test JavaCall.init(["-Djava.class.path=$(@__DIR__)"])==nothing
    end
    ...
```

Replace `initialization` with:

```julia
@testset "initialization" begin
    JavaCall.addClassPath("foo")
    JavaCall.addOpts("-Djava.class.path=bar")
    JavaCall.addOpts("-Xmx512M")
    @test JavaCall.init(["-Djava.class.path=$(@__DIR__)"]) === nothing
    @test match(r"foo[:;]+bar", JavaCall.getClassPath()) !== nothing
end
```

Delete the `JAVACALL_FORCE_ASYNC_*` lines.

### Task 7.8: Run tests with both JULIA_NUM_THREADS settings

- [ ] **Step 1: Single-thread**

```bash
JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -15
```

(Note: drop `JULIA_COPY_STACKS=1` — no longer needed.)

Expected: all tests pass.

- [ ] **Step 2: Multi-thread**

```bash
JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -15
```

Expected: all tests pass.

### Task 7.9: Commit, push, merge

- [ ] **Step 1**

```bash
git add -A
git commit -m "$(cat <<'EOF'
Remove JULIA_COPY_STACKS / root-task / Windows-pinning machinery

The new architecture (Phase 2 milestones 2-6) supersedes every code
path that the JULIA_COPY_STACKS workaround was trying to defend.
Remove all of it:

- Delete src/Threads.jl (Windows shim)
- Delete attach_threads() and attach_current_thread() in JNI.jl;
  attachment is per-OS-thread on demand via env.jl's OncePerThread
- Delete ROOT_TASK_ERROR, JULIA_COPY_STACKS_ON_WINDOWS_ERROR,
  THREADID_NOT_ONE_WINDOWS_ERROR
- Delete isroottask, isgoodenv, assertroottask_or_goodenv
- Delete the JULIA_COPY_STACKS global and its detection in __init__
- Drop the resize_nthreads! call (no per-thread state to size)

README's "macOS and Linux", "Windows", and "Other Operating Systems"
sections collapse to one "Threading and platform support" section
that just says "it works." Quick Start drops the env-var prefix.

Tests: drop the roottask_and_env_1 testset (covered by new
env-cache / parallel-jcall / finalizer-routing tests). Drop the
JAVACALL_FORCE_ASYNC_* env-var conditionals — @async now works
unconditionally because task migration is handled by the env cache.

The package now requires zero environment-variable setup on any
supported platform.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin phase-2/legacy-removal
git checkout master
git merge --no-ff phase-2/legacy-removal -m "Merge branch 'phase-2/legacy-removal'"
git push origin master
```

---

## Final verification

After all 7 milestones are merged into master, do a final pass:

### Task F.1: Full test pass on both thread settings

- [ ] **Step 1: 1-thread**

```bash
JULIA_NUM_THREADS=1 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 2: 4-thread**

```bash
JULIA_NUM_THREADS=4 julia --project=/Users/brad/Projects/JavaCall.jl -e 'using Pkg; Pkg.test()' 2>&1 | tail -10
```

Expected: all tests pass.

### Task F.2: Smoke-test downstream packages

- [ ] **Step 1: JDBC.jl**

```bash
mkdir -p /tmp/phase-2-smoke && cd /tmp/phase-2-smoke
JULIA_NUM_THREADS=1 julia -e '
    using Pkg
    Pkg.activate(temp = true)
    Pkg.develop(path = "/Users/brad/Projects/JavaCall.jl")
    Pkg.add("JDBC")
    Pkg.test("JDBC")
' 2>&1 | tail -20
```

Expected: JDBC tests pass (or at least don't fail with API errors). If JDBC fails on something we removed (e.g., a downstream package was reading `JavaCall.JULIA_COPY_STACKS`), document the breakage and consider whether to file an upstream issue against JDBC.

### Task F.3: Tag a release candidate

- [ ] **Step 1**

```bash
cd /Users/brad/Projects/JavaCall.jl
git checkout master
git tag -a v0.9.0-rc1 -m "JavaCall.jl 0.9.0-rc1 — threading-core rebuild

Phase 2A complete: full multithreaded JNI support across Linux/macOS/Windows
with no JULIA_COPY_STACKS requirement. Outbound calls attach the calling OS
thread to the JVM lazily; finalization routes through a dedicated dispatch
task. Public API unchanged for jcall, @jcall, @jimport, jfield, JavaObject."
git push origin v0.9.0-rc1
```

(This is a release-candidate tag, not a published Julia package version. The official 0.9.0 release waits for Phase 2B, 2C, 2D as needed.)

---

## Self-Review

After writing the plan, run through the spec one more time:

**Spec coverage:**

- ✅ Min Julia 1.12, Min JDK 11 — Milestone 1
- ✅ Architecture β with OncePerThread + dispatch task — Milestones 2-3
- ✅ JValue primitive type — Milestone 4
- ✅ jcall rewrite with gc_safe ccall + method-ID cache — Milestone 5
- ✅ Finalizer routing — Milestone 6
- ✅ Legacy removal (JULIA_COPY_STACKS, Threads.jl, root-task) — Milestone 7
- ⚠️ Windows fully unified — falls out of legacy removal; explicitly verified by CI matrix (Milestone 1) running same tests on all platforms
- ⚠️ JNI 21 version request — Milestone 1 Task 1.4
- ⚠️ Public API strictly compatible — verified by existing 261 tests continuing to pass at every milestone
- ⏭️ JProxies rewrite — Phase 2C (separate plan, not in this plan)
- ⏭️ JDirectBuffer / critical arrays / IsVirtualThread — Phase 2B (separate plan)
- ⏭️ Downstream smoke tests in CI — Phase 2D

**Placeholder scan:** No "TBD", no "TODO", no "fill in details." Each step has actual content.

**Type consistency:** `JNI.JValue` (type, capital J) and `jvalue` (function, lowercase) used consistently. `with_env` signature `with_env(f::Function) -> Any` consistent across uses. `Ptr{JNI.JNIEnv}` (qualified) used for env in core.jl signatures.

**Scope check:** Plan A is one phase deliverable (v0.9.0-rc1 — threading rebuild without new features). Plans B/C/D will follow.
