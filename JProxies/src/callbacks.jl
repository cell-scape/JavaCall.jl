# Julia-implements-a-Java-interface. `@jproxy` fills `_proxy_method_table` at
# module-load time (no runtime `eval`). `jproxy(value, iface)` builds the Java
# `Proxy` and returns a `JProxyRef` that keeps the handler registration alive.

"""
    @jproxy YourType "java.fully.qualified.Interface" begin
        function methodName(self, args...) ... end
        otherMethod(self) = ...
    end

Register each `function` / short-form definition in the block as the Julia
implementation of the like-named interface method for `YourType`. Lowers to plain
assignments into `_proxy_method_table` (precompile-friendly; no runtime `eval`).
The first parameter (`self`) receives the Julia value later passed to
`jproxy(self, iface)`.
"""
macro jproxy(T, iface, block)
    Meta.isexpr(block, :block) || error("@jproxy: third argument must be a begin…end block")
    assigns = Expr[]
    for stmt in block.args
        stmt isa LineNumberNode && continue
        # Accept `function name(args...) body end` and `name(args...) = body`,
        # and rewrite each to an *anonymous* function so we never (re)define a
        # top-level binding named after the method (which would clash with
        # `Base.run`, `Base.size`, …).
        local sig, body
        if Meta.isexpr(stmt, :function) && length(stmt.args) == 2
            sig, body = stmt.args[1], stmt.args[2]
        elseif Meta.isexpr(stmt, :(=)) && Meta.isexpr(stmt.args[1], :call) && length(stmt.args) == 2
            sig, body = stmt.args[1], stmt.args[2]
        else
            error("@jproxy: each entry must be a method definition, got: $stmt")
        end
        Meta.isexpr(sig, :call) || error("@jproxy: malformed method signature: $sig")
        fname = sig.args[1]
        fname isa Symbol || error("@jproxy: method name must be a plain symbol, got: $fname")
        params = sig.args[2:end]                    # the argument list, incl. `self`
        anon = Expr(:function, Expr(:tuple, params...), body)
        push!(assigns, quote
            $(_proxy_method_table)[($(esc(T)), $(QuoteNode(fname)))] = $(esc(anon))
        end)
    end
    quote
        $(assigns...)
        nothing
    end
end

"""
    JProxyRef{T}

Owns a registered callback handler. While alive the Julia value is reachable from
`_proxy_registry` (so it is not GC'd) and the Java `Proxy` object is held. A
`JProxyRef` is substitutable for the underlying `JavaObject` anywhere `jcall` /
`jnew` expect one. On finalization it unregisters the handler; the wrapped
`JavaObject`'s own finalizer releases the JNI ref.
"""
mutable struct JProxyRef{T}
    obj::JavaObject{T}
    handler_id::Int64
    function JProxyRef{T}(obj::JavaObject{T}, hid::Int64) where {T}
        j = new{T}(obj, hid)
        finalizer(x -> _unregister_handler!(x.handler_id), j)
        return j
    end
end

convert(::Type{JavaObject{T}}, jp::JProxyRef{T}) where {T} = jp.obj
convert(::Type{JavaObject{T}}, jp::JProxyRef{S}) where {T, S} = convert(JavaObject{T}, jp.obj)
Base.unsafe_convert(::Type{Ptr{Nothing}}, jp::JProxyRef) = JavaCall.Ptr(jp.obj)
JavaCall.Ptr(jp::JProxyRef) = JavaCall.Ptr(jp.obj)
JavaCall.isnull(jp::JProxyRef) = JavaCall.isnull(jp.obj)
show(io::IO, jp::JProxyRef{T}) where {T} = print(io, "JProxyRef{", T, "}(handler=", jp.handler_id, ")")

"""
    jproxy(value, interface::AbstractString) -> JProxyRef

Create a Java object implementing `interface` (a fully-qualified name, possibly a
nested class written with `\$`) whose methods invoke the `@jproxy`-registered
implementations for `typeof(value)`, executed on JavaCall's dispatch task.
"""
function jproxy(value, interface::AbstractString)
    _ensure_native_registered()
    any(k -> k[1] === typeof(value), keys(_proxy_method_table)) ||
        throw(JProxiesError("no @jproxy methods registered for $(typeof(value))"))
    id = _register_handler!(value)
    try
        ifacecls = classforname(interface)
        JClassLoader = @jimport java.lang.ClassLoader
        loader = jcall(ifacecls, "getClassLoader", JClassLoader, ())
        if isnull(loader)
            loader = jcall(JClassLoader, "getSystemClassLoader", JClassLoader, ())
        end
        JHandler = @jimport "org.juliainterop.JavaCallInvocationHandler"
        proxyobj = jcall(JHandler, "newProxy", JObject,
                         (jlong, JClassLoader, JClass), id, loader, ifacecls)
        # JavaCall does not checkcast; `narrow` would yield the runtime class
        # ($Proxy0). Reinterpret the ref under the declared interface type so the
        # object dispatches correctly when passed to `jcall`.
        T = Symbol(interface)
        typedobj = JavaObject{T}(proxyobj.ref)
        proxyobj.ref = JavaCall.J_NULL   # transfer ownership of the ref to typedobj
        return JProxyRef{T}(typedobj, id)
    catch err
        _unregister_handler!(id)
        rethrow(err)
    end
end
