using JProxies
import JProxies: JavaCall
using Test

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
