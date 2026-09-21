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
# a task, never a thread. A helper that does not answer within the deadline is marked busy and the
# other one is tried; while both are busy the hub answers 504 `filesystem_busy` at once, for those
# requests only. A stuck helper is not killed and not replaced while it is stuck: it cannot be
# killed (it is inside the kernel), it comes back by itself when the filesystem does, and starting a
# process during a hang can itself wait on that filesystem. One that has exited is replaced.
# `SPACESTATION_FILE_HELPER=0` turns the helpers off (file handlers then run in the hub as before).

const FILE_HELPER_COUNT = Ref(2)
"Seconds a helper gets for a listing or a read before it is considered stuck."
const FILE_HELPER_DEADLINE = Ref(3)
"Seconds for a request that writes (a save of a large file is slow on a healthy network filesystem too)."
const FILE_HELPER_WRITE_DEADLINE = Ref(30)

mutable struct FileHelper
    proc::Union{Base.Process,Nothing}
    port::Int
    secret::String
    busy_since::Float64   # 0.0: answering
    lifeline::Any         # the write end of the helper's stdin: held for as long as the helper should live
end

const FILE_HELPERS = FileHelper[]
const FILE_HELPERS_LOCK = ReentrantLock()

is_file_helper_process() = get(ENV, "SPACESTATION_FILE_HELPER_SECRET", "") != ""
file_helpers_enabled() = get(ENV, "SPACESTATION_FILE_HELPER", "1") != "0"
file_helpers_active() = !is_file_helper_process() && lock(() -> !isempty(FILE_HELPERS), FILE_HELPERS_LOCK)

"The header that carries a request's workspace folder to a helper (percent-encoded). Believed only by a helper, which only the hub can reach."
const WORKSPACE_ROOT_HEADER = "X-SpaceStation-Workspace-Root"

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
    reader = @async for line in eachline(out)
        m = match(r"^SPACESTATION_FILE_HELPER_READY (\d+)$", line)
        m === nothing || (port[] = parse(Int, m.captures[1]); break)
    end
    timedwait(() -> port[] != 0 || istaskdone(reader) || process_exited(proc), timeout; pollint=0.1)
    if port[] == 0
        try kill(proc) catch end
        return nothing
    end
    FileHelper(proc, port[], secret, 0.0, lifeline)
end

"Hub startup: bring the helpers up before anything is served. Returns how many answer."
function start_file_helpers!(; count::Integer=FILE_HELPER_COUNT[])::Int
    (file_helpers_enabled() && !is_file_helper_process()) || return 0
    tasks = [@async _spawn_file_helper() for _ in 1:count] # side by side: each is a Julia start
    helpers = filter(!isnothing, fetch.(tasks))
    lock(FILE_HELPERS_LOCK) do
        append!(FILE_HELPERS, helpers)
    end
    isempty(helpers) && @warn "SpaceStation: no file helper came up; this hub will read the workspace's files itself, and will wait with them if their filesystem hangs"
    length(helpers)
end

function stop_file_helpers!()
    helpers = lock(FILE_HELPERS_LOCK) do
        hs = copy(FILE_HELPERS); empty!(FILE_HELPERS); hs
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

function _helper_answers(h::FileHelper)::Bool
    try
        HTTP.get("http://127.0.0.1:$(h.port)/ping"; connect_timeout=1, readtimeout=1, retry=false, status_exception=false, cookies=false).status == 200
    catch
        false
    end
end

"A helper to ask: one that is answering; a busy one is asked again only once it answers a ping. A dead one is replaced in the background."
function _pick_file_helper()::Union{FileHelper,Nothing}
    helpers = lock(() -> copy(FILE_HELPERS), FILE_HELPERS_LOCK)
    for h in helpers
        if h.proc !== nothing && process_exited(h.proc)
            lock(() -> filter!(x -> x !== h, FILE_HELPERS), FILE_HELPERS_LOCK)
            @async begin
                fresh = _spawn_file_helper()
                fresh === nothing || lock(() -> push!(FILE_HELPERS, fresh), FILE_HELPERS_LOCK)
            end
            continue
        end
        h.busy_since == 0.0 && return h
    end
    for h in helpers
        (h.proc === nothing || !process_exited(h.proc)) || continue
        if _helper_answers(h)
            h.busy_since = 0.0
            return h
        end
    end
    nothing
end

const _FILESYSTEM_BUSY = """{"filesystem_busy": true, "detail": "the filesystem that holds these files is not answering; the rest of the workspace keeps working, and this will catch up when it does"}"""

"Forward a file request to a helper and relay the answer. Holds a task, never a thread."
function relay_to_file_helper(request::HTTP.Request)::HTTP.Response
    headers = Pair{String,String}[String(k) => String(v) for (k, v) in request.headers if lowercase(String(k)) ∉ _HOP_REQUEST_HEADERS && lowercase(String(k)) != lowercase(WORKSPACE_ROOT_HEADER)]
    root = get(request.context, :workspace_root, nothing)
    root === nothing || push!(headers, WORKSPACE_ROOT_HEADER => HTTP.escapeuri(String(root)))
    deadline = request.method == "GET" ? FILE_HELPER_DEADLINE[] : FILE_HELPER_WRITE_DEADLINE[]
    # One stuck helper is not yet a stuck filesystem (the other may be asked about another one), so the
    # next is tried before giving up. A write is never sent twice: the first may still land.
    for attempt in 1:(request.method == "GET" ? 2 : 1)
        h = _pick_file_helper()
        h === nothing && break
        upstream = try
            HTTP.request(request.method, "http://127.0.0.1:$(h.port)" * child_target(request.target, h.secret), headers, request.body;
                connect_timeout=2, readtimeout=deadline, redirect=false, retry=false, status_exception=false, decompress=false, cookies=false)
        catch
            h.busy_since = time()
            continue
        end
        response = HTTP.Response(upstream.status, Pair{String,String}[], upstream.body)
        for hd in upstream.headers
            lowercase(hd.first) ∈ _HOP_RESPONSE_HEADERS && continue
            HTTP.setheader(response, hd)
        end
        return response
    end
    _json_response(504, _FILESYSTEM_BUSY)
end

"Is this a directory? Asked of a helper when there are helpers (`nothing`: the filesystem is not answering)."
function hub_isdir(path::AbstractString)::Union{Bool,Nothing}
    file_helpers_active() || return offload_blocking(() -> isdir(path))
    request = HTTP.Request("GET", "/api/v1/browse?path=" * HTTP.escapeuri(String(path)))
    status = relay_to_file_helper(request).status
    status == 200 ? true : status == 504 ? nothing : false
end
