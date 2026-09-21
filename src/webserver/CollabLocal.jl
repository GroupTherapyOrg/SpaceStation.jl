###
# Local multi-workspace: the hub server spawns ONE child SpaceStation server per local workspace folder
# (its own OS process, own port, own secret), each opened in its own browser tab. This is the SSH-remote
# model (see CollabRemote.jl) MINUS the SSH hop and tunnel — everything is already local: julia and the
# project are here, there's no bootstrap/install, and the browser reaches the child on 127.0.0.1 directly.
#
# The point: each child is a vanilla `SpaceStation.run(workspace=…)` — an individual server behaves exactly
# like Pluto always has. ALL the multi-workspace orchestration lives out here in the wrapper, never inside
# Pluto. (Per-port cookie scoping — see Authentication.jl — lets the hub and every child coexist in the
# browser, each with its own secret.)
#
# Lifecycle (chosen): closing a workspace TAB leaves its child running, so reopening from the launcher
# reattaches instantly with notebooks still alive (matched by the "workspace" field every server writes
# into its connection file). An explicit "shut down this workspace" stops one child; quitting the hub
# reaps them all — local processes aren't meant to outlive the app that launched them.
###

mutable struct LocalSession
    path::String     # workspace folder (absolute, tamepath'd) — the dict key
    state::String    # starting | ready | error
    detail::String
    port::Int
    secret::String
    proc::Union{Base.Process,Nothing}  # nothing when we reattached to a child we didn't spawn
    task::Union{Task,Nothing}
    cancelled::Bool  # set by the UI to abort an in-flight spawn (the spawn task checks it and bails)
end

const LOCAL_SESSIONS = Dict{String,LocalSession}()
const LOCAL_SESSIONS_LOCK = ReentrantLock()

# Where the browser goes for this workspace: the hub's own page for it (Proxy.jl), relative to the
# hub, so it is right on a Mac (`http://localhost:1234/w/…`) and through an SSH tunnel alike — and it
# carries no secret: the browser holds the hub's, and the child's never leaves this process.
_local_session_url(s::LocalSession) = "$(WORKSPACE_PREFIX)$(workspace_id(s.path))/"

# Find a LIVE child server already serving `path` on THIS node, so a reopened tab reattaches (and a
# crashed-and-restarted hub self-heals) instead of spawning a duplicate. Every server records its
# workspace in its connection file (CollabAPI.write_collab_registry_file); we match on that, restrict to
# this node (shared $HOME on a cluster holds other nodes' files too), and confirm it actually answers.
# The whole scan runs off the serving thread: it is a directory walk plus a read per file on $HOME.
_find_local_server(path::String; pid::Union{Nothing,Integer}=nothing) = offload_blocking(() -> _find_local_server_now(path; pid))

# A child on another SpaceStation version than this hub is never adopted: the hub serves the editor
# and relays the protocol, and the two would disagree. Said once a minute per folder, not per request.
const _version_mismatch_warned = Dict{String,Float64}()
function _warn_version_mismatch(path::String, theirs::AbstractString)
    now = time()
    if now - get(_version_mismatch_warned, path, 0.0) > 60
        _version_mismatch_warned[path] = now
        @warn "SpaceStation: not adopting the workspace server for $(path): it runs $(theirs), this one is $(PLUTO_VERSION_STR). Shut it down and open the workspace again."
    end
end

_find_local_server_now(path::String; pid::Union{Nothing,Integer}=nothing) = (want = tamepath(path); _scan_registry_now(p -> p == want; pid))

"Is a process with this pid running on this machine? (Unix: signal 0. Elsewhere we cannot tell cheaply, so: yes.)"
function _pid_alive(pid::Integer)::Bool
    Sys.isunix() || return true
    0 < pid <= typemax(Cint) || return false
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 || Libc.errno() == Libc.EPERM
end

"""
Walk this node's connection files for a LIVE server whose workspace folder satisfies `matches`
(paths arrive `tamepath`'d). Synchronous disk reads: call through `offload_blocking`.

A connection file is a claim, and it outlives a server that was killed. The port in it proves
nothing: ports are reused, and the next server for the same folder usually gets the same one, and
it binds that port BEFORE it rewrites the file. So a file only counts if the process that wrote it
is still running (its `pid`), and a caller that spawned the server passes that `pid` and accepts no
other file. Without this the hub adopted a dead child's file while the new child held its port, and
relayed every request with the dead child's secret: 403, forever. A dead process's file is skipped,
not deleted: the next server for the port renames its own file over that very name, and a delete
decided on text read a moment ago could remove the new file instead.
"""
function _scan_registry_now(matches::Function; pid::Union{Nothing,Integer}=nothing)
    me = gethostname()
    dir = collab_registry_dir()
    isdir(dir) || return nothing
    for name in readdir(dir)
        endswith(name, ".json") || continue
        txt = try
            read(joinpath(dir, name), String)
        catch
            continue
        end
        node_m = match(r"\"node\": \"([^\"]+)\"", txt)
        node_m !== nothing && String(node_m.captures[1]) != me && continue
        ws_m = match(r"\"workspace\": \"([^\"]+)\"", txt)
        ws_m === nothing && continue
        ws_path = tamepath(String(ws_m.captures[1]))
        matches(ws_path) || continue
        pid_m = match(r"\"pid\": (\d+)", txt)
        if pid_m !== nothing
            file_pid = tryparse(Int, pid_m.captures[1])
            (file_pid === nothing || !_pid_alive(file_pid)) && continue
            pid !== nothing && file_pid != pid && continue
        end
        port_m = match(r"\"port\": (\d+)", txt)
        secret_m = match(r"\"secret\": \"([^\"]+)\"", txt)
        (port_m === nothing || secret_m === nothing) && continue
        version_m = match(r"\"spacestation_version\": \"([^\"]+)\"", txt)
        if version_m !== nothing && String(version_m.captures[1]) != PLUTO_VERSION_STR
            _warn_version_mismatch(ws_path, version_m.captures[1])
            continue
        end
        port = parse(Int, port_m.captures[1])
        # don't adopt a corpse (stale file → tunnel/redirect to a dead port); a server that is merely busy
        # (accepts, answers late) IS the workspace's server — spawning next to it would make two
        _probe_port(port) != :dead || continue
        return (path=ws_path, port=port, secret=String(secret_m.captures[1]))
    end
    nothing
end

# Launch (or reattach to) the child server for one workspace, off the request thread. Mirrors
# _remote_connect_task! but local: no SSH, no install — just spawn `julia --project=… -e 'run(workspace=…)'`
# and wait for its connection file to appear, then hand back port + secret.
function _local_spawn_task!(s::LocalSession)
    # On a cluster the launcher names a directory on the node's own disk (TMPDIR there is often network
    # scratch, and a child whose stderr is a file on a hung filesystem stops at its first message).
    logdir = get(ENV, "SPACESTATION_NODE_DIR", "")
    logfile = joinpath(isempty(logdir) ? tempdir() : logdir, "spacestation-workspace-$(getpid())-$(string(hash(s.path), base=16)).log")
    try
        # Already up (tab reopened, or a previous hub left it running)? Reattach — never duplicate.
        existing = _find_local_server(s.path)
        if existing !== nothing
            s.port = existing.port
            s.secret = existing.secret
            s.state = "ready"
            s.detail = "reattached — this workspace was already running"
            return
        end

        s.state = "starting"
        s.detail = "starting a SpaceStation server for $(basename(s.path))"

        # Reproduce the hub's own environment for the child: same julia, same active project, so the child
        # imports SpaceStation from a precompiled depot (fast — no recompile). The workspace path rides in an
        # ENV var, never interpolated into the -e code, so any folder name survives intact.
        # A workspace server runs notebooks: it needs the USER's julia and depot (their packages, already
        # compiled), which on a cluster is not what this hub runs from (UserEnv.jl).
        projdir = user_project_dir()
        env = _child_env(s.path)
        code = "import SpaceStation; SpaceStation.run(workspace=ENV[\"SPACESTATION_CHILD_WORKSPACE\"], launch_browser=false)"
        # SERVER_THREAD_FLAGS last, so it wins over any --threads julia_cmd() copied from the hub: see Offload.jl.
        cmd = setenv(`$(user_julia_command()) $(SERVER_THREAD_FLAGS) --project=$(projdir) -e $(code)`, env)
        s.proc = Base.run(pipeline(cmd; stdin=devnull, stdout=logfile, stderr=logfile); wait=false)
        child_pid = try getpid(s.proc) catch; nothing end # asked once, now: getpid throws after the process exits
        # Cancelled in the window before/just-after spawn? Don't leave the child orphaned.
        if s.cancelled
            try; process_exited(s.proc) || kill(s.proc); catch; end
            s.state = "error"; s.detail = "canceled"
            return
        end

        # Poll for the child's connection file (it writes one once the HTTP server is listening). The hub's
        # project is already precompiled, so this is load latency (seconds), not a compile.
        for _ in 1:180
            sleep(1)
            if s.cancelled
                try; process_exited(s.proc) || kill(s.proc); catch; end
                s.state = "error"; s.detail = "canceled"
                return
            end
            # only the file written by the process we spawned: see _scan_registry_now
            found = _find_local_server(s.path; pid=child_pid)
            if found !== nothing
                s.port = found.port
                s.secret = found.secret
                s.state = "ready"
                s.detail = "ready — workspace runs on this machine"
                return
            end
            if s.proc !== nothing && process_exited(s.proc)
                s.state = "error"
                s.detail = "the workspace server for $(basename(s.path)) exited before it came up — see $(logfile)"
                return
            end
        end
        s.state = "error"
        s.detail = "the workspace server for $(basename(s.path)) did not come up in time — see $(logfile)"
    catch e
        s.state = "error"
        s.detail = sprint(showerror, e)
    end
end

"""
The environment of a workspace child: the hub's own, minus what a child must not inherit.
`SPACESTATION_HUB=1` marks a hub BEFORE `import SpaceStation`, so it never parses the package
registries (`PkgCompat.__init__`). A child is the process that opens notebooks: with the marker
inherited it would start with an empty registry cache, and `package_exists` would answer no to
every package a notebook adds. The tunneled flags are the hub's too: a local child is never tunneled.
"""
function _child_env(path::AbstractString)::Dict{String,String}
    env = user_env() # what the user launched from, not this hub's cut-down environment (UserEnv.jl)
    # where this hub keeps its node-local state is the hub's to say
    for name in ("SPACESTATION_STATE_HOME", "SPACESTATION_NODE_DIR")
        haskey(ENV, name) && (env[name] = ENV[name])
    end
    depot = get(ENV, "SPACESTATION_USER_DEPOT_PATH", "")
    isempty(depot) || (env["JULIA_DEPOT_PATH"] = depot) # the user's depot, behind a node-local writable one
    env["SPACESTATION_CHILD_WORKSPACE"] = String(path)
    delete!(env, "JULIA_LOAD_PATH")  # don't leak the app's load path into the child (matches worker/terminal hygiene)
    delete!(env, "SPACESTATION_TUNNELED")
    delete!(env, "PLUTOSPACE_TUNNELED")  # legacy alias
    delete!(env, "SPACESTATION_HUB")
    env
end

const CREDENTIAL_REFRESH_COOLDOWN = Ref(3.0)
const _credential_refreshes = Dict{String,Float64}()
const _credential_refreshes_lock = ReentrantLock()

"""
The child refused the hub's credentials. Read them again from its connection file; true when they
changed (the caller retries once). A hub that holds a wrong secret has no other way to notice.
"""
function _refresh_child_credentials!(s::LocalSession)::Bool
    # A child has 403s of its own (a path outside the workspace, a foreign Origin), and each one
    # lands here. The answer is a directory walk on \$HOME: at most one per session every few seconds.
    now = time()
    last = lock(() -> get(_credential_refreshes, s.path, 0.0), _credential_refreshes_lock)
    now - last < CREDENTIAL_REFRESH_COOLDOWN[] && return false
    lock(() -> (_credential_refreshes[s.path] = now), _credential_refreshes_lock)
    pid = try (s.proc !== nothing && !process_exited(s.proc)) ? getpid(s.proc) : nothing catch; nothing end
    found = _find_local_server(s.path; pid)
    found === nothing && return false
    (found.port == s.port && found.secret == s.secret) && return false
    s.port = found.port
    s.secret = found.secret
    true
end

"Get-or-create the local session for a workspace folder; idempotent — a live child is reused, a dead one respawned."
function open_local_session!(path::String)::LocalSession
    path = tamepath(path)
    # The liveness probe can take seconds (a busy child answers late); it runs outside the lock so a
    # hub relaying other workspaces' requests (Proxy.jl resolves under this lock) is never held up.
    existing = lock(() -> get(LOCAL_SESSIONS, path, nothing), LOCAL_SESSIONS_LOCK)
    if existing !== nothing
        if existing.state == "ready" && _probe_port(existing.port) != :dead
            return existing # alive (answering, or busy behind a live port): reuse, never respawn beside it
        end
        if existing.state ∉ ("ready", "error") && existing.task !== nothing && !istaskdone(existing.task)
            return existing # already starting
        end
    end
    lock(LOCAL_SESSIONS_LOCK) do
        s = get(LOCAL_SESSIONS, path, nothing)
        # someone else replaced it while we were probing: theirs wins
        (s !== nothing && s !== existing) && return s
        s = LocalSession(path, "starting", "", 0, "", nothing, nothing, false)
        s.task = @asynclog _local_spawn_task!(s)
        LOCAL_SESSIONS[path] = s
        return s
    end
end

"Shut down the child server for one workspace: ask it to stop cleanly (it removes its own registry + notebooks), then make sure the process is gone, and forget the session."
function shutdown_local_session!(path::String)
    path = tamepath(path)
    s = lock(LOCAL_SESSIONS_LOCK) do
        get(LOCAL_SESSIONS, path, nothing)
    end
    s === nothing || (s.cancelled = true) # also aborts an in-flight spawn task (cancel during "starting")
    lock(() -> delete!(_credential_refreshes, path), _credential_refreshes_lock) # the next child heals at once
    # Works for a child we spawned AND for one we only reattached to (no proc handle): the graceful path
    # is its own /api/v1/shutdown (secret-gated), which fires the child's on_shutdown.
    found = if s !== nothing && s.port != 0
        (port=s.port, secret=s.secret)
    else
        _find_local_server(path)
    end
    if found !== nothing
        try
            HTTP.post("http://127.0.0.1:$(found.port)/api/v1/shutdown?secret=$(HTTP.escapeuri(found.secret))"; cookies=false,
                connect_timeout=3, readtimeout=4, retry=false, status_exception=false)
        catch
        end
    end
    if s !== nothing && s.proc !== nothing
        t = s.proc
        try
            if !process_exited(t)
                sleep(0.5)
                process_exited(t) || kill(t)
                # SIGTERM can leave a Julia 1.12 process spinning in its exit-time finalizers; do not
                # let a child that ignores it outlive the hub with its port.
                timedwait(() -> process_exited(t), 5.0; pollint=0.1)
                process_exited(t) || kill(t, Base.SIGKILL)
            end
        catch
        end
    end
    lock(LOCAL_SESSIONS_LOCK) do
        delete!(LOCAL_SESSIONS, path)
    end
    nothing
end

"""
Stop every child workspace server. Called on hub shutdown: unlike SSH remotes (left running to reattach),
local children live on this machine and shouldn't outlive the app that launched them.
"""
function close_all_local_sessions()
    paths = lock(LOCAL_SESSIONS_LOCK) do
        collect(keys(LOCAL_SESSIONS))
    end
    for p in paths
        try
            shutdown_local_session!(p)
        catch
        end
    end
end

function register_collab_local!(router, session::ServerSession)
    function local_status_json(s::LocalSession)
        _json(Pair[
            "path" => s.path,
            "state" => s.state,
            "detail" => s.detail,
            "url" => s.state == "ready" ? _local_session_url(s) : nothing,
            "wid" => workspace_id(s.path),
        ]) * "\n"
    end

    function serve_local_open(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        isdir_answer = hub_isdir(path) # asked of a file helper in a hub: see FileHelper.jl
        isdir_answer === nothing && return _api_error(504, "the filesystem that holds $path is not answering; try again when it does", false)
        isdir_answer || return _api_error(400, "not a directory: $path", false)
        s = open_local_session!(path)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], local_status_json(s))
    end
    HTTP.register!(router, "POST", "/api/v1/local/open", serve_local_open)

    function serve_local_status(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        path = tamepath(get(query, "path", ""))
        s = lock(LOCAL_SESSIONS_LOCK) do
            get(LOCAL_SESSIONS, path, nothing)
        end
        s === nothing && return _api_error(404, "no local session for $path", false)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], local_status_json(s))
    end
    HTTP.register!(router, "GET", "/api/v1/local/status", serve_local_status)

    # The launcher uses this to show which workspaces are live (so they reattach in one click).
    function serve_local_list(request::HTTP.Request)
        items = lock(LOCAL_SESSIONS_LOCK) do
            Vector{Pair}[
                Pair[
                    "path" => s.path,
                    "state" => s.state,
                    "url" => s.state == "ready" ? _local_session_url(s) : nothing,
                    "wid" => workspace_id(s.path),
                ]
                for s in values(LOCAL_SESSIONS)
            ]
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(items) * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/local/list", serve_local_list)

    # The workspace page's answer to a dead or wedged child (a 503 `workspace_down` from the relay):
    # stop whatever is left of it and spawn a fresh one for the same folder. Answers at once with the
    # new session's status; the page polls /status until it is ready, as on a first open.
    function serve_local_restart(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        try
            shutdown_local_session!(path)
        catch
        end
        s = open_local_session!(path)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], local_status_json(s))
    end
    HTTP.register!(router, "POST", "/api/v1/local/restart", serve_local_restart)

    function serve_local_shutdown(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        # Respond first, tear down on a short delay (the child's shutdown is itself async).
        @async begin
            sleep(0.2)
            try
                shutdown_local_session!(path)
            catch
            end
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["status" => "shutting_down", "path" => path]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/local/shutdown", serve_local_shutdown)
end
