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
"root => (the helper stuck on it, when it was last probed)"
const HUNG_ROOTS = Dict{String,Tuple{FileHelper,Float64}}()
const _last_helper_spawn = Ref(0.0)
const _helper_spawning = Ref(false)

is_file_helper_process() = get(ENV, "SPACESTATION_FILE_HELPER_SECRET", "") != ""
file_helpers_enabled() = get(ENV, "SPACESTATION_FILE_HELPER", "1") != "0"
file_helpers_active() = FILE_HELPER_MODE[] && !is_file_helper_process()

"The header that carries a request's workspace folder to a helper (percent-encoded). Believed only by a helper, which only the hub can reach."
const WORKSPACE_ROOT_HEADER = "X-SpaceStation-Workspace-Root"

"What a helper answers, and nothing else: it is a whole server underneath, and none of the rest (terminals, workspaces, shutdown) is its business."
const _FILE_HELPER_PATHS = Set(["/ping", "/api/v1/browse", "/api/v1/ssh_hosts", "/api/v1/workspace", "/api/v1/workspace/listing",
    "/api/v1/file", "/api/v1/file/save", "/api/v1/file/new", "/api/v1/file/delete", "/api/v1/helper/stat"])
file_helper_serves(path::AbstractString) = path in _FILE_HELPER_PATHS

function _file_helper_command(secret::String)
    proj = something(Base.active_project(), "")
    projdir = isempty(proj) ? pkgdir(@__MODULE__) : dirname(proj)
    env = copy(ENV)
    env["SPACESTATION_FILE_HELPER_SECRET"] = secret
    env["SPACESTATION_HUB"] = "1" # a helper never opens a notebook either: no registry parse at import
    delete!(env, "JULIA_LOAD_PATH")
    code = "import SpaceStation; SpaceStation.file_helper_main()"
    setenv(`$(Base.julia_cmd()) --threads=2,1 --project=$(projdir) -e $(code)`, env)
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
    tasks = [@async begin
        h = try _spawn_file_helper() catch; nothing end
        h === nothing || lock(() -> push!(FILE_HELPERS, h), FILE_HELPERS_LOCK)
        h
    end for _ in 1:count]
    watcher = @async begin
        all(isnothing, fetch.(tasks)) && @warn "SpaceStation: no file helper came up; the workspace's files cannot be listed or edited from this hub until one does"
    end
    wait && Base.wait(watcher)
    nothing
end

function stop_file_helpers!()
    helpers = lock(FILE_HELPERS_LOCK) do
        hs = copy(FILE_HELPERS); empty!(FILE_HELPERS); empty!(HUNG_ROOTS); hs
    end
    FILE_HELPER_MODE[] = false
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
            h === nothing || lock(() -> push!(FILE_HELPERS, h), FILE_HELPERS_LOCK)
        catch
        finally
            _helper_spawning[] = false
        end
    end
end

"The folder a request is about: its workspace, or else the path it names."
function _request_root(request::HTTP.Request)::String
    root = get(request.context, :workspace_root, nothing)
    root === nothing || return String(root)
    try
        String(get(HTTP.queryparams(HTTP.URI(request.target)), "path", ""))
    catch
        ""
    end
end

function _ask_helper(h::FileHelper, method::AbstractString, target::AbstractString, headers, body; deadline::Integer)
    HTTP.request(method, "http://127.0.0.1:$(h.port)" * child_target(target, h.secret), headers, body;
        connect_timeout=2, readtimeout=deadline, redirect=false, retry=false, status_exception=false, decompress=false, cookies=false)
end

"Is `root` still hung? Asked (at most once a second) of the helper that stuck on it, as a `stat` of that root."
function _root_still_hung(root::String)::Bool
    entry = lock(() -> get(HUNG_ROOTS, root, nothing), FILE_HELPERS_LOCK)
    entry === nothing && return false
    h, probed = entry
    if h.proc !== nothing && process_exited(h.proc)
        lock(() -> delete!(HUNG_ROOTS, root), FILE_HELPERS_LOCK) # whatever held it is gone: ask afresh
        return false
    end
    time() - probed < 1.0 && return true
    lock(() -> (HUNG_ROOTS[root] = (h, time())), FILE_HELPERS_LOCK)
    ok = try
        _ask_helper(h, "GET", "/api/v1/helper/stat?path=" * HTTP.escapeuri(root), Pair{String,String}[], UInt8[]; deadline=1).status == 200
    catch
        false
    end
    ok && lock(() -> delete!(HUNG_ROOTS, root), FILE_HELPERS_LOCK)
    !ok
end

const _FILESYSTEM_BUSY = """{"filesystem_busy": true, "detail": "the filesystem that holds these files is not answering; the rest of the workspace keeps working. A listing will catch up by itself; a save that was under way may or may not have been written, check the file when it answers again"}"""
const _HELPERS_STARTING = """{"filesystem_busy": true, "detail": "this hub's file helpers are still starting"}"""

"Forward a file request to a helper and relay the answer. Holds a task, never a thread."
function relay_to_file_helper(request::HTTP.Request)::HTTP.Response
    _replace_exited_helpers!()
    root = _request_root(request)
    _root_still_hung(root) && return _json_response(504, _FILESYSTEM_BUSY)
    stuck = lock(() -> Set(h for (h, _) in values(HUNG_ROOTS)), FILE_HELPERS_LOCK)
    helpers = lock(() -> [h for h in FILE_HELPERS if !(h in stuck) && (h.proc === nothing || !process_exited(h.proc))], FILE_HELPERS_LOCK)
    if isempty(helpers)
        return _json_response(504, isempty(stuck) ? _HELPERS_STARTING : _FILESYSTEM_BUSY)
    end
    h = rand(helpers)
    headers = Pair{String,String}[String(k) => String(v) for (k, v) in request.headers if lowercase(String(k)) ∉ _HOP_REQUEST_HEADERS && lowercase(String(k)) != lowercase(WORKSPACE_ROOT_HEADER)]
    ws = get(request.context, :workspace_root, nothing)
    ws === nothing || push!(headers, WORKSPACE_ROOT_HEADER => HTTP.escapeuri(String(ws)))
    deadline = request.method == "GET" ? FILE_HELPER_DEADLINE[] : FILE_HELPER_WRITE_DEADLINE[]
    upstream = try
        _ask_helper(h, request.method, request.target, headers, request.body; deadline)
    catch
        # never sent to the other helper: it would ask the same filesystem and stick too
        lock(() -> (HUNG_ROOTS[root] = (h, time())), FILE_HELPERS_LOCK)
        return _json_response(504, _FILESYSTEM_BUSY)
    end
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
    st = stat(path)
    _json_response(200, """{"exists": $(ispath(st)), "isdir": $(isdir(st))}""")
end
