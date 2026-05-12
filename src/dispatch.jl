"""
    JavaCall dispatch-task layer (Phase 2)

A single sticky task in the `:interactive` pool that owns one OS thread,
pre-attached to the JVM. The dispatch task drains a `Channel{DispatchMsg}`
and executes each message on its attached thread. This guarantees that
finalization (and, in Phase 2C, callbacks) always runs on a known-good
JNI context regardless of which Julia task or thread originated the
message.

This branch (Phase 2A milestone 3) introduces the message types,
the lifecycle, and a working drain loop. Real workloads are not
yet routed through it — `deleteref` still calls JNI directly until
milestone 6, which replaces the direct JNI call with a channel
post.
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

"""
    Callback(handler, args, result_box)

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

# Effectively unbounded — Julia Channels with sz_max=typemax(Int) only
# allocate as items arrive. Bounded sizes turned out unworkable for the
# finalizer-routing path: Julia's `push!`/`put!` block on a full
# bounded channel (they don't throw), and blocking finalizers risk
# deadlocking GC. Future work can replace this with a bounded ring
# buffer + drop-on-overflow if memory profiling shows a concern.
const _dispatch_channel = Channel{DispatchMsg}(typemax(Int))
const _dispatch_task = Ref{Task}()

# Debug counter (testing only): incremented for every DeleteRef handled.
const _dispatch_processed_count = Base.Threads.Atomic{Int}(0)

function _handle(msg::DeleteRef)
    with_env() do env
        if msg.kind === :local
            JNI.DeleteLocalRef(msg.ptr, env)
        elseif msg.kind === :global
            JNI.DeleteGlobalRef(msg.ptr, env)
        end
    end
    Base.Threads.atomic_add!(_dispatch_processed_count, 1)
    return
end

_handle(msg::Shutdown) = nothing

function _handle(msg::Callback)
    result = try
        Base.invokelatest(msg.handler, msg.args...)
    catch err
        @error "JProxies callback handler threw" exception=(err, catch_backtrace())
        err
    end
    put!(msg.result_box, result)
    return nothing
end

function _drain_loop()
    while true
        msg = take!(_dispatch_channel)
        msg isa Shutdown && break
        try
            _handle(msg)
        catch err
            err isa InterruptException && rethrow()
            err isa OutOfMemoryError && rethrow()
            @error "Dispatch task error" exception=(err, catch_backtrace())
        end
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
    t = Task() do
        # Eagerly attach this OS thread so subsequent _handle calls don't
        # pay the attach cost on the first message.
        with_env() do _ end
        _drain_loop()
    end
    # Set sticky BEFORE schedule so the task can never migrate. Scheduling
    # a sticky task pins it to the scheduling thread (typically thread 1
    # at JVM init time).
    t.sticky = true
    schedule(t)
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
