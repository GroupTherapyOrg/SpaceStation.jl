###
# Remote workspaces over SSH (the VS Code Remote-SSH model, EXPERIMENTAL).
#
# Point-and-click from the workspace opener: the LOCAL server orchestrates everything
# under the hood, idempotently —
#   1. reuse: if this host already has a live tunnel, or a SpaceStation server already runs
#      remotely (its connection file says so), just (re)attach. Nothing repeats.
#   2. bootstrap (first contact only): clone the fork to ~/.spacestation/Pluto.jl on the
#      remote and instantiate it.
#   3. start: launch the remote server headless, read its connection file for port+secret.
#   4. tunnel: ssh -N -L <local>:127.0.0.1:<remote>, probe /ping, hand the browser
#      http://localhost:<local>/?secret=… — the ENTIRE Land (files, kernels, terminal,
#      agent API) then runs on the remote with zero further changes.
#
# Keyed SSH only (BatchMode=yes): hosts come from ~/.ssh/config; we never prompt.
###

const REMOTE_BOOTSTRAP_DIR = "~/.spacestation/Pluto.jl"
const REMOTE_FORK_URL = "https://github.com/GroupTherapyOrg/SpaceStation.jl"
const REMOTE_FORK_BRANCH = "main"

mutable struct RemoteSession
    host::String
    state::String   # connecting | checking | installing | starting | tunneling | ready | error
    detail::String
    local_port::Int
    secret::String
    julia::String   # absolute path of julia on the remote, once discovered
    tunnel::Union{Base.Process,Nothing}
    task::Union{Task,Nothing}
    cancelled::Bool # set by the UI to abort an in-flight connect (the connect task checks it and bails)
end

const REMOTE_SESSIONS = Dict{String,RemoteSession}()
const REMOTE_SESSIONS_LOCK = ReentrantLock()

# --- stable local ports -------------------------------------------------------------------------
#
# The browser addresses a remote workspace as `http://localhost:<local_port>/`, so that port IS the
# workspace's identity as far as an open tab, a bookmark or a reload is concerned. Handing it out
# with `listenany(45200)` made it "first free port at this moment", i.e. assigned by arrival order:
#
#   • reconnect a host after its tunnel died and it could come back on a DIFFERENT port, so every
#     tab already open on the old one was dead for good — you had to close it and reopen from
#     homebase, which is the opposite of "refresh and it just works";
#   • worse, a host reconnecting first could inherit a port another host had been using, silently
#     pointing that host's still-open tabs at the WRONG machine.
#
# So a host gets the same port every time. The mapping is remembered on disk (the local hub restarts
# and its tunnels die with it, but the tabs survive — they only need the port to come back), and a
# host that has never been seen starts from a hash of its name so two hosts rarely want the same
# port in the first place. Ports handed to other hosts are never reused while they are remembered.
const TUNNEL_PORT_BASE = 45200
const TUNNEL_PORT_SPAN = 300

tunnel_ports_path() = joinpath(collab_registry_dir(), "tunnel-ports.tsv")

# Julia's `hash` is not promised to be stable across versions, and this value has to mean the same
# thing next month as it does today — so spell the hash out.
_stable_hash(s::AbstractString) = foldl((h, c) -> (h * UInt64(31) + UInt64(c)) & 0x00ffffffffffffff, codeunits(s); init=UInt64(7))

function _read_tunnel_ports()::Dict{String,Int}
    d = Dict{String,Int}()
    path = tunnel_ports_path()
    isfile(path) || return d
    try
        for line in eachline(path)
            parts = split(line, '\t')
            length(parts) == 2 || continue
            p = tryparse(Int, parts[2])
            p === nothing || (d[String(parts[1])] = p)
        end
    catch
    end
    d
end

function _save_tunnel_port(host::AbstractString, port::Integer)
    try
        d = _read_tunnel_ports()
        d[String(host)] = Int(port)
        mkpath(collab_registry_dir())
        # 0o600 like the other files here: this one names the hosts you connect to.
        _write_private_file(tunnel_ports_path(), join(("$(h)\t$(p)" for (h, p) in d), "\n") * "\n")
    catch
    end
end

"Can we bind this local port right now? (The tunnel binds it a moment later — same small race the old `listenany` had.)"
function _port_bindable(port::Integer)::Bool
    try
        server = Sockets.listen(Sockets.localhost, UInt16(port))
        close(server)
        true
    catch
        false
    end
end

"""
The local port for `host`'s tunnel: the same one every time, so a tab opened on it keeps working
across reconnects, sleep/wake and hub restarts.

Falls back to the next free port only when the preferred one is genuinely occupied, and never picks
one that is remembered for a *different* host — that swap is what used to cross-wire two nodes.
"""
function stable_tunnel_port(host::String)::Int
    remembered = _read_tunnel_ports()
    # Ports promised to OTHER hosts are off limits even when free right now — a disconnected host's
    # port being idle is precisely when a newcomer would otherwise steal it and inherit its tabs.
    # `host`'s own remembered port is not in here, so it always gets first refusal on it.
    reserved = Set(p for (h, p) in remembered if h != host)
    preferred = get(remembered, host, TUNNEL_PORT_BASE + Int(mod(_stable_hash(host), TUNNEL_PORT_SPAN)))
    if preferred ∉ reserved && _port_bindable(preferred)
        _save_tunnel_port(host, preferred)
        return preferred
    end
    for candidate in TUNNEL_PORT_BASE:(TUNNEL_PORT_BASE + TUNNEL_PORT_SPAN + 200)
        candidate ∈ reserved && continue
        if _port_bindable(candidate)
            _save_tunnel_port(host, candidate)
            return candidate
        end
    end
    # Everything in the range is spoken for — better a working tunnel on an odd port than none.
    port, probe = Sockets.listenany(Sockets.localhost, TUNNEL_PORT_BASE)
    close(probe)
    Int(port)
end

# ssh joins its argument vector into ONE space-separated string and the remote shell
# re-splits it — so the command must be shell-quoted by US to survive the trip as a
# single `bash -lc` argument. (Without this, `bash -lc rm -rf x` runs bare `rm`.)
# LogLevel=ERROR mutes the SSH *client's* own chatter (the "Permanently added … to known
# hosts" line, and OpenSSH 10's post-quantum "store now, decrypt later" warning) so it
# neither scares the user in the terminal nor pollutes the output we parse. It does NOT
# silence the remote command's own stderr, so real failures stay diagnosable. (A ProxyJump
# hop reads its own config, not this flag — see _ssh_run, which also drops client stderr.)
# SSH connect timeout, in seconds. A homebase setting (the launcher reads/writes it via
# /api/v1/remote/config) — applied to every SSH call AND the tunnel below. Defaults to 25 (was a
# hardcoded 8): a ProxyJump through a busy login node can take well over 8s just to relay the compute
# node's SSH banner, which OpenSSH reports as "Connection timed out during banner exchange". That is a
# SLOW HOP, not an auth failure — the bare terminal `ssh` the user tries has no timeout, so it always
# waits it out and "works fine", while our short cap spuriously fails. Users on slow clusters can raise
# it from the launcher.
const SSH_CONNECT_TIMEOUT = Ref(25)
const SSH_CONNECT_TIMEOUT_MIN, SSH_CONNECT_TIMEOUT_MAX = 3, 180

# ServerAlive* lets a connection that stalls MID-command die in ~60s rather than hang forever.
_ssh_command(host::String, cmd::String) =
    `ssh -o BatchMode=yes -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT[]) -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new $host -- bash -lc $(_shquote(cmd))`

"Run a command on the remote through a login shell (so juliaup/julia are on PATH). Keyed auth only."
function _ssh_run(host::String, cmd::String)::String
    # Drop the client's stderr: across the many polling calls a ProxyJump login node would
    # otherwise reprint its post-quantum warning every time (LogLevel only reaches the final
    # hop). Callers read stdout only and surface their own errors, so nothing useful is lost.
    read(pipeline(_ssh_command(host, cmd); stderr=devnull), String)
end

"Like `_ssh_run`, but never throws: returns (ok, combined stdout+stderr) so failures are diagnosable."
function _ssh_try(host::String, cmd::String)::Tuple{Bool,String}
    out = IOBuffer()
    proc = Base.run(pipeline(_ssh_command(host, cmd); stdout=out, stderr=out); wait=false)
    wait(proc)
    (success(proc), String(take!(out)))
end

_tail(s::String; n=4) = join(last(split(strip(s), '\n'), n), " · ")

# julia is often invisible to non-interactive login shells on clusters (module load / .bashrc
# only happen interactively) — so hunt for it and use the ABSOLUTE path from then on.
const _FIND_JULIA_SNIPPET = raw"""
# prefer a REAL julia binary over the juliaup shim: the shim takes juliaup's config lock
# and may block forever on a hung self-update (e.g. on internet-less compute nodes)
p=$(ls -d "$HOME"/.julia/juliaup/julia-*/bin/julia 2>/dev/null | sort -V | tail -n 1)
[ -z "$p" ] && p=$(command -v julia 2>/dev/null)
case "$p" in *"/.juliaup/bin/"*) real=$(ls -d "$HOME"/.julia/juliaup/julia-*/bin/julia 2>/dev/null | sort -V | tail -n 1); [ -n "$real" ] && p="$real" ;; esac
[ -z "$p" ] && [ -x "$HOME/.juliaup/bin/julia" ] && p="$HOME/.juliaup/bin/julia"
[ -z "$p" ] && [ -x "$HOME/.local/bin/julia" ] && p="$HOME/.local/bin/julia"
[ -z "$p" ] && p=$(bash -ic 'command -v julia' 2>/dev/null | tail -n 1)
case "$p" in /*) echo "JULIA:$p" ;; *) echo "JULIA:" ;; esac
"""

function _find_remote_julia(host::String)::String
    ok, out = _ssh_try(host, _FIND_JULIA_SNIPPET)
    m = match(r"JULIA:(\S+)", out)
    m === nothing ? "" : String(m.captures[1])
end

function _parse_remote_registry(reg::String)
    port_m = match(r"\"port\": (\d+)", reg)
    secret_m = match(r"\"secret\": \"([^\"]+)\"", reg)
    (port_m === nothing || secret_m === nothing) && return nothing
    (port=parse(Int, port_m.captures[1]), secret=String(secret_m.captures[1]))
end

_remote_url(r::RemoteSession) = "http://localhost:$(r.local_port)/?secret=$(r.secret)"

function _local_ping_ok(port::Int)::Bool
    try
        resp = HTTP.get("http://127.0.0.1:$port/ping"; connect_timeout=2, readtimeout=4, retry=false, status_exception=false)
        resp.status == 200
    catch
        false
    end
end

# A registry file can outlive the server that wrote it: HPC jobs end, nodes reboot, and a
# SIGKILL'd server never gets to delete its own connection file. Reusing such a stale file
# tunnels forever to a dead port ("tunnel did not come up"). So before trusting a registry,
# confirm something is actually answering on the remote loopback port — curl /ping when
# available (truest: confirms a live Pluto), else a dependency-free bash /dev/tcp probe.
function _remote_server_alive(host::String, port::Int)::Bool
    probe = """
    if command -v curl >/dev/null 2>&1; then
      curl -fsS -m 4 -o /dev/null http://127.0.0.1:$(port)/ping && echo __LIVE__ || echo __DEAD__
    else
      (exec 3<>/dev/tcp/127.0.0.1/$(port)) 2>/dev/null && echo __LIVE__ || echo __DEAD__
    fi
    """
    _, out = _ssh_try(host, probe)
    occursin("__LIVE__", out)
end

# Discover the SpaceStation server running ON THIS node: scan every connection file in the (possibly NFS-
# shared) registry dir and print the first that belongs to THIS node AND is actually answering on 127.0.0.1.
# Two discriminators, both needed on a shared $HOME:
#   - node match: a "<host>-<port>.json" file records its node, so skip any whose node isn't us. WITHOUT
#     this, two nodes that both grabbed port 1234 each write a file saying "port":1234; curling 127.0.0.1:1234
#     here answers (OUR server) for EITHER file, so we'd hand back a sibling node's file — and its secret —
#     and the tunnel would auth-fail ("secret does not exist"). A bare "<port>.json" from a remote still on
#     the published code has no node field; fall back to the liveness probe alone for those (best effort).
#   - liveness: confirms a real, reachable Pluto (not a stale registry left by a dead server).
# (curl when present — truest — else a dependency-free /dev/tcp probe.)
const _FIND_REMOTE_SERVER_SNIPPET = raw"""
me=$(hostname)
for f in "$HOME"/.local/state/pluto/servers/*.json; do
    [ -e "$f" ] || continue
    p=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$f")
    [ -n "$p" ] || continue
    node=$(sed -n 's/.*"node": *"\([^"]*\)".*/\1/p' "$f")
    [ -n "$node" ] && [ "$node" != "$me" ] && continue
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$p/ping" 2>/dev/null && { cat "$f"; exit 0; }
    else
        (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null && { cat "$f"; exit 0; }
    fi
done
"""

# Keep the remote install in lockstep with `main`: fast-forward the existing clone and report whether
# anything actually changed. This is what makes "the remote always matches your local SpaceStation" —
# the VS Code Remote-SSH feel. No clone yet, or no internet on the node (common for HPC compute
# nodes), is a silent no-op — we keep whatever is already there.
function _maybe_update_remote_clone!(host::String)::Bool
    snippet = """
    d="\$HOME/.spacestation/Pluto.jl"
    [ -d "\$d/.git" ] || { echo __NOCLONE__; exit 0; }
    cd "\$d" || { echo __NOCLONE__; exit 0; }
    before=\$(git rev-parse HEAD 2>/dev/null)
    git fetch --depth 1 origin $(REMOTE_FORK_BRANCH) >/dev/null 2>&1 || { echo __OFFLINE__; exit 0; }
    git reset --hard FETCH_HEAD >/dev/null 2>&1 || { echo __RESETFAIL__; exit 0; }
    after=\$(git rev-parse HEAD 2>/dev/null)
    [ "\$before" = "\$after" ] && echo __UPTODATE__ || echo __UPDATED__
    """
    _, out = _ssh_try(host, snippet)
    occursin("__UPDATED__", out)
end

# The UI can cancel an in-flight connect. The connect task can't be interrupted mid-`_ssh_run`, but it
# checks this between phases and inside its poll loops — so a cancel lands within a couple seconds, tears
# down any half-open tunnel, and stops the remote from being marked ready.
function _remote_bail(r::RemoteSession)::Bool
    r.cancelled || return false
    t = r.tunnel
    t === nothing || try
        process_exited(t) || kill(t)
    catch
    end
    r.state = "error"
    r.detail = "canceled"
    true
end

function _remote_connect_task!(r::RemoteSession)
    try
        _remote_bail(r) && return
        r.state = "connecting"
        r.detail = "reaching $(r.host) with your SSH keys"
        # Use _ssh_try (captures stderr) so we can tell a SLOW HOP from a real auth failure: a
        # ProxyJump banner timeout and a refused key produce very different fixes, and reporting
        # "check your SSH keys" for what is actually a busy login node sends the user down a dead end.
        ok, probe_out = _ssh_try(r.host, "true")
        if !ok
            r.state = "error"
            r.detail = if occursin(r"banner exchange|timed out|timeout|Connection reset"i, probe_out)
                "timed out reaching $(r.host) — the SSH hop is slow right now (often a busy ProxyJump login node), not an auth problem. Try connecting again; it usually goes through on a retry."
            else
                "cannot reach $(r.host) with key-based SSH (check `ssh $(r.host)` works without a password prompt)"
            end
            return
        end

        r.state = "checking"
        r.detail = "looking for a running SpaceStation on $(r.host)"
        reg = try
            _ssh_run(r.host, _FIND_REMOTE_SERVER_SNIPPET)
        catch
            ""
        end
        # The snippet only prints a server that's actually answering on this node, so there's no stale
        # corpse to clear and no foreign-node file to mistake for ours — a dead/other registry is simply
        # never returned, and we fall through to a fresh bootstrap/start.
        remote = _parse_remote_registry(reg)

        # Auto-update: if the clone is behind main, fast-forward it, then retire the running server +
        # its install marker so a fresh, UPDATED server boots below. No-op when already current, not
        # yet cloned, or the node has no internet — so reconnecting always lands you on the latest.
        if _maybe_update_remote_clone!(r.host)
            r.state = "checking"
            r.detail = "updating SpaceStation on $(r.host) to the latest version"
            # Retire only THIS node's server(s): match the node field (skip a sibling node's same-port file
            # on a shared $HOME — see the discovery snippet), then confirm it's actually alive here. kill hits
            # a real pid because a node-matched, answering port is a process on this very node. Bare
            # "<port>.json" files (no node field) fall back to the liveness probe alone.
            _ssh_try(r.host, raw"""
            me=$(hostname)
            rm -f "$HOME/.spacestation/.install_ok"
            for f in "$HOME"/.local/state/pluto/servers/*.json; do
                [ -e "$f" ] || continue
                p=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$f")
                pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$f")
                node=$(sed -n 's/.*"node": *"\([^"]*\)".*/\1/p' "$f")
                [ -n "$node" ] && [ "$node" != "$me" ] && continue
                alive=0
                if command -v curl >/dev/null 2>&1; then
                    curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$p/ping" 2>/dev/null && alive=1
                else
                    (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null && alive=1
                fi
                [ "$alive" = 1 ] || continue
                [ -n "$pid" ] && kill "$pid" 2>/dev/null
                rm -f "$f"
            done
            """)
            remote = nothing
        end

        if remote === nothing
            # find julia (absolute path) — checks PATH, juliaup, ~/.local/bin, and an interactive shell (for module/.bashrc setups)
            r.julia = _find_remote_julia(r.host)
            if isempty(r.julia)
                r.state = "error"
                r.detail = "julia not found on $(r.host) — tried the login-shell PATH, ~/.juliaup/bin, ~/.local/bin, and an interactive shell. Install juliaup there, or add 'module load julia' to your ~/.bash_profile."
                return
            end

            # idempotent bootstrap with a COMPLETION MARKER (the VS Code Remote-SSH pattern):
            # the install only counts once instantiate finished; a clone without the marker
            # resumes at instantiate, a missing clone starts over.
            ok, out = _ssh_try(r.host, "test -f ~/.spacestation/.install_ok && echo done; test -d $(REMOTE_BOOTSTRAP_DIR)/.git && echo cloned")
            install_done = occursin("done", out)
            cloned = occursin("cloned", out)
            # The marker only says that an earlier instantiate completed. On HPC systems DEPOT_PATH is
            # commonly shared across nodes, and an artifact can later be garbage-collected, partially
            # written, or otherwise disappear while .install_ok remains. Validate the thing we actually
            # need before trusting the marker. A failed import invalidates it and falls through to the
            # detached repair/install path below instead of repeatedly launching a server that crashes.
            if install_done
                r.state = "checking"
                r.detail = "validating the SpaceStation installation on $(r.host)"
                healthy, _ = _ssh_try(r.host,
                    "$(r.julia) --project=$(REMOTE_BOOTSTRAP_DIR) -e 'import SpaceStation'")
                if !healthy
                    _ssh_try(r.host, "rm -f ~/.spacestation/.install_ok")
                    install_done = false
                    r.state = "installing"
                    r.detail = "repairing missing or damaged SpaceStation dependencies on $(r.host)"
                end
            end
            if !install_done
                r.state = "installing"
                if !cloned
                    r.detail = "first-time setup on $(r.host): cloning SpaceStation (a minute or two)"
                    ok, out = _ssh_try(r.host, "rm -rf $(REMOTE_BOOTSTRAP_DIR) && mkdir -p ~/.spacestation && git clone --depth 1 --branch $(REMOTE_FORK_BRANCH) $(REMOTE_FORK_URL) $(REMOTE_BOOTSTRAP_DIR)")
                    if !ok
                        hint = occursin(r"resolve host|Could not resolve|unable to access|Connection timed out|Network is unreachable"i, out) ?
                            " — this node looks like it has NO INTERNET ACCESS (common for HPC compute/GPU nodes). Try your LOGIN node instead, or clone SpaceStation to $(REMOTE_BOOTSTRAP_DIR) there manually." : ""
                        r.state = "error"
                        r.detail = "git clone failed on $(r.host): $(_tail(out))$(hint)"
                        return
                    end
                end
                # run the slow step DETACHED on the remote (nohup + pidfile + log): it survives
                # connection drops and local restarts; we just poll for the completion marker.
                # If an install is already running (e.g. we reconnected), attach to it instead.
                _, out = _ssh_try(r.host, "kill -0 \$(cat ~/.spacestation/install.pid 2>/dev/null) 2>/dev/null && echo alive || echo dead")
                if !occursin("alive", out)
                    launch = """
                    mkdir -p ~/.spacestation
                    rm -f ~/.spacestation/.install_ok
                    nohup sh -c 'cd "\$HOME/.spacestation/Pluto.jl" && $(r.julia) --project=. -e "import Pkg; Pkg.instantiate(); import SpaceStation" && touch "\$HOME/.spacestation/.install_ok"' > ~/.spacestation/install.log 2>&1 < /dev/null &
                    echo \$! > ~/.spacestation/install.pid
                    echo launched
                    """
                    ok, out = _ssh_try(r.host, launch)
                    if !ok || !occursin("launched", out)
                        r.state = "error"
                        r.detail = "could not start the install on $(r.host): $(_tail(out))"
                        return
                    end
                end
                started = time()
                while true
                    sleep(5)
                    _remote_bail(r) && return
                    elapsed = round(Int, (time() - started) / 60)
                    # PROOF over promises: stream the live install log line into the banner.
                    # Fence the tail behind a __LOG__ marker and extract only that — a ProxyJump
                    # login node reprints its post-quantum warning on every hop (LogLevel can't
                    # reach it), and without the fence that client chatter would land in the
                    # banner instead of the real progress line.
                    _, out = _ssh_try(r.host, "test -f ~/.spacestation/.install_ok && echo __DONE__; kill -0 \$(cat ~/.spacestation/install.pid 2>/dev/null) 2>/dev/null && echo __ALIVE__; printf '__LOG__%s' \"\$(tail -n 1 ~/.spacestation/install.log 2>/dev/null)\"")
                    occursin("__DONE__", out) && break
                    log_m = match(r"__LOG__(.*)", out)
                    log_line = log_m === nothing ? "" : strip(String(log_m.captures[1]))
                    if occursin("Juliaup configuration is locked", out)
                        _ssh_try(r.host, "kill -9 \$(cat ~/.spacestation/install.pid 2>/dev/null) 2>/dev/null; rm -f ~/.spacestation/install.pid")
                        r.state = "error"
                        r.detail = "the juliaup shim deadlocked on its config lock on $(r.host) (often a hung self-update on an internet-less node) — retry: the real julia binary will be used directly"
                        return
                    end
                    if !occursin("__ALIVE__", out)
                        _, log = _ssh_try(r.host, "tail -n 6 ~/.spacestation/install.log 2>/dev/null")
                        r.state = "error"
                        r.detail = "Pkg.instantiate failed on $(r.host): $(_tail(log))"
                        return
                    end
                    r.detail = "installing on $(r.host) ($(elapsed) min): $(isempty(log_line) ? "starting up…" : last(log_line, 110))"
                    if time() - started > 45 * 60
                        r.state = "error"
                        r.detail = "install on $(r.host) still not finished after 45 minutes — check ~/.spacestation/install.log there"
                        return
                    end
                end
            end

            r.state = "starting"
            r.detail = "starting the SpaceStation server on $(r.host)"
            # SPACESTATION_TUNNELED marks this server as reached over an SSH tunnel: its child workspace
            # ports aren't forwarded to the browser, so its frontend opens workspaces IN-PLACE instead of
            # spawning unreachable children (see serve_api_config + land.js).
            _ssh_run(r.host, "export SPACESTATION_TUNNELED=1; nohup $(r.julia) --project=$(REMOTE_BOOTSTRAP_DIR) -e 'import SpaceStation; SpaceStation.run(launch_browser=false)' > ~/.spacestation/server.log 2>&1 < /dev/null & disown; true")
            for _ in 1:90
                sleep(2)
                _remote_bail(r) && return
                reg = try
                    # the server we just launched announces itself by answering /ping on this node (see snippet)
                    _ssh_run(r.host, _FIND_REMOTE_SERVER_SNIPPET)
                catch
                    ""
                end
                remote = _parse_remote_registry(reg)
                remote === nothing || break
            end
            if remote === nothing
                r.state = "error"
                r.detail = "the remote server did not come up — see ~/.spacestation/server.log on $(r.host)"
                return
            end
        end

        r.state = "tunneling"
        r.detail = "opening the SSH tunnel"
        local_port = stable_tunnel_port(r.host)
        # `-n` + stdin=devnull keep the tunnel ssh OFF the launching terminal's stdin: a backgrounded
        # `ssh -N` otherwise fights the shell for the terminal, so quitting the server (or just having a
        # remote open) can leave that terminal "disconnected". stdout→devnull too — we only watch
        # process_exited and the /ping probe, never the tunnel's streams.
        r.tunnel = Base.run(pipeline(`ssh -n -o BatchMode=yes -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT[]) -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR -o ExitOnForwardFailure=yes -N -L $local_port:127.0.0.1:$(remote.port) $(r.host)`; stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
        ok = false
        for _ in 1:20
            sleep(1)
            _remote_bail(r) && return
            if _local_ping_ok(local_port)
                ok = true
                break
            end
            process_exited(r.tunnel) && break
        end
        if !ok
            r.state = "error"
            r.detail = "tunnel did not come up (local port $local_port → $(r.host):$(remote.port))"
            return
        end
        _remote_bail(r) && return

        r.local_port = local_port
        r.secret = remote.secret
        # a local connection file so pluto-collab and agents reach the REMOTE workspace transparently
        try
            dir = collab_registry_dir()
            mkpath(dir)
            try
                Sys.iswindows() || chmod(dir, 0o700)
            catch
            end
            path = collab_registry_path(local_port)
            # 0o600 from creation (holds the remote's secret) — see _write_private_file.
            _write_private_file(path, """{"pid": $(getpid()), "host": "127.0.0.1", "port": $(local_port), "node": $(_json_string(gethostname())), "secret": $(_json_string(remote.secret)), "remote_ssh_host": $(_json_string(r.host)), "spacestation_version": $(_json_string(PLUTO_VERSION_STR)), "pluto_version": $(_json_string(PLUTO_VERSION_STR)), "started_at": $(time())}\n""")
        catch end
        r.state = "ready"
        r.detail = "connected — the workspace runs on $(r.host)"
    catch e
        r.state = "error"
        r.detail = sprint(showerror, e)
    end
end

"""
Kill every live SSH tunnel. Called on server shutdown so the `ssh -N -L` children don't orphan
onto the launching terminal. The REMOTE servers themselves are intentionally left running — they
persist and reattach (the tmux-without-tmux design), so quitting locally never loses remote work.
"""
function close_all_remote_tunnels()
    lock(REMOTE_SESSIONS_LOCK) do
        for r in values(REMOTE_SESSIONS)
            t = r.tunnel
            t === nothing && continue
            try
                process_exited(t) || kill(t)
            catch
            end
            # Drop the tunnel's local connection file: its recorded pid is OURS (the hub's), so
            # the CLIs' `kill -0` liveness check would keep trusting the file long after the
            # tunnel port went dead — a phantom server that slows every discovery.
            r.local_port > 0 && remove_collab_registry_file(r.local_port)
        end
    end
end

"Get-or-create the remote session for a host; idempotent — a live tunnel is reused, a dead one restarted."
function open_remote_session!(host::String)::RemoteSession
    lock(REMOTE_SESSIONS_LOCK) do
        r = get(REMOTE_SESSIONS, host, nothing)
        if r !== nothing
            if r.state == "ready" && r.tunnel !== nothing && !process_exited(r.tunnel) && _local_ping_ok(r.local_port)
                return r # alive: nothing to repeat
            end
            if r.state ∉ ("ready", "error") && r.task !== nothing && !istaskdone(r.task)
                return r # already connecting
            end
        end
        r = RemoteSession(host, "connecting", "", 0, "", "", nothing, nothing, false)
        r.task = @asynclog _remote_connect_task!(r)
        REMOTE_SESSIONS[host] = r
        return r
    end
end

"""
Cancel/forget a remote session: flag the connect task to bail, tear down a half-open tunnel, and drop it
from the registry. Serves the UI's ✕ — whether the session is still connecting (cancel), errored (dismiss),
or ready (disconnect; the remote server itself persists and re-tunnels on the next connect).
"""
function cancel_remote_session!(host::String)
    r = lock(REMOTE_SESSIONS_LOCK) do
        get(REMOTE_SESSIONS, host, nothing)
    end
    if r !== nothing
        r.cancelled = true
        t = r.tunnel
        t === nothing || try
            process_exited(t) || kill(t)
        catch
        end
        # see close_all_remote_tunnels: the tunnel's connection file outlives its dead port otherwise
        r.local_port > 0 && remove_collab_registry_file(r.local_port)
    end
    lock(REMOTE_SESSIONS_LOCK) do
        delete!(REMOTE_SESSIONS, host)
    end
    nothing
end

# --- keeping tunnels up ---------------------------------------------------------------------------
#
# `ssh -N -L` is a child process, and nothing was watching it. With ServerAliveInterval=15 and
# ServerAliveCountMax=4 it gives up about a minute after the network stops answering — which is what
# closing a laptop lid does. The remote server itself survives (it is nohup'd and disowned), so the
# work is all still there; only the path to it is gone. But `open_remote_session!` rebuilds a dead
# tunnel just once, when something calls it, and the only caller was the Connect button. So a lid
# close meant: reopen homebase, find the host, click connect.
#
# The watchdog closes that loop. It re-runs the ordinary connect path, which is idempotent and
# already handles "remote server also died" — and now lands on the same local port every time, so a
# tab left open across the gap starts working again by itself.
const TUNNEL_WATCHDOG_PERIOD = 5.0
const TUNNEL_RETRY_MIN = 5.0
const TUNNEL_RETRY_MAX = 120.0
const TUNNEL_RETRY = Dict{String,Tuple{Float64,Float64}}() # host => (next attempt at, current delay)
const TUNNEL_WATCHDOG = Ref{Union{Task,Nothing}}(nothing)

"Is this session's path to the remote actually usable right now?"
function _tunnel_healthy(r::RemoteSession)::Bool
    r.tunnel === nothing && return false
    process_exited(r.tunnel) && return false
    _local_ping_ok(r.local_port)
end

function _supervise_tunnels_once()
    ready = lock(REMOTE_SESSIONS_LOCK) do
        [(h, r) for (h, r) in REMOTE_SESSIONS if r.state == "ready" && !r.cancelled]
    end
    for (host, r) in ready
        if _tunnel_healthy(r)
            lock(REMOTE_SESSIONS_LOCK) do
                delete!(TUNNEL_RETRY, host) # healthy again: forget the backoff
            end
            continue
        end

        now = time()
        due = lock(REMOTE_SESSIONS_LOCK) do
            at, delay = get(TUNNEL_RETRY, host, (0.0, TUNNEL_RETRY_MIN))
            now < at && return false
            # back off while it keeps failing: a node that is off for the weekend must not be
            # probed every 5s, and each probe costs an SSH round trip.
            TUNNEL_RETRY[host] = (now + delay, min(delay * 2, TUNNEL_RETRY_MAX))
            true
        end
        due || continue

        # Say so in the UI rather than leaving a stale "ready" while nothing works.
        r.state = "tunneling"
        r.detail = "connection lost — reconnecting to $(host)"
        try
            t = r.tunnel
            t === nothing || process_exited(t) || kill(t)
        catch
        end
        lock(REMOTE_SESSIONS_LOCK) do
            # only start a rebuild if one is not already running for this host
            if r.task === nothing || istaskdone(r.task)
                r.task = @asynclog _remote_connect_task!(r)
            end
        end
    end
end

"Start the tunnel watchdog once per server process."
function start_tunnel_watchdog!()
    TUNNEL_WATCHDOG[] === nothing || return
    TUNNEL_WATCHDOG[] = @asynclog while true
        sleep(TUNNEL_WATCHDOG_PERIOD)
        try
            _supervise_tunnels_once()
        catch e
            # a watchdog that dies on one bad host is worse than no watchdog
            @debug "tunnel watchdog iteration failed" exception = (e, catch_backtrace())
        end
    end
    nothing
end

function register_collab_remote!(router, session::ServerSession)
    start_tunnel_watchdog!()

    function remote_status_json(r::RemoteSession)
        _json(Pair[
            "host" => r.host,
            "state" => r.state,
            "detail" => r.detail,
            "url" => r.state == "ready" ? _remote_url(r) : nothing,
        ]) * "\n"
    end

    function serve_remote_open(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "host") || return _api_error(400, "pass ?host=<ssh-config-host>", false)
        host = query["host"]
        # Reject a leading '-' so the host can't be read by ssh as an option (`-Ffile`, `-D1234`,
        # …). The rest of the charset already excludes '=' , '/' and space, so no option that needs
        # an argument can be smuggled; this closes the last argv-injection foothold.
        (occursin(r"^[A-Za-z0-9._@-]+$", host) && !startswith(host, "-")) || return _api_error(400, "invalid host name", false)
        r = open_remote_session!(host)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], remote_status_json(r))
    end
    HTTP.register!(router, "POST", "/api/v1/remote/open", serve_remote_open)

    function serve_remote_status(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        host = get(query, "host", "")
        r = lock(REMOTE_SESSIONS_LOCK) do
            get(REMOTE_SESSIONS, host, nothing)
        end
        r === nothing && return _api_error(404, "no session for $host", false)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], remote_status_json(r))
    end
    HTTP.register!(router, "GET", "/api/v1/remote/status", serve_remote_status)

    # The launcher's "homebase" lists every active remote alongside the local workspaces (see
    # /api/v1/local/list), so you see — and reattach to — all running workspaces from one place.
    function serve_remote_list(request::HTTP.Request)
        items = lock(REMOTE_SESSIONS_LOCK) do
            Vector{Pair}[
                Pair[
                    "host" => r.host,
                    "state" => r.state,
                    "url" => r.state == "ready" ? _remote_url(r) : nothing,
                ]
                for r in values(REMOTE_SESSIONS)
            ]
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(items) * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/remote/list", serve_remote_list)

    function serve_remote_cancel(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "host") || return _api_error(400, "pass ?host=<ssh-config-host>", false)
        host = query["host"]
        @async begin
            sleep(0.1)
            try
                cancel_remote_session!(host)
            catch
            end
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["status" => "canceled", "host" => host]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/remote/cancel", serve_remote_cancel)

    # Homebase setting: the SSH connect timeout (seconds). The launcher reads it (GET) and writes it
    # (POST ?connect_timeout=N) so users on a slow ProxyJump cluster can give the banner exchange more
    # than the 25s default. Clamped to a sane range; takes effect on the next SSH call/tunnel. A server
    # restart resets it to the default, so the launcher re-pushes its stored value on load.
    remote_config_json() = _json(Pair["connect_timeout" => SSH_CONNECT_TIMEOUT[]]) * "\n"
    function serve_remote_config(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        if haskey(query, "connect_timeout")
            v = tryparse(Int, query["connect_timeout"])
            v === nothing && return _api_error(400, "connect_timeout must be an integer number of seconds", false)
            SSH_CONNECT_TIMEOUT[] = clamp(v, SSH_CONNECT_TIMEOUT_MIN, SSH_CONNECT_TIMEOUT_MAX)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], remote_config_json())
    end
    HTTP.register!(router, "GET", "/api/v1/remote/config", serve_remote_config)
    HTTP.register!(router, "POST", "/api/v1/remote/config", serve_remote_config)

    # Shut the whole server down cleanly from the UI — the terminal-independent way out. Behind the
    # normal secret (auth_middleware gates /api/v1/*). Respond FIRST, then tear down on a short delay
    # so the 200 reaches the browser: close SSH tunnels, then stop the HTTP server (which fires
    # on_shutdown — notebooks, registry file — and unblocks `wait`, so a CLI launch exits).
    function serve_shutdown(request::HTTP.Request)
        @info "Shutdown requested from the SpaceStation UI"
        @async begin
            sleep(0.4)
            try
                close_all_remote_tunnels()
            catch
            end
            try
                close_all_local_sessions() # reap child workspace servers (local processes — don't outlive the hub)
            catch
            end
            try
                request_server_shutdown()
            catch e
                @warn "server shutdown failed" exception = (e, catch_backtrace())
            end
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["status" => "shutting_down"]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/shutdown", serve_shutdown)
end
