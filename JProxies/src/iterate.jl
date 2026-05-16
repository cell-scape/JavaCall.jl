# JProxy iteration — Base.iterate / length / eltype / IteratorSize.
#
# Strategy is decided once on the first iteration call (state === nothing) by
# reflecting on the wrapped Java object's runtime class:
#   1. array         → :prim_array or :obj_array
#   2. Iterator      → step `w` directly as the iterator
#   3. Map           → call w.entrySet().iterator(), step it, yield Pair{Any,Any}
#   4. Iterable      → call w.iterator(), step it, yield each elem
#   5. otherwise     → ArgumentError
#
# State shape encodes the strategy + the live handle:
#   (:iter,       iter::JavaObject)                           # Iterable & raw-Iterator paths
#   (:map_iter,   iter::JavaObject)                           # iterator of an entrySet()
#   (:prim_array, jnivec::JNIVector, len::Int, i::Int)        # i is the next 0-based index
#   (:obj_array,  arr::JavaObject,    len::Int, i::Int)
#
# Local-ref lifetime: this code runs from regular Julia tasks, NOT from a
# RegisterNatives upcall — so JNI local refs created by next() /
# GetObjectArrayElement persist past the call and are freed when the wrapping
# JavaObject is finalized. For very large iterations callers can wrap the loop
# in jlocalframe.
#
# Primitive-array path: `JNIVector{T}(ptr)` takes ownership of the ref (its
# finalizer calls DeleteLocalRef via deleteref). The JProxy-wrapped JavaObject
# already owns the raw array ref, so we MUST give the JNIVector its own fresh
# local ref via JNI.NewLocalRef — otherwise both finalizers would delete the
# same ref, corrupting the JVM.

"""
    Base.iterate(jp::JProxy)
    Base.iterate(jp::JProxy, state)

Iterate a `JProxy` wrapping a Java `Iterable`, `Collection`, `Set`, `List`, `Map`,
Java array, or raw `Iterator`. Each yielded element is run through `_juliafy`:
narrowed to its runtime class, then `JString`s decode to Julia `String`s and
boxed primitives unbox to `jint`/`jdouble`/etc. For `Map`, yields Julia
`Pair{Any,Any}` so `for (k, v) in JProxy(jmap) … end` destructures cleanly.
Throws `ArgumentError` if the wrapped object isn't one of the supported shapes.
"""
function Base.iterate(jp::JProxy{T, W}) where {T, W<:JavaObject}
    w = unwrap(jp)
    isnull(w) && throw(ArgumentError("JProxy iteration on a Java null reference"))
    cls = getclass(w)
    if isarray(cls)
        return _start_array(w, cls)
    elseif isConvertible(JIterator, w)
        return _step((:iter, w))
    elseif isConvertible(JMap, w)
        entrySet = jcall(w, "entrySet", JSet, ())
        return _step((:map_iter, jcall(entrySet, "iterator", JIterator, ())))
    elseif isConvertible(JIterable, w)
        return _step((:iter, jcall(w, "iterator", JIterator, ())))
    else
        throw(ArgumentError("JProxy iteration: $(getname(cls)) is neither an array, an Iterable, a Map, nor an Iterator"))
    end
end

Base.iterate(jp::JProxy{T, W}, state) where {T, W<:JavaObject} = _step(state)

# java.util.Map.Entry — used to resolve getKey()/getValue() statically when
# iterating an entrySet() (whose iterator's next() returns Object; we cast it
# to Map.Entry so the method-lookup against the Entry interface succeeds).
const JMapEntry = JavaObject{Symbol("java.util.Map\$Entry")}

# :iter and :map_iter share the (Symbol, JavaObject) shape.
function _step(state::Tuple{Symbol, JavaObject})
    iter = state[2]
    if jcall(iter, "hasNext", jboolean, ()) == 0x01
        if state[1] === :map_iter
            # Iterator.next() returns Object; reinterpret as Map.Entry to resolve
            # getKey()/getValue() against the Entry interface.
            obj = jcall(iter, "next", JObject, ())
            entry = convert(JMapEntry, obj)
            k = _juliafy(jcall(entry, "getKey",   JObject, ()))
            v = _juliafy(jcall(entry, "getValue", JObject, ()))
            return (k => v, state)
        else
            obj = jcall(iter, "next", JObject, ())
            return (_juliafy(obj), state)
        end
    else
        return nothing
    end
end

# Array detection — dispatch on the component type's primitive-vs-reference.
function _start_array(w::JavaObject, cls::JClass)
    component = jcall(cls, "getComponentType", JClass, ())
    len = JavaCall.with_env() do env
        Int(JNI.GetArrayLength(Ptr(w), env))
    end
    if isprimitive(component)
        # The component's getName() returns "int" / "double" / etc. — map to the
        # JNI primitive Julia type via JavaCall's primitive_names_to_types table.
        comp_name = getname(component)
        elty = primitive_names_to_types[Symbol(comp_name)]
        # JNIVector{T}(ptr) wraps the ptr in a JavaLocalRef whose finalizer
        # DeleteLocalRefs it. `w` already owns its own ref, so we MUST give the
        # JNIVector a fresh local ref to avoid double-free on the same handle.
        # `get_elements!` (the JavaCall-internal helper used by convert_result)
        # pins the array and populates `.arr` via Get<Primitive>ArrayElements;
        # without it `getindex(jnivec, i)` would error on a `nothing` `.arr`.
        fresh_ptr = JavaCall.with_env() do env
            JNI.NewLocalRef(Ptr(w), env)
        end
        jnivec = JavaCall.get_elements!(JNIVector{elty}(fresh_ptr))
        return _step((:prim_array, jnivec, len, 0))
    else
        return _step((:obj_array, w, len, 0))
    end
end

# :prim_array — index a JNIVector{T}; T elements come out already-unboxed.
function _step(state::Tuple{Symbol, JNIVector, Int, Int})
    sym, jnivec, len, i = state
    i >= len && return nothing
    return (jnivec[i+1], (sym, jnivec, len, i+1))
end

# :obj_array — JNI.GetObjectArrayElement per index; wrap + _juliafy.
function _step(state::Tuple{Symbol, JavaObject, Int, Int})
    sym, arr, len, i = state
    i >= len && return nothing
    elem = JavaCall.with_env() do env
        ptr = JNI.GetObjectArrayElement(Ptr(arr), jint(i), env)
        ptr == C_NULL ? nothing : JObject(JavaLocalRef(ptr))
    end
    return (_juliafy(elem), (sym, arr, len, i+1))
end

"""
    Base.length(jp::JProxy)

Return the size of a `JProxy` wrapping a Java array, `Collection`, or `Map`.
Throws `ArgumentError` for any wrapped class that doesn't expose a size (raw
`Iterator`s and bare `Iterable`s that aren't `Collection`s).
"""
function Base.length(jp::JProxy{T, W}) where {T, W<:JavaObject}
    w = unwrap(jp)
    cls = getclass(w)
    if isarray(cls)
        return JavaCall.with_env() do env
            Int(JNI.GetArrayLength(Ptr(w), env))
        end
    elseif isConvertible(JCollection, w)
        return Int(jcall(w, "size", jint, ()))
    elseif isConvertible(JMap, w)
        return Int(jcall(w, "size", jint, ()))
    else
        throw(ArgumentError("JProxy: length not defined for $(getname(cls)) (no .size() and not an array)"))
    end
end

Base.eltype(::Type{<:JProxy}) = Any
Base.IteratorSize(::Type{<:JProxy}) = Base.SizeUnknown()
