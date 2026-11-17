import MsgPack
import UUIDs: UUID
import HTTP
import Sockets
import .PkgCompat

_browser_os() = Sys.isapple() ? :apple : (Sys.iswindows() || detectwsl()) ? :windows : Sys.islinux() ? :linux : :unknown

"""
The command that opens `url` in the default browser, or `nothing` where we know of none.

Never `cmd /c start` on Windows: cmd.exe splits a command line at `&`, and Julia only quotes arguments
that contain spaces, so `cmd /c start "" http://…/edit?id=…&secret=…` opened the page WITHOUT its
secret (and ran `secret=…` as a command). PowerShell gets the URL as one single-quoted string, where
`&` is literal and a `'` is written `''`.
"""
function default_browser_cmd(url::AbstractString; os::Symbol=_browser_os())
    if os === :apple
        `open $url`
    elseif os === :windows
        quoted = "'" * replace(url, "'" => "''") * "'"
        `powershell.exe Start $quoted`
    elseif os === :linux
        `xdg-open $url`
    else
        nothing
    end
end

"""
Open `url` in the default browser; `false` when there is no opener for this OS or it could not be
started. With `wait=false` the opener is only spawned: some `xdg-open` backends run the browser in
the foreground and return when it closes, which must not hold up a caller like an HTTP handler.
"""
function open_in_default_browser(url::AbstractString; wait::Bool=true)::Bool
    cmd = default_browser_cmd(url)
    cmd === nothing && return false
    try
        Base.run(pipeline(cmd; stdin=devnull, stdout=devnull, stderr=devnull); wait)
        true
    catch ex
        false
    end
end

function swallow_exception(f, exception_type::Type{T}) where {T}
    try
        f()
    catch e
        isa(e, T) || rethrow(e)
    end
end

"""
    Pluto.run()

Start Pluto!

## Keyword arguments
You can configure some of Pluto's more technical behaviour using keyword arguments, but this is mostly meant to support testing and strange setups like Docker. If you want to do something exciting with Pluto, you can probably write a creative notebook to do it!

    Pluto.run(; kwargs...)

For the full list, see the [`Pluto.Configuration`](@ref) module. Some **common parameters**:

- `launch_browser`: Optional. Whether to launch the system default browser. Disable this on SSH and such.
- `host`: Optional. The default `host` is `"127.0.0.1"`. For wild setups like Docker and heroku, you might need to change this to `"0.0.0.0"`.
- `port`: Optional. The default `port` is `1234`.
- `auto_reload_from_file`: Reload when the `.jl` file is modified. The default is `false`.

## Technobabble

This will start the static HTTP server and a WebSocket server. The server runs _synchronously_ (i.e. blocking call) on `http://[host]:[port]/`.
Pluto notebooks can be started from the main menu in the web browser.
"""
function run(; kwargs...)
    options = Configuration.from_flat_kwargs(; kwargs...)
    run(options)
end

function run(options::Configuration.Options)
    session = ServerSession(; options)
    run(session)
end

const is_first_run = Ref(true)

"Return a port and serversocket to use while taking into account the `favourite_port`."
function port_serversocket(hostIP::Sockets.IPAddr, favourite_port, port_hint)
    if favourite_port === nothing
        port = UInt16(port_hint)
        while true
            try
                return port, listen_socket(hostIP, port)
            catch e
                port == typemax(UInt16) && rethrow(e)
                port += UInt16(1)
            end
        end
    else
        port = UInt16(favourite_port)
        serversocket = try
            listen_socket(hostIP, port)
        catch e
            error("Cannot listen on port $port. It may already be in use, or you may not have sufficient permissions. Use Pluto.run() to automatically select an available port.")
        end
        return port, serversocket
    end
end

struct RunningPlutoServer
    http_server
    on_shutdown::Function
    initial_registry_update_task::Task
end

function Base.close(ssc::RunningPlutoServer)
    # Disconnect clients and shut down notebooks first: closing the HTTP server
    # is graceful, i.e. it waits for the open (WebSocket) connections to finish.
    ssc.on_shutdown()
    close(ssc.http_server)
    wait(ssc.http_server)
    wait(ssc.initial_registry_update_task)
end

function Base.wait(ssc::RunningPlutoServer)
    try
        # create blocking call and switch the scheduler back to the server task, so that interrupts land there
        while isopen(ssc.http_server)
            sleep(.1)
        end
    catch e
        println()
        println()
        (e isa InterruptException) || rethrow(e)
    finally
        Base.close(ssc)
    end

    nothing
end

# Set once the server is listening, so a UI "Shut down" action can stop it without needing Ctrl+C
# in the launching terminal (the whole point: that terminal may be gone, or ssh'd away).
# Holds `(; http_server, on_shutdown)`: the same two things a `RunningPlutoServer` closes.
const RUNNING_HTTP_SERVER = Ref{Any}(nothing)

"""
Wrap the server's shutdown hook `f` (registry files, file helpers, remote tunnels, child workspace
servers, terminals, clients, notebooks) so that it runs exactly once, whoever asks for it and
however often. HTTP.jl is no longer given the hook (its `on_shutdown=` keyword is HTTP.jl 1 only),
so it runs where the server is closed:

- `Base.close(::RunningPlutoServer)`: a library launch's `close(server)`, and the `finally` of
  `Base.wait(::RunningPlutoServer)`, which is how Ctrl+C and the end of a CLI launch get here;
- `request_server_shutdown()`: the UI's `POST /api/v1/shutdown`.

Those overlap: a shutdown asked over HTTP closes the listen socket, which ends `wait`, which closes
the server again. A caller that arrives while the hook runs waits for it to finish, and one that
arrives afterwards returns at once. An error in the hook is logged and not thrown, as HTTP.jl did
with it, so that the HTTP server is closed and the port released all the same.
"""
function shutdown_hook_once(f::Function)
    guard = ReentrantLock()
    ran = Ref(false)
    function ()
        lock(guard) do
            ran[] && return nothing
            ran[] = true
            try
                f()
            catch e
                @error "SpaceStation: the shutdown hook failed" exception = (e, catch_backtrace())
            end
            nothing
        end
    end
end

"""
Stop the running SpaceStation server cleanly: run its shutdown hook (notebooks, registry file, and
the rest: see `shutdown_hook_once`), then close the HTTP server. Closing the listen socket unblocks
`wait(::RunningPlutoServer)`, so a CLI launch returns and the process exits; a library/REPL launch
simply returns from `run`. Done async so the caller (an HTTP handler) can finish responding first.
"""
function request_server_shutdown()
    srv = RUNNING_HTTP_SERVER[]
    srv === nothing && return
    @async swallow_exception(Exception) do
        # the same order as `Base.close(::RunningPlutoServer)`
        srv.on_shutdown()
        close(srv.http_server)
    end
end

"""
    run(session::ServerSession)

Specifiy the [`Pluto.ServerSession`](@ref) to run the web server on, which includes the configuration. Passing a session as argument allows you to start the web server with some notebooks already running. See [`SessionActions`](@ref) to learn more about manipulating a `ServerSession`.
"""
function run(session::ServerSession)
    Base.wait(run!(session))
end

"The SpaceStation integrated terminal: a raw PTY bridge, separate from the notebook protocol. Called for an authenticated websocket upgrade on `/terminal` (at the root, or under a hub's `/w/<id>/`)."
function serve_terminal_upgrade(http::HTTP.Stream, session::ServerSession, terminal_query)
    try
        HTTP.WebSockets.upgrade(http; WEBSOCKET_UPGRADE_KWARGS...) do clientstream
            HTTP.WebSockets.isclosed(clientstream) || handle_terminal_websocket(clientstream, session, terminal_query)
        end
    catch ex
        if !(ex isa InterruptException || ex isa HTTP.WebSockets.WebSocketError || is_disconnection_exception(ex))
            @warn "Terminal websocket connection failed" error = sprint(showerror, ex) # no backtrace: symbolicating one reads the depot (PinCode.jl)
        end
    end
    nothing
end

# On a remote machine a hub's runtime and its state live under /tmp on that machine (CollabRemote.jl),
# and a /tmp cleaner deletes what has not been read or changed for some days (systemd-tmpfiles: 10 on
# most clusters), file by file. A hub that lives longer than that would lose the sources its compiled
# caches are checked against (the next workspace server would not start), its own connection file (the
# next connect would not find it and would start a second hub) and the saved environment it gives to
# terminals. node/runtime.sh marks the runtime as read at every launch; this does the same, for the
# runtime and the node directory, for as long as the hub runs. The access time only: the caches are
# validated against modification times.
const NODE_FILES_FRESH_EVERY = 6 * 60 * 60 # seconds
node_dirs_to_keep_fresh() = filter(isdir, unique(filter(!isempty, [get(ENV, "SPACESTATION_RUNTIME_DIR", ""), get(ENV, "SPACESTATION_NODE_DIR", "")])))
freshen_command(dirs::Vector{String}) = `find $dirs -exec touch -a -c -h '{}' +`
function keep_node_files_fresh(; every::Real=NODE_FILES_FRESH_EVERY)
    dirs = node_dirs_to_keep_fresh()
    (isempty(dirs) || Sys.iswindows()) && return nothing
    Timer(every; interval=every) do _
        try
            Base.run(pipeline(ignorestatus(freshen_command(dirs)); stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
        catch
        end
    end
end

"""
Generate a middleware that records the `token` url parameter passed in by Binder,
so that it can be added to every URL that Pluto prints (and you can share that URL
to collaborate).
"""
function create_binder_token_middleware(session::ServerSession)
    function binder_token_middleware(handler)
        function (request::HTTP.Request)
            params = HTTP.queryparams(HTTP.URI(request.target))
            if haskey(params, "token") && params["token"] ∉ ("null", "undefined", "") && session.binder_token === nothing
                session.binder_token = params["token"]
            end
            handler(request)
        end
    end
end

"""
Middleware that turns an exception thrown while handling a request into a `500` error page,
and logs it. The details only go to the log, since the request might not be authenticated.
"""
function internal_error_middleware(handler)
    function (request::HTTP.Request)
        try
            handler(request)
        catch e
            @error "Failed to handle request" request.method path = HTTP.URI(request.target).path exception = (e, catch_backtrace())
            error_response(500, "Internal server error", "Pluto ran into an unexpected error while handling this request. The details are in the terminal where Pluto is running. Please <a href='https://github.com/JuliaPluto/Pluto.jl/issues'>report this error</a>!")
        end
    end
end

"Middleware that adds the headers that Pluto sets on every HTTP response."
function default_headers_middleware(handler)
    function (request::HTTP.Request)
        response = handler(request)
        set_content_length!(response)
        # https://github.com/fonsp/Pluto.jl/pull/722
        HTTP.setheader(response, "Referrer-Policy" => "same-origin")
        # https://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#:~:text=is%202%20minutes.-,14.38%20Server
        HTTP.setheader(response, "Server" => "Pluto.jl/$(PLUTO_VERSION_STR[2:end]) Julia/$(JULIA_VERSION_STR[2:end])")
        response
    end
end

function run!(session::ServerSession)
    # Before we spawn ANY notebook worker or integrated terminal, drop the Pkg-app launcher's
    # JULIA_LOAD_PATH pin so those children honor their own `--project=` / Pkg.activate instead of
    # inheriting SpaceStation's private app environment. (No-op for library use and SSH remotes; see
    # neutralize_app_load_path_pin!.)
    neutralize_app_load_path_pin!()
    if is_first_run[]
        is_first_run[] = false
        @info "Loading..."
    end
    if !session.options.security.require_secret_for_open_links
        @warn "Dangerous setting:\n\n\trequire_secret_for_open_links = false\n\nDo not use this setting on your own computer – it allows any website to run arbitrary code on your computer. Only use this on an isolated disposable server like Binder, or when using your own authentication layer."
    end
        
    warn_julia_compat()

    if session.options.server.hub
        session.options.server.workspace_folder === nothing || error("a workspace hub (hub=true) has no workspace of its own: it serves workspaces at /w/<id>/, each in a child server. Drop `workspace=` or `hub=true`.")
        session.options.server.notebook === nothing || error("a workspace hub (hub=true) cannot open notebooks itself: drop `notebook=` or `hub=true`.")
        ASSET_CACHE_ALL[] = true
        keep_node_files_fresh()
        if !PkgCompat.is_hub_process()
            @warn "SpaceStation: this hub was started without SPACESTATION_HUB=1 in its environment, so the package registries were parsed at import — set it in the launcher so the hub never touches the depot."
        end
    end
    pluto_router = http_router_for(session)
    store_session_middleware = create_session_context_middleware(session)
    store_binder_token_middleware = create_binder_token_middleware(session)
    app = pluto_router |> auth_middleware |> store_session_middleware |> store_binder_token_middleware |> internal_error_middleware |> default_headers_middleware
    # `HTTP.streamhandler` reads the request body, calls `app`, and writes the response.
    streamed_app = HTTP.streamhandler(app)

    let n = session.options.server.notebook
        SessionActions.open.((session,), 
            n === nothing ? [] : 
            n isa AbstractString ? [n] : 
            n;
            run_async=true,
        )
    end

    host = session.options.server.host
    hostIP = parse(Sockets.IPAddr, host)
    favourite_port = session.options.server.port
    port_hint = session.options.server.port_hint

    # Before the port is bound (a connect must be refused, not left hanging, while this reads a few
    # hundred MB on a cold node): the program's own pages must never be a read from a cluster
    # filesystem at the moment they run (PinCode.jl). A no-op off Linux and off network filesystems.
    keep_code_pinned!()
    local port, serversocket = port_serversocket(hostIP, favourite_port, port_hint)

    # remember the actual port (it may have been auto-chosen) so e.g. the connection file can be rewritten when the workspace changes at runtime
    session.options.server.port = port

    # connection file: lets external tools (e.g. coding agents) discover this server's port and secret.
    # Keep the path: the name carries the hostname, which can change while we run (VPN on/off), and
    # shutdown must remove the file we wrote, not the one today's hostname would name.
    # A hub and its helpers never symbolicate a backtrace: that reads the depot (PinCode.jl).
    (session.options.server.hub || is_file_helper_process()) && log_without_backtraces!()
    # A file helper (FileHelper.jl) is nobody's server but its hub's: it is not announced, and installs nothing.
    helper = is_file_helper_process()
    # A hub decides here, once, that it never touches the user's files in its own process; its file
    # helpers come up in the background, and until one answers those requests get 504 (FileHelper.jl).
    session.options.server.hub && !helper && start_file_helpers!()
    # before the secret is written anywhere or printed: a hub takes up the sign-in it had (Authentication.jl)
    session.options.server.hub && !helper && keep_sign_in!(session, port)
    # The copy for older clients goes into the shared home: a hub with helpers has a helper write it.
    registry_file = helper ? "" : write_collab_registry_file(session, port; announce_legacy=!file_helpers_active())
    file_helpers_active() && announce_legacy_via_helper(registry_file)
    if !helper
        # agent surface: put `pluto-collab` on PATH next to the app, and (opt-in) seed the workspace's AGENTS.md
        ensure_pluto_collab_installed()
        maybe_write_agents_md(session)
    end

    on_shutdown() = @sync begin
        # Called by `Base.close(::RunningPlutoServer)` before the HTTP server is closed, and by
        # `request_server_shutdown()`: through `shutdown_once` below, never directly.
        @info("\nClosing SpaceStation... Restart Julia for a fresh session. \n\nHave a nice day! 🎈🏝\n\n")
        try
            isfile(registry_file) && rm(registry_file)
        catch
        end
        if file_helpers_active()
            retract_legacy_via_helper(registry_file)
            remove_collab_registry_file(port)
        elseif !helper
            remove_collab_registry_file(port; legacy=true)
        end
        stop_file_helpers!()
        # tear down any SSH remote tunnels so the `ssh -N -L` children don't orphan onto the terminal
        try
            close_all_remote_tunnels()
        catch
        end
        # reap child workspace servers (also handles Ctrl-C / programmatic close; idempotent after serve_shutdown)
        try
            close_all_local_sessions()
        catch
        end
        # reap integrated-terminal shells — they're session leaders (SETSID) so they get no SIGHUP
        # from the dying server and would otherwise orphan onto init
        try
            close_all_terminals!()
        catch
        end
        # TODO: put do_work tokens back
        @async swallow_exception(() -> close(serversocket), Exception)
        for client in values(session.connected_clients)
            @async swallow_exception(() -> close(client.stream), Exception)
        end
        empty!(session.connected_clients)
        for nb in values(session.notebooks)
            @asynclog SessionActions.shutdown(session, nb; keep_in_session=false, async=false, verbose=false)
        end
    end

    # This hook has several callers (`shutdown_hook_once` lists them), and it must run exactly once.
    shutdown_once = shutdown_hook_once(on_shutdown)

    server = http_listen!(serversocket) do http::HTTP.Stream
        # A workspace served by this hub: `/w/<id>/…` (see Proxy.jl). The hub answers its own part of it
        # and relays the notebook part to the workspace's child server.
        # A file helper answers the handful of routes its hub forwards, and nothing else (FileHelper.jl).
        if is_file_helper_process() && !file_helper_serves(HTTP.URI(http.message.target).path)
            http.message.body = read(http)
            _write_response!(http, HTTP.Response(404, ["Content-Type" => "text/plain"], "not served by a file helper\n"))
            return
        end
        let ws = split_workspace_target(http.message.target; base_url=session.options.server.base_url)
            if ws !== nothing
                handle_workspace_request(http, session, app, ws[1], ws[2])
                return
            end
        end
        # the if statement below asks if the current request is a "websocket upgrade" request: the start of a websocket connection.
        if HTTP.WebSockets.isupgrade(http.message)
            secret_required = let
                s = session.options.security
                s.require_secret_for_access || s.require_secret_for_open_links
            end
            finish() = try
                HTTP.setstatus(http, 403)
                HTTP.startwrite(http)
                write(http, "Forbidden")
                HTTP.closewrite(http)
            catch e
                if !is_disconnection_exception(e)
                    rethrow(e)
                end
            end
            # A WebSocket handshake is a GET, so it slips past the HTTP CSRF guard in auth_middleware
            # — enforce the same-origin check here. This is the lever that closes cross-site
            # WebSocket hijacking of BOTH the notebook protocol (arbitrary cell execution) and the
            # /terminal shell bridge (arbitrary command execution): a page on another localhost port
            # is same-site for the cookie, but its Origin never matches our Host. Non-browser clients
            # (no Origin) still pass and must present the secret via cookie/?secret as before.
            if (!secret_required || is_authenticated(session, http.message)) && origin_matches_host(http.message)
                if startswith(HTTP.URI(http.message.target).path, "/terminal")
                    serve_terminal_upgrade(http, session, HTTP.queryparams(HTTP.URI(http.message.target)))
                    return
                end
                upgraded = Ref(false)
                try
                    # "upgrade" means accept and start the websocket connection that the client requested
                    HTTP.WebSockets.upgrade(http; WEBSOCKET_UPGRADE_KWARGS...) do clientstream
                        upgraded[] = true
                        if HTTP.WebSockets.isclosed(clientstream)
                            return
                        end
                        found_client_id_ref = Ref(Symbol(:none))
                        try
                            # the loop below will keep running for this websocket connection, it iterates over all incoming websocket messages.
                            for message in clientstream
                                # This stream contains data received over the WebSocket.
                                # It is formatted and MsgPack-encoded by send(...) in PlutoConnection.js
                                local parentbody = nothing
                                local did_read = false
                                try
                                    parentbody = unpack(message)
                                    
                                    # for debug only
                                    let
                                        lag = session.options.server.simulated_lag
                                        (lag > 0) && sleep(lag * (0.5 + rand())) # sleep(0) would yield to the process manager which we dont want
                                    end
                                    
                                    did_read = true
                                    if found_client_id_ref[] === :none
                                        found_client_id_ref[] = Symbol(parentbody["client_id"])
                                    end
                                    process_ws_message(session, parentbody, clientstream)
                                catch ex
                                    if ex isa InterruptException || ex isa HTTP.WebSockets.WebSocketError || ex isa EOFError
                                        # that's fine!
                                    else
                                        bt = catch_backtrace()
                                        if did_read
                                            @warn "Processing message failed for unknown reason:" parentbody exception = (ex, bt)
                                        else
                                            @warn "Reading WebSocket client stream failed for unknown reason:" parentbody exception = (ex, bt)
                                        end
                                    end
                                end
                            end
                        catch ex
                            if ex isa InterruptException || ex isa HTTP.WebSockets.WebSocketError || is_disconnection_exception(ex)
                                # that's fine!
                            else
                                bt = catch_backtrace()
                                @warn "Reading WebSocket client stream failed for unknown reason:" exception = (ex, bt)
                            end
                        finally
                            if haskey(session.connected_clients, found_client_id_ref[])
                                @debug "Removing client $(found_client_id_ref[]) from connected_clients"
                                delete!(session.connected_clients, found_client_id_ref[])
                            end
                        end
                    end
                catch ex
                    if ex isa InterruptException || is_disconnection_exception(ex)
                        # that's fine!
                    else
                        bt = catch_backtrace()
                        @warn "HTTP upgrade failed for unknown reason" exception = (ex, bt)
                    end
                finally
                    # if we never wrote a response, then do it now
                    if !upgraded[] && isopen(http)
                        finish()
                    end
                end
            else
                finish()
            end
        else
            # then it's a regular HTTP request, not a WS upgrade
            try
                streamed_app(http)
            catch e
                # @warn "Attempted to write to a closed stream at $(http.message.target)"
                is_disconnection_exception(e) || rethrow(e)
            end
        end
    end

    # expose the live server so the UI "Shut down" action can stop it without Ctrl+C in the terminal
    RUNNING_HTTP_SERVER[] = (; http_server=server, on_shutdown=shutdown_once)

    server_running() =
        try
            HTTP.get("http://$(hostIP):$(port)$(session.options.server.base_url)ping"; status_exception=false, retry=false, CLIENT_TIMEOUT_KWARGS...).status == 200
        catch
            false
        end
    # Wait for the server to start up before opening the browser. We have a 5 second grace period for allowing the connection, and then 10 seconds for the server to write data.
    WorkspaceManager.poll(server_running, 5.0, 1.0)

    address = pretty_address(session, hostIP, port)
    if session.options.server.launch_browser && open_in_default_browser(address)
        @info("\nOpening $address in your default browser... ~ have fun!\n\n")
    else
        @info("\nGo to $address in your browser to start writing ~ have fun!\n\n")
    end
    @info("\nPress Ctrl+C in this terminal to stop Pluto\n\n")

    # Trigger ServerStartEvent with server details
    try_event_call(session, ServerStartEvent(address, port))

    if frontend_directory() == "frontend"
        @info("It looks like you are developing the Pluto package, using the unbundled frontend...")
    end

    # Start this in the background, so that the first notebook launch (which will trigger registry update) will be faster.
    # Not in a hub: a hub never opens a notebook, and a registry update is Pkg touching the depot — on a
    # cluster that is the filesystem that stalls (see Proxy.jl), and this thread must never wait on it.
    initial_registry_update_task = if session.options.server.hub
        @async nothing
    else
        @asynclog withtoken(pkg_token) do
            will_update = !PkgCompat.check_registry_age()
            PkgCompat.update_registries(; force = false)
            PkgCompat.ensure_registry_cache()
            will_update && println("    Updating registry done ✓")
        end
    end

    return RunningPlutoServer(server, shutdown_once, initial_registry_update_task)
end
precompile(run, (ServerSession, HTTP.Handlers.Router{Symbol("##001")}))

function pretty_address(session::ServerSession, hostIP, port)
    root = if session.options.server.root_url !== nothing
        @assert endswith(session.options.server.root_url, "/")
        replace(session.options.server.root_url, "{PORT}" => string(Int(port)))
    elseif haskey(ENV, "JULIAHUB_APP_URL")
        "$(ENV["JULIAHUB_APP_URL"])proxy/$(Int(port))/"
    elseif haskey(ENV, "JH_APP_URL")
        # legacy name for JULIAHUB_APP_URL, still set on older JuliaHub jobs
        "$(ENV["JH_APP_URL"])proxy/$(Int(port))/"
    else
        host_str = string(hostIP)
        host_pretty = if isa(hostIP, Sockets.IPv6)
            if host_str == "::1"
                "localhost"
            else
                "[$(host_str)]"
            end
        elseif host_str == "127.0.0.1" # Assuming the other alternative is IPv4
            "localhost"
        else
            host_str
        end
        port_pretty = Int(port)
        base_url = session.options.server.base_url
        "http://$(host_pretty):$(port_pretty)$(base_url)"
    end

    url_params = Dict{String,String}()

    if session.options.security.require_secret_for_access
        url_params["secret"] = session.secret
    end
    fav_notebook = let n = session.options.server.notebook
        n isa AbstractVector ? (isempty(n) ? nothing : first(n)) : n
    end
    new_root = if fav_notebook !== nothing
        # since this notebook already started running, this will get redicted to that session
        url_params["path"] = string(fav_notebook)
        root * "open"
    else
        root
    end
    string(HTTP.URI(HTTP.URI(new_root); query = url_params))
end

"""
All messages sent over the WebSocket from the client get decoded+deserialized and end up here.

It calls one of the functions from the `responses` Dict, see the file Dynamic.jl.
"""
function process_ws_message(session::ServerSession, parentbody::Dict, clientstream)
    client_id = Symbol(parentbody["client_id"])
    client = get!(session.connected_clients, client_id) do 
        ClientSession(client_id, clientstream, session.options.server.simulated_lag)
    end
    client.stream = clientstream # it might change when the same client reconnects

    messagetype = Symbol(parentbody["type"])
    request_id = Symbol(parentbody["request_id"])

    notebook = if haskey(parentbody, "notebook_id") && parentbody["notebook_id"] !== nothing
        notebook = let
            notebook_id = UUID(parentbody["notebook_id"])
            get(session.notebooks, notebook_id, nothing)
        end

        if messagetype === :connect
            if notebook === nothing
                messagetype === :connect || @warn "Remote notebook not found locally!"
            else
                client.connected_notebook = notebook
            end
        end

        notebook
    else
        nothing
    end

    body = parentbody["body"]

    if haskey(responses, messagetype)
        responsefunc = responses[messagetype]
        try
            responsefunc(ClientRequest(session, notebook, body, Initiator(client, request_id)))
        catch ex
            @warn "Response function to message of type $(repr(messagetype)) failed"
            rethrow(ex)
        end
    else
        @warn "Message of type $(messagetype) not recognised"
    end
end
