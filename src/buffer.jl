"""
    JavaCall buffer-exchange layer (Phase 2B)

Helpers for moving primitive numeric data between Julia and Java without
copying:

  * `with_critical_array(f, arr, T)` — pin a Java primitive array via
    JNI's GetPrimitiveArrayCritical, hand `f` a non-owning Vector{T}
    view of the same memory, release on exit.

  * `JDirectBuffer{T}` (Milestone 3) — back a Java NIO ByteBuffer with
    a Julia-owned Vector{T}.

The critical-section path is strictly more restrictive than direct
buffers: callers MUST NOT allocate, yield, or call back into the JVM
while the section is held. Use `JDirectBuffer` when those constraints
are unworkable; use `with_critical_array` when they are not, and the
performance win matters.
"""

"""
    with_critical_array(f, arr::JavaObject, ::Type{T}) -> Any

Pin `arr` (a Java primitive array reference) for the duration of `f`,
giving `f` a non-owning `Vector{T}` view of the array's storage.

The `T` parameter must match the array's actual element type (jint for
int[], jdouble for double[], etc.); JNI does not check this and a
mismatch reads garbage.

Inside `f` you must NOT:

  * allocate Julia objects (the JVM may stop the world for GC)
  * yield to the Julia scheduler (`sleep`, `wait`, I/O, `@spawn`)
  * call into the JVM via jcall, jnew, or jfield
  * hold the result Vector past the return — the storage is unpinned
    on exit

Returns `f`'s return value. The Vector view is invalidated immediately
after `f` returns; copy out anything you need to keep.

# Example

    arr = jcall(JTest, "testDoubleArray", JavaObject{Symbol("[D")}, ())
    sum_val = with_critical_array(arr, jdouble) do view
        s = zero(jdouble)
        @inbounds for x in view
            s += x
        end
        s
    end
"""
function with_critical_array(f, arr::JavaObject, ::Type{T}) where T
    with_env() do env
        sz = Int(JNI.GetArrayLength(Ptr(arr), env))
        ptr = JNI.GetPrimitiveArrayCritical(Ptr(arr), Ptr{jboolean}(C_NULL), env)
        ptr == C_NULL && throw(JavaCallError("GetPrimitiveArrayCritical returned NULL"))
        try
            jl_view = unsafe_wrap(Array, Ptr{T}(ptr), sz; own = false)
            return f(jl_view)
        finally
            JNI.ReleasePrimitiveArrayCritical(Ptr(arr), ptr, jint(0), env)
        end
    end
end
