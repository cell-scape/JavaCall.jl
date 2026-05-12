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
