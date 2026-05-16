"""
    JavaRef

Abstract parent of [`JavaLocalRef`](@ref), [`JavaGlobalRef`](@ref) and
[`JavaNullRef`](@ref) — the three flavours of JNI reference held inside a
[`JavaObject`](@ref). Distinct from `JavaCall.JNI.AbstractJavaRef` because its
meaning (and the cleanup it implies) is defined here, not in the `JNI`
submodule.
"""
abstract type JavaRef <: JNI.AbstractJavaRef end

"""
    JavaLocalRef

A JNI *local* reference — valid only on the OS thread it was created on and only
until that thread's current JNI frame returns. This is the reference type the JNI
returns by default, so it is the default wrapped by a [`JavaObject`](@ref).
`deleteref` releases it via `JNI.DeleteLocalRef`. Use [`jlocalframe`](@ref)
(`PushLocalFrame`/`PopLocalFrame`) to scope batches of local refs in long loops,
or [`jglobal`](@ref) to promote a long-lived one.
"""
struct JavaLocalRef <: JavaRef
    ptr::Ptr{Nothing}
end

"""
    JavaGlobalRef

A JNI *global* reference — valid on any thread for as long as it is not deleted.
`deleteref` releases it via `JNI.DeleteGlobalRef`. Created by [`jglobal`](@ref)
for references that must outlive a single call frame.
"""
struct JavaGlobalRef <: JavaRef
    ptr::Ptr{Nothing}
end

"""
    JavaNullRef

A sentinel `JavaRef` wrapping `C_NULL`, used to mark a reference whose underlying
JNI ref has already been deleted (so `deleteref` on it is a no-op). See
[`J_NULL`](@ref).
"""
struct JavaNullRef <: JavaRef
    ptr::Ptr{Nothing}
    JavaNullRef() = new(C_NULL)
end

"""
    J_NULL

The singleton [`JavaNullRef`](@ref). Assigned to a `JavaObject`'s `ref` field
after its JNI reference has been deleted so further `deleteref` calls are no-ops.
"""
const J_NULL = JavaNullRef()

Ptr(ref::JavaRef) = ref.ptr
Ptr{Nothing}(ref::JavaRef) = ref.ptr

JavaLocalRef(ref::JavaRef) = with_env() do env; JavaLocalRef(JNI.NewLocalRef(Ptr(ref), env)); end
JavaGlobalRef(ref::JavaRef) = with_env() do env; JavaGlobalRef(JNI.NewGlobalRef(Ptr(ref), env)); end

"""
    deleteref deletes a JavaRef using either JNI.DeleteLocalRef or JNI.DeleteGlobalRef
"""
function deleteref(x::JavaRef)
    x.ptr == C_NULL && return
    JNI.is_env_loaded() || return
    # Synchronous deletion via with_env — the calling OS thread gets
    # attached on demand if it isn't already. The original Phase 2 spec
    # called for routing finalizer-driven deletion through the dispatch
    # task, but the resulting async cleanup couldn't keep up with
    # synchronous-allocation throughput in tight loops (the JVM heap
    # ran out before the dispatch task drained DeleteRef messages).
    # Daemon-attaching every Julia OS thread that runs a finalizer is
    # acceptable: the thread count is bounded by JULIA_NUM_THREADS, the
    # attachment is daemon (so it doesn't block VM shutdown), and the
    # JVM's per-thread bookkeeping is O(1) per attached thread.
    # The dispatch task remains for Phase 2C callbacks.
    with_env() do env
        if x isa JavaLocalRef
            JNI.DeleteLocalRef(x.ptr, env)
        elseif x isa JavaGlobalRef
            JNI.DeleteGlobalRef(x.ptr, env)
        end
    end
    return
end

"""
    jlocalframe(f, [returntype]; [capacity = 16])
    
    Manages java local references by using JNI's PushLocalFrame and PopLocalFrame.
    Only the local reference returned by f will be valid. Other local references
    will be freed and available for garbage collection.

    Specifying a `returntype` will allow for type stability. If `returntype` is
    specified and is not `Nothing` or `Any`, it will also be passed to the function.

    Capacity specifies the minimum number of local references that can be
    created. See the [JNI documentation](
    https://docs.oracle.com/en/java/javase/15/docs/specs/jni/functions.html#pushlocalframe
    )
    for further information.

    # Example
    ```
    julia> jlocalframe() do
               a = JObject() # Local reference created, will be GCed
               println(a)
               b = JObject() # Local reference returned
               println(b)
               b
           end

    julia> jlocalframe(JObject) do T # Specify returntype for type stability
               a = T()
               println(a)
               b = T()
               println(b)
               b
           end
    
    julia> jlocalframe(Nothing) do # Specify Nothing if you do want to return anything
               a = JObject()
               println(a)
           end
    ```
"""
function jlocalframe(f::Function, returntype::Type = Any; capacity = 16)
    with_env() do env
        JNI.PushLocalFrame(jint(capacity), env)
        result_ref = C_NULL
        return_ref = JavaLocalRef(result_ref)
        result = nothing
        # Holds a strong reference to the original f() return value so that, if
        # it is a JavaObject, its finalizer cannot fire (and thus DeleteLocalRef
        # cannot run) between when we extract its raw pointer and when
        # PopLocalFrame consumes it below.
        result_keep = nothing
        try
            if returntype == Any
                result = f()
            else
                result = f(returntype)
            end
            result_keep = result
            if isa(result, JavaObject)
                result = Ptr{Nothing}(result)
            end
            if isa(result, Ptr{Nothing}) &&
               JNI.GetObjectRefType(result, env) == JNI.JNILocalRefType
                result_ref = result
            end
        catch err
            rethrow(err)
        finally
            GC.@preserve result_keep begin
                return_ref = JavaLocalRef( JNI.PopLocalFrame(result_ref, env) )
            end
        end

        # Return
        if returntype == Any # Not Type Stable
            if !isnull(return_ref.ptr)
                return narrow( JObject(return_ref) )
            else
                return result
            end
        elseif returntype <: JavaObject
            return returntype(return_ref)
        else
            return result::returntype
        end
    end
end

# Closer to https://github.com/ahnlabb/BioformatsLoader.jl/commit/4d4e2d5decd87c8bfd2bfca2fdfbc4214b120977
function jlocalframe(f::Function, returntype::Type{Nothing}; capacity = 16)
    with_env() do env
        JNI.PushLocalFrame(jint(capacity), env)
        try
            f()
        catch err
            rethrow(err)
        finally
            JNI.PopLocalFrame(C_NULL, env)
        end
        return nothing
    end
end

"""
    JavaMetaClass{T}

A cached handle to a Java class (a JNI `jclass`, held as a global ref so it
survives `PopLocalFrame`). `T` is the `Symbol` of the fully-qualified Java class
name. Obtain one with [`metaclass`](@ref); results are memoized in the
process-wide `_jmc_cache_v2` dict under `_jmc_cache_lock`, so a class is looked
up via `FindClass` at most once per process.
"""
struct JavaMetaClass{T} <: JNI.AbstractJavaRef
    ref::JavaRef
end

#The metaclass, sort of equivalent to a the
JavaMetaClass(T, ref::JavaRef) = JavaMetaClass{T}(ref)
JavaMetaClass(T, ptr::Ptr{Nothing}) = JavaMetaClass{T}(JavaGlobalRef(ptr))

ref(mc::JavaMetaClass{T}) where T = mc.ref
Ptr(mc::JavaMetaClass{T}) where T = Ptr(mc.ref)
Ptr{Nothing}(mc::JavaMetaClass{T}) where T = Ptr(mc.ref)

"""
    JavaObject{T}

The main JavaCall type — a mutable wrapper around a [`JavaRef`](@ref) (a JNI
reference) to a Java object. `T` is the `Symbol` of the fully-qualified Java class
name, e.g. `JavaObject{Symbol("java.util.ArrayList")}`. Obtain one via
[`@jimport`](@ref) + [`jnew`](@ref) (constructing a new Java instance), or as the
return value of a [`jcall`](@ref) / [`jfield`](@ref). When `T` is a class but no
instance is needed (static method/field calls), the *type* `JavaObject{T}` itself
is passed.

A finalizer calls `deleteref`, which releases the underlying JNI reference (via
`DeleteLocalRef` / `DeleteGlobalRef`) on a JVM-attached thread — so Java's GC
cannot collect the object while a live `JavaObject` exists. Aliases for common
classes: [`JObject`](@ref) and friends.
"""
mutable struct JavaObject{T} <: JNI.AbstractJavaRef
    ref::JavaRef

    #This below is ugly. Once we stop supporting 0.5, this can be replaced by
    # function JavaObject{T}(ptr) where T
    function JavaObject{T}(ref) where T
        j = new{T}(ref)
        finalizer(deleteref, j)
        return j
    end

    #replace with: JavaObject{T}(argtypes::Tuple, args...) where T
    JavaObject{T}(argtypes::Tuple, args...) where {T} = jnew(T, argtypes, args...)
end

# JavaObject Construction
JavaObject(ptr) = JObject(ptr)
JavaObject(T, ptr) = JavaObject{T}(ptr)
JavaObject{T}() where {T} = JavaObject{T}((),)
JavaObject{T}(ptr::Ptr{Nothing}) where {T} = JavaObject{T}(JavaLocalRef(ptr))

# JavaObject Reference Management
ref(x::JavaObject{T}) where T = x.ref
copyref(x::JavaObject{T}) where T = JavaObject{T}(JavaLocalRef(x.ref))
deleteref(x::JavaObject{T}) where T = ( deleteref(x.ref); x.ref = J_NULL )

# Obtain the underlying pointer for a JavaObject
Ptr(x::JavaObject{T}) where T = Ptr(x.ref)
Ptr{Nothing}(x::JavaObject{T}) where T = Ptr(x.ref)

"""
    jglobal(x::JavaObject)

Promote `x` to a long-lived reference: replace its inner [`JavaRef`](@ref) with a
freshly-created [`JavaGlobalRef`](@ref) and delete the prior (typically local)
ref. Use for `JavaObject`s that must remain valid across JNI frames or be passed
between OS threads.
"""
function jglobal(x::JavaObject)
    with_env() do env
        gref = JavaGlobalRef(JNI.NewGlobalRef(Ptr(x), env))
        deleteref(x.ref)
        x.ref = gref
    end
end

"""
```
isnull(obj::JavaObject)
```
Checks if the passed JavaObject is null or not

### Args
* obj: The object of type JavaObject

### Returns
true if the passed object is null else false
"""
isnull(obj::JavaObject) = Ptr(obj) == C_NULL
isnull(obj::Ptr{Nothing}) = obj == C_NULL

"""
```
isnull(obj::JavaMetaClass)
```
Checks if the passed JavaMetaClass is null or not

### Args
* obj: The object of type JavaMetaClass

### Returns
true if the passed object is null else false
"""
isnull(obj::JavaMetaClass) = Ptr(obj) == C_NULL

macro checknull(expr, msg="")
    if expr isa Expr && expr.head == :call
        jnifun = "$(expr.args[1])"
        quote
            local ptr = $(esc(expr))
            if isnull(ptr) && geterror() === nothing
                throw(JavaCallError("JavaCall."*$jnifun*": "*$(esc(msg))))
            end
            ptr
        end
    else
        quote
            local ptr = $(esc(expr))
            if isnull(ptr) && geterror() === nothing
                throw(JavaCallError($(esc(msg))))
            end
            ptr
        end
    end
end

function checknull(ptr, msg="Unexpected null pointer from Java Native Interface", jnifun=nothing)
    if isnull(ptr) && geterror() === nothing
        if jnifun === nothing
            throw(JavaCallError(msg))
        else
            throw(JavaCallError("JavaCall.JNI.$jnifun: $msg"))
        end
    end
    ptr
end

"""
    JObject, JClass, JString, JMethod, JConstructor, JField, JThread, JClassLoader,
    JList, JArrayList, JMap, JHashMap, JSet, JHashSet, JCollection, JIterator,
    JIterable, JComparator, JNumber, JBoolean, JByte, JCharacter, JShort, JInteger,
    JLong, JFloat, JDouble, JCharSequence, JThrowable, JException, JRunnable, JFile,
    JInputStream, JOutputStream, JReader, JWriter, JDate, JCalendar, JProperties

Convenience aliases for [`JavaObject{T}`](@ref) over commonly-used Java classes —
e.g. `JString === JavaObject{Symbol("java.lang.String")}`, `JArrayList ===
JavaObject{Symbol("java.util.ArrayList")}`. They are used pervasively as
return-type / argument-type arguments to [`jcall`](@ref) and as the first
argument to [`jnew`](@ref).
"""
const JClass = JavaObject{Symbol("java.lang.Class")}
const JObject = JavaObject{Symbol("java.lang.Object")}
const JMethod = JavaObject{Symbol("java.lang.reflect.Method")}
const JConstructor = JavaObject{Symbol("java.lang.reflect.Constructor")}
const JField = JavaObject{Symbol("java.lang.reflect.Field")}
const JThread = JavaObject{Symbol("java.lang.Thread")}
const JClassLoader = JavaObject{Symbol("java.lang.ClassLoader")}
const JString = JavaObject{Symbol("java.lang.String")}

# Phase 3 sub-2: broader set of built-in JavaObject{Symbol("…")} aliases for the
# most-common Java standard-library classes. Each is exported from JavaCall.

# Collections / util
const JList       = JavaObject{Symbol("java.util.List")}
const JArrayList  = JavaObject{Symbol("java.util.ArrayList")}
const JMap        = JavaObject{Symbol("java.util.Map")}
const JHashMap    = JavaObject{Symbol("java.util.HashMap")}
const JSet        = JavaObject{Symbol("java.util.Set")}
const JHashSet    = JavaObject{Symbol("java.util.HashSet")}
const JCollection = JavaObject{Symbol("java.util.Collection")}
const JIterator   = JavaObject{Symbol("java.util.Iterator")}
const JComparator = JavaObject{Symbol("java.util.Comparator")}

# Boxed primitives
const JNumber    = JavaObject{Symbol("java.lang.Number")}
const JBoolean   = JavaObject{Symbol("java.lang.Boolean")}
const JByte      = JavaObject{Symbol("java.lang.Byte")}
const JCharacter = JavaObject{Symbol("java.lang.Character")}
const JShort     = JavaObject{Symbol("java.lang.Short")}
const JInteger   = JavaObject{Symbol("java.lang.Integer")}
const JLong      = JavaObject{Symbol("java.lang.Long")}
const JFloat     = JavaObject{Symbol("java.lang.Float")}
const JDouble    = JavaObject{Symbol("java.lang.Double")}

# java.lang misc
const JIterable     = JavaObject{Symbol("java.lang.Iterable")}
const JCharSequence = JavaObject{Symbol("java.lang.CharSequence")}
const JThrowable    = JavaObject{Symbol("java.lang.Throwable")}
const JException    = JavaObject{Symbol("java.lang.Exception")}
const JRunnable     = JavaObject{Symbol("java.lang.Runnable")}

# IO
const JFile         = JavaObject{Symbol("java.io.File")}
const JInputStream  = JavaObject{Symbol("java.io.InputStream")}
const JOutputStream = JavaObject{Symbol("java.io.OutputStream")}
const JReader       = JavaObject{Symbol("java.io.Reader")}
const JWriter       = JavaObject{Symbol("java.io.Writer")}

# Util extras
const JDate       = JavaObject{Symbol("java.util.Date")}
const JCalendar   = JavaObject{Symbol("java.util.Calendar")}
const JProperties = JavaObject{Symbol("java.util.Properties")}

#JavaObject(ptr::Ptr{Nothing}) = ptr == C_NULL ? JavaObject(ptr) : JavaObject{Symbol(getclassname(getclass(ptr)))}(ptr)

function JString(str::AbstractString)
    with_env() do env
        JString(env, str)
    end
end

function JString(env::Ptr{JNI.JNIEnv}, str::AbstractString)
    jstring = @checknull JNI.NewStringUTF(String(str), env)
    return JString(jstring)
end

# Encode Julia values into a JValue (the C jvalue union). The function
# name is lowercase `jvalue` to match the C convention; the type name is
# `JValue` (CamelCase Julia primitive type).
jvalue(v::Integer)::JNI.JValue = JNI.JValue(Int64(v))
# Use UInt32 (zero-extension to Int64) rather than Int32 (sign-extension)
# so the high 4 bytes of the 8-byte jvalue slot are clean. Currently
# harmless on every Julia-supported architecture (all little-endian, where
# the JVM reads jfloat from bytes 0-3).
jvalue(v::Float32)::JNI.JValue = JNI.JValue(Int64(reinterpret(UInt32, v)))
jvalue(v::Float64)::JNI.JValue = JNI.JValue(reinterpret(Int64, v))
jvalue(v::Ptr)::JNI.JValue = JNI.JValue(Int64(UInt(v)))
jvalue(v::JavaObject) = jvalue(Ptr(v))


function _jimport(juliaclass)
    for str ∈ [" ", "(", ")"]
        juliaclass = replace(juliaclass, str=>"")
    end
    :(JavaObject{Symbol($juliaclass)})
end

# === @jimport multi-import helpers (Phase 3 sub-2) =========================
#
# Background on AST shapes Julia's parser produces (verified via `dump`):
#
#   @jimport java.util: ArrayList
#       Expr(:call, :(:), :(java.util), :ArrayList)
#
#   @jimport java.util: ArrayList, HashMap, Map
#       Expr(:tuple,
#            Expr(:call, :(:), :(java.util), :ArrayList),  # colon binds tightly
#            :HashMap,
#            :Map)
#
#   @jimport java.util: ArrayList => JAL, HashMap
#       Expr(:tuple,
#            Expr(:call, :(=>),
#                 Expr(:call, :(:), :(java.util), :ArrayList),
#                 :JAL),
#            :HashMap)
#
#   @jimport (java.util.ArrayList, java.lang.System)
#       Expr(:tuple,
#            Expr(:., :(java.util), QuoteNode(:ArrayList)),
#            Expr(:., :(java.lang), QuoteNode(:System)))
#
# So a `:tuple` may be either the colon form (first element carries the
# `Expr(:call, :(:), prefix, _)` either directly or wrapped in `=>`) or the
# tuple form (each element is a dotted FQN or `FQN => Target`).
# `_colon_split_first` performs that disambiguation: it returns
# `(prefix, normalized_entries)` if the head is colon-form, or
# `(nothing, _)` if it's tuple-form.

# Try to extract the colon prefix out of the first tuple element. Returns
# `(prefix, entries)` on a colon-form match (entries is the input list with
# the prefix peeled from the first element), or `(nothing, args)` otherwise.
function _colon_split_first(args)
    isempty(args) && return (nothing, args)
    head = args[1]
    # `prefix : Name` directly as the first element
    if head isa Expr && head.head === :call && length(head.args) == 3 &&
       head.args[1] === :(:)
        prefix = head.args[2]
        first_entry = head.args[3]
        return (prefix, Any[first_entry, args[2:end]...])
    end
    # `prefix : Name => Target` wraps the colon-call in an `=>` call
    if head isa Expr && head.head === :call && length(head.args) == 3 &&
       head.args[1] === :(=>)
        lhs = head.args[2]
        if lhs isa Expr && lhs.head === :call && length(lhs.args) == 3 &&
           lhs.args[1] === :(:)
            prefix = lhs.args[2]
            short = lhs.args[3]
            target = head.args[3]
            # Re-fold the first entry as `short => target` (without the colon prefix)
            rebuilt = Expr(:call, :(=>), short, target)
            return (prefix, Any[rebuilt, args[2:end]...])
        end
    end
    return (nothing, args)
end

# Colon form emitter. `entries` are the body entries with the colon prefix
# already stripped (each is either a Symbol or `Name => Target` Expr).
function _jimport_colon(prefix, entries)
    pkg = sprint(Base.show_unquoted, prefix)
    isempty(entries) && error("@jimport: empty colon-form import list.")
    assignments = Any[]
    for entry in entries
        short, target = _parse_short_entry(entry)
        fqn = string(pkg, ".", short)
        push!(assignments, :($(esc(target)) = JavaObject{Symbol($fqn)}))
    end
    push!(assignments, :(nothing))   # the block evaluates to `nothing`
    return Expr(:block, assignments...)
end

# Parse one entry of a colon-form body — either `Name` or `Name => Target`.
# Returns (short::Symbol, target::Symbol). Errors on anything else.
function _parse_short_entry(entry)
    if entry isa Symbol
        return (entry, entry)
    end
    if entry isa Expr && entry.head === :call && length(entry.args) == 3 &&
       entry.args[1] === :(=>) && entry.args[2] isa Symbol && entry.args[3] isa Symbol
        return (entry.args[2], entry.args[3])
    end
    error("@jimport: expected `Name` or `Name => Target` after `:`, got `$entry`.")
end

# Tuple form emitter. Each entry is a dotted FQN Expr, a bare Symbol (no
# package), or `FQN => Target`.
function _jimport_tuple(entries)
    isempty(entries) && error("@jimport: empty tuple-form import list.")
    assignments = Any[]
    for entry in entries
        fqn_expr, target = _parse_tuple_entry(entry)
        fqn = sprint(Base.show_unquoted, fqn_expr)
        push!(assignments, :($(esc(target)) = JavaObject{Symbol($fqn)}))
    end
    push!(assignments, :(nothing))
    return Expr(:block, assignments...)
end

# Parse one entry of a tuple-form import — either a dotted FQN Expr (or bare
# Symbol for an unpackaged class), or `FQN => Target`. Returns
# `(fqn_expression, target::Symbol)`. Errors otherwise.
function _parse_tuple_entry(entry)
    if entry isa Symbol
        return (entry, entry)
    end
    if entry isa Expr && entry.head === :.
        target = _last_dotted_segment(entry)
        return (entry, target)
    end
    if entry isa Expr && entry.head === :call && length(entry.args) == 3 &&
       entry.args[1] === :(=>)
        entry.args[3] isa Symbol ||
            error("@jimport: rename target (right-hand side of `=>`) must be a Symbol, got `$(entry.args[3])`.")
        lhs = entry.args[2]
        (lhs isa Symbol || (lhs isa Expr && lhs.head === :.)) ||
            error("@jimport: rename source must be a fully-qualified class expression, got `$lhs`.")
        return (lhs, entry.args[3])
    end
    error("@jimport: tuple entries must be `FQN` or `FQN => Target`, got `$entry`.")
end

# `Expr(:., :(java.util), QuoteNode(:ArrayList))` -> `:ArrayList`.
function _last_dotted_segment(expr::Expr)
    expr.head === :. || error("@jimport: expected a dotted expression, got `$expr`.")
    last = expr.args[2]
    last isa QuoteNode && (last = last.value)
    last isa Symbol || error("@jimport: cannot derive a short name from `$expr`.")
    return last
end

"""
    @jimport class                                # returns the JavaObject{Symbol(class)} type
    @jimport package: Class                       # binds `Class = JavaObject{Symbol("package.Class")}`
    @jimport package: A, B => JB, C               # multi-bind with optional `=>` rename
    @jimport (pkg1.A, pkg2.B => JB)               # tuple form (cross-package), `=>` rename optional

Bring Java class types into the local / module scope.

**Single-class form** (the original): `@jimport java.util.ArrayList` returns the
type `JavaObject{Symbol("java.util.ArrayList")}` as an expression value. `class`
may be a dotted expression, a symbol, a string, or the nested-class escape
`@jimport(Outer\$Inner)`.

**Multi-import (colon form):** `@jimport java.util: ArrayList, HashMap, Map`
binds three locals at the expansion site — equivalent to three single-class
`@jimport` statements. Use `=>` to rename: `@jimport java.util: ArrayList =>
JArrayList`. (`=>` is the standard `Pair` operator; `as` would not parse outside
of `using/import` clauses.)

**Multi-import (tuple form):** `@jimport (java.util.ArrayList, java.lang.System)`
binds each by the FQN's last segment; cross-package is allowed in one call.
Renames work the same way: `@jimport (java.util.ArrayList => JArrayList)`.
A one-element tuple `@jimport (java.util.ArrayList,)` is a multi-import of one
(binds `ArrayList`); the un-tupled `@jimport java.util.ArrayList` (no trailing
comma) keeps the single-class semantics of returning the type.

In every form, JavaCall already ships built-in aliases for the standard
library's most-common classes (`JList`, `JArrayList`, `JMap`, `JHashMap`,
`JInteger`, `JRunnable`, `JFile`, and more — see the [`JObject`](@ref) block) so
the common cases need no `@jimport` at all.

A macro-expansion-time `error(...)` is raised on a malformed multi-import:
non-Symbol rename target, empty colon-form import list, non-FQN tuple entry,
etc.
"""
macro jimport(class::Expr)
    # Colon form (single name): `@jimport package: Name`
    #   parses as Expr(:call, :(:), prefix, entry)
    if class.head === :call && length(class.args) == 3 && class.args[1] === :(:)
        return _jimport_colon(class.args[2], Any[class.args[3]])
    end
    # Colon form (single rename): `@jimport package: Name => Target`
    #   `=>` is right-associative and binds looser than the `:` call here, so
    #   the whole expression is `Expr(:call, :(=>), Expr(:call, :(:), prefix,
    #   Name), Target)`. We peel off the outer `=>` and feed the rebuilt
    #   `Name => Target` to the colon path.
    if class.head === :call && length(class.args) == 3 && class.args[1] === :(=>)
        lhs = class.args[2]
        if lhs isa Expr && lhs.head === :call && length(lhs.args) == 3 &&
           lhs.args[1] === :(:)
            prefix = lhs.args[2]
            short  = lhs.args[3]
            target = class.args[3]
            return _jimport_colon(prefix, Any[Expr(:call, :(=>), short, target)])
        end
    end
    # Colon form (multi-name) or tuple form: both parse as Expr(:tuple, ...).
    # Disambiguate by looking at the first element — if it carries an
    # `Expr(:call, :(:), prefix, first)` (possibly wrapped in `=>`), it's
    # the colon form spliced across a `,`; otherwise it's the tuple form.
    if class.head === :tuple
        prefix, entries = _colon_split_first(class.args)
        if prefix !== nothing
            return _jimport_colon(prefix, entries)
        end
        return _jimport_tuple(class.args)
    end
    # Single-class form (unchanged): a dotted FQN expression / nested-class
    # escape / etc.
    juliaclass = sprint(Base.show_unquoted, class)
    _jimport(juliaclass)
end
macro jimport(class::Symbol)
    juliaclass = string(class)
    _jimport(juliaclass)
end
macro jimport(class::AbstractString)
    _jimport(class)
end

const primitive_names_to_types = Dict(
    :boolean => jboolean,
    :byte    => jbyte,
    :char    => jchar,
    :short   => jshort,
    :int     => jint,
    :long    => jlong,
    :float   => jfloat,
    :double  => jdouble,
    :void    => jvoid
)
jimport(juliaclass::Symbol) = juliaclass == :void ? Nothing :
    haskey(primitive_names_to_types, juliaclass) ? jimport(juliaclass, Val(true), Val(false)) : JavaObject{juliaclass}
jimport(juliaclass::Symbol, isprimitive::Val{false}, isarray::Val{false}) = jimport(juliaclass)
jimport(juliaclass::Symbol, isprimitive::Val{true},  isarray::Val{false}) = primitive_names_to_types[juliaclass]

jimport(juliaclass::String, args...) = isarray(juliaclass) ? Vector{ jimport(Symbol(juliaclass[1:end-2])) } : jimport(Symbol(juliaclass), args...)

function jimport(juliaclass::JClass)
    jimport(juliaclass, Val(isprimitive(juliaclass)), Val(isarray(juliaclass)))
end
function jimport(juliaclass::JClass, isprimitive, isarray::Val{true})
    elementType = jimport( jcall(juliaclass, "getComponentType", JClass) )
    Vector{elementType}
end
jimport(juliaclass::JClass, isprimitive, isarray::Val{false}) = jimport(getname(juliaclass), isprimitive, isarray)

isprimitive(juliaclass::JClass) = jcall(juliaclass, "isPrimitive", jboolean, ()) == 0x01
isarray(juliaclass::JClass) = jcall(juliaclass, "isArray", jboolean, ()) == 0x01
isarray(juliaclass::String) = endswith(juliaclass, "[]")

"""
    jnew(T::Symbol, argtypes::Tuple = (), args...)

Construct a new Java object of class `T` (a fully-qualified class name symbol) by
invoking the constructor whose parameter types match `argtypes`, passing `args`.
Returns a [`JavaObject{T}`](@ref). Usually reached via the `JavaObject{T}(argtypes,
args...)` constructor rather than called directly.
"""
function jnew(T::Symbol, argtypes::Tuple = (), args...)
    assertloaded()
    with_env() do env
        jmethodId = _cached_method_id(env, T, "<init>", Nothing, argtypes, false)
        _jcall(env, metaclass(env, T), jmethodId, JavaObject{T}, argtypes, args...; callmethod=JNI.NewObjectA)
    end
end

"""
    jnew(T::Type{<:JavaObject}, args...)

Resolved-overload form of [`jnew`](@ref): constructs a `T` by picking the
constructor that best matches the Julia types of `args` — see [`resolve_call`](@ref)
— and delegating to the explicit `T(argtypes::Tuple, args...)` machinery. Java
varargs constructors are spread automatically. Throws `JavaCallError` on an
ambiguous match or no match. For a pinned constructor use
`T((ArgTypes...,), args...)` / `jnew(:fqn, (ArgTypes...,), args...)`.
"""
function jnew(::Type{JavaObject{T}}, args...) where {T}
    assertloaded()
    r = resolve_call(JavaObject{T}, _CONSTRUCTOR, args)
    callargs = r.varargs ? _pack_varargs(r, args) : args
    # The fixed param types, plus the trailing Vector{eltype} for a varargs ctor —
    # matching the shape of `callargs`.
    paramtypes = r.varargs ? (r.paramtypes..., Vector{r.vararg_eltype}) : r.paramtypes
    return jnew(T, paramtypes, callargs...)
end

_jcallable(typ::Type{JavaObject{T}}) where T = metaclass(T)
function _jcallable(obj::JavaObject)
    isnull(obj) && throw(JavaCallError("Attempt to call method on Java NULL"))
    obj
end

"""
    jcall(receiver, method::AbstractString, rettype::Type, (argtypes...,), args...)
    jcall(receiver, method::JMethod, args...)

Call a Java method, modelled on Julia's `ccall`. `receiver` is either a
[`JavaObject`](@ref) instance (instance method) or a `JavaObject{T}` *type*
(static method). `method` is the method name (and `rettype` / `argtypes` pin the
overload and JNI signature) or a reflected [`JMethod`](@ref) (which carries its
own types). `args` are converted to the declared `argtypes` (see `convert.jl`),
the call is made on the current OS thread's `JNIEnv*`, and the result is converted
back to `rettype`. A pending Java exception is raised as a `JavaCallError`.
"""
function jcall(ref, method::AbstractString, rettype::Type, argtypes::Tuple = (), args...)
    assertloaded()
    with_env() do env
        jmethodId = get_method_id(env, ref, method, rettype, argtypes)
        _jcall(env, _jcallable(ref), jmethodId, rettype, argtypes, args...)
    end
end

function jcall(ref, method::JMethod, args...)
    assertloaded()
    with_env() do env
        jmethodId = get_method_id(env, method)
        rettype = jimport(getreturntype(method))
        argtypes = Tuple(jimport.(getparametertypes(method)))
        _jcall(env, _jcallable(ref), jmethodId, rettype, argtypes, args...)
    end
end

"""
    jcall(receiver, method::AbstractString, args...)

Resolved-overload form of [`jcall`](@ref): picks the Java overload of `method` on
`receiver` (a [`JavaObject`](@ref) instance, or a `@jimport`ed `JavaObject{T}`
*type* for a static method) that best matches the Julia types of `args` — see
[`resolve_call`](@ref) — dispatches it, and post-processes the result: `void` →
`nothing`; a `java.lang.String` return → a Julia `String` (a `null` String as
`""`, matching JavaCall's existing behavior); any other object return →
[`narrow`](@ref)ed to its runtime class; primitives unchanged. A null reference
return becomes `nothing` (except a declared-`String` return, which becomes `""`
per JavaCall's existing convention). Java varargs are spread automatically
(pass a single `AbstractVector` to forward an array directly). Throws
`JavaCallError` on an ambiguous match or no match. For a pinned overload /
return type, or in a hot loop, use the explicit
`jcall(receiver, method, RetType, (ArgTypes...,), args...)` form.
"""
function jcall(receiver, method::AbstractString, args...)
    assertloaded()
    r = resolve_call(receiver, method, args)
    callargs = r.varargs ? _pack_varargs(r, args) : args
    # argtypes are re-derived inside jcall(_, ::JMethod, _...) from the cached JMethod; r.paramtypes is only used on the jnew path
    result = jcall(receiver, r.member::JMethod, callargs...)   # reuse the existing JMethod-dispatch path
    return _resolved_result(r.rettype, result)
end

# Pack the trailing args of a varargs call into a Vector of the declared element
# type. If the caller already passed a single trailing AbstractVector, forward it
# as-is rather than double-wrapping. Empty varargs → an empty Vector{eltype}.
# r is a ResolvedCall (untyped here because core.jl is included before overload.jl defines ResolvedCall)
function _pack_varargs(r, args)
    fixed = args[1:r.n_fixed]
    rest  = args[(r.n_fixed + 1):end]
    arr = if length(rest) == 1 && rest[1] isa AbstractVector
        rest[1]
    elseif isempty(rest)
        r.vararg_eltype[]
    else
        collect(r.vararg_eltype, rest)
    end
    return (fixed..., arr)
end

# Post-process a resolved call's result for the ergonomic form:
# `void` → `nothing`; primitives pass through; a `JString` rettype → Julia `String`
# (a null String becomes `""`, matching JavaCall's existing behavior); any other
# `JavaObject` rettype → [`narrow`](@ref)ed to its runtime class (a null reference
# returns `nothing`). When narrowing produces a `JString` we decode it to Julia
# `String` (so e.g. `List.get` — declared `Object` — yields a Julia `String` when
# it actually holds one).
function _resolved_result(rettype::Type, x)
    rettype === Nothing && return nothing
    rettype === JString && return x                # already a Julia String
    if rettype <: JavaObject
        isnull(x) && return nothing                # Java null reference -> Julia nothing
        n = narrow(x)
        return n isa JString ? (isnull(n) ? "" : unsafe_string(n)) : n
    end
    return x
end

function get_method_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    _cached_method_id(env, T, method, rettype, argtypes, true)
end

function get_method_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject{T}, method::AbstractString, rettype::Type, argtypes::Tuple) where T
    _cached_method_id(env, T, method, rettype, argtypes, false)
end

get_method_id(env::Ptr{JNI.JNIEnv}, method::JMethod) = @checknull JNI.FromReflectedMethod(Ptr(method), env)

# JMethod invoke
(m::JMethod)(obj, args...) = jcall(obj, m, args...)


"""
    jfield(ref, field, [fieldType])

Get a pointer to a field of of a Java class or object.
* `ref` could be a JavaObject{T} type or a JavaObject
* `field` can be an AbstractString or JField
* `fieldType` is a Type
"""
function jfield(ref, field, fieldType)
    assertloaded()
    with_env() do env
        jfieldID = get_field_id(env, ref, field, fieldType)
        _jfield(env, _jcallable(ref), jfieldID, fieldType)
    end
end

function jfield(ref, field)
    assertloaded()
    with_env() do env
        fieldType = jimport(gettype(field))
        jfieldID = get_field_id(env, ref, field, fieldType)
        _jfield(env, _jcallable(ref), jfieldID, fieldType)
    end
end

function jfield(ref, field::AbstractString)
    assertloaded()
    with_env() do env
        field = listfields(ref, field)[]
        fieldType = jimport(gettype(field))
        jfieldID = get_field_id(env, ref, field)
        _jfield(env, _jcallable(ref), jfieldID, fieldType)
    end
end

jfield(ref, field::Symbol) = jfield(ref, String(field))

function get_field_id(env::Ptr{JNI.JNIEnv}, typ::Type{JavaObject{T}}, field::AbstractString, fieldType::Type) where T
    @checknull JNI.GetStaticFieldID(Ptr(metaclass(env, T)), String(field), signature(fieldType), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::Type{JavaObject{T}}, field::JField) where T
    @checknull JNI.FromReflectedField(field, env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::Type{JavaObject{T}}, field::JField, fieldType::Type) where T
    @checknull JNI.FromReflectedField(field, env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::AbstractString, fieldType::Type)
    @checknull JNI.GetFieldID(Ptr(metaclass(env, obj)), String(field), signature(fieldType), env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::JField, fieldType::Type)
    @checknull JNI.FromReflectedField(field, env)
end

function get_field_id(env::Ptr{JNI.JNIEnv}, obj::JavaObject, field::JField)
    @checknull JNI.FromReflectedField(field, env)
end

# JField invoke
(f::JField)(obj) = jfield(obj, f)

for (x, name) in [(:(<:Any),  :Object),
                  (:jboolean, :Boolean),
                  (:jchar,    :Char   ),
                  (:jbyte,    :Byte   ),
                  (:jshort,   :Short  ),
                  (:jint,     :Int    ),
                  (:jlong,    :Long   ),
                  (:jfloat,   :Float  ),
                  (:jdouble,  :Double ),
                  (:jvoid,    :Void   )]
    for (t, callprefix, getprefix) in [
        (:JavaObject,    :Call, :Get ),
        (:JavaMetaClass, :CallStatic, :GetStatic )
    ]
        callmethod = :(JNI.$(Symbol(callprefix, name, :MethodA)))
        fieldmethod = :(JNI.$(Symbol(getprefix, name, :Field)))
        m = quote
            function _jfield(env::Ptr{JNI.JNIEnv}, obj::T, jfieldID::Ptr{Nothing}, fieldType::Type{$x}) where T <: $t
                result = $fieldmethod(Ptr(obj), jfieldID, env)
                geterror(env)
                return convert_result(env, fieldType, result)
            end
            function _jcall(env::Ptr{JNI.JNIEnv}, obj::T, jmethodId::Ptr{Nothing}, rettype::Type{$x},
                            argtypes::Tuple, args...; callmethod=$callmethod) where T <: $t
                savedArgs, convertedArgs = convert_args(env, argtypes, args...)
                GC.@preserve obj savedArgs convertedArgs begin
                    result = callmethod(Ptr(obj), jmethodId, Array{JNI.JValue}(jvalue.(convertedArgs)), env)
                end
                cleanup_arg.(convertedArgs)
                geterror(env)
                return convert_result(env, rettype, result)
            end
        end
        eval(m)
    end
end

cleanup_arg(arg) = nothing

# cleanup_arg runs inside _jcall on the same JVM-attached thread that just
# made the call, so it can free the local ref synchronously rather than
# routing through the dispatch task. The dispatch route is reserved for
# *finalizers*, which can fire on any thread (including Julia GC threads
# that are not JVM-attached). Routing cleanup_arg through the channel
# instead caused a real OOM regression: tight `for i in 1:N` loops over
# `jcall(..., big_array)` would accumulate N un-freed Java arrays before
# the cooperative scheduler ran the dispatch task.
function cleanup_arg(arg::JavaObject)
    ref = arg.ref
    ref.ptr == C_NULL && return
    JNI.is_env_loaded() || return
    with_env() do env
        if ref isa JavaLocalRef
            JNI.DeleteLocalRef(ref.ptr, env)
        elseif ref isa JavaGlobalRef
            JNI.DeleteGlobalRef(ref.ptr, env)
        end
    end
    arg.ref = J_NULL
    return
end

const _jmc_cache_lock = ReentrantLock()
const _jmc_cache_v2 = Dict{Symbol, JavaMetaClass}()

struct MethodKey
    class::Symbol
    name::Symbol
    signature::String
end

const _method_id_cache = Dict{MethodKey, Ptr{Nothing}}()
const _method_id_cache_lock = ReentrantLock()

function _cached_method_id(env::Ptr{JNI.JNIEnv}, class_sym::Symbol, name::AbstractString,
                           rettype::Type, argtypes::Tuple, isstatic::Bool)
    sig = method_signature(rettype, argtypes...)
    key = MethodKey(class_sym, Symbol(name), sig)
    lock(_method_id_cache_lock) do
        get!(_method_id_cache, key) do
            mc = metaclass(env, class_sym)
            jnifun = isstatic ? JNI.GetStaticMethodID : JNI.GetMethodID
            @checknull jnifun(Ptr(mc), String(name), sig, env) "Problem getting method id for $class_sym.$name $sig"
        end
    end
end

function _metaclass(env::Ptr{JNI.JNIEnv}, class::Symbol)
    jclass = javaclassname(class)
    jclassptr = @checknull JNI.FindClass(jclass, env)
    # FindClass returns a local ref; promote to a global ref so the cache
    # entry survives PopLocalFrame and outlives the caller's frame.
    globalptr = JNI.NewGlobalRef(jclassptr, env)
    JNI.DeleteLocalRef(jclassptr, env)
    return JavaMetaClass{class}(JavaGlobalRef(globalptr))
end

"""
    metaclass(class)
    metaclass(env, class)

Return the cached [`JavaMetaClass`](@ref) (JNI `jclass` handle) for `class` — a
fully-qualified class-name `Symbol`, a `JavaObject{T}` / `Type{JavaObject{T}}`, or
an `AbstractVector` type. Lookups are memoized process-wide in `_jmc_cache_v2`
under `_jmc_cache_lock`; the no-`env` form fetches the current thread's
`JNIEnv*` via `with_env`.
"""
function metaclass(env::Ptr{JNI.JNIEnv}, class::Symbol)
    lock(_jmc_cache_lock) do
        get!(_jmc_cache_v2, class) do
            _metaclass(env, class)
        end
    end
end

# Convenience: fetch env on demand if caller did not pass one.
metaclass(class::Symbol) = with_env() do env
    metaclass(env, class)
end

metaclass(env::Ptr{JNI.JNIEnv}, ::Type{JavaObject{T}}) where {T} = metaclass(env, T)
metaclass(env::Ptr{JNI.JNIEnv}, ::JavaObject{T}) where {T} = metaclass(env, T)
metaclass(env::Ptr{JNI.JNIEnv}, ::Type{T}) where T <: AbstractVector = metaclass(env, Symbol(JavaCall.signature(T)))

# Backwards-compat single-arg forms
metaclass(::Type{JavaObject{T}}) where {T} = metaclass(T)
metaclass(::JavaObject{T}) where {T} = metaclass(T)
metaclass(::Type{T}) where T <: AbstractVector = metaclass( Symbol( JavaCall.signature(T) ) )

javaclassname(class::Symbol) = replace(string(class), "."=>"/")
javaclassname(class::AbstractString) = replace(class, "."=>"/")
javaclassname(::Type{T}) where T <: AbstractVector = JavaCall.signature(T)

function _notnull_assert(ptr)
    isnull(ptr) && throw(JavaCallError("Java Exception thrown, but no details could be retrieved from the JVM"))
end

function get_exception_string(env::Ptr{JNI.JNIEnv}, jthrow)
    jthrowable = JNI.FindClass("java/lang/Throwable", env)
    _notnull_assert(jthrowable)
    res = C_NULL
    try
        tostring_method = JNI.GetMethodID(jthrowable, "toString", "()Ljava/lang/String;", env)
        _notnull_assert(tostring_method)
        res = JNI.CallObjectMethodA(jthrow, tostring_method, JNI.JValue[], env)
        _notnull_assert(res)
        # Use the Ptr{Nothing} overload of unsafe_string to copy out the
        # UTF-8 chars without wrapping res in a JString JavaObject — that
        # would attach a finalizer racing with the eager DeleteLocalRef
        # below.
        return unsafe_string(env, res)
    finally
        # Eagerly free both local refs. A long exception-handling loop
        # would otherwise exhaust the JNI local ref table waiting on
        # Julia GC of the (no longer created) JString wrapper.
        res != C_NULL && JNI.DeleteLocalRef(res, env)
        JNI.DeleteLocalRef(jthrowable, env)
    end
end

function geterror(env::Ptr{JNI.JNIEnv})
    isexception = JNI.ExceptionCheck(env)

    if isexception == JNI_TRUE
        jthrow = JNI.ExceptionOccurred(env)
        _notnull_assert(jthrow)
        try
            JNI.ExceptionDescribe(env) #Print java stackstrace to stdout

            msg = get_exception_string(env, jthrow)
            throw(JavaCallError(string("Error calling Java: ", msg)))
        finally
            JNI.ExceptionClear(env)
            JNI.DeleteLocalRef(jthrow, env)
        end
    end
end

# Backwards-compatible no-arg form
geterror() = with_env() do env
    geterror(env)
end

"""
    is_virtual_thread(thread::JavaObject{Symbol("java.lang.Thread")}) -> Bool

Return true if the given Thread is a virtual thread (JEP 444, JDK 21+).
On JVMs older than JDK 21, virtual threads don't exist; this helper
feature-detects via JNI.GetVersion() and returns false rather than
calling the (potentially garbage) IsVirtualThread function pointer.

Why GetVersion and not a C_NULL check on JNI.jniref[].IsVirtualThread?
The JNINativeInterface struct is sized at compile time (234 slots,
incl. IsVirtualThread). On a JDK <21 JVM the table is only 233 slots
long, so reading the IsVirtualThread slot reads adjacent memory that
may contain non-NULL garbage. GetVersion is reliably present
everywhere from JNI 1.1 onward and returns the JVM's actual JNI
version, making the feature check authoritative.
"""
function is_virtual_thread(thread::JavaObject{Symbol("java.lang.Thread")})
    with_env() do env
        version = JNI.GetVersion(env)
        version < JNI.JNI_VERSION_21 && return false
        result = ccall(JNI.jniref[].IsVirtualThread, Cuchar,
                       (Ptr{JNI.JNIEnv}, Ptr{Nothing}),
                       env, Ptr(thread))
        return result == 0x01
    end
end

"""
    method_signature(rettype, argtypes...) -> String

Build the JNI method type descriptor for a method with the given return and
argument types, e.g. `method_signature(jint, JString, jdouble) == "(Ljava/lang/String;D)I"`.
Uses [`signature`](@ref) per type. Used to look up `jmethodID`s.
"""
function method_signature(rettype, argtypes...)
    s=IOBuffer()
    write(s, "(")
    for arg in argtypes
        write(s, signature(arg))
    end
    write(s, ")")
    write(s, signature(rettype))
    return String(take!(s))
end

"""
    signature(T) -> String

The JNI field type descriptor for a Julia-side type `T`: `"I"` for `jint`, `"D"`
for `jdouble`, `"Ljava/lang/String;"` for [`JString`](@ref), `"[I"` for
`Vector{jint}`, and so on. See also [`method_signature`](@ref).
"""
signature(::Type{jboolean}) = "Z"
signature(::Type{jbyte}) = "B"
signature(::Type{jchar}) = "C"
signature(::Type{jshort}) = "S"
signature(::Type{jint}) = "I"
signature(::Type{jlong}) = "J"
signature(::Type{jfloat}) = "F"
signature(::Type{jdouble}) = "D"
signature(::Type{jvoid}) = "V"
signature(::Type{Array{T,N}}) where {T,N} = string("[" ^ N, signature(T))
signature(arg::Type{JavaObject{T}}) where {T} = string("L", javaclassname(T), ";")
signature(arg::Type{JavaObject{T}}) where {T <: AbstractVector} = JavaCall.javaclassname(T)

