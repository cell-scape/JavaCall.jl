using JProxies
import JProxies: JavaCall
using Test

JavaCall.addClassPath(@__DIR__)   # picks up the bundled Test.class fixtures
JProxies.init()

JArrayList = @jimport java.util.ArrayList
JSystem    = @jimport java.lang.System
JMath      = @jimport java.lang.Math
JInteger   = @jimport java.lang.Integer

@testset "JProxy instance dot-access" begin
    a = JProxy(JArrayList(()))
    @test a.size() == 0
    a.add("one")
    a.add("two")
    @test a.size() == 2
    @test a.get(0) == "one"           # narrowed: returns a Julia String
    @test a.isEmpty() == false
    a.clear()
    @test a.isEmpty() == true
end

@testset "JProxy static dot-access" begin
    m = JProxy(JMath)
    @test m.abs(-3) == 3
    @test isapprox(m.sin(0.0), 0.0; atol = 1e-12)
    s = JProxy(JSystem)
    @test s.getProperty("java.version") isa AbstractString
end

@testset "JProxy field access" begin
    # java.lang.Integer.MAX_VALUE — static final field via the Type wrapper
    @test JProxy(JInteger).MAX_VALUE == typemax(Int32)
end

@testset "JProxy field writes unsupported" begin
    @test_throws ArgumentError (JProxy(JInteger).MAX_VALUE = 1)
end

@testset "overload resolution: no such method throws" begin
    a = JProxy(JArrayList(()))
    @test_throws Exception a.thisMethodDoesNotExist(1, 2, 3)
end

@testset "unwrap smoke test" begin
    @test JProxies.unwrap(JProxy(JArrayList(()))) isa JavaCall.JavaObject
    @test JProxies.unwrap(JProxy(JArrayList)) === JArrayList
end

# --- jproxy() callback fixtures (hoisted: struct defs need module scope) ---
mutable struct Doubler
    calls::Int
end
@jproxy Doubler "Test\$IntSupplierLike" begin
    function supply(self, x::Integer)
        self.calls += 1
        return Int32(2x)
    end
end

const _flip_flag = Ref(false)
struct Flip end
@jproxy Flip "java.lang.Runnable" begin
    run(self) = (_flip_flag[] = true; nothing)
end

struct Boom end
@jproxy Boom "java.lang.Runnable" begin
    run(self) = error("intentional callback failure")
end

@testset "jproxy callbacks" begin
    JTest = @jimport Test
    JRunnable = @jimport java.lang.Runnable

    # value-returning one-method interface
    d = Doubler(0)
    jd = jproxy(d, "Test\$IntSupplierLike")
    @test JavaCall.jcall(JTest, "callSupplier", JavaCall.jint,
                (@jimport("Test\$IntSupplierLike"), JavaCall.jint), jd, 21) == 42
    @test d.calls == 1

    # void Runnable
    _flip_flag[] = false
    jr = jproxy(Flip(), "java.lang.Runnable")
    @test JavaCall.jcall(JTest, "runAndReport", JavaCall.JString, (JRunnable,), jr) == "ran"
    @test _flip_flag[] == true

    # exception in handler surfaces as a thrown exception on the Java side
    jb = jproxy(Boom(), "java.lang.Runnable")
    @test_throws Exception JavaCall.jcall(JTest, "runAndReport", JavaCall.JString, (JRunnable,), jb)
end

@testset "jproxy callbacks under GC pressure" begin
    # Hammer a callback while forcing GC. Before the dangling-local-ref fix the
    # boxed-Integer arg refs (raw native-method local refs) could be finalized
    # after the native frame was gone, corrupting JVM arena memory -> intermittent
    # SIGSEGV inside libjvm. After the fix the args are JNI *global* refs, so this
    # runs clean.
    JTest = @jimport Test
    JISL  = @jimport "Test\$IntSupplierLike"
    d = Doubler(0)
    jd = jproxy(d, "Test\$IntSupplierLike")
    for i in 1:300
        @test JavaCall.jcall(JTest, "callSupplier", JavaCall.jint, (JISL, JavaCall.jint), jd, i) == 2i
        iszero(i % 10) && GC.gc()
    end
    @test d.calls == 300
end

@testset "Phase 3 sub-3: JProxy iteration" begin
    JTest = @jimport Test

    # --- Iterable / Collection / List of Strings -----------------------------
    jl_strs = JavaCall.jnew(JavaCall.JArrayList)
    JavaCall.jcall(jl_strs, "add", "a")
    JavaCall.jcall(jl_strs, "add", "b")
    @test collect(JProxy(jl_strs)) == ["a", "b"]

    # --- List of boxed integers --------------------------------------------
    jl_ints = JavaCall.jnew(JavaCall.JArrayList)
    box7  = JavaCall.jcall(JavaCall.JInteger, "valueOf", JavaCall.JInteger, (JavaCall.jint,), Int32(7))
    box11 = JavaCall.jcall(JavaCall.JInteger, "valueOf", JavaCall.JInteger, (JavaCall.jint,), Int32(11))
    JavaCall.jcall(jl_ints, "add", JavaCall.jboolean, (JavaCall.JObject,), box7)
    JavaCall.jcall(jl_ints, "add", JavaCall.jboolean, (JavaCall.JObject,), box11)
    @test collect(JProxy(jl_ints)) == [7, 11]

    # --- Set (single element for deterministic order) -----------------------
    js = JavaCall.jnew(@jimport(java.util.HashSet))
    JavaCall.jcall(js, "add", "x")
    @test collect(JProxy(js)) == ["x"]

    # --- Map: Pair yield + destructuring ------------------------------------
    jm = JavaCall.jnew(JavaCall.JHashMap)
    JavaCall.jcall(jm, "put", "k1", "v1")
    @test collect(JProxy(jm)) == ["k1" => "v1"]
    let captured = nothing
        for (k, v) in JProxy(jm)
            captured = (k, v)
        end
        @test captured == ("k1", "v1")
    end

    # --- Primitive int[] -- bypass jcall's auto-array-conversion so we get
    # the raw JavaObject. The `signature(JavaObject{Symbol("[I")})` shape
    # generates `L[I;` not `[I`, so `jcall` can't look up the static method
    # via the explicit-form path; we call JNI directly to fetch the raw ref. -
    JIntArr = JavaCall.JavaObject{Symbol("[I")}
    arr_i = let cls = JavaCall.classforname("Test")
        JavaCall.with_env() do env
            mid = JavaCall.JNI.GetStaticMethodID(JavaCall.Ptr(cls), "intArray", "()[I", env)
            JIntArr(JavaCall.JNI.CallStaticObjectMethodA(JavaCall.Ptr(cls), mid, JavaCall.JNI.JValue[], env))
        end
    end
    @test collect(JProxy(arr_i)) == [10, 20, 30]

    # --- Object[] of mixed elements (same direct-JNI bypass) ----------------
    JObjArr = JavaCall.JavaObject{Symbol("[Ljava.lang.Object;")}
    arr_o = let cls = JavaCall.classforname("Test")
        JavaCall.with_env() do env
            mid = JavaCall.JNI.GetStaticMethodID(JavaCall.Ptr(cls), "objArray", "()[Ljava/lang/Object;", env)
            JObjArr(JavaCall.JNI.CallStaticObjectMethodA(JavaCall.Ptr(cls), mid, JavaCall.JNI.JValue[], env))
        end
    end
    @test collect(JProxy(arr_o)) == ["a", 7]

    # --- Raw Iterator (already an Iterator, no .iterator() call needed) -----
    it = JavaCall.jcall(jl_strs, "iterator", JavaCall.JIterator, ())
    @test collect(JProxy(it)) == ["a", "b"]

    # --- length() where defined --------------------------------------------
    @test length(JProxy(jl_strs)) == 2
    @test length(JProxy(jm)) == 1
    @test length(JProxy(arr_i)) == 3
    # raw Iterator has no length
    it2 = JavaCall.jcall(jl_strs, "iterator", JavaCall.JIterator, ())
    @test_throws ArgumentError length(JProxy(it2))

    # --- Non-iterable rejection --------------------------------------------
    jobj = JavaCall.jnew(@jimport(java.lang.Object))
    @test_throws ArgumentError iterate(JProxy(jobj))

    # --- Empty containers ---------------------------------------------------
    @test isempty(collect(JProxy(JavaCall.jnew(JavaCall.JArrayList))))
    @test isempty(collect(JProxy(JavaCall.jnew(JavaCall.JHashMap))))
end
