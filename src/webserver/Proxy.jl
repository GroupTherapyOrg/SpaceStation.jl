import HTTP
import SHA

###
# The workspace hub: a process that never runs a notebook.
#
# A Pluto server does everything on one thread — HTTP.jl's accept loop, every connection, every
# notebook task — so anything in the notebook or package machinery that blocks (a Pkg write to a
# depot on a networked filesystem, a compile, a collection) freezes the sidebar and the terminal
# along with it. Offloading individual calls (Offload.jl) narrows that, but the set of things that
# can block inside Pkg and Pluto is open-ended, so it cannot close it.
#
# This is the boundary that closes it, and it is the one Jupyter, VS Code Remote and browsers all
# use: the process the user's page talks to only RELAYS. Every workspace's notebooks live in a child
# server (one process per workspace folder, spawned and reattached by CollabLocal.jl), and the hub
# serves the workspace page at `/w/<id>/`, answers its own sidebar, file and terminal requests
# there, and forwards everything else — the editor's requests and its websocket — to the child over
# loopback. A stalled child parks one relayed request as an asynchronous wait; the hub's thread is
# idle, and the terminal, the sidebar and the other workspaces keep answering. A dead child is a
# 503 within one round trip, with a restart, not a frozen window.
#
# The browser only ever authenticates to the hub. The child's own secret is added by the hub on the
# loopback hop and never reaches the browser: every Set-Cookie the child sends is dropped.
###

const WORKSPACE_PREFIX = "/w/"

# The id is a pure function of the folder, so a tab's URL survives hub restarts, and it is not
# Julia's `hash` (which may change between Julia versions): bookmarks would break on an upgrade.
workspace_id(path::AbstractString) = bytes2hex(SHA.sha1(tamepath(String(path))))[1:16]

"""
Split a `/w/<id>...` target into `(id, rest)`. `rest` is the target as the child (or the hub's own
router) should see it: `/edit?id=…`, `/api/v1/notebooks`, or `""` when the URL is `/w/<id>` with no
slash after the id (the caller redirects to `/w/<id>/`, so relative URLs resolve under the prefix).
`nothing` for any other target.
"""
function split_workspace_target(target::AbstractString; base_url::AbstractString="/")
    if base_url != "/" && startswith(target, base_url)
        target = "/" * SubString(target, ncodeunits(base_url) + 1)
    end
    startswith(target, WORKSPACE_PREFIX) || return nothing
    after = SubString(target, ncodeunits(WORKSPACE_PREFIX) + 1)
    slash = findfirst('/', after)
    q = findfirst('?', after)
    if slash === nothing || (q !== nothing && q < slash)
        wid = q === nothing ? String(after) : String(after[1:prevind(after, q)])
        isempty(wid) && return nothing
        return (wid, "")
    end
    wid = String(after[1:prevind(after, slash)])
    isempty(wid) && return nothing
    (wid, String(after[slash:end]))
end

# Requests the hub answers itself under the prefix — the workspace page, its assets, the sidebar and
# file APIs, the terminal, the launcher's own session APIs. They read the disk (off the serving
# thread) and the hub's own state, never a notebook. Everything else under the prefix is the
# child's: the editor page's requests, `/open`, `/new`, exports, the notebook API, the websocket.
const _HUB_NATIVE_PATHS = Set{String}([
    "", "/", "/land", "/edit", "/ping", "/auth-check", "/favicon.ico",
    "/api/v1/workspace", "/api/v1/workspace/listing",
    "/api/v1/file", "/api/v1/file/save", "/api/v1/file/new", "/api/v1/file/delete",
    "/api/v1/browse", "/api/v1/config", "/api/v1/ssh_hosts",
    "/api/v1/terminal/close",
])
const _HUB_NATIVE_PREFIXES = ("/api/v1/local/", "/api/v1/remote/")
const _ASSET_EXTENSIONS = Set{String}([".ico", ".js", ".mjs", ".css", ".html", ".png", ".gif", ".svg", ".woff2", ".woff", ".ttf", ".eot", ".otf", ".json", ".map", ".wasm", ".txt", ".md"])

function hub_serves_natively(path::AbstractString, query::AbstractDict)
    path ∈ _HUB_NATIVE_PATHS && return true
    any(p -> startswith(path, p), _HUB_NATIVE_PREFIXES) && return true
    # the PDF export opens the notebook in the system browser: that URL must be a hub URL
    path == "/api/v1/desktop_export" && get(query, "type", "") == "pdf" && return true
    splitext(path)[2] ∈ _ASSET_EXTENSIONS
end

# --- finding the workspace's child --------------------------------------------------------------

"The live session for a workspace id: the one the hub spawned, or a child found in the registry (a hub restart, another hub on this node)."
function resolve_workspace(wid::AbstractString)::Union{LocalSession,Nothing}
    s = lock(LOCAL_SESSIONS_LOCK) do
        for (p, s) in LOCAL_SESSIONS
            workspace_id(p) == wid && return s
        end
        nothing
    end
    s === nothing || return s
    adopt_workspace_by_id(wid)
end

# The registry dir is on $HOME; reading it is a disk walk, so it happens off the serving thread — and
# not on every request for an id nobody has: a miss is remembered for a few seconds, so a flood of
# unknown ids cannot keep the default-pool threads (which the sidebar's own file APIs share) walking
# the registry. The scan itself (and its version guard) is CollabLocal's, the same one a reopen uses.
const _ADOPT_MISS_TTL = 3.0
const _adopt_misses = Dict{String,Float64}()
const _adopt_misses_lock = ReentrantLock()

function adopt_workspace_by_id(wid::AbstractString)::Union{LocalSession,Nothing}
    lock(_adopt_misses_lock) do
        time() - get(_adopt_misses, wid, 0.0) < _ADOPT_MISS_TTL && return true
        false
    end && return nothing
    found = offload_blocking(() -> _scan_registry_now(p -> workspace_id(p) == wid))
    if found === nothing
        lock(_adopt_misses_lock) do
            now = time()
            length(_adopt_misses) > 1024 && filter!(kv -> now - kv.second < _ADOPT_MISS_TTL, _adopt_misses) # bounded, in a long-lived hub
            _adopt_misses[String(wid)] = now
        end
        return nothing
    end
    lock(LOCAL_SESSIONS_LOCK) do
        get!(LOCAL_SESSIONS, found.path) do
            LocalSession(found.path, "ready", "", found.port, found.secret, nothing, nothing, false)
        end
    end
end

# --- the relay ------------------------------------------------------------------------------------

# A pool per workspace, sized to the parked-request cap below: a notebook run holds its connection
# for the whole run, and one stalled workspace must not starve another's relay — nor the hub's own
# outbound requests (probes, child shutdowns), which use HTTP.jl's default pool.
const PROXY_POOLS = Dict{String,HTTP.Pool}()
const PROXY_POOLS_LOCK = ReentrantLock()
_proxy_pool(wid::AbstractString) = lock(() -> get!(() -> HTTP.Pool(PROXY_PARKED_MAX), PROXY_POOLS, String(wid)), PROXY_POOLS_LOCK)
# The frontend polls a few endpoints every few seconds. Against a stalled child those would pile up:
# on one origin the browser allows six connections, so twelve hanging polls block the sidebar and
# the terminal handshake — the freeze this design exists to remove, moved into the browser. So the
# polls get a deadline (an absolute one, in HTTP.jl) and a 504 `workspace_busy`; everything else —
# runs, restarts, exports of any size — waits as long as it takes, bounded only by the parked cap.
# A Ref so tests can shorten it.
const PROXY_READ_TIMEOUT = Ref(20)
const _PROXY_POLL_PATHS = Set{String}(["/api/v1/notebooks", "/notebooklist", "/api/v1/notebook", "/api/v1/notebook/env", "/api/v1/notebook/cell", "/ping", "/auth-check"])
# …and a stalled child cannot exhaust the pool either: past this many parked requests per workspace,
# the rest get the 503 straight away.
const PROXY_PARKED_MAX = 64
const _proxy_parked = Dict{String,Int}()
const _proxy_parked_lock = ReentrantLock()
# Headers that describe this hop, not the message, plus the ones the child must not see: the
# browser's Host (so the child names its cookie and builds URLs for its own port), the hub's cookie,
# and the browser Origin (the child's CSRF check accepts a missing Origin; the hub already checked it).
const _HOP_REQUEST_HEADERS = Set{String}(["host", "cookie", "origin", "connection", "content-length", "transfer-encoding", "keep-alive", "upgrade", "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "accept-encoding"])
const _HOP_RESPONSE_HEADERS = Set{String}(["set-cookie", "connection", "content-length", "transfer-encoding", "keep-alive", "upgrade", "server"])

"The child-side target: the same path and query, with the child's secret in place of whatever `secret` the browser sent (the hub's)."
function child_target(rest::AbstractString, secret::AbstractString)
    uri = HTTP.URI(rest)
    query = HTTP.queryparams(uri)
    query["secret"] = secret
    string(HTTP.URI(; path=uri.path, query=query))
end

_json_response(status::Integer, body::AbstractString) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")

function _parked!(wid::AbstractString, delta::Int)
    lock(_proxy_parked_lock) do
        n = get(_proxy_parked, wid, 0) + delta
        n <= 0 ? delete!(_proxy_parked, wid) : (_proxy_parked[wid] = n)
        n
    end
end

"""
Relay one HTTP request to the workspace's child and return the child's response as the hub's own —
(the body is buffered in full: fine for API calls and pages; a very large export lives briefly in
the hub's heap — streaming those is a later step) —
status, headers (minus this hop's and minus every Set-Cookie) and body. Never follows the child's
redirects (`/open` answers with one, and it is the browser that must follow it, under the prefix).
"""
function proxy_http(s::LocalSession, wid::AbstractString, request::HTTP.Request, rest::AbstractString)::HTTP.Response
    path = HTTP.URI(rest).path
    if _parked!(wid, 1) > PROXY_PARKED_MAX
        _parked!(wid, -1)
        return _json_response(503, """{"workspace_busy": true, "detail": "too many requests are waiting on this workspace's server"}""")
    end
    url = "http://127.0.0.1:$(s.port)" * child_target(rest, s.secret)
    headers = [h for h in request.headers if lowercase(h.first) ∉ _HOP_REQUEST_HEADERS]
    upstream = try
        HTTP.request(request.method, url, headers, request.body;
            connect_timeout=3, readtimeout=(path ∈ _PROXY_POLL_PATHS ? PROXY_READ_TIMEOUT[] : 0),
            redirect=false, retry=false, status_exception=false, decompress=false, pool=_proxy_pool(wid))
    catch e
        if _probe_port(s.port; wait=0.2) == :dead
            return _json_response(503, """{"workspace_down": true, "state": $(_json_string(s.state)), "detail": "the server for this workspace is not answering; restart the workspace"}""")
        elseif e isa HTTP.TimeoutError || (e isa HTTP.RequestError && e.error isa HTTP.TimeoutError)
            return _json_response(504, """{"workspace_busy": true, "detail": "the server for this workspace did not answer within $(PROXY_READ_TIMEOUT[])s; it is busy, and this request was dropped"}""")
        else
            return _json_response(502, """{"workspace_error": true, "detail": $(_json_string(sprint(showerror, e)))}""")
        end
    finally
        _parked!(wid, -1)
    end
    response = HTTP.Response(upstream.status, Pair{String,String}[], upstream.body) # (status, body) alone reads the Vector as headers
    for h in upstream.headers
        lowercase(h.first) ∈ _HOP_RESPONSE_HEADERS && continue
        HTTP.setheader(response, h)
    end
    response
end

"""
Relay a websocket: open the child's end first, so a child that is down fails the browser's
handshake (the frontend retries) instead of getting a socket that never answers; then copy frames
both ways with no buffering, so a slow reader only slows its own connection. Either side ending
closes the other's socket outright rather than negotiating a close it might have to wait for.
"""
function proxy_ws(http::HTTP.Stream, s::LocalSession, rest::AbstractString)
    url = "ws://127.0.0.1:$(s.port)" * child_target(rest, s.secret)
    opened = Ref(false)
    try
        HTTP.WebSockets.open(url; suppress_close_error=true, connect_timeout=3, retry=false) do childws
            opened[] = true
            HTTP.WebSockets.upgrade(http) do clientws
                HTTP.WebSockets.isclosed(clientws) && return
                downstream = @async try
                    for msg in childws
                        HTTP.WebSockets.send(clientws, msg)
                    end
                catch
                finally
                    try close(clientws.io) catch end
                end
                try
                    for msg in clientws
                        HTTP.WebSockets.send(childws, msg)
                    end
                catch
                finally
                    try close(childws.io) catch end
                    timedwait(() -> istaskdone(downstream), 5.0; pollint=0.05)
                end
            end
        end
    catch e
        if !opened[]
            # the child could not be reached: fail the handshake now, the browser retries by itself
            try
                if isopen(http) && !iswritable(http)
                    HTTP.setstatus(http, 503)
                    HTTP.setheader(http, "Content-Type" => "application/json; charset=utf-8")
                    HTTP.startwrite(http)
                    write(http, """{"workspace_down": true}\n""")
                    HTTP.closewrite(http)
                end
            catch
            end
        elseif !(e isa HTTP.WebSockets.WebSocketError || e isa EOFError || e isa Base.IOError || e isa InterruptException)
            @debug "workspace websocket relay ended" exception = (e, catch_backtrace())
        end
    end
    nothing
end

# --- the request handler under /w/<id>/ -----------------------------------------------------------

function _write_response!(http::HTTP.Stream, response::HTTP.Response)
    try
        HTTP.setstatus(http, response.status)
        for h in response.headers
            HTTP.setheader(http, h)
        end
        HTTP.setheader(http, "Content-Length" => string(length(response.body)))
        HTTP.setheader(http, "Referrer-Policy" => "same-origin")
        HTTP.startwrite(http)
        write(http, response.body)
    catch e
        (e isa Base.IOError || e isa ArgumentError) || rethrow()
    end
end

"""
Serve one `/w/<id>/…` request. The hub authenticates the browser (its own secret, its own Origin
check), then either answers itself (workspace page, assets, sidebar, files, terminal, launcher APIs —
through the ordinary router, with the workspace recorded in the request context) or relays to the
workspace's child. `app` is the hub's router with its middleware.
"""
function handle_workspace_request(http::HTTP.Stream, session::ServerSession, app, wid::AbstractString, rest::AbstractString)
    request = http.message
    if isempty(rest)
        # `/w/<id>` → `/w/<id>/`, keeping the query: relative URLs in the page need the slash
        q = HTTP.URI(request.target).query
        response = HTTP.Response(302, "")
        HTTP.setheader(response, "Location" => WORKSPACE_PREFIX * wid * "/" * (isempty(q) ? "" : "?" * q))
        HTTP.WebSockets.isupgrade(request) || (request.body = read(http))
        return _write_response!(http, response)
    end
    uri = HTTP.URI(rest)
    path = uri.path
    query = HTTP.queryparams(uri)
    is_upgrade = HTTP.WebSockets.isupgrade(request)
    security = session.options.security
    secret_required = security.require_secret_for_access || security.require_secret_for_open_links

    # Assets and /ping need no workspace at all: serve them straight from the hub, no lookup.
    if !is_upgrade && (path == "/ping" || splitext(path)[2] ∈ _ASSET_EXTENSIONS)
        request.target = rest
        request.body = read(http)
        return _write_response!(http, app(request))
    end

    # The hub's own gate first — before anything costs a registry walk or reaches a child. The
    # ordinary router repeats it for hub-native routes, which is harmless.
    if is_upgrade
        if !((!secret_required || is_authenticated(session, request)) && origin_matches_host(request))
            try
                HTTP.setstatus(http, 403)
                HTTP.startwrite(http)
                write(http, "Forbidden")
                HTTP.closewrite(http)
            catch
            end
            return
        end
    else
        request.target = rest # the auth helpers read the path and query from the target
        if !is_safe_http_method(request) && !origin_matches_host(request)
            request.body = read(http)
            return _write_response!(http, error_response(403, "Cross-origin request blocked", "This request was refused because its <em>Origin</em> does not match the server."))
        end
        if auth_required(session, request) && !is_authenticated(session, request)
            request.body = read(http)
            return _write_response!(http, error_response(403, "Not yet authenticated", "<b>Open the link that was printed in the terminal where you launched SpaceStation.</b> It includes a <em>secret</em>, which is needed to access this server."))
        end
    end

    s = resolve_workspace(wid)
    if s === nothing
        is_upgrade || (request.body = read(http))
        return _write_response!(http, _json_response(404, """{"workspace_unknown": true, "detail": "no workspace with this id is open on this server"}"""))
    end
    # From here the request looks, to the router and to the child, like it was made at the root.
    request.target = rest
    request.context[:workspace_root] = s.path
    request.context[:workspace_id] = String(wid)
    request.context[:workspace_session] = s

    if is_upgrade
        if startswith(path, "/terminal")
            serve_terminal_upgrade(http, session, query)
        else
            proxy_ws(http, s, rest)
        end
        return
    end

    request.body = read(http)
    if path == "/api/v1/shutdown"
        # "shut down" on a workspace page means this workspace's server, never the hub and every
        # other workspace with it (the hub's own shutdown stays at the root)
        @async begin
            sleep(0.2)
            try
                shutdown_local_session!(s.path)
            catch
            end
        end
        return _write_response!(http, _json_response(200, """{"status": "shutting_down", "workspace": $(_json_string(s.path))}"""))
    end
    if hub_serves_natively(path, query)
        response = app(request) # the hub's own router + auth middleware, which sets the hub cookie
        return _write_response!(http, response)
    end
    if path ∈ ("/api/v1/workspace/open", "/api/v1/workspace/close")
        # switching the folder in place is what a leaf does; under the prefix the folder IS the workspace
        return _write_response!(http, _json_response(409, """{"error": "this server is a workspace hub: open another folder from the launcher instead"}"""))
    end
    response = proxy_http(s, wid, request, rest)
    auth_required(session, request) && add_set_secret_cookie!(session, request, response)
    _write_response!(http, response)
end

"""
Wrap a route that opens or creates notebooks IN this process so a hub refuses it: a hub never runs a
notebook, and these are the routes that would turn it into one. Leaves keep them (the test suites and
plain `Pluto.run()` use them at the root).
"""
leaf_only(session::ServerSession, handler) = function (request::HTTP.Request)
    session.options.server.hub || return handler(request)
    _json_response(409, """{"error": "this server is a workspace hub and does not run notebooks itself; open the notebook from a workspace page (/w/<id>/)"}""")
end
