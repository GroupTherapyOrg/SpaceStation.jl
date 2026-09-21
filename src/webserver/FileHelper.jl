# The hub never touches the user's files itself.
#
# One file call on a hung filesystem takes the whole process down with it (evaluation/PinCode.jl says
# why: the garbage collector cannot stop a thread that is stuck in the kernel, so it waits, and every
# other thread waits for the collector). Reproduced in test/hangfs: a hub that keeps answering in
# 70 ms while Julia, the depot and the checkout are all hung stops dead for the length of the hang at
# the first `stat` of a hung directory, which is what the sidebar asks for every ten seconds.
# Moving that call to another thread (Offload.jl) does not help. Moving it to another PROCESS does:
# a process that is allowed to get stuck. This is the browser's utility process, the editor's
# extension host, the web server's CGI worker: keep the part that must stay responsive free of
# blocking work, and hand that work to something disposable over a pipe or a socket.
#
# So a hub starts two "file helpers" before it serves anything: ordinary SpaceStation servers in hub
# mode on a loopback port, with a secret only the hub knows, that never see a browser. Every handler
# that reads or writes the user's files (`_offloaded` in CollabAPI.jl is the one place they are
# wrapped) forwards its request to a helper and relays the answer. Forwarding is socket I/O: it holds
# a task, never a thread.
#
# What is hung is a FILESYSTEM, not a helper, and a node has several (a hung \$HOME next to a healthy
# local scratch is the normal case). A request that misses its deadline marks its ROOT (the workspace
# folder, or the path asked about) as hung, held by the helper that is now stuck on it. Requests for
# that root are refused at once, 504 `filesystem_busy`, and are never tried on the other helper, which
# would only stick it too: it stays free for the other roots. The root is asked about again only
# when the helper that stuck on it answers a `stat` of that very root (answering a ping proves
# nothing: a helper with one stuck thread keeps serving until its next garbage collection).
# A stuck helper is not killed and not replaced while it is stuck: it cannot be killed (it is inside
# the kernel), it comes back by itself when the filesystem does, and starting a process during a hang
# can itself wait on a filesystem. One that has exited is replaced, one at a time, with a pause.
# A hub that has helpers NEVER runs a file handler itself, helpers or no helpers at that moment: the
# mode is decided once at start. `SPACESTATION_FILE_HELPER=0` turns it off (handlers then run in
# the hub, as before).

"How many helpers: two where there are several filesystems to tell apart (Linux, the clusters), one elsewhere."
const FILE_HELPER_COUNT = Ref(Sys.islinux() ? 2 : 1)
"Seconds a helper gets for a listing or a read before its root is considered hung."
const FILE_HELPER_DEADLINE = Ref(3)
"Seconds for a request that writes (a save of a large file is slow on a healthy network filesystem too)."
const FILE_HELPER_WRITE_DEADLINE = Ref(30)
"Seconds between two starts of a replacement helper."
const FILE_HELPER_RESPAWN_PAUSE = Ref(10.0)

mutable struct FileHelper
    proc::Union{Base.Process,Nothing}
    port::Int
    secret::String
    lifeline::Any         # the write end of the helper's stdin: held for as long as the helper should live
end

const FILE_HELPERS = FileHelper[]
const FILE_HELPERS_LOCK = ReentrantLock()
"Decided once, at hub start: this process forwards file requests, and never runs them itself."
const FILE_HELPER_MODE = Ref(false)
"""
What is known to be hung: `key => (the helper stuck on it, when it was last probed, the path to probe)`.
The key is the FILESYSTEM a path is on, as far as that can be told without asking the filesystem:
the longest mount point in `/proc/self/mountinfo` that contains it (read at hub start and on a
timer, never for a request; reading /proc touches no mount). So a second folder on a hung
filesystem is refused at once instead of costing the second helper. Where there is no /proc the
key is the path itself.
"""
const HUNG_ROOTS = Dict{String,Tuple{FileHelper,Float64,String}}()
"key => the helper that missed the deadline once: the next request gets a longer one, on the SAME helper"
const SUSPECT_ROOTS = Dict{String,FileHelper}()
const _mount_points = Ref(String[])
const _last_helper_spawn = Ref(0.0)
const _helper_spawning = Ref(false)

is_file_helper_process() = get(ENV, "SPACESTATION_FILE_HELPER_SECRET", "") != ""
file_helpers_enabled() = get(ENV, "SPACESTATION_FILE_HELPER", "1") != "0"
file_helpers_active() = FILE_HELPER_MODE[] && !is_file_helper_process()

"The header that carries a request's workspace folder to a helper (percent-encoded). Believed only by a helper, which only the hub can reach."
const WORKSPACE_ROOT_HEADER = "X-SpaceStation-Workspace-Root"

"What a helper answers, and nothing else: it is a whole server underneath, and none of the rest (terminals, workspaces, shutdown) is its business."
const _FILE_HELPER_PATHS = Set(["/ping", "/api/v1/browse", "/api/v1/ssh_hosts", "/api/v1/workspace", "/api/v1/workspace/listing",
    "/api/v1/file", "/api/v1/file/save", "/api/v1/file/new", "/api/v1/file/delete", "/api/v1/helper/stat", "/api/v1/helper/private_file"])
file_helper_serves(path::AbstractString) = path in _FILE_HELPER_PATHS

function _file_helper_command(secret::String)
    proj = something(Base.active_project(), "")
    projdir = isempty(proj) ? pkgdir(@__MODULE__) : dirname(proj)
    env = copy(ENV)
    env["SPACESTATION_FILE_HELPER_SECRET"] = secret
    env["SPACESTATION_HUB"] = "1" # a helper never opens a notebook either: no registry parse at import
    env["HOME"] = user_home()     # it reads the USER's files: `~`, ~/.ssh/config, the default folder to browse
    delete!(env, "JULIA_LOAD_PATH")
    code = "import SpaceStation; SpaceStation.file_helper_main()"
    setenv(`$(Base.julia_cmd()) --threads=2,1 --project=$(projdir) -e $(code)`, env)
end

function refresh_mount_points!()
    Sys.islinux() || return
    points = String[]
    try
        for line in readlines("/proc/self/mountinfo") # line by line: see PinCode.jl about /proc files
            fields = split(line)
            length(fields) >= 5 && push!(points, _unescape_mountinfo(fields[5]))
        end
    catch
        return
    end
    _mount_points[] = sort!(unique!(points); by=ncodeunits, rev=true)
    nothing
end
_unescape_mountinfo(x::AbstractString) = replace(x, "\\040" => " ", "\\011" => "\t", "\\012" => "\n", "\\134" => "\\")

"The filesystem a path is on, by name only (no system call on the path). See HUNG_ROOTS."
function filesystem_key(path::AbstractString, mount_points=_mount_points[])::String
    for m in mount_points
        m == "/" && continue # everything is under it: says nothing
        (path == m || startswith(path, m * "/")) && return m
    end
    String(path)
end

"Start one helper and wait for it to say which port it serves. `nothing` when it does not come up."
function _spawn_file_helper(; timeout::Real=180)::Union{FileHelper,Nothing}
    secret = String(rand(('a':'z') ∪ ('A':'Z') ∪ ('0':'9'), 24))
    out = Pipe(); lifeline = Pipe()
    # stdin is a pipe whose write end we hold: it closes when this hub dies, however it dies, and the helper exits with it
    proc = Base.run(pipeline(_file_helper_command(secret); stdin=lifeline, stdout=out, stderr=devnull); wait=false) # stderr: its startup banner prints its secret
    close(out.in); close(lifeline.out)
    port = Ref(0)
    @async try
        for line in eachline(out) # read to the end: a helper that prints must never block on a full pipe
            m = port[] == 0 ? match(r"^SPACESTATION_FILE_HELPER_READY (\d+)$", line) : nothing
            m === nothing || (port[] = parse(Int, m.captures[1]))
        end
    catch
    end
    timedwait(() -> port[] != 0 || process_exited(proc), timeout; pollint=0.1)
    if port[] == 0
        try close(lifeline.in) catch end
        try kill(proc) catch end
        return nothing
    end
    FileHelper(proc, port[], secret, lifeline)
end

"""
Hub startup: from here on this process forwards file requests and never runs them. The helpers come
up in the background (each is a Julia start); until the first one answers, file requests get 504.
"""
function start_file_helpers!(; count::Integer=FILE_HELPER_COUNT[], wait::Bool=false)
    (file_helpers_enabled() && !is_file_helper_process()) || return nothing
    FILE_HELPER_MODE[] = true
    refresh_mount_points!()
    @async while FILE_HELPER_MODE[]
        sleep(60); refresh_mount_points!() # autofs mounts appear late
    end
    _helper_spawning[] = true; _last_helper_spawn[] = time() # these ARE the starts: a first request must not add a third
    tasks = [@async begin
        h = try _spawn_file_helper() catch; nothing end
        h === nothing || _admit_helper!(h)
        h
    end for _ in 1:count]
    @async (foreach(t -> try wait(t) catch end, tasks); _helper_spawning[] = false)
    watcher = @async begin
        all(isnothing, fetch.(tasks)) && @warn "SpaceStation: no file helper came up; the workspace's files cannot be listed or edited from this hub until one does"
    end
    wait && Base.wait(watcher)
    nothing
end

"A helper that came up joins, unless the hub stopped in the meantime: then it goes at once."
function _admit_helper!(h::FileHelper)
    lock(FILE_HELPERS_LOCK) do
        if FILE_HELPER_MODE[]
            push!(FILE_HELPERS, h)
        else
            try close(h.lifeline.in) catch end
            try kill(h.proc) catch end
        end
    end
end

function stop_file_helpers!()
    helpers = lock(FILE_HELPERS_LOCK) do
        FILE_HELPER_MODE[] = false
        hs = copy(FILE_HELPERS); empty!(FILE_HELPERS); empty!(HUNG_ROOTS); empty!(SUSPECT_ROOTS); hs
    end
    for h in helpers
        try close(h.lifeline.in) catch end
        try h.proc === nothing || kill(h.proc) catch end
    end
end

"The process a helper runs: a hub-mode server nobody but its hub can talk to, that exits when its hub goes away."
function file_helper_main()
    session = ServerSession(; secret=ENV["SPACESTATION_FILE_HELPER_SECRET"], options=Configuration.from_flat_kwargs(;
        launch_browser=false, hub=true, port_hint=rand(20000:40000), auto_reload_from_file=false))
    run!(session)
    println(stdout, "SPACESTATION_FILE_HELPER_READY $(session.options.server.port)"); flush(stdout)
    try read(stdin) catch end # until the hub closes it, or dies
    exit(0)
end

"Replace helpers that have exited: one start at a time, a pause between starts, and never while a root is hung (a start can wait on the same filesystem)."
function _replace_exited_helpers!()
    lock(FILE_HELPERS_LOCK) do
        filter!(h -> h.proc === nothing || !process_exited(h.proc), FILE_HELPERS)
        missing_count = FILE_HELPER_COUNT[] - length(FILE_HELPERS)
        (missing_count > 0 && !_helper_spawning[] && isempty(HUNG_ROOTS) && time() - _last_helper_spawn[] > FILE_HELPER_RESPAWN_PAUSE[]) || return
        _helper_spawning[] = true; _last_helper_spawn[] = time()
        @async try
            h = _spawn_file_helper()
            h === nothing || _admit_helper!(h)
        catch
        finally
            _helper_spawning[] = false
        end
    end
end

"""
The path a request is about, as specific as it says: the `path` it names, else its workspace, else
the home directory (what the handlers fall back to). String work only: nothing here asks a filesystem.
"""
function _request_path(request::HTTP.Request)::String
    named = try
        String(get(HTTP.queryparams(HTTP.URI(request.target)), "path", ""))
    catch
        ""
    end
    path = !isempty(named) ? named : String(something(get(request.context, :workspace_root, nothing), user_home()))
    try tamepath(path) catch; path end
end

function _ask_helper(h::FileHelper, method::AbstractString, target::AbstractString, headers, body; deadline::Integer)
    HTTP.request(method, "http://127.0.0.1:$(h.port)" * child_target(target, h.secret), headers, body;
        connect_timeout=2, readtimeout=deadline, redirect=false, retry=false, status_exception=false, decompress=false, cookies=false)
end

"Is this filesystem still hung? Asked (at most once a second) of the helper that stuck on it, as a `stat` of the very path it stuck on."
function _still_hung(key::String)::Bool
    entry = lock(() -> get(HUNG_ROOTS, key, nothing), FILE_HELPERS_LOCK)
    entry === nothing && return false
    h, probed, probe_path = entry
    if h.proc !== nothing && process_exited(h.proc)
        lock(() -> delete!(HUNG_ROOTS, key), FILE_HELPERS_LOCK) # whatever held it is gone: ask afresh
        return false
    end
    time() - probed < 1.0 && return true
    lock(() -> (HUNG_ROOTS[key] = (h, time(), probe_path)), FILE_HELPERS_LOCK)
    ok = try
        r = _ask_helper(h, "GET", "/api/v1/helper/stat?path=" * HTTP.escapeuri(probe_path), Pair{String,String}[], UInt8[]; deadline=1)
        r.status == 200 && !isempty(r.body)
    catch
        false
    end
    ok && lock(() -> delete!(HUNG_ROOTS, key), FILE_HELPERS_LOCK)
    !ok
end

_busy(detail::AbstractString) = _json_response(504, """{"filesystem_busy": true, "detail": $(_json_string(detail))}""")
const _FILESYSTEM_BUSY = "the filesystem that holds these files is not answering; the rest of the workspace keeps working. A listing will catch up by itself; a save that was under way may or may not have been written, check the file when it answers again"
const _HELPER_BUSY = "the file helpers of this hub are waiting on another filesystem that is not answering; files here will be served again when one of them is free"
const _HELPERS_STARTING = "this hub's file helpers are still starting"

"Forward a file request to a helper and relay the answer. Holds a task, never a thread."
function relay_to_file_helper(request::HTTP.Request)::HTTP.Response
    _replace_exited_helpers!()
    path = _request_path(request)
    key = filesystem_key(path)
    _still_hung(key) && return _busy(_FILESYSTEM_BUSY)
    # A first miss is only a suspicion (a big healthy listing is slow too): the next request for this
    # filesystem goes to the SAME helper (another would only stick as well) with a longer deadline.
    suspect = lock(() -> get(SUSPECT_ROOTS, key, nothing), FILE_HELPERS_LOCK)
    stuck = lock(() -> Set(h for (h, _, _) in values(HUNG_ROOTS)), FILE_HELPERS_LOCK)
    suspects = lock(() -> Set(values(SUSPECT_ROOTS)), FILE_HELPERS_LOCK)
    h = if suspect !== nothing && (suspect.proc === nothing || !process_exited(suspect.proc))
        suspect
    else
        free = lock(() -> [x for x in FILE_HELPERS if !(x in stuck) && !(x in suspects) && (x.proc === nothing || !process_exited(x.proc))], FILE_HELPERS_LOCK)
        if isempty(free)
            nobody = lock(() -> isempty(FILE_HELPERS), FILE_HELPERS_LOCK)
            return _busy(nobody ? _HELPERS_STARTING : _HELPER_BUSY)
        end
        rand(free)
    end
    headers = Pair{String,String}[String(k) => String(v) for (k, v) in request.headers if lowercase(String(k)) ∉ _HOP_REQUEST_HEADERS && lowercase(String(k)) != lowercase(WORKSPACE_ROOT_HEADER)]
    ws = get(request.context, :workspace_root, nothing)
    ws === nothing || push!(headers, WORKSPACE_ROOT_HEADER => HTTP.escapeuri(String(ws)))
    deadline = request.method == "GET" ? FILE_HELPER_DEADLINE[] * (suspect === nothing ? 1 : 4) : FILE_HELPER_WRITE_DEADLINE[]
    upstream = try
        _ask_helper(h, request.method, request.target, headers, request.body; deadline)
    catch
        lock(FILE_HELPERS_LOCK) do
            if suspect === nothing && request.method == "GET"
                SUSPECT_ROOTS[key] = h
            else
                delete!(SUSPECT_ROOTS, key); HUNG_ROOTS[key] = (h, time(), path)
            end
        end
        return _busy(_FILESYSTEM_BUSY)
    end
    suspect === nothing || lock(() -> delete!(SUSPECT_ROOTS, key), FILE_HELPERS_LOCK)
    response = HTTP.Response(upstream.status, Pair{String,String}[], upstream.body)
    for hd in upstream.headers
        lowercase(hd.first) ∈ _HOP_RESPONSE_HEADERS && continue
        HTTP.setheader(response, hd)
    end
    response
end

"Is this a directory? One `stat`, asked of a helper when this process forwards (`nothing`: its filesystem is not answering)."
function hub_isdir(path::AbstractString)::Union{Bool,Nothing}
    file_helpers_active() || return offload_blocking(() -> isdir(path))
    response = relay_to_file_helper(HTTP.Request("GET", "/api/v1/helper/stat?path=" * HTTP.escapeuri(String(path))))
    response.status == 200 ? occursin("\"isdir\": true", String(response.body)) : nothing
end

"In a helper only: one `stat`. `{\"exists\": …, \"isdir\": …}`"
function serve_helper_stat(request::HTTP.Request)
    is_file_helper_process() || return HTTP.Response(404)
    path = String(get(HTTP.queryparams(HTTP.URI(request.target)), "path", ""))
    # off the helper's serving thread: a probe of a hung path must cost a worker, not the event loop
    exists, dir = offload_blocking() do
        try
            st = stat(path); (ispath(st), isdir(st))
        catch
            (false, false) # no permission to look is "not there" for our purposes, not "not answering"
        end
    end
    _json_response(200, """{"exists": $(exists), "isdir": $(dir)}""")
end

"In a helper only: write (POST, the body) or remove (DELETE) a file that holds a secret: mode 0600, written whole."
function serve_helper_private_file(request::HTTP.Request)
    is_file_helper_process() || return HTTP.Response(404)
    path = String(get(HTTP.queryparams(HTTP.URI(request.target)), "path", ""))
    (isempty(path) || !isabspath(path)) && return _json_response(400, """{"error": "pass ?path=/abs/file"}""")
    body = String(copy(request.body))
    ok = offload_blocking() do
        try
            if request.method == "DELETE"
                rm(path; force=true)
            else
                mkpath(dirname(path)); _write_private_file_now(path, body)
            end
            true
        catch
            false
        end
    end
    _json_response(ok ? 200 : 500, """{"ok": $(ok)}""")
end

"""
A hub's connection file also goes where older clients look (`legacy_registry_dir`), which on a cluster
is the shared home. The hub does not write there itself: it asks a file helper, in the background,
as soon as one is up. Until then, and if the home is hung, only the node-local file exists.
"""
function announce_legacy_via_helper(registry_file::AbstractString)
    dir = legacy_registry_dir()
    dir === nothing && return nothing
    target = joinpath(dir, basename(registry_file))
    contents = read(registry_file) # node-local
    @async for _ in 1:150
        FILE_HELPER_MODE[] || break
        r = relay_to_file_helper(HTTP.Request("POST", "/api/v1/helper/private_file?path=" * HTTP.escapeuri(target), Pair{String,String}[], contents))
        r.status == 200 && break
        sleep(2)
    end
    nothing
end

"At shutdown, best-effort and bounded: a helper removes what `announce_legacy_via_helper` wrote."
function retract_legacy_via_helper(registry_file::AbstractString)
    dir = legacy_registry_dir()
    (dir === nothing || isempty(registry_file)) && return nothing
    try
        relay_to_file_helper(HTTP.Request("DELETE", "/api/v1/helper/private_file?path=" * HTTP.escapeuri(joinpath(dir, basename(registry_file)))))
    catch
    end
    nothing
end
