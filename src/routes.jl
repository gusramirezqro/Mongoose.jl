abstract type Route end

mutable struct Node <: Route
    static::Dict{String,Node}                # static children
    dynamic::Union{Nothing,Node}             # parameter child
    param::Union{Nothing,String}             # parameter name
    handlers::Dict{Symbol,Function}          # HTTP verb → handler
    Node() = new(Dict{String,Node}(), nothing, nothing, Dict{Symbol,Function}())
end

struct Fixed <: Route
    handlers::Dict{Symbol,Function}
    Fixed() = new(Dict{Symbol,Function}())
end

struct Router
    node::Node
    fixed::Dict{String,Fixed}
    Router() = new(Node(), Dict{String,Fixed}())
end

struct Matched
    handler::Dict{Symbol,Function}
    params::Dict{String,String}
end

function match_route(router::Router, method::Symbol, path::AbstractString)
    # Check fixed routes first
    if (route = get(router.fixed, path, nothing)) !== nothing
        return Matched(route.handlers, Dict{String,String}())
    end
    # Check dynamic routes
    segments = split(path, '/'; keepempty=false)
    params = Dict{String,String}()
    sizehint!(params, 4)
    return _match(router.node, segments, 1, method, params)
end

@inline function _match(node::Node, segments::Vector{<:AbstractString}, idx::Integer, method::Symbol, params::Dict{String,String})
    # Base case: reached end of path
    if idx > length(segments)
        return isempty(node.handlers) ? nothing : Matched(node.handlers, params)
    end
    seg = segments[idx]
    next_idx = idx + 1
    # Try static first
    if (static_node = get(node.static, seg, nothing)) !== nothing
        result = _match(static_node, segments, next_idx, method, params)
        result !== nothing && return result
    end
    # Try dynamic
    if (dyn = node.dynamic) !== nothing
        param_name = dyn.param
        had_value = haskey(params, param_name)
        old_value = had_value ? params[param_name] : ""
        params[param_name] = seg
        result = _match(dyn, segments, next_idx, method, params)
        result !== nothing && return result
        # Backtrack
        had_value ? (params[param_name] = old_value) : delete!(params, param_name)
    end
    return nothing
end

function execute_handler(router::Router, request::IdRequest)
    # Convert string method to symbol for backward compatibility with existing Router
    method_sym = Symbol(lowercase(request.payload.method))

    if (matched = match_route(router, method_sym, request.payload.uri)) === nothing
        return IdResponse(request.id, Response(404, "Content-Type: text/plain\r\n", "404 Not Found"))
    end
    if (handler = get(matched.handler, method_sym, nothing)) === nothing
        return IdResponse(request.id, Response(405, "Content-Type: text/plain\r\n", "405 Method Not Allowed"))
    end
    try
        return IdResponse(request.id, handler(request.payload, matched.params))
    catch e
        @error "Route handler failed to execute" exception = (e, catch_backtrace())
        return IdResponse(request.id, Response(500, "Content-Type: text/plain\r\n", "500 Internal Server Error"))
    end
end
