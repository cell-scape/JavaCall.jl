"""
    @jcall receiver.method(arg::ArgType, ...)::RetType   # fully-annotated (explicit)
    @jcall receiver.method(args...)                       # annotation-free (resolved)

`ccall`-style sugar for [`jcall`](@ref). Two forms are accepted:

- **Fully-annotated** — every argument has a `::Type` annotation **and** the call
  has a `::RetType` trailer. Lowers verbatim to the explicit
  `jcall(receiver, "method", RetType, (ArgType,...), args...)` form (zero runtime
  overload-resolution overhead). The receiver may be a dotted chain (resolved
  through [`jfield`](@ref)), e.g.
  `@jcall System.getProperty("os.name"::JString)::JString`.

- **Annotation-free** — *no* `::Type` annotations on any arg **and** *no*
  `::RetType`. Lowers to the resolved `jcall(receiver, "method", args...)` form,
  which picks the Java overload from `args`' Julia types via
  [`resolve_call`](@ref) and narrows the result (object → runtime class,
  `java.lang.String` → Julia `String`, `void` → `nothing`). Examples:
  `@jcall al.add("one")`, `@jcall al.size()`, `@jcall JMath.abs(Int32(-5))`,
  `@jcall System.getProperty("java.version")`. Static calls through an
  `@jimport`ed class type (`@jcall JMath.abs(x)`) use the same lowering — the
  resolved `jcall` dispatches static-vs-instance automatically from `typeof(receiver)`.

- **Mixed** — some args annotated and some not, OR a `::RetType` but at least
  one un-annotated arg, OR at least one annotated arg without a `::RetType` —
  is rejected at **macro-expansion time** with
  `error("@jcall: annotate all arguments and the return type, or none — use jcall(...) directly for partial cases.")`.
  A zero-argument call is never "mixed": annotation-free iff no `::RetType`,
  fully-annotated iff a `::RetType` is given.

See `test/jcall_macro.jl` for the full grammar (varargs, static vs instance,
`\$`-interpolated method names).
"""
macro jcall(expr)
    return jcall_macro_lower(jcall_macro_parse(expr)...)
end

function jcall_macro_lower(func, rettype, types, args)
    @debug "args: " func rettype types args
    # Classify annotation mode. `rettype === nothing` means no `::RetType`; a
    # `nothing` entry in `types` means the corresponding arg was un-annotated.
    has_ret = rettype !== nothing
    n       = length(args)
    n_typed = count(t -> t !== nothing, types)
    if n == 0
        # zero-arg call: explicit iff a rettype is given, annotation-free otherwise.
        # Never "mixed".
        mode = has_ret ? :explicit : :resolved
    elseif has_ret && n_typed == n
        mode = :explicit
    elseif !has_ret && n_typed == 0
        mode = :resolved
    else
        error("@jcall: annotate all arguments and the return type, or none — use jcall(...) directly for partial cases.")
    end

    jargs = Expr(:tuple, esc.(args)...)
    if func isa Expr
        @debug "func" func.head func.args
        obj = resolve_dots(func.args[2])
        f = string(func.args[1].value)
        if mode === :explicit
            jtypes = Expr(:tuple, esc.(types)...)
            jret = esc(rettype)
            return :(jcall($(esc(obj)), $f, $jret, $jtypes, ($jargs)...))
        else
            return :(jcall($(esc(obj)), $f, ($jargs)...))
        end
    elseif func isa QuoteNode
        if mode === :explicit
            jtypes = Expr(:tuple, esc.(types)...)
            return :($(esc(func.value))($jtypes, ($jargs)...))
        else
            # Bare-Symbol call — historically used for constructor invocation via
            # `JavaObject{T}(argtypes, args...)`. In annotation-free mode dispatch
            # through the resolved `jnew(T, args...)` form (M2) instead.
            return :(jnew($(esc(func.value)), ($jargs)...))
        end
    end
end

function resolve_dots(obj)
    if obj isa Expr && obj.head == :.
        return :(jfield($(resolve_dots(obj.args[1])), string($(obj.args[2]))))
    else
        return obj
    end
end

# @jcall implementation, based on Base.@ccall
"""
    jcall_macro_parse(expression)

`jcall_macro_parse` is an implementation detail of `@jcall`.
It accepts both annotation-free and fully-annotated call syntax and returns
`(func, rettype, types, args)` where:
- `func` is a `QuoteNode` (bare-symbol call) or a 2-element `Expr` capturing
  the dotted receiver chain + method name.
- `rettype` is the `::RetType` expression, or `nothing` if no return-type
  annotation was given.
- `types` is a `Vector` whose i-th entry is the `::Type` expression for the
  i-th positional arg, or `nothing` if that arg was not annotated.
- `args` is the `Vector` of positional argument expressions (annotations stripped).

Examples (head only, of the input):
- `:(System.out.println("Hello"::JString)::Nothing)` → `(.., :Nothing, [:JString], ["Hello"])`
- `:(al.add("x"))` (annotation-free) → `(.., nothing, [nothing], ["x"])`
- `:(al.size())` (annotation-free zero-arg) → `(.., nothing, [], [])`
- `:(al.get(0)::JString)` (mixed — rettype only) → `(.., :JString, [nothing], [0])` — and
  `jcall_macro_lower` then errors on the mixed form.

Detecting "mixed" is left to the caller (`jcall_macro_lower`) — this parser is
permissive so the lower can produce a single, unified error message.
"""
function jcall_macro_parse(expr::Expr)
    # A bare call like `al.size()` has head `:call`; a call with `::RetType`
    # has head `:(::)` and `args[1]` is the call.
    if Meta.isexpr(expr, :(::))
        rettype = expr.args[2]
        call = expr.args[1]
    elseif Meta.isexpr(expr, :call)
        rettype = nothing
        call = expr
    else
        throw(ArgumentError("@jcall expects a function call, optionally annotated with `::RetType`"))
    end

    if !Meta.isexpr(call, :call)
        throw(ArgumentError("@jcall has to take a function call"))
    end

    # get the function symbols
    func = let f = call.args[1]
        if Meta.isexpr(f, :.)
            :(($(f.args[2]), $(f.args[1])))
        elseif Meta.isexpr(f, :$)
            f
        elseif f isa Symbol
            QuoteNode(f)
        else
            throw(ArgumentError("@jcall function name must be a symbol or a `.` node (e.g. `System.out.println`)"))
        end
    end

    # detect varargs
    varargs = nothing
    argstart = 2
    callargs = call.args
    if length(callargs) >= 2 && Meta.isexpr(callargs[2], :parameters)
        argstart = 3
        varargs = callargs[2].args
    end

    # collect args and types; un-annotated args contribute `nothing` to `types`
    args = []
    types = []

    function pusharg!(arg)
        if Meta.isexpr(arg, :(::))
            push!(args, arg.args[1])
            push!(types, arg.args[2])
        else
            push!(args, arg)
            push!(types, nothing)
        end
    end

    for i in argstart:length(callargs)
        pusharg!(callargs[i])
    end

    return func, rettype, types, args
end

