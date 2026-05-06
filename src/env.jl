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
const _env_cache = Base.OncePerThread{Ptr{JNI.JNIEnv}}() do
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
@inline with_env(f::Function) = f(_env_cache[Threads.threadid()])
