# Maybe another name and add handle_request functions
function build_request(conn::Ptr{Cvoid}, ev_data::Ptr{Cvoid})
    id = Int(conn)
    msg_ptr = Ptr{MgHttpMessage}(ev_data)
    payload = build_request(msg_ptr)
    return IdRequest(id, payload)
end

function select_server(conn::Ptr{Cvoid})
    fn_data = mg_conn_get_fn_data(conn)
    id = UInt(fn_data)
    return REGISTRY[id]
end

function sync_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    # ev != MG_EV_POLL && @info "Event: $ev (Raw), Conn: $conn, EvData: $ev_data"
    ev == MG_EV_HTTP_MSG || return
    server = select_server(conn)
    request = build_request(conn, ev_data)
    handle_request(conn, server, request)
    return
end

function async_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    ev == MG_EV_POLL && return
    server = select_server(conn)
    ev == MG_EV_CLOSE && return cleanup_connection(conn, server)
    if ev == MG_EV_HTTP_MSG
        request = build_request(conn, ev_data)
        handle_request(conn, server, request)
    end
    return
end

# The "Bridge" - Single Global C-Callback
function internal_event_handler(conn::Ptr{Cvoid}, ev::Cint, ev_data::Ptr{Cvoid})
    if ev == MG_EV_HTTP_MSG
        # A. Wrap the C data
        msg_ptr = Ptr{MgHttpMessage}(ev_data)
        req = build_request(msg_ptr)

        # B. Construct the lookup key (e.g., "GET /data")
        route_key = "$(req.method) $(req.uri)"

        # C. Dispatch
        if haskey(ROUTER, route_key)
            user_func = ROUTER[route_key]

            # D. Execute User Logic
            response_body = user_func(req)

            # E. Reply (Standardized)
            # Assuming JSON as per spec, but could be customizable in future
            mg_http_reply(conn, 200, "Content-Type: application/json\r\n", string(response_body))
        else
            # 404 Handler
            mg_http_reply(conn, 404, "", "Not Found")
        end
    end
end
