# JavaCall.jl

![master GHA CI](https://github.com/JuliaInterop/JavaCall.jl/actions/workflows/CI.yml/badge.svg)

Call Java programs from [Julia](https://julialang.org).

## Documentation

Documentation is available at http://juliainterop.github.io/JavaCall.jl

## Quick Start Example Usage

```julia
$ julia

julia> using Pkg; Pkg.activate(; temp = true)
  Activating new project at `/tmp/jl_e6uPja`

julia> using JavaCall
 │ Package JavaCall not found, but a package named JavaCall is available from a
 │ registry. 
 │ Install package?
 │   (jl_e6uPja) pkg> add JavaCall 
 └ (y/n) [y]: y

...

julia> JavaCall.addClassPath(pwd()) # Set appropriate classpath

julia> JavaCall.addOpts("-Xmx1024M") # Use 1 GB of memory
OrderedCollections.OrderedSet{String} with 1 element:
  "-Xmx1024M"

julia> JavaCall.addOpts("-Xrs") # Disable signal handling in the JVM, reducing performance but enhancing compatability
OrderedCollections.OrderedSet{String} with 2 elements:
  "-Xmx1024M"
  "-Xrs"

julia> JavaCall.init() # Call before using `jcall` or `jfield`. Do not use this in package `__init__()` to allow other packages to add classpaths or options.

julia> jls = @jimport java.lang.System
JavaObject{Symbol("java.lang.System")}

julia> out = jfield(jls, "out", @jimport java.io.PrintStream) # Third arg is optional, but helps type stability.
JavaObject{Symbol("java.io.PrintStream")}(JavaCall.JavaLocalRef(Ptr{Nothing} @0x0000000003ecda38))

julia> jcall(out, "println", Nothing, (JString,), "Hello World")
Hello World
```

If you need several classes from one package, use the `using`-style colon
syntax: `@jimport java.util: ArrayList, HashMap`. For cross-package imports,
use a tuple: `@jimport (java.util.ArrayList, java.lang.System)`. Both forms
accept `=>` renames (`@jimport java.util: ArrayList => JArrayList`). JavaCall
already ships built-in aliases for the standard library's most-common classes
— `JList`, `JArrayList`, `JMap`, `JHashMap`, `JInteger`, `JRunnable`, `JFile`,
and others — so the common cases need no `@jimport` at all.

## JProxies — ergonomic Java objects and Julia callbacks

`JProxies` is a companion package shipped in this repository under `JProxies/` (it
has its own `Project.toml` and is not part of the `JavaCall` API). Add it with
`Pkg.develop(path="path/to/JavaCall.jl/JProxies")`.

**Dot-access with overload resolution:**

```julia
using JProxies
JProxies.init()                       # forwards to JavaCall.init()

a = JProxy(@jimport(java.util.ArrayList)(()))
a.add("one"); a.add("two")
a.size()                              # 2
a.get(0)                              # "one"

JProxy(@jimport java.lang.Math).sin(0.0)          # static methods via the class
JProxy(@jimport java.lang.Integer).MAX_VALUE      # static field read
unwrap(a)                             # the raw JavaObject, for low-level jcall
```

`jp.method(args...)` resolves the best Java overload for the Julia argument types
(exact > subclass > boxing/widening; ambiguous ties throw) and returns the result
`narrow`ed to its runtime class. `jp.field` reads a field. **Field writes are not
supported** — `jp.field = v` throws; use the low-level field setter for that.

**Implementing a Java interface in Julia:**

```julia
mutable struct Counter; n::Int; end
@jproxy Counter "java.lang.Runnable" begin
    run(self) = (self.n += 1; nothing)
end
c = Counter(0)
r = jproxy(c, "java.lang.Runnable")   # pass `r` wherever Java expects a Runnable
```

`@jproxy` lowers to plain table assignments — no runtime `eval`, so it is
precompile-friendly. Callbacks execute on JavaCall's dispatch task (a known
JVM-attached thread), which is the supported single-OS-thread configuration
(`JULIA_NUM_THREADS=1`). Inside a handler, primitive arguments, `String`, and the
boxed wrapper types arrive as Julia values; any other object argument is delivered
as a raw `JavaObject` (not narrowed) — `convert`/`narrow` it yourself if needed.

**Removed in this release:** the `@class` macro, `staticproxy`, `interfacehas`,
and implicit `String`↔`JString` / `Vector`↔`JList` widening. Use explicit
`convert` and the low-level `jcall` for those cases.

**Iteration.** `for x in JProxy(obj) … end` works on Java `Iterable`/`Collection`/`Set`/`List`, `Map`,
Java arrays (primitive and object), and raw `Iterator`. Maps yield `Pair{Any,Any}` so destructuring
works: `for (k, v) in JProxy(jmap); println("$k → $v"); end`. Each element is decoded the same way
JProxy method-call results are (narrowed; `JString` → `String`; boxed primitives unboxed). Use
`length(JProxy(obj))` for sized containers (`Collection`/`Map`/array); raw `Iterator`s have no
known length and `length` on them throws.

## Julia version compatibility

JavaCall.jl 0.10 requires Julia 1.12 or newer. CI tests Julia 1.12 (`min`), Julia LTS, and the latest stable release. For older Julia versions, use JavaCall.jl 0.8.x.

## Threading and platform support

JavaCall.jl 0.10 supports multithreaded JNI access on Linux, macOS, and Windows alike. The package attaches each Julia OS thread to the JVM lazily on first use; there is no Windows-specific pinning.

For **synchronous** `jcall` / `jnew` / `jfield` on regular tasks (including `Threads.@threads` and `Threads.@spawn` — both sticky and non-sticky), no environment variables are required.

If your code uses **`@async`** to make JNI calls, you should still set `JULIA_COPY_STACKS=1` before starting Julia on Linux/macOS. The env-cache layer fixes the per-thread `JNIEnv*` question, but the underlying HotSpot stack-walking issue that `JULIA_COPY_STACKS` papers over is still real for tasks that yield mid-flight. On Windows, `@async` works without any env var.

If you maintain code that targets JavaCall.jl 0.8.x or earlier, see [the legacy threading guide](https://github.com/JuliaInterop/JavaCall.jl/tree/v0.8.1#macos-and-linux) for the older requirements.
