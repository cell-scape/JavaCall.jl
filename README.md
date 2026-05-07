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

## Julia version compatibility

JavaCall.jl 0.9 requires Julia 1.12 or newer. CI tests Julia 1.12 (`min`), Julia LTS, and the latest stable release. For older Julia versions, use JavaCall.jl 0.8.x.

## Threading and platform support

JavaCall.jl 0.9 supports multithreaded JNI access on Linux, macOS, and Windows alike. The package attaches each Julia OS thread to the JVM lazily on first use; there is no Windows-specific pinning.

For **synchronous** `jcall` / `jnew` / `jfield` on regular tasks (including `Threads.@threads` and `Threads.@spawn` — both sticky and non-sticky), no environment variables are required.

If your code uses **`@async`** to make JNI calls, you should still set `JULIA_COPY_STACKS=1` before starting Julia on Linux/macOS. The env-cache layer fixes the per-thread `JNIEnv*` question, but the underlying HotSpot stack-walking issue that `JULIA_COPY_STACKS` papers over is still real for tasks that yield mid-flight. On Windows, `@async` works without any env var.

If you maintain code that targets JavaCall.jl 0.8.x or earlier, see [the legacy threading guide](https://github.com/JuliaInterop/JavaCall.jl/tree/v0.8.1#macos-and-linux) for the older requirements.
