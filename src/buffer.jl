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

"""
    JDirectBuffer{T}

A Java NIO `ByteBuffer` whose underlying storage is a Julia-owned
`Vector{T}`. Java code that accepts a `java.nio.ByteBuffer` reads and
writes the same memory the Julia Vector points at — no copying.

Both `obj` (the Java-side ByteBuffer global ref) and `data` (the Julia
Vector) are held by the struct; neither side can free the memory while
the JDirectBuffer is reachable. When the JDirectBuffer is GC'd by
Julia, the wrapped JavaObject's finalizer routes DeleteGlobalRef
through `with_env`, and the Julia Vector frees normally.

# Example

    buf = JDirectBuffer{Float64}(1024)
    fill!(buf.data, 3.14)
    # Pass `buf` (or `buf.obj`) to a Java method accepting ByteBuffer.
    # Mutations on the Java side are immediately visible in `buf.data`.
"""
struct JDirectBuffer{T}
    obj::JavaObject{Symbol("java.nio.ByteBuffer")}
    data::Vector{T}
end

"""
    JDirectBuffer{T}(n::Integer) where T

Allocate a fresh `JDirectBuffer{T}` backed by a `Vector{T}` of length
`n`. The Java-side ByteBuffer's capacity is reported as `n * sizeof(T)`
bytes.
"""
function JDirectBuffer{T}(n::Integer) where T
    data = Vector{T}(undef, Int(n))
    capacity = jlong(Int(n) * sizeof(T))
    obj = with_env() do env
        # GC.@preserve so Julia GC cannot move the Vector's storage while
        # NewDirectByteBuffer captures the pointer. Once the resulting
        # JavaObject is constructed and held by the JDirectBuffer, the
        # Vector is reachable via `data` for the JDirectBuffer's lifetime.
        local_ref = GC.@preserve data begin
            JNI.NewDirectByteBuffer(Ptr{Nothing}(pointer(data)), capacity, env)
        end
        local_ref == C_NULL && throw(JavaCallError(
            "NewDirectByteBuffer returned NULL — JVM may not support direct buffers"))
        # Promote to global ref so the JavaObject's finalizer routes
        # DeleteGlobalRef through with_env when the JDirectBuffer is GC'd.
        global_ptr = JNI.NewGlobalRef(local_ref, env)
        JNI.DeleteLocalRef(local_ref, env)
        JavaObject{Symbol("java.nio.ByteBuffer")}(JavaGlobalRef(global_ptr))
    end
    # Java NIO ByteBuffers default to BIG_ENDIAN. Set native byte order so
    # the typed views (DoubleBuffer, IntBuffer, etc.) interpret the bytes
    # with the same layout as the backing Julia Vector{T}.
    JBB = JavaObject{Symbol("java.nio.ByteBuffer")}
    JBO = JavaObject{Symbol("java.nio.ByteOrder")}
    native_order = jcall(JBO, "nativeOrder", JBO, ())
    jcall(obj, "order", JBB, (JBO,), native_order)
    return JDirectBuffer{T}(obj, data)
end

# Allow JDirectBuffer to flow into jcall as if it were the underlying ByteBuffer.
Base.convert(::Type{JavaObject{Symbol("java.nio.ByteBuffer")}}, b::JDirectBuffer) = b.obj
Base.unsafe_convert(::Type{Ptr{Nothing}}, b::JDirectBuffer) = Ptr(b.obj)
Ptr(b::JDirectBuffer) = Ptr(b.obj)
