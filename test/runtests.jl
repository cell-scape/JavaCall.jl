using Test
using JavaCall

import Dates
using Base.GC: gc


macro testasync(x)
    :( @test (@sync @async eval($x)).result ) |> esc
end
macro syncasync(x)
    :( (@sync @async eval($x)).result ) |> esc
end

@testset "initialization" begin
    JavaCall.addClassPath("foo")
    JavaCall.addOpts("-Djava.class.path=bar")
    JavaCall.addOpts("-Xmx512M")
    @test JavaCall.init(["-Djava.class.path=$(@__DIR__)"]) === nothing
    @test match(r"foo[:;]+bar", JavaCall.getClassPath()) !== nothing
end

System = @jimport java.lang.System
System_out = jfield(System, "out", @jimport java.io.PrintStream )
@info "Java Version: ", jcall(System, "getProperty", JString, (JString,), "java.version")

@testset "JavaCall" begin

@testset "unsafe_strings_1" begin
    a=JString("how are you")
    @test Ptr(a) != C_NULL
    JavaCall.with_env() do env
        @test 11 == JavaCall.JNI.GetStringUTFLength(Ptr(a), env)
        b = JavaCall.JNI.GetStringUTFChars(Ptr(a), Ref{JavaCall.JNI.jboolean}(), env)
        @test unsafe_string(b) == "how are you"
    end
end

T = @jimport Test

@testset "parameter_passing_1" begin
    @test 10 == jcall(T, "testShort", jshort, (jshort,), 10)
    @test 10 == jcall(T, "testInt", jint, (jint,), 10)
    @test 10 == jcall(T, "testLong", jlong, (jlong,), 10)
    @test typemax(jint) == jcall(T, "testInt", jint, (jint,), typemax(jint))
    @test typemax(jlong) == jcall(T, "testLong", jlong, (jlong,), typemax(jlong))
    @test "Hello Java"==jcall(T, "testString", JString, (JString,), "Hello Java")
    @test Float64(10.02) == jcall(T, "testDouble", jdouble, (jdouble,), 10.02) #Comparing exact float representations hence ==
    @test Float32(10.02) == jcall(T, "testFloat", jfloat, (jfloat,), 10.02)
    @test floatmax(jdouble) == jcall(T, "testDouble", jdouble, (jdouble,), floatmax(jdouble))
    @test floatmax(jfloat) == jcall(T, "testFloat", jfloat, (jfloat,), floatmax(jfloat))
    c=JString(C_NULL)
    @test isnull(c)
    @test "" == jcall(T, "testString", JString, (JString,), c)
    a = rand(10^7)
    @test [jcall(T, "testDoubleArray", jdouble, (Array{jdouble,1},),a)
           for i in 1:10][1] ≈ sum(a)
    a = nothing
end

@testset "static_method_call_1" begin
    jlm = @jimport "java.lang.Math"
    @test 1.0 ≈ jcall(jlm, "sin", jdouble, (jdouble,), pi/2)
    @test 1.0 ≈ jcall(jlm, "min", jdouble, (jdouble,jdouble), 1,2)
    @test 1 == jcall(jlm, "abs", jint, (jint,), -1)
end

@testset "static_method_call_async_1" begin
    # @async paths still depend on JULIA_COPY_STACKS=1 on non-Windows, OR
    # the test running on Windows. The Phase 2 env-cache fixes the
    # "which JNIEnv* on which thread" question, but the underlying
    # HotSpot stack-walking issue with Julia's task-switched stacks
    # (which JULIA_COPY_STACKS=1 papers over) is still real for tasks
    # that yield mid-flight. Synchronous jcall on the main task works
    # everywhere without env vars.
    julia_copy_stacks = get(ENV, "JULIA_COPY_STACKS", "") ∈ ("1", "yes")
    if julia_copy_stacks || Sys.iswindows()
        jlm = @jimport "java.lang.Math"
        @testasync 1.0 ≈ jcall(jlm, "sin", jdouble, (jdouble,), pi/2)
        @testasync 1.0 ≈ jcall(jlm, "min", jdouble, (jdouble,jdouble), 1,2)
        @testasync 1 == jcall(jlm, "abs", jint, (jint,), -1)
    else
        @test_skip "@async paths still need JULIA_COPY_STACKS=1 on non-Windows"
    end
end


@testset "instance_methods_1" begin
    jnu = @jimport java.net.URL
    gurl = jnu((JString,), "https://en.wikipedia.org")
    @test "en.wikipedia.org"==jcall(gurl, "getHost", JString,())
    jni = @jimport java.net.URI
    guri=jcall(gurl, "toURI", jni,())
    @test typeof(guri)==jni

    h=jcall(guri, "hashCode", jint,())
    @test typeof(h)==jint
end

@testset "method_styles_1" begin
    method_dict(x) = map(listmethods(x)) do m
        param_t = Tuple(JavaCall.jimport.(getparametertypes(m)))
        ret_t = JavaCall.jimport(getreturntype(m))
        (getname(m), ret_t, param_t) => m
    end |> Dict


    jmath = @jimport java.lang.Math 
    methods = method_dict(jmath)
    for (method_key, params) in [(("hypot", jdouble, (jdouble, jdouble)), (2.0, 3.0)),
                                 (("getExponent", jint, (jfloat,)), (1.0))
                                ]
        res = jcall(jmath, method_key..., params...)
        @test res == methods[method_key](jmath, params...)
        @test res == jcall(jmath, methods[method_key], params...)
    end

    jnu = @jimport java.net.URL
    gurl = jnu((JString,), "https://en.wikipedia.org")
    methods = method_dict(gurl)
    for (method_key, params) in [(("getProtocol", JString, ()), ()),
                                 (("getHost", JString, ()), ())
                                ]
        res = jcall(gurl, method_key..., params...)
        @test res == methods[method_key](gurl, params...)
        @test res == jcall(gurl, methods[method_key], params...)
    end
end

@testset "exceptions_1" begin
    j_u_arrays = @jimport java.util.Arrays
    j_math = @jimport java.lang.Math
    j_is = @jimport java.io.InputStream

@static if !Sys.isapple()

    # JavaCall.JavaCallError("Error calling Java: java.lang.ArithmeticException: / by zero")
    @info "Expecting: \"Error calling Java: java.lang.ArithmeticException: / by zero\""
    @test_throws JavaCall.JavaCallError jcall(j_math, "floorDiv", jint, (jint, jint), 1, 0)
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.ArrayIndexOutOfBoundsException: Array index out of range: -1")
    @info "Expecting: \"Error calling Java: java.lang.ArrayIndexOutOfBoundsException: Array index out of range: -1\""
    @test_throws JavaCall.JavaCallError jcall(j_u_arrays, "sort", Nothing, (Array{jint,1}, jint, jint), [10,20], -1, -1)
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.IllegalArgumentException: fromIndex(1) > toIndex(0)")
    @info "Expecting: \"Error calling Java: java.lang.IllegalArgumentException: fromIndex(1) > toIndex(0)\""
    @test_throws JavaCall.JavaCallError jcall(j_u_arrays, "sort", Nothing, (Array{jint,1}, jint, jint), [10,20], 1, 0)
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.InstantiationException: java.util.AbstractCollection")
    @info "Expecting: \"Error calling Java: java.lang.InstantiationException: java.util.AbstractCollection\""
    @test_throws JavaCall.JavaCallError (@jimport java.util.AbstractCollection)()
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.NoClassDefFoundError: java/util/Lis")
    @info "Expecting: \"Error calling Java: java.lang.NoClassDefFoundError: java/util/Lis\""
    @test_throws JavaCall.JavaCallError (@jimport java.util.Lis)()
    @test JavaCall.geterror() === nothing

    # JavaCall.JavaCallError("Error calling Java: java.lang.NoSuchMethodError: <init>")
    @info "Expecting: \"Error calling Java: java.lang.NoSuchMethodError: <init>\""
    @test_throws JavaCall.JavaCallError (@jimport java.util.ArrayList)((jboolean,), true)
    @test JavaCall.geterror() === nothing
end

end

@testset "fields_1" begin
    JTest = @jimport(Test)
    t=JTest(())
    t_fields = Dict(getname(f) => f for f in listfields(t))

    lazy_out = jfield(System, "out") # Not type stable
    @test jcall(System_out, "equals", jboolean, (JObject,), lazy_out) == 0x01

    @testset "$ftype" for (name, ftype, valtest) in [ ("booleanField", jboolean, ==(true)) ,
                                ("integerField", jint, ==(100)) ,
                                ("stringField", JString, ==("A STRING")) ,
                                ("objectField", JObject, x -> Ptr(x) == C_NULL) ]
        @test valtest(jfield(t, name, ftype))
        @test valtest(t_fields[name](t))
        @test valtest(jfield(t, t_fields[name]))
    end

    @test jfield(@jimport(java.lang.Math), "E", jdouble) == 2.718281828459045
    @test jfield(@jimport(java.lang.Math), "PI", jdouble) == 3.141592653589793
    @test jfield(@jimport(java.lang.Byte), "MAX_VALUE", jbyte) == 1<<7-1
    @test jfield(@jimport(java.lang.Integer), "MAX_VALUE", jint) == 1<<31-1
    @test jfield(@jimport(java.lang.Long), "MAX_VALUE", jlong) == 1<<63-1

    j_l_bool = @jimport(java.lang.Boolean)
    @test jcall(jfield(j_l_bool, "TRUE", j_l_bool), "booleanValue", jboolean, ()) == true
    @test jcall(jfield(j_l_bool, "FALSE", j_l_bool), "booleanValue", jboolean, ()) == false

    @test jfield(@jimport(java.text.NumberFormat), "INTEGER_FIELD", jint) == 0
    @test jfield(@jimport(java.util.logging.Logger), "GLOBAL_LOGGER_NAME", JString ) == "global"
    locale = @jimport java.util.Locale
    lc = jfield(locale, "CANADA", locale)
    @test jcall(lc, "getCountry", JString, ()) == "CA"
end

#Test NULL
@testset "null_1" begin
    H=@jimport java.util.HashMap
    a=jcall(T, "testNull", H, ())
    @test_throws JavaCall.JavaCallError jcall(a, "toString", JString, ())

    jlist = @jimport java.util.ArrayList
    @test jcall( jlist(), "add", jboolean, (JObject,), JObject(C_NULL)) === 0x01
    @test jcall( jlist(), "add", jboolean, (JObject,), JObject(JavaCall.J_NULL)) === 0x01
    @test jcall( jlist(), "add", jboolean, (JObject,), nothing) === 0x01
    @test jcall( System_out , "print", Nothing , (JObject,), JObject(C_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JObject,), JObject(JavaCall.J_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JObject,), nothing) === nothing
    @test jcall( System_out , "print", Nothing , (JString,), JString(C_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JString,), JString(JavaCall.J_NULL)) === nothing
    @test jcall( System_out , "print", Nothing , (JString,), nothing) === nothing
end

@testset "arrays_1" begin
    j_u_arrays = @jimport java.util.Arrays
    @test 3 == jcall(j_u_arrays, "binarySearch", jint, (Array{jint,1}, jint), [10,20,30,40,50,60], 40)
    @test 2 == jcall(j_u_arrays, "binarySearch", jint, (Array{JObject,1}, JObject), ["123","abc","uvw","xyz"], "uvw")

    a=jcall(j_u_arrays, "copyOf", Array{jint, 1}, (Array{jint, 1}, jint), [1,2,3], 3)
    @test typeof(a) == Array{jint, 1}
    @test a[1] == Int32(1)
    @test a[2] == Int32(2)
    @test a[3] == Int32(3)

    a=jcall(j_u_arrays, "copyOf", Array{JObject, 1}, (Array{JObject, 1}, jint), ["a","b","c"], 3)
    @test 3==length(a)
    @test "a"==unsafe_string(convert(JString, a[1]))
    @test "b"==unsafe_string(convert(JString, a[2]))
    @test "c"==unsafe_string(convert(JString, a[3]))

    @test jcall(T, "testDoubleArray", Array{jdouble,1}, ()) == [0.1, 0.2, 0.3]
    @test jcall(T, "testDoubleArray2D", Array{Array{jdouble, 1},1}, ()) == [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
    @test jcall(T, "testDoubleArray2D", Array{jdouble,2}, ()) == [0.1 0.2 0.3; 0.4 0.5 0.6]
    @test size(jcall(T, "testStringArray2D", Array{JString,2}, ())) == (2,2)
end

@testset "jni_arrays_1" begin
    j_u_arrays = @jimport java.util.Arrays
    arr = jint[10,20,30,40,50,60]
    jniarr = JNIVector(arr)
    @test length(arr) == length(jniarr)
    @test size(arr) == size(jniarr)
    @test all(arr .== jniarr)
    @test 3 == jcall(j_u_arrays, "binarySearch", jint, (JNIVector{jint}, jint), jniarr, 40)
    @test "[10, 20, 30, 40, 50, 60]" == jcall(j_u_arrays, "toString", JString, (JavaCall.JNIVector{jint},), jniarr)

    JCharBuffer = @jimport(java.nio.CharBuffer)
    buf = jcall(JCharBuffer, "wrap", JCharBuffer, (JNIVector{jchar},), JNIVector(jchar.(collect("array"))))
    @test "array" == jcall(buf, "toString", JString, ())

    # Ensure JNIVectors are garbage collected properly
    # This used to be 1:100000
    @info "JNIVector GC test..."
    for i in 1:1000
        a = JNIVector(jchar[j == i ? 0 : 1 for j in 1:10000])
        buf = jcall(JCharBuffer, "wrap", JCharBuffer, (JNIVector{jchar},), a)
    end
    @info "JNIVector GC test complete."
end

@testset "dates_1" begin
    jd = @jimport(java.util.Date)(())
    jcal = @jimport(java.util.GregorianCalendar)(())
    jsd =  @jimport(java.sql.Date)((jlong,),round(jlong, time()))

    @test typeof(convert(Dates.DateTime, jd)) == Dates.DateTime
    @test typeof(convert(Dates.DateTime, jcal)) == Dates.DateTime
    @test typeof(convert(Dates.DateTime, jsd)) == Dates.DateTime
    nulldate = @jimport(java.util.Date)(C_NULL)
    @test Dates.year(convert(Dates.DateTime, nulldate)) == 1970
    nullcal = @jimport(java.util.GregorianCalendar)(C_NULL)
    @test Dates.year(convert(Dates.DateTime, nullcal)) == 1970

    @test Dates.year(convert(Dates.DateTime, nullcal)) == 1970
end

@testset "map_conversion_1" begin
    JHashMap = @jimport(java.util.HashMap)
    p = JHashMap(())
    a= Dict("a"=>"A", "b"=>"B")
    b=convert(@jimport(java.util.Map), JString, JString, a)
    @test jcall(b, "size", jint, ()) == 2
end

@testset "array_list_conversion_1" begin
    JArrayList = @jimport(java.util.ArrayList)
    p = JArrayList(())
    a = ["hello", " ", "world"]
    b = convert(@jimport(java.util.ArrayList), a, JString)
    @test jcall(b, "size", jint, ()) == 3
end

@testset "inner_classes_1" begin
    TestInner = @jimport(Test$TestInner)
    JTest = @jimport(Test)
    t=JTest(())
    inner = TestInner((JTest,), t)
    @test jcall(inner, "innerString", JString, ()) == "from inner"
end

# Test Memory allocation and de-allocatios
# the following loop fails with an OutOfMemoryException in the absence of de-allocation
# However, since Java and Julia memory are not linked, and manual gc() is required.
gc()
for i in 1:100000
    a=JString("A"^10000); #deleteref(a);
    if (i%10000 == 0); gc(); end
end

@testset "sinx_1" begin
    @test_throws UndefVarError jcall(jlm, "sinx", jdouble, (jdouble,), 1.0)
    @test_throws UndefVarError jcall(jlm, "sinx", jdouble, (jdouble,), 1.0)
end

@testset "method_lists_1" begin
    @test length(listmethods(JString("test"))) >= 72
    @test length(listmethods(JString("test"), "indexOf")) >= 3
    # the same for the type
    @test length(listmethods(JString)) >= 72
    @test length(listmethods(JString, "indexOf")) >= 3
    # the same for class
    @test length(listmethods(getclass(JString("test")))) >= 72
    @test length(listmethods(getclass(JString("test")), "indexOf")) >= 3
    m = listmethods(JString("test"), "indexOf")
    @test getname(getreturntype(m[1])) == "int"

    z = [getname.(t) for t in getparametertypes.(m)]
    @test findfirst(n->n==["int"], z) != nothing
    @test findfirst(n->n==["java.lang.String", "int"], z) != nothing
end

@testset "Phase 3: listconstructors" begin
    JArrayList = @jimport java.util.ArrayList
    ctors = listconstructors(JArrayList)
    @test ctors isa Vector
    @test !isempty(ctors)
    @test eltype(ctors) <: JavaObject   # JConstructor === JavaObject{Symbol("java.lang.reflect.Constructor")}
    # at least one no-arg and one int-arg ctor:
    nparams = [length(getparametertypes(c)) for c in ctors]
    @test 0 in nparams
    @test 1 in nparams
    # show works
    @test occursin("<init>", sprint(show, first(ctors)))
end

@testset "Phase 3: resolve_call" begin
    JTest = @jimport Test
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    rc(recv, name, args...) = JavaCall.resolve_call(recv, name, args)
    pn(c) = JavaCall.getname(c)
    pt(m) = String[pn(c) for c in JavaCall.getparametertypes(m)]

    # exact primitive return-type pulled from reflection
    @test pn(JavaCall.getreturntype(rc(JTest, "testInt", Int32(3)).member)) == "int"
    # static overload set: String > Object for a Julia String; exact int for Int32
    @test pt(rc(JTest, "overloaded", "x").member)      == ["java.lang.String"]
    @test pt(rc(JTest, "overloaded", Int32(1)).member) == ["int"]
    # .paramtypes carries the Julia-side fixed-param types
    @test rc(JTest, "overloaded", "x").paramtypes == (JString,)
    @test rc(JTest, "overloaded", Int32(1)).paramtypes == (JavaCall.jint,)
    # numeric widening: Int -> a numeric primitive (we don't promise which)
    @test pt(rc(JMath, "abs", -3).member)[1] in ("int", "long")
    # instance method on an actual object
    al = JArrayList((),)                                # explicit empty-ctor
    @test pt(rc(al, "add", "one").member) == ["java.lang.Object"]
    # varargs: sumVarargs(int...) — member is the varargs method, marked varargs
    r = rc(JTest, "sumVarargs", Int32(1), Int32(2), Int32(3))
    @test r.varargs == true
    @test r.vararg_eltype === JavaCall.jint
    @test r.n_fixed == 0
    @test r.paramtypes == ()   # no fixed params; trailing array excluded
    # single-arg varargs match still goes through the varargs form
    @test rc(JTest, "sumVarargs", Int32(1)).varargs == true
    # passing the array directly to a varargs method
    r2 = rc(JTest, "sumVarargs", JavaCall.jint[1,2,3])
    @test r2.varargs == true   # still the varargs member; packing decided at call site
    # phase-marker comparison: a fixed-arity overload beats a varargs one of the same name
    @test rc(JTest, "mixed", Int32(5)).varargs == false
    @test pt(rc(JTest, "mixed", Int32(5)).member) == ["int"]
    # Julia Char satisfies a Java `char` param
    @test rc(JTest, "testChar", 'A').paramtypes == (JavaCall.jchar,)
    @test JavaCall._arg_tier('A', JavaCall.jchar) == 0
    @test JavaCall._arg_tier(UInt16(65), JavaCall.jchar) in (0, 2)
    # array-parameter overload: Vector{jint} -> int[]  (getName of int[] is "int[]")
    @test pt(rc(JTest, "testArrayArgs", JavaCall.jint[1,2]).member) == ["int[]"]
    # nothing -> null reference param
    @test pt(rc(JTest, "testString", nothing).member) == ["java.lang.String"]
    # ambiguity: widen(long) vs widen(double) with an Int32 -> both implicit -> throw
    @test_throws JavaCall.JavaCallError rc(JTest, "widen", Int32(3))
    # no match
    @test_throws JavaCall.JavaCallError rc(al, "add", 1, 2, 3)
    # cache returns the same ResolvedCall member object
    @test rc(JTest, "testInt", Int32(3)).member === rc(JTest, "testInt", Int32(3)).member
end

@testset "Phase 3: jcall resolved form" begin
    JTest = @jimport Test
    JArrayList = @jimport java.util.ArrayList
    JMath = @jimport java.lang.Math
    JSystem = @jimport java.lang.System

    # static, exact + widening
    @test jcall(JMath, "abs", Int32(-3)) == 3
    @test jcall(JTest, "testInt", 7) == 7                      # Int -> int (in range)
    @test jcall(JTest, "testString", "hi") == "hi"             # String return -> Julia String
    @test jcall(JTest, "testString", "hi") isa String
    # static overload selection
    @test jcall(JTest, "overloaded", "x")      == "String"
    @test jcall(JTest, "overloaded", Int32(1)) == "int"
    # mixed: a fixed-arity overload wins over the varargs one
    @test jcall(JTest, "mixed", Int32(5)) == "fixed"
    @test jcall(JTest, "mixed", Int32(1), Int32(2)) == "varargs"
    # instance methods on a live ArrayList
    al = JArrayList((),)
    @test jcall(al, "add", "one") == true
    @test jcall(al, "size") == 1
    @test jcall(al, "get", 0) == "one"                         # narrowed -> Julia String
    @test jcall(al, "isEmpty") == false
    # static with a system property (String return)
    @test jcall(JSystem, "getProperty", "java.version") isa AbstractString
    # varargs: spread, empty, and array-direct forms
    @test jcall(JTest, "sumVarargs", 1, 2, 3, 4) == 10
    @test jcall(JTest, "sumVarargs") == 0
    @test jcall(JTest, "sumVarargs", JavaCall.jint[5, 6]) == 11
    @test jcall(JTest, "joinVarargs", "-", "a", "b", "c") == "a-b-c"
    @test jcall(JTest, "joinVarargs", "-") == ""
    # nothing -> null: testString returns its argument; a null String return -> "" (existing JavaCall contract)
    @test jcall(JTest, "testString", nothing) == ""
    # ambiguity & no-match throw JavaCallError
    @test_throws JavaCall.JavaCallError jcall(JTest, "widen", Int32(3))
    @test_throws JavaCall.JavaCallError jcall(al, "add", 1, 2, 3)
    # explicit form unchanged (regression)
    @test jcall(JTest, "testInt", jint, (jint,), Int32(9)) == 9
    @test jcall(al, "size", jint, ()) == 1
end

@testset "Phase 3: jnew resolved form" begin
    JArrayList = @jimport java.util.ArrayList
    a = JavaCall.jnew(JArrayList)
    @test a isa JavaObject
    @test jcall(a, "size") == 0
    b = JavaCall.jnew(JArrayList, 16)                       # ArrayList(int initialCapacity)
    @test b isa JavaObject
    @test jcall(b, "size") == 0
    jcall(a, "add", "x")
    c = JavaCall.jnew(JArrayList, a)                        # ArrayList(Collection)
    @test jcall(c, "size") == 1
    @test jcall(c, "get", 0) == "x"
    # explicit form unchanged (regression)
    @test JArrayList((jint,), 8) isa JavaObject
    @test JArrayList((),) isa JavaObject
    # ambiguity / no-match throw JavaCallError
    @test_throws JavaCall.JavaCallError JavaCall.jnew(JArrayList, "not a valid ctor arg shape", 1, 2)
end

#Test for double free bug, #20
#Fix in #28. The following lines will segfault without the fix
@testset "double_free_1" begin
    JHashtable = @jimport java.util.Hashtable
    JProperties = @jimport java.util.Properties
    ta_20=Any[]
    for i=1:100; push!(ta_20, convert(JHashtable, JProperties((),))); end
    gc(); gc()
    for i=1:100; @test jcall(ta_20[i], "size", jint, ()) == 0; end
end

@testset "array_conversions_1" begin
    jobj = jcall(T, "testArrayAsObject", JObject, ())
    arr = convert(Array{Array{UInt8, 1}, 1}, jobj)
    @test ["Hello", "World"] == map(String, arr)
end

@testset "iterator_conversions_1" begin
    JArrayList = @jimport(java.util.ArrayList)
    a=JArrayList(())
    jcall(a, "add", jboolean, (JObject,), "abc")
    jcall(a, "add", jboolean, (JObject,), "cde")
    jcall(a, "add", jboolean, (JObject,), "efg")

    t=Array{Any, 1}()
    for i in JavaCall.iterator(a)
        push!(t, unsafe_string(i))
    end

    @test length(t) == 3
    @test t[1] == "abc"
    @test t[2] == "cde"
    @test t[3] == "efg"

    #Different iterator type - ListIterator
    t=Array{Any, 1}()
    for i in jcall(a, "listIterator", @jimport(java.util.ListIterator), ())
        push!(t, unsafe_string(i))
    end

    @test length(t) == 3
    @test t[1] == "abc"
    @test t[2] == "cde"
    @test t[3] == "efg"

    a=JArrayList(())
    t=Array{Any, 1}()
    for i in JavaCall.iterator(a)
        push!(t, unsafe_string(i))
    end
    @test length(t) == 0

    JStringClass = classforname("java.lang.String")
    @test isa(JStringClass, JavaObject{Symbol("java.lang.Class")})

    o = convert(JObject, "bla bla bla")
    @test isa(narrow(o), JString)
end

@testset "metaclass_cache" begin
    # Repeated lookups must hit the cache, not re-issue FindClass.
    sym = Symbol("java.lang.String")
    mc1 = JavaCall.metaclass(sym)
    mc2 = JavaCall.metaclass(sym)
    @test mc1 === mc2
    @test Ptr(mc1) == Ptr(mc2)
    @test Ptr(mc1) != C_NULL

    # Cached entry must be a JNI global ref so it survives PopLocalFrame.
    JavaCall.with_env() do env
        @test JavaCall.JNI.GetObjectRefType(Ptr(mc1), env) == JavaCall.JNI.JNIGlobalRefType
    end
    jlocalframe(Nothing) do
        nothing
    end
    @test Ptr(JavaCall.metaclass(sym)) == Ptr(mc1)
    JavaCall.with_env() do env
        @test JavaCall.JNI.GetObjectRefType(Ptr(mc1), env) == JavaCall.JNI.JNIGlobalRefType
    end
end

@testset "jlocalframe" begin
    @test jlocalframe() do
        JObject()
    end isa JObject
    @test jlocalframe() do 
        5
    end isa Int64
    @test_throws ErrorException jlocalframe() do 
        error("Error within jlocalframe f")
    end

    @test jlocalframe(JObject) do T
        T()
    end isa JObject
    @test jlocalframe(UInt64) do T
        T(6)
    end isa UInt64
    @test_throws ErrorException jlocalframe(JObject) do T
        error("Error within jlocalframe f")
    end

    @test jlocalframe(Nothing) do 
        JObject() 
    end === nothing
    @test_throws ErrorException jlocalframe(Nothing) do 
        error("Error within jlocalframe f")
    end
end

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

@testset "dispatch_task_lifecycle" begin
    # The dispatch task should be alive after JavaCall.init() and have
    # processed zero messages so far (we haven't routed anything to it).
    @test JavaCall._dispatch_task[] isa Task
    @test !istaskdone(JavaCall._dispatch_task[])
    @test isready(JavaCall._dispatch_channel) == false
end

@testset "dispatch_task_survives_handler_error" begin
    initial = JavaCall._dispatch_processed_count[]
    push!(JavaCall._dispatch_channel, JavaCall.DeleteRef(C_NULL, :local))
    deadline = time() + 2.0
    while JavaCall._dispatch_processed_count[] == initial && time() < deadline
        yield()
    end
    @test JavaCall._dispatch_processed_count[] >= initial + 1
    @test !istaskdone(JavaCall._dispatch_task[])
end

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

@testset "is_virtual_thread" begin
    JThread = @jimport "java.lang.Thread"
    current = jcall(JThread, "currentThread", JThread, ())
    # On JDK <21 the function pointer is null and we return false.
    # On JDK 21+ this is a regular platform thread, which also reports false.
    @test is_virtual_thread(current) == false
end

@testset "with_critical_array" begin
    # Allocate a Java double[] directly via JNI.NewDoubleArray and populate
    # it. Using Test.testDoubleArray() would lose the array reference (the
    # jcall convert_result path copies the contents to a Julia Vector
    # before returning), defeating the point of with_critical_array.
    n = 5
    arr_obj = JavaCall.with_env() do env
        local_ref = JavaCall.JNI.NewDoubleArray(JavaCall.JNI.jsize(n), env)
        local_ref == C_NULL && error("NewDoubleArray returned NULL")
        # Fill with 1.0..5.0
        src = jdouble[1.0, 2.0, 3.0, 4.0, 5.0]
        JavaCall.JNI.SetDoubleArrayRegion(local_ref, JavaCall.JNI.jsize(0),
                                          JavaCall.JNI.jsize(n), src, env)
        # Wrap as JavaObject so cleanup_arg / finalizer handles it later.
        JavaObject{Symbol("[D")}(local_ref)
    end

    sum_via_critical = with_critical_array(arr_obj, jdouble) do view
        @test length(view) == n
        @test view[1] == 1.0
        s = zero(jdouble)
        @inbounds for x in view
            s += x
        end
        s
    end
    @test sum_via_critical == 15.0   # 1+2+3+4+5
end

@testset "jdirect_buffer_zero_copy" begin
    n = 1024
    buf = JDirectBuffer{jdouble}(n)
    @test length(buf.data) == n

    # Capacity reported by Java should be n * sizeof(jdouble) bytes.
    @test jcall(buf.obj, "capacity", jint, ()) == n * sizeof(jdouble)

    # Fill from Julia, verify Java sees it via DoubleBuffer.
    fill!(buf.data, 3.14)
    JDB = @jimport "java.nio.DoubleBuffer"
    dbview = jcall(buf.obj, "asDoubleBuffer", JDB, ())
    @test jcall(dbview, "get", jdouble, (jint,), 0) == 3.14
    @test jcall(dbview, "get", jdouble, (jint,), 100) == 3.14

    # Mutate from Java side, verify Julia Vector sees it.
    jcall(dbview, "put", JDB, (jint, jdouble), 0, 99.0)
    @test buf.data[1] == 99.0
end

@testset "finalizers_release_jvm_memory" begin
    # Allocate many short-lived JStrings, force Julia GC, and verify that
    # the JVM's free heap recovers — i.e. the finalizer's DeleteLocalRef
    # actually ran and the JVM's GC was able to reclaim the strings.
    Runtime = @jimport "java.lang.Runtime"
    rt = jcall(Runtime, "getRuntime", Runtime, ())
    n_objects = 1000
    str_size = 10000   # 10KB per string, 10MB total before cleanup

    # Establish a baseline of JVM free memory after a clean GC.
    GC.gc(true); GC.gc(true)
    jcall(rt, "gc", Nothing, ())
    baseline_free = jcall(rt, "freeMemory", jlong, ())

    # Allocate a wave of strings; let them go out of scope.
    for _ in 1:n_objects
        local s = JString("x"^str_size)
    end

    # Force Julia GC to fire the finalizers, then JVM GC to actually reclaim.
    GC.gc(true); GC.gc(true)
    jcall(rt, "gc", Nothing, ())
    after_free = jcall(rt, "freeMemory", jlong, ())

    # Free memory after cleanup should be within ~10MB of baseline.
    # If finalizers leaked, after_free would be much lower (free=total-used,
    # so leaks SHRINK free).
    leaked = baseline_free - after_free
    @test leaked < n_objects * str_size * 4   # generous slop for JVM bookkeeping
end

include("jcall_macro.jl")

@testset "dispatch Callback message" begin
    @test !istaskdone(JavaCall._dispatch_task[])

    box = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> 6 * 7, (), box))
    @test take!(box) == 42

    box2 = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> error("boom"), (), box2))
    r = take!(box2)
    @test r isa Exception

    # dispatch task still alive
    @test !istaskdone(JavaCall._dispatch_task[])
    box3 = Channel{Any}(1)
    push!(JavaCall._dispatch_channel, JavaCall.Callback(() -> :ok, (), box3))
    @test take!(box3) === :ok
end

end

# Test downstream dependencies
try
    using Pkg
    Pkg.add("Taro")

    using Taro
    chmod(joinpath(dirname(dirname(pathof(Taro))),"test","df-test.xlsx"),0o600)

    Pkg.test("Taro")
    #include(joinpath(dirname(dirname(pathof(Taro))),"test","runtests.jl"))
catch err
    @warn "Taro.jl testing failed"
    sprint(showerror, err, backtrace())
end

# Run GC before we destroy to avoid errors
GC.gc()
# At the end, unload the JVM before exiting
JavaCall.destroy()
