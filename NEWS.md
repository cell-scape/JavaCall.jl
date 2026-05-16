# JavaCall.jl release notes

## Unreleased

### Added

- `@jimport` gained `using`-style multi-import grammars: `@jimport java.util:
  ArrayList, HashMap, Map => JMap` binds three locals from one package, and
  `@jimport (java.util.ArrayList, java.lang.System)` binds across packages.
  `=>` renames are supported in both forms. Existing single-class forms
  (`@jimport java.util.ArrayList`, `"java.util.ArrayList"`, `@jimport(Outer$Inner)`)
  are unchanged.
- 31 new built-in `J*` aliases for common Java standard-library classes —
  `JList`, `JArrayList`, `JMap`, `JHashMap`, `JSet`, `JHashSet`, `JCollection`,
  `JIterator`, `JIterable`, `JComparator`, all the boxed primitives
  (`JNumber`/`JBoolean`/`JByte`/`JCharacter`/`JShort`/`JInteger`/`JLong`/
  `JFloat`/`JDouble`), `JCharSequence`, `JThrowable`, `JException`, `JRunnable`,
  the basic `java.io` types (`JFile`/`JInputStream`/`JOutputStream`/`JReader`/
  `JWriter`), and a few `java.util` extras (`JDate`/`JCalendar`/`JProperties`).
  All exported alongside the existing `JObject`/`JClass`/`JString`/etc.

## v0.9.0

A large internal modernization ("Phase 2"). The public calling API — `jcall`,
`@jcall`, `@jimport`, `jfield`, `JavaObject`, `jnew`, `jlocalframe`, `jglobal` —
is unchanged. The JProxies companion package gained features and dropped some
old ones (see below).

### Breaking

- **Julia 1.12 is now the minimum.** The threading rebuild relies on `OncePerThread`
  and `@ccall foo() gc_safe = true`, which are 1.12+ features. Use JavaCall.jl 0.8.x
  on older Julia.
- **The `JULIA_COPY_STACKS=1` requirement is gone**, along with the root-task
  constraint, the Windows "JNI on thread 1 only" pinning, and the
  `JavaCall.JNI.Threads` shim. There is now one unified codebase across Linux,
  macOS, and Windows, and you no longer need to set `JULIA_COPY_STACKS` (it is no
  longer consulted). The `assertroottask_or_goodenv()` runtime check has been
  removed. `JAVACALL_FORCE_ASYNC_INIT` / `JAVACALL_FORCE_ASYNC_TEST` are gone.
- **JProxies:** the `@class` macro, `staticproxy`, `interfacehas`, and the implicit
  Julia↔Java widening (e.g. automatic `String`→`JString`, `Vector`→`JList`) have
  been removed. Use explicit `convert` and the low-level `jcall` for those cases.
  `JProxy(obj).method(args)` dot-access is preserved (now with proper overload
  resolution).

### Threading rebuild

- Outbound JNI calls fetch a per-OS-thread `JNIEnv*` lazily (via `OncePerThread`),
  attaching the thread to the JVM as a daemon on first use. Multithreaded JNI
  access is supported on all platforms.
- Long-running JNI calls are annotated `gc_safe = true` so they don't block Julia
  GC.
- A dedicated **dispatch task** (sticky, in the `:interactive` pool, owns one
  pre-attached OS thread) services Java→Julia callbacks. JNI reference cleanup in
  finalizers is performed synchronously via on-demand thread attach.

### JProxies rewrite

- `JProxy(obj).method(args...)` resolves Java method overloads by argument type
  (a quality-score ladder: exact > subclass > boxing/widening; ambiguous calls
  throw), with results narrowed to their runtime class. Works for instance and
  static methods; `jp.field` reads fields; `unwrap(jp)` returns the underlying
  `JavaObject`.
- `@jproxy YourType "java.fully.qualified.Interface" begin ...method defs... end`
  plus `jproxy(value, "java.fully.qualified.Interface")` let you implement a Java
  interface in Julia. The macro lowers to plain table assignments — no runtime
  `eval`, so JProxies now precompiles cleanly. Callbacks execute on the dispatch
  task; they are designed for the supported single-OS-thread configuration
  (`JULIA_NUM_THREADS=1`) and the handler should do pure-Julia work.
- A small `org.juliainterop.JavaCallInvocationHandler` class is bundled (source and
  compiled `.class`); its native method is wired to a Julia `@cfunction` via
  `JNI.RegisterNatives`.

### Other modernizations

- JNI version requested at startup bumped from `JNI_VERSION_1_8` to
  `JNI_VERSION_21` (forward-compatible; unlocks newer JNI functions on JDK 21+).
- `JValue` is now a primitive type matching the C `jvalue` union, replacing the
  old `jvalue = Int64` alias.
- New `JDirectBuffer{T}` for zero-copy numeric exchange backed by a Java direct
  `ByteBuffer`.
- New `with_critical_array(f, arr, T)` for pinned access to a Java primitive array
  via the JNI critical APIs.
- New `is_virtual_thread(thread)` (JDK 21+; returns `false` on older JDKs).

### CI

- The CI matrix drops the `JULIA_COPY_STACKS` dimension and adds
  `JULIA_NUM_THREADS` ∈ {1, 4}. The Julia minimum in the matrix is 1.12.
- A non-gating `downstream.yml` workflow runs JDBC.jl / Spark.jl /
  BioformatsLoader.jl / Taro.jl against `master` as a tripwire for unintended API
  breakage. (`Taro` / `DataFrames` were removed from JavaCall's own test-only deps —
  Taro currently pins `JavaCall ≤ 0.8` and will need a release before it can be
  installed alongside 0.9.)
