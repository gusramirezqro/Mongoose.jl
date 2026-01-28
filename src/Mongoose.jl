module Mongoose

using Mongoose_jll
using Libc

export AsyncServer, SyncServer, Request, Response, start!, shutdown!, route!, deserialize, serialize
export @get, @post, serve, start_async

include("wrappers.jl")
include("structs.jl")
include("routes.jl")
include("events.jl")
include("servers.jl")
include("registry.jl")

const VALID_METHODS = Set([:get, :post, :put, :patch, :delete])

"""
    route!(server::Server, method::Symbol, path::String, handler::Function)
    Registers an HTTP request handler for a specific method and URI.
    # Arguments
    - `server::Server`: The server to register the handler with.
    - `method::Symbol`: The HTTP method (e.g., :get, :post, :put, :patch, :delete).
    - `path::AbstractString`: The URI path to register the handler for (e.g., "/api/users").
    - `handler::Function`: The Julia function to be called when a matching request arrives.
    This function should accept a `Request` object as its first argument, followed by any additional keyword arguments.
"""
function route!(server::Server, method::Symbol, path::AbstractString, handler::Function)
    if method ∉ VALID_METHODS
        error("Invalid HTTP method: $method")
    end
    if !occursin(':', path)
        if !haskey(server.router.fixed, path)
            server.router.fixed[path] = Fixed()
        end
        server.router.fixed[path].handlers[method] = handler
        return server
    end
    segments = eachsplit(path, '/'; keepempty=false)
    node = server.router.node
    for seg in segments
        if startswith(seg, ':')
            param = seg[2:end]
            # Create or validate dynamic child
            if (dyn = node.dynamic) === nothing
                dyn = Node()
                dyn.param = param
                node.dynamic = dyn
            elseif dyn.param != param
                error("Parameter conflict: :$param vs existing :$(dyn.param)")
            end
            node = dyn
        else
            # Static segment
            if (child = get(node.static, seg, nothing)) === nothing
                child = Node()
                node.static[seg] = child
            end
            node = child
        end
    end
    # Attach handler at final node
    node.handlers[method] = handler
    return server
end

# --- 6. Server Management ---
"""
    start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=false)

    Starts the Mongoose HTTP server. Initialize the Mongoose manager, binds an HTTP listener, and starts a background Task to poll the Mongoose event loop.

    Arguments
    - `server::Server`: The server object to start.
    - `host::AbstractString="127.0.0.1"`: The IP address or hostname to listen on. Defaults to "127.0.0.1" (localhost).
    - `port::Integer=8080`: The port number to listen on. Defaults to 8080.
    - `blocking::Bool=true`: If true, blocks until the server is stopped. If false, runs the server in a non-blocking mode.
"""
function start!(server::Server; host::AbstractString="127.0.0.1", port::Integer=8080, blocking::Bool=true)
    if server.running
        @info "Server already running. Nothing to do."
        return
    end
    @info "Starting server..."
    server.running = true
    try
        register!(server)
        setup_resources!(server)
        setup_listener!(server, host, port)
        start_workers!(server)
        start_master!(server)
        blocking && run_blocking!(server)
    catch e
        shutdown!(server)
        rethrow(e)
    end
    return
end

"""
    shutdown!(server::Server)
    Stops the running Mongoose HTTP server. Sets a flag to stop the background event loop task, and then frees the Mongoose associated resources.
    Arguments
    - `server::Server`: The server object to shutdown.
"""
function shutdown!(server::Server)
    if !server.running
        @info "Server not running. Nothing to do."
        return
    end
    @info "Stopping server..."
    server.running = false
    stop_workers!(server)
    stop_master!(server)
    free_resources!(server)
    unregister!(server)
    @info "Server stopped successfully."
    return
end

# --- New Architecture (Oxygen-like) ---

const GLOBAL_MANAGER_REF = Ref{Ptr{Cvoid}}(C_NULL)

function get_global_manager()
    if GLOBAL_MANAGER_REF[] == C_NULL
        ptr = Libc.malloc(Csize_t(128))
        ptr == C_NULL && error("Failed to allocate manager memory")
        mg_mgr_init!(ptr)
        GLOBAL_MANAGER_REF[] = ptr
    end
    return GLOBAL_MANAGER_REF[]
end

macro get(path, func)
    return quote
        key = "GET " * $path
        Mongoose.ROUTER[key] = $func
    end
end

macro post(path, func)
    return quote
        key = "POST " * $path
        Mongoose.ROUTER[key] = $func
    end
end

function serve(; port="8000")
    mgr = get_global_manager()
    # Internal handler is defined in events.jl
    handler_c = @cfunction(internal_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    mg_http_listen(mgr, "http://0.0.0.0:"*port, handler_c, C_NULL)

    # Infinite Loop (Blocking)
    while true
        mg_mgr_poll(mgr, 1000)
    end
end

function start_async(; port="8000")
    # Run the C-Loop on a background thread so the REPL remains active
    errormonitor(Threads.@spawn begin
        mgr = get_global_manager()
        handler_c = @cfunction(internal_event_handler, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
        mg_http_listen(mgr, "http://0.0.0.0:"*port, handler_c, C_NULL)
        while true
            mg_mgr_poll(mgr, 1000)
        end
    end)
end

end
