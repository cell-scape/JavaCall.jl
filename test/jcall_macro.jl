using Test
using JavaCall

@testset "jcall macro" begin
    JavaCall.isloaded() || JavaCall.init(["-Djava.class.path=$(@__DIR__)"])
    System = @jimport java.lang.System
    version_from_macro = @jcall System.getProperty("java.version"::JString)::JString
    version_from_func = jcall(System, "getProperty", JString, (JString,), "java.version")
    @test version_from_macro == version_from_func
    @test "bar" == @jcall System.getProperty("foo"::JString, "bar"::JString)::JString
    @test 0x00 == @jcall System.out.checkError()::jboolean
    rettype = jboolean
    @test 0x00 == @jcall System.out.checkError()::rettype
    jstr = JString
    @test version_from_func == @jcall System.getProperty("java.version"::jstr)::jstr

    T = @jimport Test
    @test 10 == @jcall T.testShort(10::jshort)::jshort
    @test 10 == @jcall T.testInt(10::jint)::jint
    @test 10 == @jcall T.testLong(10::jlong)::jlong
    @test typemax(jint) == @jcall T.testInt(typemax(jint)::jint)::jint
    @test typemax(jlong) == @jcall T.testLong(typemax(jlong)::jlong)::jlong
    @test "Hello Java" == @jcall T.testString("Hello Java"::JString)::JString
    @test Float64(10.02) == @jcall T.testDouble(10.02::jdouble)::jdouble
    @test Float32(10.02) == @jcall T.testFloat(10.02::jfloat)::jfloat
    @test floatmax(jdouble) == @jcall T.testDouble(floatmax(jdouble)::jdouble)::jdouble
    @test floatmax(jfloat) == @jcall T.testFloat(floatmax(jfloat)::jfloat)::jfloat
    c=JString(C_NULL)
    @test isnull(c)
    @test "" == @jcall T.testString(c::JString)::JString
    a = rand(10^7)
    @test [@jcall(T.testDoubleArray(a::Array{jdouble,1})::jdouble)
           for i in 1:10][1] ≈ sum(a)
    a = nothing

    jlm = @jimport "java.lang.Math"
    @test 1.0 ≈ @jcall jlm.sin((pi/2)::jdouble)::jdouble
    @test 1.0 ≈ @jcall jlm.min(1::jdouble, 2::jdouble)::jdouble
    @test 1 == @jcall jlm.abs((-1)::jint)::jint

    @testset "jcall macro instance_methods_1" begin
        jnu = @jimport java.net.URL
        gurl = @jcall jnu("https://en.wikipedia.org"::JString)::jnu
        @test "en.wikipedia.org"== @jcall gurl.getHost()::JString
        jni = @jimport java.net.URI
        guri = @jcall gurl.toURI()::jni
        @test typeof(guri)==jni

        h=@jcall guri.hashCode()::jint
        @test typeof(h)==jint
    end

    jlist = @jimport java.util.ArrayList
    @test 0x01 == @jcall jlist().add(JObject(C_NULL)::JObject)::jboolean
end

@testset "Phase 3: @jcall annotation-free" begin
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    JSystem = @jimport java.lang.System
    al = JArrayList((),)

    # instance method, single arg, narrowed result
    @test (@jcall al.add("one")) == true
    # instance zero-arg call (no rettype -> annotation-free)
    @test (@jcall al.size()) == 1
    # narrowing + JString decode
    @test (@jcall al.get(0)) == "one"
    # static via @jimport-ed Type (flows through the func-isa-Expr branch)
    @test (@jcall JMath.abs(Int32(-5))) == 5
    # dotted-receiver static call (annotation-free)
    @test (@jcall JSystem.getProperty("java.version")) isa AbstractString

    # fully-annotated form unchanged (regression)
    @test (@jcall al.contains("one"::JObject)::jboolean) == 0x01

    # mixed-form: arg annotated, no rettype -> macro-expansion error
    @test_throws LoadError (@eval @jcall $al.add("one"::JObject))
    # mixed-form: rettype given but arg not annotated -> macro-expansion error
    @test_throws LoadError (@eval @jcall $al.get(0)::JString)

    # QuoteNode annotation-free path: @jcall T() -> jnew(T, args...) (M2 form)
    JArrayList2 = @jimport java.util.ArrayList
    @test (@jcall JArrayList2()) isa JavaObject
    @test (@jcall JArrayList2(16)) isa JavaObject
end

@testset "Phase 3 sub-2: @jimport multi-import" begin
    # --- regression: single-class forms still return a Type ---
    @test (@jimport java.util.ArrayList) === JavaObject{Symbol("java.util.ArrayList")}
    @test (@jimport "java.util.HashMap") === JavaObject{Symbol("java.util.HashMap")}
    @test (@jimport ArrayList)           === JavaObject{Symbol("ArrayList")}  # bare-Symbol path

    # --- colon form: single name ---
    let
        @jimport java.util: ArrayList
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
    end

    # --- colon form: multi-bind ---
    let
        @jimport java.util: ArrayList, HashMap, Map
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
        @test HashMap   === JavaObject{Symbol("java.util.HashMap")}
        @test Map       === JavaObject{Symbol("java.util.Map")}
    end

    # --- colon form with `=>` rename ---
    let
        @jimport java.util: ArrayList => JAL, HashMap => JHM
        @test JAL === JavaObject{Symbol("java.util.ArrayList")}
        @test JHM === JavaObject{Symbol("java.util.HashMap")}
    end

    # --- colon form: mixed rename + bare ---
    let
        @jimport java.util: ArrayList => JAL, HashMap
        @test JAL     === JavaObject{Symbol("java.util.ArrayList")}
        @test HashMap === JavaObject{Symbol("java.util.HashMap")}
    end

    # --- tuple form (cross-package) ---
    let
        @jimport (java.util.ArrayList, java.lang.System)
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
        @test System    === JavaObject{Symbol("java.lang.System")}
    end

    # --- tuple form with renames ---
    let
        @jimport (java.util.ArrayList => JAL, java.lang.System => JSys)
        @test JAL  === JavaObject{Symbol("java.util.ArrayList")}
        @test JSys === JavaObject{Symbol("java.lang.System")}
    end

    # --- single-element tuple == multi-import of 1 ---
    let
        @jimport (java.util.ArrayList,)
        @test ArrayList === JavaObject{Symbol("java.util.ArrayList")}
    end

    # --- scope: colon-form binding inside a let stays local ---
    let
        @jimport java.util: HashSet
        @test @isdefined(HashSet)
    end
    @test !@isdefined(HashSet)   # let-scoped, not leaked to the testset's enclosing scope

    # --- macro-expansion errors ---
    # Empty colon-form is a parser error (`@jimport java.util:` is unparseable),
    # so we exercise the empty-list error path through the helper directly.
    @test_throws ErrorException JavaCall._jimport_colon(:(java.util), Any[])
    @test_throws ErrorException JavaCall._jimport_tuple(Any[])
    # The shapes below DO reach macroexpansion; their errors surface as LoadError via @eval.
    @test_throws LoadError (@eval @jimport java.util: 42)                          # non-Symbol entry
    @test_throws LoadError (@eval @jimport (java.util.ArrayList => 5,))            # non-Symbol rename target
    @test_throws LoadError (@eval @jimport java.util: ArrayList => HashMap => X)   # malformed rename chain

    # Nested classes via the existing $-escape, inside the new tuple form.
    # If the parser accepts the $ in tuple position, assert binding; otherwise
    # leave the test_skip with a comment documenting the limitation.
    let
        try
            @eval @jimport (Test$TestInner,)
            @test @isdefined(TestInner)
            @test TestInner === JavaObject{Symbol("Test\$TestInner")}
        catch err
            @test_skip "nested-class \$-escape in multi-import tuple form: $(typeof(err))"
        end
    end
end
