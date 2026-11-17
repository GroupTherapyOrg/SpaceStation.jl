import .Throttled

"""
The port the BROWSER used to reach us, read from the `Host` header — which is the only port that
scopes anything in a cookie jar. Falls back to the port we are bound to when there is no usable
`Host` (non-browser clients, which do not carry cookies anyway).

`Host` is `name`, `name:port`, `[::1]` or `[::1]:port`; only a `:` *after* any closing bracket
introduces a port.
"""
function browser_visible_port(request::HTTP.Request, fallback::Integer)::Int
    host = HTTP.header(request, "Host", "")
    isempty(host) && return Int(fallback)
    start = something(findlast(']', host), 0) + 1
    i = findnext(':', host, start)
    i === nothing && return Int(fallback)
    something(tryparse(Int, SubString(host, i + 1)), Int(fallback))
end

"""
The name of the auth cookie, scoped by the port the browser used to reach this server.

Cookies are scoped by host + name + path — **the port is not part of a cookie's scope**
(RFC 6265). So multiple Pluto servers on the same host (e.g. several `spacestation` workspaces
on `localhost:1234`, `:1235`, …) would all set a cookie named `secret` for `localhost` and
*clobber each other*: launching a second server logs the first one out of its own browser tab,
turning every cookie-authenticated request (`./api/v1/notebooks`, `./edit?id=…`, the editor
WebSocket) into a 403. Putting the port in the cookie *name* gives each server its own cookie.

The port has to be the one the BROWSER dialled, not the one we bound. An SSH tunnel decouples the
two — `ssh -L 45200:127.0.0.1:1234` means the browser says `localhost:45200` while the server
believes it is on `1234` — and every SpaceStation binds `port_hint = 1234` by default, so a local
hub and every remote node all claimed the name `pluto_secret_1234` on `localhost` and clobbered
each other. Opening a second workspace 403'd the first; refreshing the first 403'd the second.
Naming from `Host` restores the intent: one cookie per address the browser can actually name.
"""
secret_cookie_name(session::ServerSession, request::HTTP.Request) =
    "pluto_secret_$(browser_visible_port(request, something(session.options.server.port, 0)))"

"Are these the same secret? Every byte is compared, so the time taken says nothing about where they differ."
function same_secret(a::AbstractString, b::AbstractString)::Bool
    x, y = codeunits(a), codeunits(b)
    (isempty(x) || isempty(y)) && return false
    diff = UInt8(length(x) == length(y) ? 0 : 1)
    for i in eachindex(y)
        diff |= xor(y[i], x[mod1(i, length(x))])
    end
    diff == 0
end

###
# A sign-in link for another browser.
#
# The page takes `?secret=` out of its address once it is signed in (an address is copied, shown in
# a screen share and kept in the history), so the address bar no longer carries a way in. A way in
# for another browser is asked for instead: a code that works once, for a few minutes. It is not the
# secret, so a link that was pasted somewhere it should not have been is worth nothing afterwards.
###
const SIGN_IN_CODES = Dict{String,Float64}() # code => when it stops working
const SIGN_IN_CODES_LOCK = ReentrantLock()
const SIGN_IN_CODE_LIFETIME = Ref(300.0)

function new_sign_in_code()::String
    code = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))
    lock(SIGN_IN_CODES_LOCK) do
        now = time()
        filter!(kv -> kv.second > now, SIGN_IN_CODES)
        SIGN_IN_CODES[code] = now + SIGN_IN_CODE_LIFETIME[]
    end
    code
end

const SIGN_IN_CODE_GRACE = Ref(15.0)

"""
Use a sign-in code: true within its lifetime, and from its first use only for a few seconds more.
Not strictly once: opening one page is often two requests with the same address (a redirect to the
address with its slash, a browser that asks twice), and the second must not be refused.
"""
function take_sign_in_code!(code::AbstractString)::Bool
    occursin(r"^[0-9a-f]{32}$", code) || return false
    lock(SIGN_IN_CODES_LOCK) do
        now = time()
        until = get(SIGN_IN_CODES, code, nothing)
        (until === nothing || until <= now) && (delete!(SIGN_IN_CODES, code); return false)
        SIGN_IN_CODES[code] = min(until, now + SIGN_IN_CODE_GRACE[])
        true
    end
end

"A page of the shell or the editor, under a hub's workspace prefix or not: showing one changes nothing."
function is_page_path(path::AbstractString)::Bool
    m = match(r"^/w/[0-9a-f]{16}(/.*)?$", path)
    rest = m === nothing ? path : something(m.captures[1], "")
    rest ∈ ("", "/", "/land", "/edit")
end

"""
May a request that is signed in only by its cookie be acted on? The cookie is ambient: the browser
adds it by itself, and not only to requests this server's own pages make. `SameSite=Strict` keeps
it off requests from other sites, but a browser's "site" has no port in it: a page on any other
port of this machine (another program's, another user's on a shared machine through a forward) is
the same site, gets the cookie added, and a plain link or image there to `/shutdown`, `/move` or
`/open?path=…` was carried out. Those are GETs, which the Origin check for writes does not cover.

Browsers say where a request comes from (`Sec-Fetch-Site`). One from this server's own pages
(`same-origin`) or from the user (`none`: typed, a bookmark, a link in another program) passes. One
from anywhere else passes only when it is the user being taken to a page. A client that sends no
such header is not a browser of this decade, or not a browser: it is judged as before.
"""
function fetch_site_allows(request::HTTP.Request)::Bool
    site = lowercase(HTTP.header(request, "Sec-Fetch-Site", ""))
    (isempty(site) || site == "same-origin" || site == "none") && return true
    uppercase(request.method) == "GET" || return false
    (lowercase(HTTP.header(request, "Sec-Fetch-Mode", "")) == "navigate" && lowercase(HTTP.header(request, "Sec-Fetch-Dest", "")) == "document") || return false
    is_page_path(HTTP.URI(request.target).path)
end

"""
Return whether the `request` was authenticated in one of these ways:
1. the session's `secret` was included in the URL as a search parameter, or
2. the session's `secret` was included in a cookie, or
3. a page was asked for with a sign-in code (`?code=`) that had not been used.
"""
function is_authenticated(session::ServerSession, request::HTTP.Request)
    (
        secret_in_url = try
            uri = HTTP.URI(request.target)
            query = HTTP.queryparams(uri)
            # a code is used up by the first check, and a request can be checked more than once on
            # its way (a hub checks before it relays, and the handler checks again): remember it
            same_secret(get(query, "secret", ""), session.secret) || get(request.context, :signed_in_by_code, false) ||
                (request.method == "GET" && haskey(query, "code") && take_sign_in_code!(query["code"]) && (request.context[:signed_in_by_code] = true))
        catch e
            @warn "Failed to authenticate request using URL" exception = (e, catch_backtrace())
            false
        end
    ) || (
        secret_in_cookie = try
            cookies = HTTP.cookies(request)
            cookie_name = secret_cookie_name(session, request)
            fetch_site_allows(request) && any(cookies) do cookie
                cookie.name == cookie_name && same_secret(cookie.value, session.secret)
            end
        catch e
            @warn "Failed to authenticate request using cookies" exception = (e, catch_backtrace())
            false
        end
    )
    # that ) || ( kind of looks like Krabs from spongebob
end

# Function to log the url with secret on the Julia CLI when a request comes to the server without the secret. Executes at most once every 5 seconds
const log_secret_throttled = Throttled.simple_leading_throttle(5) do session::ServerSession, request::HTTP.Request
    host = HTTP.header(request, "Host")
    target = request.target
    url = Text(string(HTTP.URI(HTTP.URI("http://$host/"); query=Dict("secret" => session.secret))))
    @info("No longer authenticated? Visit this URL to continue:", url)
end


function add_set_secret_cookie!(session::ServerSession, request::HTTP.Request, response::HTTP.Response)
    HTTP.setheader(response, "Set-Cookie" => "$(secret_cookie_name(session, request))=$(session.secret); Path=/; SameSite=Strict; HttpOnly")
    response
end

"""
    origin_matches_host(request) -> Bool

Cross-origin defense for requests that carry ambient credentials (the secret cookie).

`SameSite=Strict` is NOT enough on its own here: a cookie's scope is host + name + path —
**the port is not part of it** — and browsers treat every `localhost:<port>` as the *same site*.
So a page served from any *other* local port (a second dev server, a docs preview, a compromised
dependency's dev server) is same-site with this one, and the browser will happily attach our
`pluto_secret_<port>` cookie to a request it initiates at us. That turns two of the fork's
additions into remote code execution: the `/terminal` WebSocket (an interactive shell) and the
`POST /api/v1/file/*` endpoints (arbitrary-path file writes).

The robust signal a browser cannot forge from another origin is the `Origin` header: it always
reflects the page that initiated the request, and script cannot set it. So:

  • No `Origin` header → allow. Non-browser clients (the `pluto-collab` CLI, `curl`, native
    WebSocket libraries) don't send one, and they are not a CSRF vector — they must still present
    the secret. A browser NEVER omits `Origin` on a WebSocket handshake or a cross-origin fetch.
  • `Origin` present → its authority (host:port) must equal the request's `Host`. The legitimate
    same-origin frontend always matches; a cross-origin attacker page never can.

Fails closed (unparseable Origin, or absent Host → reject). This is a backstop that holds even
in the dangerous `require_secret_for_access=false` Binder config, where the same-origin frontend
still matches but any attacker origin is refused.
"""
function origin_matches_host(request::HTTP.Request)::Bool
    origin = HTTP.header(request, "Origin", "")
    isempty(origin) && return true
    host = HTTP.header(request, "Host", "")
    isempty(host) && return false
    return try
        o = HTTP.URI(origin)
        authority = isempty(o.port) ? o.host : "$(o.host):$(o.port)"
        authority == host
    catch
        false
    end
end

"HTTP methods that (by spec) don't change server state — the browser sends them freely, so they carry no CSRF risk on their own. Anything else must pass [`origin_matches_host`]."
is_safe_http_method(request::HTTP.Request)::Bool = uppercase(request.method) in ("GET", "HEAD", "OPTIONS")

# too many layers i know
"""
Generate a middleware (i.e. a function `HTTP.Handler -> HTTP.Handler`) that stores the `session` in every `request`'s context.
"""
function create_session_context_middleware(session::ServerSession)
    function session_context_middleware(handler::Function)::Function
        function(request::HTTP.Request)
            request.context[:pluto_session] = session
            handler(request)
        end
    end
end


session_from_context(request::HTTP.Request) = request.context[:pluto_session]::ServerSession


function auth_required(session::ServerSession, request::HTTP.Request)
    path = HTTP.URI(request.target).path
    ext = splitext(path)[2]
    security = session.options.security

    if path ∈ ("/ping", "/possible_binder_token_please") || ext ∈ (".ico", ".js", ".css", ".png", ".gif", ".svg", ".ico", ".woff2", ".woff", ".ttf", ".eot", ".otf", ".json", ".map")
        false
    elseif path ∈ ("", "/")
        # / does not need security.require_secret_for_open_links, because this is how we handle the configuration where:
        #    require_secret_for_open_links == true
        #    require_secret_for_access == false
        # 
        # This means that access to all 'risky' endpoints is restricted to authenticated requests (to prevent CSRF), but we allow an unauthenticated request to visit the `/` page and acquire the cookie (see `add_set_secret_cookie!`).
        # 
        # (By default, `require_secret_for_access` (and `require_secret_for_open_links`) is `true`.)
        security.require_secret_for_access
    else
        security.require_secret_for_access || 
        security.require_secret_for_open_links
    end
end


###
# A sign-in that outlives the hub.
#
# A hub made a new secret each time it started. Every page left open across a restart (an update, a
# crash, a laptop that was shut) was signed out, and with one address for local and remote
# workspaces that is every tab the user has. A hub now keeps its secret beside its connection file
# (the same directory, the same owner-only mode: that file already holds it while the hub runs) and
# takes it up again at its next start on the same port, for as long as `SIGN_IN_KEPT_FOR` allows.
# `SPACESTATION_KEEP_SIGN_IN=0` turns this off; deleting the file signs every browser out.
###
const SIGN_IN_KEPT_FOR = Ref(30 * 24 * 3600.0)
kept_sign_in_path(port::Integer) = joinpath(collab_registry_dir(), "sign-in-$(port).txt")

function _read_kept_sign_in(path::AbstractString)::Union{Nothing,String}
    isfile(path) || return nothing
    if !Sys.iswindows()
        st = stat(path)
        # written by this user and readable by nobody else, or it is not ours to trust
        (st.uid == ccall(:getuid, Cuint, ()) && filemode(st) & 0o077 == 0) || return nothing
    end
    m = match(r"^(\d+(?:\.\d+)?) ([A-Za-z0-9]{16,128})\s*$", read(path, String))
    m === nothing && return nothing
    made = parse(Float64, m.captures[1])
    -60 <= time() - made < SIGN_IN_KEPT_FOR[] || return nothing # (a clock set back a little is not a reason to sign everybody out)
    String(m.captures[2])
end

"A hub takes up the secret it had the last time it ran on this port, or keeps the one it has now for the next time."
function keep_sign_in!(session::ServerSession, port::Integer)
    get(ENV, "SPACESTATION_KEEP_SIGN_IN", "1") == "0" && return nothing
    path = kept_sign_in_path(port)
    try
        kept = offload_blocking(() -> _read_kept_sign_in(path))
        if kept !== nothing
            session.secret = kept
        else
            mkpath(dirname(path))
            _write_private_file(path, "$(floor(Int, time())) $(session.secret)\n")
        end
    catch e
        @warn "SpaceStation: could not keep the sign-in for the next start" exception = (e, catch_backtrace())
    end
    nothing
end

"""
    auth_middleware(f::HTTP.Handler) -> HTTP.Handler

Returns an `HTTP.Handler` (i.e. a function `HTTP.Request → HTTP.Response`) which does three things:
1. Check whether the request is authenticated (by calling `is_authenticated`), if not, return a 403 error.
2. Call your `f(request)` to create the response message.
3. Add a `Set-Cookie` header to the response with the session's `secret`.

This is for HTTP requests, the authentication mechanism for WebSockets is separate.
"""
function auth_middleware(handler)
    return function (request::HTTP.Request)
        session = session_from_context(request)
        required = auth_required(session, request)

        # CSRF backstop: a state-changing request that carries a mismatched browser Origin is a
        # cross-site forgery riding the ambient cookie (see origin_matches_host). Refuse it before
        # it can write a file / open a workspace / shut the server down — even in no-secret Binder
        # mode. Safe methods and non-browser clients (no Origin) are unaffected.
        if !is_safe_http_method(request) && !origin_matches_host(request)
            return error_response(403, "Cross-origin request blocked", "This request was refused because its <em>Origin</em> does not match the server. If you are a developer calling this API, connect from the same origin or omit the browser Origin header.")
        end

        if !required || is_authenticated(session, request)
            response = handler(request)
            if !required
                HTTP.removeheader(response, "Access-Control-Allow-Origin")
                HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
            end
            if required || HTTP.URI(request.target).path ∈ ("", "/")
                add_set_secret_cookie!(session, request, response)
            end
            response
        else
            log_secret_throttled(session, request)
            error_response(403, "Not yet authenticated", "<b>Open the link that was printed in the terminal where you launched Pluto.</b> It includes a <em>secret</em>, which is needed to access this server.<br><br>If you are running the server yourself and want to change this configuration, have a look at the keyword arguments to <em>Pluto.run</em>. <br><br>Please <a href='https://github.com/fonsp/Pluto.jl/issues'>report this error</a> if you did not expect it!")
        end
    end
end
