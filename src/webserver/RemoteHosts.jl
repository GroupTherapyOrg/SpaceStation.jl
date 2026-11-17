import HTTP
import SHA
import Random

###
# One address for local and remote workspaces.
#
# Today a remote machine is a second, complete SpaceStation in the browser: its own port, its own
# secret in the URL, its own copy of the launcher and the shell (whatever version the node has).
# Here the local hub is the only thing the browser signs in to, and a workspace on another machine
# is `/h/<host>/w/<id>/` on this hub:
#
#   • the page there is THIS hub's shell (land.html, land.js), so it cannot be an older copy;
#   • everything the shell asks about the workspace (files, the terminal, the notebook list) is
#     relayed to the remote hub's own `/w/<id>/` by the same relay a local workspace uses
#     (Proxy.jl), over one loopback port per host: an SSH forward's local end, or in tests the
#     stand-in hub itself;
#   • the notebook editor is NOT served by this hub. It comes from the remote (so the editor and
#     the server it talks to are always the same version), and it is script from another machine,
#     so it gets its own browser origin per host, `http://<label>.localhost:<port>/<capability>/…`,
#     served by this same listener and routed by the `Host` header. That origin can reach nothing
#     but that host's notebook routes: this hub's API, files and terminals are not there, and the
#     hub's cookie is never sent to it (it is host-only and SameSite=Strict, and `<label>.localhost`
#     is another site). It is opened by an unguessable path segment instead of a cookie.
#
# The remote hub's secret stays in this process. It is sent to the remote in a request header and
# is dropped from everything that goes back to the browser (Set-Cookie is, in the relay).
#
# What this file does not do: connect. A host gets into the table when something that has a way to
# reach it says so (`register_remote_host!`). For now that is only the test seam below; the
# SSH path (CollabRemote.jl) is unchanged and can call the same function with its tunnel's port.
###

const HOST_PREFIX = "/h/"

mutable struct RemoteHost
    name::String    # what the launcher shows and the URL carries: /h/<name>/
    label::String   # the DNS label of its content origin: <label>.localhost
    port::Int       # the loopback port this hub reaches the remote hub on
    secret::String  # the remote hub's secret: memory only, sent in a header, never to a browser
    source::String  # TEST SEAM: a connection file (or a directory of them) to read port and secret from
    read_at::Float64
end

const REMOTE_HOSTS = Dict{String,RemoteHost}()
const REMOTE_HOSTS_LOCK = ReentrantLock()

"A host name is what an ssh-config alias may be, and nothing that could be read as a path or an option."
valid_host_name(name::AbstractString) = occursin(r"^[A-Za-z0-9._@-]{1,128}$", name) && !startswith(name, "-") && name ∉ (".", "..")

"""
The DNS label for a host's content origin. A host name is not always a label (`gpu.cluster`,
`me@node`, capitals), and two names must never share an origin: a name that is not already a label
gets a few characters of its hash.
"""
function host_label(name::AbstractString)::String
    l = String(strip(replace(lowercase(name), r"[^a-z0-9-]" => "-"), '-'))
    l = first(l, 40)
    (l == name && !isempty(l)) && return l
    (isempty(l) ? "h" : l) * "-" * bytes2hex(SHA.sha1(String(name)))[1:6]
end

"""
Say that the hub of `name` answers on loopback `port` with `secret`. This is the whole interface a
transport has to this file: the SSH path would call it when its forward is up (the forward's local
port, and the secret it read from the node's connection file), the test seam calls it for a hub on
this machine.
"""
function register_remote_host!(name::AbstractString; port::Integer, secret::AbstractString, source::AbstractString="")::RemoteHost
    valid_host_name(name) || throw(ArgumentError("not a host name: $(repr(name))"))
    lock(REMOTE_HOSTS_LOCK) do
        h = get(REMOTE_HOSTS, name, nothing)
        if h === nothing
            h = REMOTE_HOSTS[String(name)] = RemoteHost(String(name), host_label(name), Int(port), String(secret), String(source), time())
        else
            h.port, h.secret, h.source, h.read_at = Int(port), String(secret), String(source), time()
        end
        h
    end
end

function unregister_remote_host!(name::AbstractString)
    lock(() -> delete!(REMOTE_HOSTS, name), REMOTE_HOSTS_LOCK)
    lock(CONTENT_CAPABILITIES_LOCK) do
        for (cap, (host, _)) in collect(CONTENT_CAPABILITIES)
            host == name || continue
            delete!(CONTENT_CAPABILITIES_BY_WORKSPACE, pop!(CONTENT_CAPABILITIES, cap))
        end
    end
    nothing
end

remote_host(name::AbstractString) = lock(() -> get(REMOTE_HOSTS, name, nothing), REMOTE_HOSTS_LOCK)
remote_hosts() = lock(() -> sort!(collect(values(REMOTE_HOSTS)); by=h -> h.name), REMOTE_HOSTS_LOCK)

# --- a machine reached over SSH -------------------------------------------------------------------
#
# CollabRemote.jl gets a hub running on the machine and a forward to it on a loopback port of this
# one. That is everything the table needs: when a connect is done the machine is registered here, and
# from then on its workspaces are pages of this hub, like those of any other machine in the table.
# The forward's own address (`http://localhost:<port>/`, the machine's own copy of the interface)
# still answers; nothing here sends anybody there.

"`SPACESTATION_ONE_ADDRESS=0`: a connected machine is not put in the table, and opens at its own address as before."
one_address_enabled() = get(ENV, "SPACESTATION_ONE_ADDRESS", "1") != "0"

"Is the server answering on this loopback port, with this secret, a hub? (Only a hub has workspaces at `/w/<id>/` to relay to; a server of one folder does not.)"
function _is_hub_at(port::Integer, secret::AbstractString)::Bool
    try
        r = HTTP.get("http://127.0.0.1:$(port)/api/v1/config?secret=$(HTTP.escapeuri(secret))";
            connect_timeout=2, readtimeout=4, retry=false, redirect=false, status_exception=false, cookies=false)
        r.status == 200 && occursin(r"\"hub\":\s*true", String(r.body))
    catch
        false
    end
end

"A connect to `name` is done: its hub answers on loopback `port`. Put it in the table, if it is a hub and one address is on."
function host_connected!(name::AbstractString, port::Integer, secret::AbstractString)::Bool
    (one_address_enabled() && valid_host_name(name) && _is_hub_at(port, secret)) || return false
    register_remote_host!(name; port, secret)
    true
end

"`name` was disconnected on purpose: it leaves the table, and its notebooks' addresses stop working."
host_disconnected!(name::AbstractString) = (remote_host(name) === nothing || unregister_remote_host!(name); nothing)

# --- TEST SEAM -----------------------------------------------------------------------------------
#
# SPACESTATION_DEV_REMOTE_HOSTS="name=/path[,name=/path…]": each path is a hub's connection file, or
# the directory a hub writes its connection file into (`<state home>/pluto/servers`). It stands in
# for "ssh to the node, read its connection file, forward its port": the hub named there runs on
# this machine, so its port is reachable as it is. Nothing here opens an SSH connection.

const DEV_REMOTE_HOSTS_ENV = "SPACESTATION_DEV_REMOTE_HOSTS"

"Port and secret of the live hub a connection file (or a directory of them) describes, or `nothing`."
function _read_hub_connection(source::AbstractString)
    files = isdir(source) ? [joinpath(source, n) for n in readdir(source) if endswith(n, ".json")] : isfile(source) ? [String(source)] : String[]
    for file in files
        txt = try
            read(file, String)
        catch
            continue
        end
        isdir(source) && !occursin(r"\"hub\": ?true", txt) && continue # a workspace's child writes its file there too
        pid_m = match(r"\"pid\": (\d+)", txt)
        pid = pid_m === nothing ? nothing : tryparse(Int, pid_m.captures[1])
        (pid !== nothing && !_pid_alive(pid)) && continue
        found = _parse_remote_registry(txt)
        found === nothing || return found
    end
    nothing
end

function register_dev_remote_hosts!()
    spec = get(ENV, DEV_REMOTE_HOSTS_ENV, "")
    for item in split(spec, ','; keepempty=false)
        parts = split(item, '='; limit=2)
        (length(parts) == 2 && valid_host_name(parts[1])) || (@warn "SpaceStation: ignoring $(DEV_REMOTE_HOSTS_ENV) entry $(repr(item))"; continue)
        found = _read_hub_connection(parts[2])
        # not up yet is fine: the first request that needs it reads the file again
        register_remote_host!(parts[1]; port=(found === nothing ? 0 : found.port), secret=(found === nothing ? "" : found.secret), source=parts[2])
    end
end

const HOST_REFRESH_COOLDOWN = Ref(2.0)

"The remote refused us or is not there: read its connection file again. True when port or secret changed."
function refresh_remote_host!(h::RemoteHost)::Bool
    isempty(h.source) && return false
    now = time()
    stale = lock(REMOTE_HOSTS_LOCK) do
        now - h.read_at < HOST_REFRESH_COOLDOWN[] && h.port != 0 && return false
        h.read_at = now
        true
    end
    stale || return false
    found = offload_blocking(() -> _read_hub_connection(h.source))
    found === nothing && return false
    (found.port == h.port && found.secret == h.secret) && return false
    h.port, h.secret = found.port, found.secret
    true
end

# --- the remote hub as an upstream of the relay (Proxy.jl) ----------------------------------------

struct RemoteUpstream
    host::RemoteHost
    prefix::String  # "" is the remote hub's root (its launcher API); "/w/<id>" is one workspace there
end

# On the way out: no cookie and no Origin (as for a child), and nothing that names this hub's own
# address. `Referer` would: the launcher is often opened as `/?secret=…`, and a Referer of that
# page would hand this hub's secret to the remote machine.
# Nor what the browser said about where its request came from (`Sec-Fetch-*`): that is about its
# request to THIS hub, which judged it; the remote would judge its own cookie by it (Authentication.jl).
const _REMOTE_HOP_REQUEST_HEADERS = union(_HOP_REQUEST_HEADERS, Set{String}(["referer", "x-forwarded-for", "forwarded", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user"]))

upstream_port(u::RemoteUpstream) = u.host.port
"The remote-side target: under the workspace's prefix there, without the `secret` the browser may have sent (this hub's)."
function upstream_target(u::RemoteUpstream, rest::AbstractString)
    uri = HTTP.URI(rest)
    query = HTTP.queryparams(uri)
    delete!(query, "secret")
    string(HTTP.URI(; path=u.prefix * uri.path, query=query))
end
# The bearer header is what a hub with this file accepts. The cookie is what every hub accepts
# today, so that a node still on older code can be reached; it is a request header written by this
# process, not a cookie any browser holds. Neither is ever part of a URL.
upstream_headers(u::RemoteUpstream) = Pair{String,String}[
    "Authorization" => "Bearer $(u.host.secret)",
    "Cookie" => "pluto_secret_$(u.host.port)=$(u.host.secret)",
]
upstream_dropped_headers(::RemoteUpstream) = _REMOTE_HOP_REQUEST_HEADERS
upstream_refresh!(u::RemoteUpstream) = refresh_remote_host!(u.host)
upstream_down_response(u::RemoteUpstream) =
    _json_response(503, """{"host_down": true, "host": $(_json_string(u.host.name)), "detail": $(_json_string("$(u.host.name) is not answering: its SpaceStation is not running, or the connection to it is down"))}""")
relay_pool_key(u::RemoteUpstream) = "host:" * u.host.name * u.prefix

"The workspace `wid` on host `name`, if that host is in the table. A lookup: it connects to nothing."
function resolve_remote_workspace(name::AbstractString, wid::AbstractString)::Union{RemoteUpstream,Nothing}
    occursin(r"^[0-9a-f]{16}$", wid) || return nothing # what `workspace_id` makes; also bounds the capability table
    h = remote_host(name)
    h === nothing && return nothing
    RemoteUpstream(h, WORKSPACE_PREFIX * wid)
end

"Split `/h/<host>/w/<id>…` into `(host, wid, rest)`; `nothing` for any other target."
function split_host_target(target::AbstractString; base_url::AbstractString="/")
    if base_url != "/" && startswith(target, base_url)
        target = "/" * SubString(target, ncodeunits(base_url) + 1)
    end
    startswith(target, HOST_PREFIX) || return nothing
    after = SubString(target, ncodeunits(HOST_PREFIX) + 1)
    slash = findfirst('/', after)
    slash === nothing && return nothing
    name = try
        HTTP.unescapeuri(after[1:prevind(after, slash)])
    catch
        return nothing
    end
    valid_host_name(name) || return nothing
    ws = split_workspace_target(after[slash:end])
    ws === nothing && return nothing
    (host=String(name), wid=ws[1], rest=ws[2])
end

# What this hub answers itself under `/h/<host>/w/<id>/`: the page, and the launcher's own APIs (the
# launcher can be shown over any workspace). Everything about the workspace is the remote's.
const _HUB_PATHS_FOR_REMOTE = Set{String}(["", "/", "/land", "/ping", "/auth-check", "/favicon.ico", "/api/v1/config", "/api/v1/ssh_hosts", "/api/v1/browse", "/api/v1/hosts", "/api/v1/sign-in-code"])
hub_serves_for_remote(path::AbstractString) =
    path ∈ _HUB_PATHS_FOR_REMOTE || any(p -> startswith(path, p), _HUB_NATIVE_PREFIXES) || splitext(path)[2] ∈ _ASSET_EXTENSIONS

"""
A response relayed from another machine and served on this hub's own origin is data for the shell's
`fetch`, never a document: if a browser is ever made to show it as a page, it is one with no script
and no origin (`sandbox`), and its type is not guessed.
"""
function inert_on_hub_origin!(response::HTTP.Response)
    HTTP.setheader(response, "Content-Security-Policy" => "sandbox")
    HTTP.setheader(response, "X-Content-Type-Options" => "nosniff")
    response
end

# --- the launcher's API, for a host ----------------------------------------------------------------
#
# The launcher's routes take `?host=<name>`: browse THAT machine's folders, open a folder there as a
# workspace, list and stop its workspaces. The remote hub already has exactly these routes for
# itself, so this is a relay to its root, with the workspace URLs it answers (`/w/<id>/`, relative to
# it) rewritten to where this hub shows them.

const _HOST_RELAYED_PATHS = Set{String}(["/api/v1/browse", "/api/v1/local/open", "/api/v1/local/status", "/api/v1/local/list", "/api/v1/local/restart", "/api/v1/local/shutdown"])

function remote_host_middleware(handler)
    function (request::HTTP.Request)
        uri = HTTP.URI(request.target)
        if uri.path ∈ _HOST_RELAYED_PATHS
            query = HTTP.queryparams(uri)
            name = get(query, "host", "")
            if !isempty(name)
                h = valid_host_name(name) ? remote_host(name) : nothing
                h === nothing && return _api_error(404, "no connected host with this name", false)
                delete!(query, "host")
                u = RemoteUpstream(h, "")
                response = proxy_http(u, relay_pool_key(u), request, string(HTTP.URI(; path=uri.path, query=query)))
                response.body = Vector{UInt8}(replace(String(copy(response.body)), r"\"url\":\s*\"/w/" => "\"url\":\"$(HOST_PREFIX)$(HTTP.escapeuri(name))/w/"))
                return inert_on_hub_origin!(response)
            end
        end
        handler(request)
    end
end

function register_remote_hosts!(router, session::ServerSession)
    # The hosts in the table and whether each answers right now. Their workspaces are asked for per
    # host (`/api/v1/local/list?host=`), so one slow host delays only its own tiles.
    function serve_hosts(request::HTTP.Request)
        hosts = remote_hosts()
        states = asyncmap(hosts) do h
            (h.port == 0 || _probe_port(h.port; wait=1.5) == :dead) && refresh_remote_host!(h)
            h.port != 0 && _probe_port(h.port; wait=1.5) != :dead ? "connected" : "unreachable"
        end
        items = Vector{Pair}[Pair["host" => h.name, "label" => h.label, "state" => st] for (h, st) in zip(hosts, states)]
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(items) * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/hosts", serve_hosts)
end

# --- content origins --------------------------------------------------------------------------------

const CONTENT_ORIGIN_SUFFIX = ".localhost"
const CONTENT_CAPABILITIES = Dict{String,Tuple{String,String}}()            # capability => (host name, workspace id)
const CONTENT_CAPABILITIES_BY_WORKSPACE = Dict{Tuple{String,String},String}()
const CONTENT_CAPABILITIES_LOCK = ReentrantLock()

"The unguessable path segment that opens `wid` of `host` on the host's content origin. Minted once per workspace, kept in memory: a hub restart makes new ones (and every page reloads then anyway)."
function content_capability(host::AbstractString, wid::AbstractString)::String
    lock(CONTENT_CAPABILITIES_LOCK) do
        get!(CONTENT_CAPABILITIES_BY_WORKSPACE, (String(host), String(wid))) do
            cap = bytes2hex(rand(Random.RandomDevice(), UInt8, 24))
            CONTENT_CAPABILITIES[cap] = (String(host), String(wid))
            cap
        end
    end
end

"`http://<label>.localhost:<the port the browser dialled>/<capability>/`: where the shell loads this workspace's notebooks from."
content_base_url(session::ServerSession, request::HTTP.Request, h::RemoteHost, wid::AbstractString) =
    "http://$(h.label)$(CONTENT_ORIGIN_SUFFIX):$(browser_visible_port(request, something(session.options.server.port, 0)))/$(content_capability(h.name, wid))/"

"The label when this request was addressed to a content origin (`Host: <label>.localhost[:port]`), else `nothing`."
function content_origin_label(request::HTTP.Request)::Union{Nothing,String}
    host = lowercase(HTTP.header(request, "Host", ""))
    name = rstrip(first(split(host, ':')), '.') # no address literal ends in .localhost; `x.localhost.` is the same host
    endswith(name, CONTENT_ORIGIN_SUFFIX) || return nothing
    String(chopsuffix(name, CONTENT_ORIGIN_SUFFIX))
end

"""
What a content origin serves: the editor page and its assets (from the remote, so they match its
server), and the notebook routes the remote hub relays to the workspace's child. Not what the
remote hub answers itself: its file API, its terminal, its launcher. A notebook's own script could
otherwise read and write any file there and open a shell with one `fetch`; it can still run Julia,
which is what a notebook is.
"""
function content_origin_serves(path::AbstractString)::Bool
    startswith(path, "/terminal") && return false
    path ∈ ("/api/v1/shutdown", "/api/v1/workspace/open", "/api/v1/workspace/close") && return false
    path ∈ ("/edit", "/ping") && return true
    splitext(path)[2] ∈ _ASSET_EXTENSIONS && return true
    !hub_serves_natively(path)
end

# `./` from an editor is "back to the main menu". Here that would be the remote's own launcher, in a
# frame: the second UI this design removes. Ask the shell to close the tab instead (as land.js does
# when it finds itself in a frame of a local workspace). The shell's origin is this listener
# without the label.
const _CONTENT_ROOT_PAGE = """
<!doctype html><meta charset="utf-8"><title>SpaceStation</title>
<script>
if (window.parent !== window) window.parent.postMessage({ type: "spacestation:close-notebook-tab" }, location.protocol + "//localhost" + (location.port ? ":" + location.port : ""))
</script>
"""

"""
Serve one request addressed to a content origin. No cookie is read and none is set: the request is
let in by the capability in its path, for the one workspace that capability was minted for, on the
one host whose label is in `Host`. Everything else is refused, whatever it asks for.
"""
function handle_content_request(http::HTTP.Stream, session::ServerSession, label::AbstractString)
    request = http.message
    is_upgrade = HTTP.WebSockets.isupgrade(request)
    function refuse(status::Integer, why::AbstractString)
        if is_upgrade
            try
                HTTP.setstatus(http, status)
                HTTP.startwrite(http)
                write(http, why)
                HTTP.closewrite(http)
            catch
            end
        else
            request.body = read(http)
            _write_response!(http, HTTP.Response(status, ["Content-Type" => "text/plain; charset=utf-8"], why * "\n"))
        end
        nothing
    end
    m = match(r"^/([0-9a-f]{48})(?=$|[/?])(.*)$"s, request.target)
    m === nothing && return refuse(403, "Forbidden")
    entry = lock(() -> get(CONTENT_CAPABILITIES, m.captures[1], nothing), CONTENT_CAPABILITIES_LOCK)
    entry === nothing && return refuse(403, "Forbidden")
    h = remote_host(entry[1])
    (h === nothing || h.label != label) && return refuse(403, "Forbidden")
    # the editor only ever asks its own origin; anything that says it comes from another is not the editor
    origin_matches_host(request) || return refuse(403, "Forbidden")
    rest = String(m.captures[2])
    if isempty(rest) || startswith(rest, "?")
        is_upgrade && return refuse(404, "Not found")
        request.body = read(http)
        return _write_response!(http, HTTP.Response(302, ["Location" => "/" * m.captures[1] * "/" * rest], ""))
    end
    path = HTTP.URI(rest).path
    if path ∈ ("/", "/land") && !is_upgrade
        request.body = read(http)
        return _write_response!(http, HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8", "Cache-Control" => "no-store"], _CONTENT_ROOT_PAGE))
    end
    u = RemoteUpstream(h, WORKSPACE_PREFIX * entry[2])
    if is_upgrade
        # the notebook's socket (the editor opens it at `./`); the remote hub's terminal is a socket too, and is not for here
        startswith(path, "/terminal") && return refuse(403, "Forbidden")
        return proxy_ws(http, u, rest)
    end
    content_origin_serves(path) || return refuse(403, "Forbidden")
    request.body = read(http)
    _write_response!(http, proxy_http(u, relay_pool_key(u), request, rest))
end
