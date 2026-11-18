###
# Remote workspaces over SSH (the VS Code Remote-SSH model, EXPERIMENTAL).
#
# Point-and-click from the workspace opener: the LOCAL server orchestrates everything
# under the hood, idempotently —
#   1. reuse: if this host already has a live tunnel, or a SpaceStation server already runs
#      remotely (its connection file says so), just (re)attach. Nothing repeats.
#   2. bootstrap (first contact only): clone the fork to ~/.spacestation/Pluto.jl on the
#      remote. What RUNS is never the clone: each commit is exported once to its own directory,
#      ~/.spacestation/versions/<commit>, instantiated there, and never changed afterwards
#      (see "installed versions": the home is shared by every node of a cluster).
#   3. start: launch the remote server headless, read its connection file for port+secret.
#   4. tunnel: ssh -N -L 127.0.0.1:<local>:127.0.0.1:<remote>, probe /ping, hand the browser
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

# Which hosts the user is currently attached to. Remembered so a hub restart (a reboot, a crash,
# quitting and relaunching) can put the tunnels back on their stable ports — otherwise a workspace
# tab left open over lunch answers a hard refresh with the browser's own "can't be reached" page,
# and nothing in it can help, because our code never runs. The remote servers themselves are
# deliberately left running when the hub goes away, so restoring is just re-opening the door to work
# that is still there. A host leaves this list only when the user explicitly disconnects it.
active_remotes_path() = joinpath(collab_registry_dir(), "active-remotes.tsv")

function _read_active_remotes()::Vector{String}
    path = active_remotes_path()
    isfile(path) || return String[]
    try
        String[String(l) for l in strip.(readlines(path)) if !isempty(l)]
    catch
        String[]
    end
end

function _set_active_remote!(host::AbstractString, active::Bool)
    try
        hosts = Set(_read_active_remotes())
        active ? push!(hosts, String(host)) : delete!(hosts, String(host))
        mkpath(collab_registry_dir())
        _write_private_file(active_remotes_path(), isempty(hosts) ? "" : join(sort(collect(hosts)), "\n") * "\n")
    catch
    end
end

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

# --- diagnosing a shadowed ssh_config entry ---------------------------------------------------------
#
# OpenSSH uses the FIRST value it finds for each keyword, across every block matching a host. Tools
# that generate config entries per compute job (HPC3 Launcher, and most SLURM helpers) append a new
# block each time a node is reallocated, so the alias ends up defined several times and the OLDEST
# definition is the one in force — routing through a jump host whose job finished weeks ago. It
# resolves, so ssh does not complain; it just fails to connect. That is indistinguishable from "your
# keys are wrong" unless somebody says otherwise, which is what this does.
#
# Strictly diagnosis. Editing somebody's ~/.ssh/config is not ours to do.

"""
The `ProxyJump` of each block naming `host` EXACTLY, in file order; `nothing` for a block that sets
none. Only an exact token counts, so a wildcard block (`Host hpc3-*`) is never mistaken for a second
definition of this alias.
"""
function _host_blocks(config_text::AbstractString, host::AbstractString)::Vector{Union{Nothing,String}}
    blocks = Union{Nothing,String}[]
    in_block = false
    for line in eachline(IOBuffer(String(config_text)))
        stripped = strip(line)
        (isempty(stripped) || startswith(stripped, "#")) && continue
        host_line = match(r"^(?i:Host)\s+(.*)$", stripped)
        if host_line !== nothing
            in_block = String(host) ∈ split(host_line.captures[1])
            in_block && push!(blocks, nothing)
            continue
        end
        if in_block
            jump = match(r"^(?i:ProxyJump)\s+(\S+)", stripped)
            jump === nothing || (blocks[end] = String(jump.captures[1]))
        end
    end
    blocks
end

"""
Say what is wrong when duplicate blocks disagree, or `nothing` when there is nothing to say.

Deliberately quiet unless the situation is both unambiguous and actionable: several blocks, more
than one `ProxyJump` among them, and ssh landing on one that is not the last written. If ssh already
resolves to the newest definition the duplication is harmless today, and if the effective value came
from somewhere we did not read (a wildcard block, an `Include`, /etc/ssh) we do not understand the
file well enough to advise on it.
"""
function _describe_ssh_config_conflict(host, effective, blocks::Vector{Union{Nothing,String}})
    length(blocks) < 2 && return nothing
    effective === nothing && return nothing
    jumps = String[b for b in blocks if b !== nothing]
    length(unique(jumps)) < 2 && return nothing
    String(effective) ∈ jumps || return nothing
    String(effective) == jumps[end] && return nothing
    string(
        "Your ~/.ssh/config defines `", host, "` ", length(blocks),
        " times with different ProxyJump values. SSH uses the FIRST one it finds, so this connection went through `",
        effective, "`, while the last block names `", jumps[end],
        "`. If that first block belongs to a job that has ended, delete it — or move the newest block above the others.",
    )
end

"Look for a shadowed duplicate entry for `host`. Never throws, and says nothing unless it is sure."
function ssh_config_conflict(host::AbstractString)::Union{Nothing,String}
    try
        path = joinpath(homedir(), ".ssh", "config")
        isfile(path) || return nothing
        # `ssh -G` resolves the config without connecting, and is the authority on what ssh will
        # actually use — far safer than re-implementing Match/Include/wildcard precedence ourselves.
        out = read(pipeline(`ssh -G $(host)`; stderr=devnull), String)
        effective = nothing
        for line in eachline(IOBuffer(out))
            m = match(r"^proxyjump\s+(\S+)", line)
            if m !== nothing
                effective = String(m.captures[1])
                break
            end
        end
        _describe_ssh_config_conflict(host, effective, _host_blocks(read(path, String), host))
    catch
        nothing
    end
end

# --- holding the port while the tunnel is down ------------------------------------------------------
#
# `ssh -L` owns the local port, so when ssh dies the port goes silent and the browser answers a
# reload with its OWN "this site can't be reached" — a page none of our code runs in. The tab can do
# nothing about it, which is why a dropped tunnel used to mean closing the tab and reopening the
# workspace from homebase.
#
# So while the tunnel is down the hub takes the port over itself and answers 503 with a page that
# waits for the real server to return. A hard refresh then lands on *our* page. The status has to
# stay 503: `_local_ping_ok` treats only 200 as healthy, and a placeholder that looked healthy would
# convince the watchdog there was nothing to fix.
const PLACEHOLDERS = Dict{String,Any}()
const PLACEHOLDERS_LOCK = ReentrantLock()

function _placeholder_page(host::AbstractString)
    """<!doctype html><html><head><meta charset="utf-8"><title>Reconnecting…</title>
    <meta name="color-scheme" content="light dark">
    <style>
      body{font:15px/1.6 system-ui,-apple-system,sans-serif;display:grid;place-items:center;height:100vh;margin:0;
           background:#1b1e28;color:#dfe1e8}
      @media (prefers-color-scheme: light){body{background:#f7f7f9;color:#22242b}}
      .c{max-width:32rem;padding:0 1.5rem;text-align:center}
      h1{font-size:1.05rem;margin:0 0 .4rem}
      p{opacity:.7;margin:.3rem 0}
      code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
      .s{width:1.1rem;height:1.1rem;margin:0 auto 1rem;border-radius:50%;border:2px solid currentColor;
         border-top-color:transparent;animation:r .8s linear infinite;opacity:.6}
      @keyframes r{to{transform:rotate(360deg)}}
    </style></head><body><div class="c">
      <div class="s"></div>
      <h1>Reconnecting to <code>$(host)</code>…</h1>
      <p>The workspace is still running on the remote machine. This page reloads itself as soon as the
         connection is back.</p>
    </div>
    <script>
      // Reload only once the REAL server answers: the placeholder marks its own replies, so a reply
      // carrying that marker means we are still talking to the stand-in.
      setInterval(async () => {
        try {
          const r = await fetch("./ping", { cache: "no-store" })
          if (!r.headers.get("X-SpaceStation-Reconnecting")) location.reload()
        } catch (e) {}
      }, 2000)
    </script></body></html>"""
end

"Take over `port` with a page that waits for the tunnel to come back. Idempotent per host."
function _start_placeholder!(host::AbstractString, port::Integer)
    lock(PLACEHOLDERS_LOCK) do
        haskey(PLACEHOLDERS, String(host)) && return
        body = _placeholder_page(host)
        try
            server = HTTP.listen!(Sockets.localhost, UInt16(port); verbose=-1) do http::HTTP.Stream
                HTTP.setstatus(http, 503)
                HTTP.setheader(http, "Content-Type" => "text/html; charset=utf-8")
                HTTP.setheader(http, "X-SpaceStation-Reconnecting" => "1")
                HTTP.setheader(http, "Cache-Control" => "no-store")
                HTTP.setheader(http, "Retry-After" => "2")
                # Explicit length rather than chunked: without it HTTP.jl streams the body chunked
                # and Chrome aborts the navigation (net::ERR_ABORTED), which puts the browser's own
                # error page back on screen — the exact thing this server exists to prevent. curl is
                # lenient about the missing terminator, so this only shows up in a real browser.
                HTTP.setheader(http, "Content-Length" => string(sizeof(body)))
                HTTP.startwrite(http)
                # a HEAD (or a probe that hangs up early) must not take the placeholder down
                try
                    write(http, body)
                catch
                end
            end
            PLACEHOLDERS[String(host)] = server
        catch
            # the port is busy — most likely the tunnel is already back, which is the good case
        end
    end
    nothing
end

"Release the port so `ssh -L` can bind it."
function _stop_placeholder!(host::AbstractString)
    server = lock(PLACEHOLDERS_LOCK) do
        pop!(PLACEHOLDERS, String(host), nothing)
    end
    server === nothing && return
    try
        close(server)
    catch
    end
    nothing
end

"""
Is `r` still the session for its host? The UI's ✕ and a reconnect both replace the session, but a
connect task cannot be interrupted mid-SSH-call, so the old one can still be running long after it
was dropped. It must not touch the host's port any more: the new session owns it now.
"""
_is_current_session(r::RemoteSession) =
    !r.cancelled && lock(() -> get(REMOTE_SESSIONS, r.host, nothing) === r, REMOTE_SESSIONS_LOCK)

"""
Put the placeholder on `port` — but only for the session that owns the host. A superseded session
re-taking the port between the new session's `_stop_placeholder!` and its `ssh -L` binding it is how a
tunnel to a perfectly healthy host came up "did not come up": ssh lost the bind, and every probe
reached the placeholder's 503.
"""
_hold_port!(r::RemoteSession, port::Integer) = _is_current_session(r) && _start_placeholder!(r.host, port)

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

"""
One probe of `127.0.0.1:<port>/ping`, classified by WHAT went wrong rather than whether anything
did: `:ok` (answered 200), `:busy` (accepted the connection, then said nothing for `wait` seconds)
or `:dead` (refused, reset, closed without answering, or answered anything but 200).

The distinction is the whole point. A Pluto server runs its notebooks on the same single thread that
answers HTTP, so a notebook that hands it a large output — or a cache to write — stalls its `/ping`
for ten, twenty seconds while nothing whatsoever is wrong with the tunnel. A probe that folded that
into "unhealthy" made the watchdog kill a working tunnel, and the reconnect it triggered then failed
to find the (still stalled) server and started a SECOND one on the same node, orphaning the
notebooks on the first. Only a connection that is refused or torn down says the path is gone;
silence says the far end is working.

A raw socket rather than HTTP.jl on purpose: the verdict must not depend on which exception type a
given HTTP.jl version wraps a timeout in.
"""
function _probe_port(port::Integer; wait::Real=4.0, target::AbstractString="/ping")::Symbol
    sock = try
        Sockets.connect(Sockets.localhost, UInt16(port))
    catch
        return :dead
    end
    try
        try
            write(sock, "GET $(target) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        catch
            return :dead
        end
        status = Ref{Union{String,Nothing}}(nothing)
        reader = @async try
            status[] = readline(sock) # "" at EOF: closed without a word
        catch
            status[] = ""
        end
        timedwait(() -> istaskdone(reader), Float64(wait); pollint=0.05)
        istaskdone(reader) || return :busy
        line = status[]
        (line === nothing || isempty(line)) && return :dead
        occursin(r"^HTTP/1\.[01] 200\b", line) && return :ok
        # asked for something only its owner may have, and refused: a server, but not the one meant
        target != "/ping" && occursin(r"^HTTP/1\.[01] 40[13]\b", line) ? :denied : :dead
    finally
        try
            close(sock) # also unblocks the reader, if it is still waiting
        catch
        end
    end
end

"Answering 200 right now. `:busy` is deliberately NOT ok here: a caller that needs a working server (adopting a registry file, declaring a tunnel up) must see it answer."
_local_ping_ok(port::Integer)::Bool = _probe_port(port) == :ok

# The forward is bound to 127.0.0.1 EXPLICITLY. With no bind address ssh listens on every loopback
# address `localhost` resolves to (::1 and 127.0.0.1), and ExitOnForwardFailure only fires when all of
# them fail. So when something already held 127.0.0.1:<port>, ssh carried on bound to ::1 alone, while
# everything on our side — `_local_ping_ok`, the placeholder, the hub itself — speaks 127.0.0.1. The
# probe reached whatever held the port, the connect reported "tunnel did not come up", and the live
# ssh stayed behind on ::1. With one address a conflict makes ssh exit at once, visibly.
#
# `-n` + stdin=devnull keep the tunnel ssh OFF the launching terminal's stdin: a backgrounded `ssh -N`
# otherwise fights the shell for the terminal, so quitting the server (or just having a remote open)
# can leave that terminal "disconnected".
_tunnel_command(host::AbstractString, local_port::Integer, remote_port::Integer) =
    `ssh -n -o BatchMode=yes -o ConnectTimeout=$(SSH_CONNECT_TIMEOUT[]) -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR -o ExitOnForwardFailure=yes -N -L 127.0.0.1:$(local_port):127.0.0.1:$(remote_port) $(host)`

"Stop `r`'s ssh and wait (briefly) until it is gone, so the port is really free for whoever binds it next."
function _kill_tunnel!(r::RemoteSession)
    t = r.tunnel
    t === nothing && return
    try
        process_exited(t) || kill(t)
        timedwait(() -> process_exited(t), 2.0; pollint=0.05)
    catch
    end
    nothing
end

"""
Open `r`'s tunnel on its stable local port and wait for the remote to answer through it. Returns
`(outcome, local_port)` with outcome `:ok`, `:cancelled` or `:failed`; for anything but `:ok` the ssh
child is already gone, so it cannot sit on the port and break the next attempt.

When ssh exits on its own and the port is no longer free, something took the port between our pick
and ssh's bind. That is a race on this machine, not a problem with the host, so it is retried
instead of being reported — on the SAME port once the holder is gone (a process still tearing
down), because the port is the host's identity to its open tabs and must not move over a blip;
only a port that stays taken makes the host move. `command` exists for the tests.

`polls` bounds the probes that come back dead (nothing behind the tunnel); `busy_polls` bounds the
ones that come back busy — the tunnel accepted and nothing hung up, so the path exists and the server
behind it is just not answering yet, typically because a notebook has its thread. A busy server
is not a failed tunnel and must not be reported as one: that report is what used to make the hub
hold the port and, on its next pass, start a duplicate server.
"""
function _open_tunnel!(r::RemoteSession, remote_port::Integer; command=_tunnel_command, polls::Integer=20, busy_polls::Integer=600, attempts::Integer=3, settle::Real=1.5)
    local_port = 0
    for attempt in 1:attempts
        if local_port == 0 || !_port_bindable(local_port)
            # Hand the port back before picking it: while the tunnel was down we were holding it
            # ourselves, and `stable_tunnel_port` would otherwise see it as occupied and move this host
            # somewhere else — losing the very stability the tab depends on.
            _stop_placeholder!(r.host)
            local_port = stable_tunnel_port(r.host)
        end
        # stdout→devnull too — we only watch process_exited and the /ping probe, never the tunnel's streams.
        r.tunnel = Base.run(pipeline(command(r.host, local_port, remote_port); stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
        dead = busy = 0
        busy_since = nothing
        while true
            sleep(1)
            _remote_bail(r) && return (:cancelled, local_port)
            verdict = _probe_port(local_port)
            verdict == :ok && return (:ok, local_port)
            process_exited(r.tunnel) && break
            if verdict == :busy
                busy += 1
                busy_since === nothing && (busy_since = time())
                r.detail = "the SpaceStation server on $(r.host) is busy — waiting for it to answer ($(round(Int, time() - busy_since))s)"
                busy < busy_polls || break
            else
                dead += 1
                dead < polls || break
            end
        end
        exited_by_itself = process_exited(r.tunnel)
        _kill_tunnel!(r)
        (exited_by_itself && !_port_bindable(local_port) && attempt < attempts) || break
        sleep(settle) # give a transient holder time to let go, so the retry can keep this port
    end
    (:failed, local_port)
end

# Everything the hub decides about a node's servers starts from ONE scan of the registry dir on the
# remote: every connection file that belongs to THIS node, each tagged with what it is right now:
#   LIVE — its port answers /ping on the node's loopback
#   BUSY — no answer within 3s, but the pid the file names is alive and is a SpaceStation process: the
#          server exists and is stalled (a notebook run has its thread), not gone
#   DEAD — neither: a corpse left by a SIGKILL'd server, an ended HPC job, a rebooted node
#
# BUSY is the state that used to be invisible. A registry file can outlive its server (jobs end, nodes
# reboot, SIGKILL never deletes a file), so a file was only trusted if its port answered — and a server
# too busy to answer within 3s was therefore "not there", which started a second server on the same
# node. The pid check tells the two apart; it inspects the process's argv so a pid recycled after a
# reboot is not mistaken for a busy server.
#
# The trailing marker separates "scanned, found nothing" from "ssh never ran the scan": the two used
# to be the same empty string, so an SSH hiccup during discovery also counted as "no server here".
#
# What "busy" means for a server on the node, as shell functions shared by everything that would
# replace code or stop a process there. A server is doing something for someone when it has a notebook
# open, OR when a terminal it started has something running in it. The second half was missing: the
# hub's notebook list knows nothing of terminals, so a hub with a training run or a coding agent in its
# terminal and no notebook open looked idle, and an update of `main` shut it down, taking the shells and
# everything in them along. A shell that sits at its prompt is not work; a shell with a child is.
#   hub_has_running_terminal <pid>   0 when a shell that <pid> started has a child process
#   server_busy <port> <secret> <pid>   0 when that server is busy, or is alive and cannot say
#   node_busy                        0 when any server of this user on this node is
const _NODE_BUSY_SH = raw"""
# http_status <port> <path?query>: the status a server on this node answers with, 000 when none comes.
# The path can carry a secret: curl reads it from stdin, never from argv (visible in `ps` on a shared
# node). Without curl, bash speaks the one request itself.
http_status() {
    if command -v curl >/dev/null 2>&1; then
        _code=$(printf 'url = "http://127.0.0.1:%s%s"\n' "$1" "$2" | curl -s -m 4 -o /dev/null -w '%{http_code}' -K - 2>/dev/null)
    else
        _code=$( (exec 3<>"/dev/tcp/127.0.0.1/$1" && printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n\r\n' "$2" "$1" >&3 && read -r -t 4 _ _c _ <&3 && printf '%s' "$_c") 2>/dev/null )
    fi
    case "$_code" in [1-5][0-9][0-9]) echo "$_code" ;; *) echo 000 ;; esac
}
hub_has_running_terminal() {
    [ -n "$1" ] || return 1
    ps -A -o pid= -o ppid= -o comm= 2>/dev/null | awk -v hub="$1" '
        { pid[NR] = $1; ppid[NR] = $2; comm[NR] = $3 }
        END {
            for (i = 1; i <= NR; i++) if (ppid[i] == hub && comm[i] ~ /^-?([^ ]*\/)?(ba|z|da|k|tc|c|fi)?sh$/) shell[pid[i]] = 1
            for (i = 1; i <= NR; i++) if (ppid[i] in shell) exit 0
            exit 1
        }'
}
server_busy() {
    if [ "$(http_status "$1" /ping)" = 200 ]; then
        # the server on that port refuses this file's secret: the port was taken over, the file is
        # stale and stands for no server (it used to count as "alive and cannot say", for ever)
        case "$(http_status "$1" "/api/v1/config?secret=$2")" in 401|403) return 1 ;; esac
        command -v curl >/dev/null 2>&1 || return 0
        _open=$(printf 'url = "http://127.0.0.1:%s/api/v1/notebooks?secret=%s"\n' "$1" "$2" | curl -fsS -m 5 -K - 2>/dev/null) || return 0
        [ "$_open" = "[]" ] || return 0
    else
        # no answer: gone (its file is stale: not busy), or alive and too busy to answer (or there is no curl to ask with)
        [ -n "$3" ] && kill -0 "$3" 2>/dev/null && ps -o args= -p "$3" 2>/dev/null | grep -q SpaceStation || return 1
        return 0
    fi
    hub_has_running_terminal "$3"
}
node_busy() {
    _me=$(hostname)
    _nd=$(cat "$HOME/.spacestation/nodedir-$_me" 2>/dev/null)
    for _f in "$HOME"/.local/state/pluto/servers/*.json ${_nd:+"$_nd"/state/pluto/servers/*.json}; do
        [ -e "$_f" ] || continue
        _node=$(sed -n 's/.*"node": *"\([^"]*\)".*/\1/p' "$_f")
        [ -n "$_node" ] && [ "$_node" != "$_me" ] && continue
        server_busy "$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$_f")" "$(sed -n 's/.*"secret": *"\([^"]*\)".*/\1/p' "$_f")" "$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$_f")" && return 0
    done
    return 1
}
"""

# Node matching: a "<host>-<port>.json" records its node; files from other nodes are skipped. Without
# this, two nodes that both took port 1234 each write a file saying "port": 1234, curling 127.0.0.1:1234
# here answers (OUR server) for either file, and the tunnel would inherit a sibling's secret and
# auth-fail. Old bare "<port>.json" files (no node field) are judged by liveness alone.
#
# And a file is a CLAIM. It outlives the server that wrote it (a job that was killed, a node that was
# rebooted), and the next server on the node takes the same port. "Something answers /ping on the port
# in the file" then says the dead server is alive, and hands out its secret: the connect that followed
# was "ready" with a secret the server refused, the page was a 403, and nothing got out of that state
# by itself. So the server on the port is asked with the file's OWN secret, and a file it refuses is
# STALE: not a server. (CollabLocal.jl does the same for a hub's workspace servers.)
#
# The node's own directory is read first. A hub writes its file there itself before it answers
# anything; the copy in the shared home is written later, by a helper, and until then that name can
# still hold the previous hub's record.
const _SCAN_REMOTE_SERVERS_SNIPPET = _NODE_BUSY_SH * raw"""
me=$(hostname)
nd=$(cat "$HOME/.spacestation/nodedir-$me" 2>/dev/null)
for f in ${nd:+"$nd"/state/pluto/servers/*.json} "$HOME"/.local/state/pluto/servers/*.json; do
    [ -e "$f" ] || continue
    p=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$f")
    [ -n "$p" ] || continue
    node=$(sed -n 's/.*"node": *"\([^"]*\)".*/\1/p' "$f")
    [ -n "$node" ] && [ "$node" != "$me" ] && continue
    pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$f")
    s=$(sed -n 's/.*"secret": *"\([^"]*\)".*/\1/p' "$f")
    status=DEAD
    if [ "$(http_status "$p" /ping)" = 200 ]; then
        status=LIVE
        case "$(http_status "$p" "/api/v1/config?secret=$s")" in 401|403) status=STALE ;; esac
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ps -o args= -p "$pid" 2>/dev/null | grep -q SpaceStation; then
        status=BUSY
    fi
    echo "__CANDIDATE__ $status $pid"
    cat "$f"; echo
    # the version a server here runs from is in use (see gc_versions)
    if [ "$status" = LIVE ] || [ "$status" = BUSY ]; then
        c=$(sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' "$f")
        [ -n "$c" ] && touch "$HOME/.spacestation/versions/.used-$c" 2>/dev/null
    fi
done
if node_busy; then echo __NODE_BUSY__; else echo __NODE_IDLE__; fi
echo __SCAN_DONE__
"""

struct RemoteCandidate
    status::Symbol      # :live | :busy | :dead | :stale (a server answers on its port and refuses its secret)
    port::Int
    secret::String
    pid::Int
    has_workspace::Bool # a folder is open in it: the one somebody is working in, given a choice
    is_hub::Bool        # a workspace hub (Proxy.jl): the one to tunnel to — its children are behind it
    node::String        # the machine it runs on, as its connection file says ("" when it does not)
    commit::String      # the installed version it runs from ("" for a server from before versions)
end
RemoteCandidate(status, port, secret, pid, has_workspace, is_hub) = RemoteCandidate(status, port, secret, pid, has_workspace, is_hub, "", "")
RemoteCandidate(status, port, secret, pid, has_workspace, is_hub, node) = RemoteCandidate(status, port, secret, pid, has_workspace, is_hub, node, "")

"Parse a scan's output. `nothing` when the scan did not run to completion — an SSH failure is not a verdict about the node."
function _parse_remote_candidates(out::AbstractString)::Union{Vector{RemoteCandidate},Nothing}
    occursin("__SCAN_DONE__", out) || return nothing
    cands = RemoteCandidate[]
    for block in split(out, "__CANDIDATE__")[2:end]
        i = findfirst('\n', block)
        head = i === nothing ? block : block[1:prevind(block, i)]
        rest = i === nothing ? "" : String(block[nextind(block, i):end])
        words = split(strip(head))
        isempty(words) && continue
        status = words[1] == "LIVE" ? :live : words[1] == "BUSY" ? :busy : words[1] == "STALE" ? :stale : :dead
        pid = length(words) >= 2 ? something(tryparse(Int, words[2]), 0) : 0
        reg = _parse_remote_registry(rest)
        reg === nothing && continue
        # one server can show up twice: it announces itself in the shared directory too (legacy_registry_dir).
        # The first one read is kept, and that is the node's own copy (see the scan).
        any(c -> c.pid == pid && c.port == reg.port, cands) && continue
        push!(cands, RemoteCandidate(status, reg.port, reg.secret, pid, occursin(r"\"workspace\": \"", rest), occursin(r"\"hub\": true", rest),
            (m = match(r"\"node\": \"([^\"\t\n]+)\"", rest); m === nothing ? "" : String(m.captures[1])),
            (m = match(r"\"commit\": \"([0-9a-f]+)\"", rest); m === nothing ? "" : String(m.captures[1]))))
    end
    cands
end

"""
Which server to attach to. The one this session was attached to before (`secret`) wins, live OR
busy, so a reconnect lands the open tabs — whose URLs carry that secret — back on their own
notebooks; otherwise a live hub (every workspace on the node is behind it), then a live server with
a workspace open (a leaf from before hubs), then any live one, then a busy one.
`nothing` only when no server process exists on the node: that, and nothing else, is the case for
starting one. A stale file is not a server, and neither is one whose secret the server behind the
tunnel has already refused (`refused`).
"""
function _choose_remote_server(cands::Vector{RemoteCandidate}, secret::AbstractString; refused=())
    usable = [c for c in cands if c.status ∈ (:live, :busy) && c.secret ∉ refused]
    if !isempty(secret)
        i = findfirst(c -> c.secret == secret, usable)
        i === nothing || return usable[i]
    end
    for pick in (c -> c.status == :live && c.is_hub, c -> c.status == :live && c.has_workspace, c -> c.status == :live, c -> c.status == :busy && c.is_hub, c -> c.status == :busy)
        i = findfirst(pick, usable)
        i === nothing || return usable[i]
    end
    nothing
end

# The launch script leaves the pid of the hub it started in the node's directory. A hub that dies while
# starting (its runtime damaged, a package that does not load) never answers /ping, and a connect that
# only waits for the answer sits on "starting" for a quarter of an hour in front of a process that was
# gone in the first ten seconds, with the reason one `cat` away in its log. This asks: is it still there,
# and if not, what did it say. Under a launch wrapper the pid may be the wrapper's: no verdict then.
const _LAUNCHED_HUB_SNIPPET = raw"""
d=$(cat "$HOME/.spacestation/nodedir-$(hostname)" 2>/dev/null)
pid=$(cat "$d/hub.pid" 2>/dev/null)
if [ -z "$d" ] || [ -z "$pid" ] || [ -n "${SPACESTATION_LAUNCH_WRAPPER:-}" ]; then
    echo __HUB_UNKNOWN__
elif kill -0 "$pid" 2>/dev/null; then
    echo __HUB_ALIVE__
else
    echo __HUB_GONE__
    line=$(grep -m 1 -E '^(ERROR|FATAL|fatal|signal|\[[0-9]+\] signal)' "$d/server.log" 2>/dev/null)
    [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$d/server.log" 2>/dev/null | tail -n 1)
    printf '%s\n' "$line" | cut -c1-400
fi
"""

"What `_LAUNCHED_HUB_SNIPPET` printed, as `(state, line)`: `:alive`, `:gone` (with what its log says, if anything) or `:unknown` (nothing can be concluded, an SSH failure included)."
function _parse_launched_hub(out::AbstractString)::Tuple{Symbol,String}
    occursin("__HUB_ALIVE__", out) && return (:alive, "")
    i = findfirst("__HUB_GONE__", out)
    i === nothing && return (:unknown, "")
    lines = filter(!isempty, strip.(split(out[nextind(out, last(i)):end], '\n')))
    (:gone, isempty(lines) ? "" : String(first(lines)))
end

function _launched_hub(host::String)::Tuple{Symbol,String}
    out = try
        _ssh_run(host, _LAUNCHED_HUB_SNIPPET)
    catch
        ""
    end
    _parse_launched_hub(out)
end

"What the launcher shows when the hub it started is gone: the reason first, then where the rest is."
function _hub_gone_detail(host::AbstractString, line::AbstractString)::String
    said = isempty(line) ? "" : ": " * first(line, 180)
    "the SpaceStation server on $(host) stopped while starting$(said) — full log: ~/.spacestation/server.log on $(host)"
end

"The first-time clone: skipped when a clone is already there, and made beside the target so that a failed clone leaves whatever was there."
_clone_command(; dir::AbstractString=REMOTE_BOOTSTRAP_DIR, url::AbstractString=REMOTE_FORK_URL, branch::AbstractString=REMOTE_FORK_BRANCH) =
    "if [ -d $(dir)/.git ]; then echo __HAVE_CLONE__; else mkdir -p ~/.spacestation && rm -rf $(dir).new && git clone --depth 1 --branch $(branch) $(url) $(dir).new && rm -rf $(dir) && mv $(dir).new $(dir); fi"

"""
Scan `host`: `(scanned, cands, idle)`. `scanned == false` means the scan itself failed and nothing can
be concluded from it. `idle` is true only when the node said that none of this user's servers there
is doing anything for anybody (no notebook open, nothing running in a terminal).
"""
function _scan_remote(host::String)
    out = try
        _ssh_run(host, _SCAN_REMOTE_SERVERS_SNIPPET)
    catch
        ""
    end
    cands = _parse_remote_candidates(out)
    cands === nothing && return (scanned=false, cands=RemoteCandidate[], idle=false)
    (scanned=true, cands=cands, idle=occursin("__NODE_IDLE__", out))
end

"Scan `host`. Returns `(scanned, chosen)`: `scanned == false` means the scan itself failed and nothing can be concluded from it."
function _find_remote_server(host::String, secret::AbstractString; refused=())
    scan = _scan_remote(host)
    scan.scanned || return (false, nothing)
    (true, _choose_remote_server(scan.cands, secret; refused))
end

# --- installed versions ---------------------------------------------------------------------------
#
# ~/.spacestation/Pluto.jl is a git clone, and on a cluster it is on the shared home: ONE directory
# for every node. A hub starts its workspace servers from the installation, and their notebook workers
# load PlutoRunner from it, for as long as the hub runs. The update used to move that directory to the
# new commit in place (`git reset --hard`), after checking that nothing was busy ON THE NODE BEING
# CONNECTED TO. Connecting a second node moved the code under the first node's hub: every workspace
# opened there afterwards started on the new version, the hub (still the old one) did not recognise
# its own child, and the workspace "did not come up in time", once per attempt, each attempt leaving
# a server behind. No check made on one node can know what the others run.
#
# So nothing runs from the clone any more, and nothing that runs is ever changed. The clone is only
# where commits are fetched to. Each commit that is run gets its own directory,
# ~/.spacestation/versions/<commit>, exported once (whole, or not there) and never written to again.
# A hub is started from one of them and names it to everything it starts; an update is a NEW directory
# beside the others, which a running hub does not notice. A hub moves to a newer version by being
# replaced, and only while it is doing nothing for anybody. (The arrangement of an editor's remote
# server, which keeps one directory per commit under ~/.vscode-server/bin/.)
#
# Markers live beside the version directories, not in them: `.installed-<commit>` (its packages are
# there and it loads), `.used-<commit>` (touched by every launch, and by every connect that finds a
# server running it), `.install-<commit>-<node>.pid|.log` (an install under way ON THAT NODE: the home
# is shared, and a pid means something on its own node only).
#
# SPACESTATION_NODE_VERSIONS=0 (in the node's shell profile) is the old arrangement: the clone is
# moved in place while the node is idle, and "the version" is a link to it. An export that fails falls
# back to the same, for the commit the clone already holds.
const _NODE_VERSIONS_SH = raw"""
ss_clone="$HOME/.spacestation/Pluto.jl"
ss_versions="$HOME/.spacestation/versions"
version_there() { [ -f "$ss_versions/$1/.commit" ] || [ -L "$ss_versions/$1" ]; }
# export_version <commit>: $ss_versions/<commit> holds that commit, whole, or does not exist.
# One export at a time, whichever node asks: two nodes connected at once ask at once, and the clone
# they fetch into is one directory (two fetches into it at the same moment fail each other).
export_version() {
    version_there "$1" && return 0
    mkdir -p "$ss_versions" || return 1
    _lock="$ss_versions/.lock-export"; _i=0
    until mkdir "$_lock" 2>/dev/null; do
        version_there "$1" && return 0
        # a lock nobody has touched for five minutes was left by an export that died
        [ -n "$(find "$_lock" -maxdepth 0 -mmin +5 2>/dev/null)" ] && { rmdir "$_lock" 2>/dev/null; continue; }
        _i=$((_i + 1)); [ "$_i" -gt 120 ] && return 1
        sleep 1
    done
    if ! version_there "$1"; then
        # the commit is fetched here, under the lock, and only when the clone does not hold it yet
        git -C "$ss_clone" cat-file -e "$1^{commit}" 2>/dev/null || git -C "$ss_clone" fetch --depth 1 origin "$branch" >/dev/null 2>&1
        _tmp="$ss_versions/.tmp-$1.$(hostname).$$"
        rm -rf "$_tmp" "$ss_versions/$1"
        mkdir -p "$_tmp" && git -C "$ss_clone" archive --format=tar "$1" 2>/dev/null | tar -xf - -C "$_tmp" 2>/dev/null \
            && [ -f "$_tmp/Project.toml" ] && echo "$1" > "$_tmp/.commit" && mv "$_tmp" "$ss_versions/$1"
        rm -rf "$_tmp"
    fi
    rmdir "$_lock" 2>/dev/null
    version_there "$1"
}
# link_version <commit>: the old arrangement, "the version" is the clone itself
link_version() { mkdir -p "$ss_versions" && { version_there "$1" || ln -s "$ss_clone" "$ss_versions/$1"; }; }
# gc_versions <keep>: the three newest stay, and so does <keep> and every one used in the last 30 days
gc_versions() {
    _n=0
    for _d in $(ls -dt "$ss_versions"/*/ 2>/dev/null); do
        _d=${_d%/}; _c=${_d##*/}; _n=$((_n + 1))
        [ "$_c" = "$1" ] && continue
        [ "$_n" -le 3 ] && continue
        [ -n "$(find "$ss_versions/.used-$_c" -mtime -30 2>/dev/null)" ] && continue
        if [ -L "$_d" ]; then rm -f "$_d"; else rm -rf "$_d"; fi
        rm -f "$ss_versions/.used-$_c" "$ss_versions/.installed-$_c" "$ss_versions"/.install-"$_c"-*
    done
}
"""

"A commit id as git prints it, and nothing that could be read as a path or as shell."
_valid_commit(c::AbstractString) = occursin(r"^[0-9a-f]{7,64}$", c)
"The directory of an installed version, as one shell word."
_version_dir_sh(commit::AbstractString) = (@assert _valid_commit(commit); "\"\$HOME/.spacestation/versions/$(commit)\"")

# Which version a hub started now would run, made ready to install: what `origin` has when the node
# can reach it; without a network the newest version that is installed here; failing that, what the
# clone holds. Additive, so it needs no "is anything busy" check: it writes a new directory or nothing.
_prepare_version_script(; branch::AbstractString=REMOTE_FORK_BRANCH) = _NODE_BUSY_SH * _NODE_VERSIONS_SH * "branch=$(_shquote(String(branch)))\n" * raw"""
[ -d "$ss_clone/.git" ] || { echo __NOCLONE__; exit 0; }
# what `origin` has now: asked over the network, nothing in the clone is written (or locked) for it
want=$(git -C "$ss_clone" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
case "$want" in *[!0-9a-f]*) want="" ;; esac
fresh=1
if [ "${SPACESTATION_NODE_VERSIONS:-1}" = 0 ]; then
    # the old arrangement: the clone moves, and only while nothing on this node is busy
    [ -n "$want" ] || fresh=0
    if [ -n "$want" ] && [ "$want" != "$(git -C "$ss_clone" rev-parse HEAD 2>/dev/null)" ] && ! node_busy; then
        git -C "$ss_clone" fetch --depth 1 origin "$branch" >/dev/null 2>&1 && git -C "$ss_clone" reset --hard FETCH_HEAD >/dev/null 2>&1
    fi
    want=$(git -C "$ss_clone" rev-parse HEAD 2>/dev/null)
    case "$want" in ""|*[!0-9a-f]*) echo __NOVERSION__; exit 0 ;; esac
    link_version "$want" || { echo __NOVERSION__; exit 0; }
elif [ -z "$want" ] || ! export_version "$want"; then
    # `origin` cannot be reached from here, or its commit could not be exported: the newest version
    # that is installed here; failing that, what the clone holds (exported, or as it stands)
    fresh=0; want=""
    for _m in $(ls -t "$ss_versions"/.installed-* 2>/dev/null); do
        _c=${_m##*.installed-}
        version_there "$_c" && { want=$_c; break; }
    done
    if [ -z "$want" ]; then
        want=$(git -C "$ss_clone" rev-parse HEAD 2>/dev/null)
        case "$want" in ""|*[!0-9a-f]*) echo __NOVERSION__; exit 0 ;; esac
        export_version "$want" || link_version "$want" || { echo __NOVERSION__; exit 0; }
    fi
fi
[ "$fresh" = 1 ] || echo __OFFLINE__ # not a version to replace a running server for
touch "$ss_versions/.used-$want" 2>/dev/null
gc_versions "$want"
[ -f "$ss_versions/.installed-$want" ] && echo __INSTALLED__
echo "__VERSION__ $want"
"""

"`state` is `:ok` (with `commit`), `:noclone`, `:failed` (a clone, and no version could be made of it) or `:unknown` (the node did not answer). `fresh`: the commit is what `origin` has now."
const PreparedVersion = @NamedTuple{state::Symbol, commit::String, fresh::Bool, installed::Bool}

function _parse_prepared_version(out::AbstractString)::PreparedVersion
    m = match(r"__VERSION__ ([0-9a-f]{7,64})\b", out)
    m !== nothing && return (state=:ok, commit=String(m.captures[1]), fresh=!occursin("__OFFLINE__", out), installed=occursin("__INSTALLED__", out))
    state = occursin("__NOCLONE__", out) ? :noclone : occursin("__NOVERSION__", out) ? :failed : :unknown
    (state=state, commit="", fresh=false, installed=false)
end

_prepare_remote_version(host::String)::PreparedVersion = _parse_prepared_version(_ssh_try(host, _prepare_version_script())[2])

# The slow step of an install, DETACHED on the node (nohup + pidfile + log): it survives connection
# drops and local restarts, and the connect only polls for the marker. An install of the same version
# already under way on this node is attached to. Another node may be installing the same version at
# the same moment (the home is shared): both run, Pkg takes its own locks, and the marker of
# whichever finishes first counts for both.
function _install_version_script(julia::AbstractString, commit::AbstractString)::String
    "c=$(commit)\nj=$(_shquote(String(julia)))\n" * raw"""
    v="$HOME/.spacestation/versions"; me=$(hostname)
    pidf="$v/.install-$c-$me.pid"; log="$v/.install-$c-$me.log"
    if kill -0 "$(cat "$pidf" 2>/dev/null)" 2>/dev/null; then echo __ATTACHED__; exit 0; fi
    rm -f "$v/.installed-$c"
    ln -sfn "$log" "$HOME/.spacestation/install.log" 2>/dev/null
    nohup sh -c 'cd "$1" && "$2" --project=. -e "import Pkg; Pkg.instantiate(); import SpaceStation" && touch "$3"' sh "$v/$c" "$j" "$v/.installed-$c" > "$log" 2>&1 < /dev/null &
    echo $! > "$pidf"
    echo __LAUNCHED__
    """
end

# Fence the tail behind a __LOG__ marker and extract only that — a ProxyJump login node reprints its
# post-quantum warning on every hop (LogLevel can't reach it), and without the fence that client
# chatter would land in the banner instead of the real progress line.
_install_poll_script(commit::AbstractString)::String = "c=$(commit)\n" * raw"""
    v="$HOME/.spacestation/versions"; me=$(hostname)
    [ -f "$v/.installed-$c" ] && echo __DONE__
    kill -0 "$(cat "$v/.install-$c-$me.pid" 2>/dev/null)" 2>/dev/null && echo __ALIVE__
    printf '__LOG__%s' "$(tail -n 1 "$v/.install-$c-$me.log" 2>/dev/null)"
    """

# Stop this node's servers that run another version than `target`, when NOTHING of this user's on the
# node is busy (`_NODE_BUSY_SH`: a notebook open, something running in a terminal, a server too busy to
# say). A reconnect must never cost someone the notebook that has been computing on the node all
# night: a busy node keeps what it runs and is attached to as it is, and moves on the next time it is
# found idle. Node-matched (a sibling node's same-port file on a shared $HOME is not ours to touch),
# so the pid is a process on this very node. The secret goes to curl through a config on stdin, never
# through argv (visible in `ps` on a shared node).
_retire_idle_servers_script(target::AbstractString)::String = _NODE_BUSY_SH * "target=$(target)\n" * raw"""
    me=$(hostname)
    command -v curl >/dev/null 2>&1 || exit 0
    node_busy && { echo __BUSY__; exit 0; }
    nd=$(cat "$HOME/.spacestation/nodedir-$me" 2>/dev/null)
    for f in ${nd:+"$nd"/state/pluto/servers/*.json} "$HOME"/.local/state/pluto/servers/*.json; do
        [ -e "$f" ] || continue
        p=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$f")
        pid=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$f")
        node=$(sed -n 's/.*"node": *"\([^"]*\)".*/\1/p' "$f")
        s=$(sed -n 's/.*"secret": *"\([^"]*\)".*/\1/p' "$f")
        c=$(sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' "$f")
        [ -n "$node" ] && [ "$node" != "$me" ] && continue
        [ -n "$c" ] && [ "$c" = "$target" ] && continue
        [ "$(http_status "$p" /ping)" = 200 ] || continue
        open=$(printf 'url = "http://127.0.0.1:%s/api/v1/notebooks?secret=%s"\n' "$p" "$s" | curl -fsS -m 5 -K - 2>/dev/null) || continue
        [ "$open" = "[]" ] || continue
        hub_has_running_terminal "$pid" && continue
        # both copies of its file (the node's own and the one in the shared home), if they are this server's
        for g in "$f" "$HOME/.local/state/pluto/servers/${f##*/}" ${nd:+"$nd/state/pluto/servers/${f##*/}"}; do
            [ "$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$g" 2>/dev/null)" = "$pid" ] && rm -f "$g"
        done
        # Its own shutdown first (it removes its files and stops cleanly), then SIGTERM, then
        # SIGKILL. A Julia 1.12 process can deadlock in its exit-time finalizers after SIGTERM
        # and spin at 100% CPU forever, still bound to its port — one did, for 21 hours.
        printf 'url = "http://127.0.0.1:%s/api/v1/shutdown?secret=%s"\nrequest = "POST"\n' "$p" "$s" | curl -fsS -m 5 -o /dev/null -K - 2>/dev/null
        [ -n "$pid" ] || continue
        for i in 1 2 3 4 5 6 7 8; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
        for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    done
    echo __RETIRED__
    """

# The UI can cancel an in-flight connect. The connect task can't be interrupted mid-`_ssh_run`, but it
# checks this between phases and inside its poll loops — so a cancel lands within a couple seconds, tears
# down any half-open tunnel, and stops the remote from being marked ready.
function _remote_bail(r::RemoteSession)::Bool
    # superseded counts as cancelled: another session owns this host now (see _is_current_session)
    _is_current_session(r) && return false
    _kill_tunnel!(r)
    r.state = "error"
    r.detail = "canceled"
    true
end

# --- the server we used last time -----------------------------------------------------------------
#
# Discovery asks the node questions over SSH: is it reachable, what is running, is the clone current.
# Each one starts a shell on the node, and a shell starts by reading its startup files from $HOME,
# which on a cluster is a network filesystem that stalls for seconds to minutes. Three of those in a
# row, in front of a server that was up the whole time, is how "Connecting…" sat for minutes while
# the workspace behind it was fine. A tunnel starts no shell. So the port and secret of the server
# a host last gave us are remembered (private file, like the connection files), and a connect tries
# exactly that first: tunnel, then one authenticated request through it. Only the server that owns
# the secret answers 200, so a different server on a reused port, or a dead node, fails this step
# and the full discovery below runs as before. (Same idea as an editor's remote reconnect: go back
# to the server you know, look for a new one only when it is gone.)
known_remotes_path() = joinpath(collab_registry_dir(), "known-remotes.tsv")

const KnownRemote = @NamedTuple{port::Int, secret::String, node::String}

function _read_known_remotes()::Dict{String,KnownRemote}
    d = Dict{String,KnownRemote}()
    path = known_remotes_path()
    isfile(path) || return d
    try
        for line in eachline(path)
            parts = split(line, '\t')
            length(parts) == 4 || continue
            port = tryparse(Int, parts[2])
            port === nothing || (d[String(parts[1])] = (port=port, secret=String(parts[3]), node=String(parts[4])))
        end
    catch
    end
    d
end

_tsv_safe(x::AbstractString) = !isempty(x) && !occursin(r"[\t\r\n]", x)

function _set_known_remote!(host::AbstractString, known::Union{Nothing,KnownRemote})
    try
        d = _read_known_remotes()
        if known === nothing
            delete!(d, String(host))
        elseif _tsv_safe(host) && _tsv_safe(known.secret) && _tsv_safe(known.node)
            d[String(host)] = known
        else
            return # no node on record (an older server), or a name that does not fit a line: not remembered
        end
        mkpath(collab_registry_dir())
        _write_private_file(known_remotes_path(), join(["$(h)\t$(v.port)\t$(v.secret)\t$(v.node)\n" for (h, v) in sort(collect(d); by=first)]))
    catch
    end
end

"""
Which machine answers at the other end of the tunnel, by its own account (`/ping` carries it, no
secret needed). Asked BEFORE the remembered secret is sent anywhere: an SSH alias can land on a
different machine than last time (round-robin login nodes), where that port may belong to someone
else's server, and a secret in a request is a secret handed over.
"""
function _tunnel_node(local_port::Integer)::String
    try
        resp = HTTP.get("http://127.0.0.1:$(local_port)/ping"; connect_timeout=3, readtimeout=10, retry=false, redirect=false, status_exception=false, cookies=false)
        resp.status == 200 ? String(HTTP.header(resp, "X-SpaceStation-Node", "")) : ""
    catch
        ""
    end
end

"""
One authenticated request through the tunnel: does the server on the other end own `secret`?
`:ok` it does, `:denied` it says no, `:unknown` it did not say (busy, or the path is gone). The
difference between the last two is the point: a server that is slow is still the server, and one
that refuses the secret is not the one the secret came from.
"""
function _tunnel_auth(local_port::Integer, secret::AbstractString; timeout::Integer=20)::Symbol
    isempty(secret) && return :denied
    try
        resp = HTTP.get("http://127.0.0.1:$(local_port)/api/v1/config?secret=$(HTTP.escapeuri(secret))";
            connect_timeout=3, readtimeout=timeout, retry=false, redirect=false, status_exception=false, cookies=false)
        resp.status == 200 ? :ok : resp.status ∈ (401, 403) ? :denied : :unknown
    catch
        :unknown
    end
end

"One authenticated request through the tunnel: is the server on the other end the one that owns `secret`?"
_tunnel_reaches_server(local_port::Integer, secret::AbstractString; timeout::Integer=20)::Bool = _tunnel_auth(local_port, secret; timeout) == :ok

"""
Try the server this host gave us last time. True when the task is finished (ready, or cancelled);
false hands over to discovery. The entry is forgotten only on a VERDICT, the tunnel came up and the
other end is not our server. A tunnel that did not come up (a laptop just woke, the hop is slow)
says nothing about the server, and forgetting it then would send every wake-up through discovery.
The wait on a busy port is short here: discovery knows a busy server by its pid, this only
remembers a number.
"""
function _reconnect_known_remote!(r::RemoteSession; known=get(_read_known_remotes(), r.host, nothing),
        open_tunnel=_open_tunnel!, node_of=_tunnel_node, reaches=_tunnel_reaches_server, after_ready=_update_remote_clone_later)::Bool
    known === nothing && return false
    r.state = "tunneling"
    r.detail = "reconnecting to the SpaceStation server already running on $(r.host)"
    outcome, local_port = open_tunnel(r, known.port; attempts=1, polls=45, busy_polls=6)
    outcome == :cancelled && return true
    if outcome == :ok
        if node_of(local_port) == known.node && reaches(local_port, known.secret)
            _remote_bail(r) && return true # disconnected while we were asking: do not mark the host active
            _mark_remote_ready!(r, local_port, known.port, known.secret, known.node; node_of=(_ -> known.node)) # just checked
            after_ready(r.host)
            return true
        end
        _set_known_remote!(r.host, nothing) # somebody else's server, or ours is gone and the port reused
    end
    _kill_tunnel!(r)
    _remote_bail(r) && return true
    local_port > 0 && _hold_port!(r, local_port) # a tab reloading during discovery gets our page, not a refusal
    false
end

# Discovery replaces an idle server of an older version by one of the current version. A reconnect
# that skips discovery only LOOKS (`git ls-remote`, nothing on the node changes): when `origin` has
# moved on from what the hub here runs, and the node is idle, the remembered entry is dropped, and
# the next connect runs discovery, which does the replacing. A busy node stays on the quick path:
# there is nothing a discovery would do there.
_behind_script(; branch::AbstractString=REMOTE_FORK_BRANCH)::String = _NODE_BUSY_SH * "branch=$(_shquote(String(branch)))\n" * raw"""
    clone="$HOME/.spacestation/Pluto.jl"; me=$(hostname)
    [ -d "$clone/.git" ] || exit 0
    nd=$(cat "$HOME/.spacestation/nodedir-$me" 2>/dev/null)
    here=""
    for f in ${nd:+"$nd"/state/pluto/servers/*.json} "$HOME"/.local/state/pluto/servers/*.json; do
        [ -e "$f" ] || continue
        grep -q '"hub": *true' "$f" || continue
        node=$(sed -n 's/.*"node": *"\([^"]*\)".*/\1/p' "$f")
        [ -n "$node" ] && [ "$node" != "$me" ] && continue
        kill -0 "$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$f")" 2>/dev/null || continue
        here=$(sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' "$f")
        break
    done
    # the version the hub here runs from is in use (see gc_versions)
    [ -n "$here" ] && touch "$HOME/.spacestation/versions/.used-$here" 2>/dev/null
    there=$(git -C "$clone" ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    [ -n "$there" ] && [ "$here" != "$there" ] || exit 0
    node_busy && exit 0
    echo __BEHIND__
    """

_remote_clone_is_behind(host::String)::Bool = occursin("__BEHIND__", _ssh_try(host, _behind_script())[2])

function _update_remote_clone_later(host::String; behind=_remote_clone_is_behind)
    @async try
        behind(host) && _set_known_remote!(host, nothing)
    catch
    end
end

function _mark_remote_ready!(r::RemoteSession, local_port::Integer, remote_port::Integer, secret::AbstractString, node::AbstractString=""; node_of=_tunnel_node)
    remote = (port=remote_port, secret=String(secret))
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
    _set_active_remote!(r.host, true) # so a hub restart can put this tunnel back by itself
    # From here its workspaces are pages of THIS hub (RemoteHosts.jl). Before the state says ready:
    # the launcher asks for the table as soon as it does.
    hosted = try
        host_connected!(r.host, local_port, remote.secret)
    catch
        false
    end
    r.state = "ready"
    r.detail = hosted ? "connected — its workspaces open here" : "connected — the workspace runs on $(r.host)"
    # remembered for the next connect: see "the server we used last time". (A reconnect through this
    # path checks the node's clone in the background: see _update_remote_clone_later.)
    # Only a server that says who it is on /ping can be reconnected to (an older one cannot, and
    # remembering it would make every connect pay for a reconnect that is bound to fail).
    if !isempty(node) && node_of(local_port) == node
        _set_known_remote!(r.host, (port=Int(remote_port), secret=String(secret), node=String(node)))
    else
        _set_known_remote!(r.host, nothing)
    end
end

"""
The script that starts a hub on a node (run there through the login shell, so `julia` and the
scheduler's variables are what the user has).

It first stages SpaceStation's own runtime on the node's disk (`node/runtime.sh`: julia, a depot with
exactly this app's packages and their compiled caches, the app) and starts the hub FROM it, with an
environment that holds no path into shared storage: working directory, HOME, TMPDIR, depot, load
path, PATH without the user's directories, no LD_LIBRARY_PATH. A Julia process touches its install
and depot in ways nobody can list (even throwing an exception opens a package image), so the only
robust rule is that there is nothing shared to touch. The environment the user launched from is
saved first (`env -0`, on the node's disk) and handed to everything the hub starts FOR the user:
terminals, workspace servers and their notebooks run with the user's julia, depot and PATH
(UserEnv.jl). When staging is not possible the hub starts as it used to, from the shared install.
"""
function _remote_launch_script(julia::AbstractString; app::AbstractString=REMOTE_BOOTSTRAP_DIR, commit::AbstractString="", code::AbstractString="import SpaceStation; SpaceStation.run(launch_browser=false, hub=true)")::String
    # (the hub's own markers, SPACESTATION_HUB and SPACESTATION_TUNNELED, go on its command line and are
    # not exported: the saved user environment must not tell a terminal that it is a hub)
    # `commit` is the installed version `app` is (see "installed versions"): the hub writes it into its
    # connection file, which is how a later connect knows what runs here.
    "commit=$(isempty(commit) ? "" : (@assert _valid_commit(commit); commit))\n" * raw"""
    mkdir -p ~/.spacestation
    chmod 700 ~/.spacestation 2>/dev/null
    [ -n "$commit" ] && touch "$HOME/.spacestation/versions/.used-$commit" 2>/dev/null
    marker=~/.spacestation/nodedir-$(hostname)
    d=$(cat "$marker" 2>/dev/null)
    if [ -z "$d" ] || [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then
        d=$(mktemp -d "${SLURM_TMPDIR:-${TMPDIR:-/tmp}}/spacestation.XXXXXX") || exit 1
        echo "$d" > "$marker"
    fi
    mkdir -p "$d/depot" "$d/state"
    export SPACESTATION_STATE_HOME="$d/state" SPACESTATION_NODE_DIR="$d"
    mv -f "$d/server.log" "$d/server.log.1" 2>/dev/null
    ln -sfn "$d/server.log" ~/.spacestation/server.log
    user_depot="$d/depot:${JULIA_DEPOT_PATH:-$HOME/.julia}:"
    app=$(cd """ * String(app) * raw""" && pwd)
    julia=""" * _shquote(String(julia)) * "\n" * raw"""
    rt=$(bash "$app/src/webserver/node/runtime.sh" "$julia" "$app" 2>"$d/runtime.log" | sed -n 's/^RUNTIME //p')
    # (without a saved copy of this environment the hub could not give terminals and notebooks the user's own)
    if [ -n "$rt" ] && [ -x "$rt/julia/bin/julia" ] && (umask 077; env -0 > "$d/user-env") 2>/dev/null && cd "$rt"; then
        nohup env -u LD_LIBRARY_PATH -u JULIA_PROJECT -u JULIA_LOAD_PATH \
            SPACESTATION_TUNNELED=1 SPACESTATION_HUB=1 SPACESTATION_APP_COMMIT="$commit" \
            HOME="$rt/home" TMPDIR="$rt/tmp" PATH="$rt/julia/bin:/usr/local/bin:/usr/bin:/bin" \
            JULIA_DEPOT_PATH="$rt/depot:" JULIA_CPU_TARGET="$(cat "$rt/cpu-target")" JULIA_PKG_OFFLINE=true \
            SPACESTATION_USER_ENV_FILE="$d/user-env" SPACESTATION_USER_JULIA="$julia" SPACESTATION_USER_PROJECT="$app" \
            SPACESTATION_USER_DEPOT_PATH="$user_depot" SPACESTATION_USER_HOME="$HOME" SPACESTATION_RUNTIME_DIR="$rt" \
            ${SPACESTATION_LAUNCH_WRAPPER:-} "$rt/julia/bin/julia" """ * SERVER_THREAD_FLAGS * raw""" --startup-file=no --history-file=no --project="$rt/app" \
            -e """ * _shquote(String(code)) * raw""" > "$d/server.log" 2>&1 < /dev/null &
        echo $! > "$d/hub.pid"; disown
    else
        export JULIA_DEPOT_PATH="$user_depot" SPACESTATION_TUNNELED=1 SPACESTATION_HUB=1 SPACESTATION_APP_COMMIT="$commit"
        nohup ${SPACESTATION_LAUNCH_WRAPPER:-} "$julia" """ * SERVER_THREAD_FLAGS * raw""" --project="$app" -e """ * _shquote(String(code)) * raw""" > "$d/server.log" 2>&1 < /dev/null &
        echo $! > "$d/hub.pid"; disown
    fi
    true
    """
end

"The node could not be asked (the SSH hop stalled). That is no answer, and it must not be read as one: say so, and let the watchdog or the user try again."
function _remote_unanswered!(r::RemoteSession, what::AbstractString)
    r.state = "error"
    r.detail = "could not check $(what) on $(r.host) (the SSH hop stalled) — retrying"
    nothing
end

"""
Make the version `prep` names ready to start a hub from: cloned (first contact), exported, its
packages installed, and loading. Returns its commit, or `nothing` with `r.state`/`r.detail` saying
what went wrong (or that the connect was cancelled). Everything here ADDS to the node: nothing a
running server uses is changed, so it is safe to do in front of one.
"""
function _ready_remote_version!(r::RemoteSession, prep::PreparedVersion)::Union{Nothing,String}
    if prep.state == :noclone
        r.state = "installing"
        r.detail = "first-time setup on $(r.host): cloning SpaceStation (a minute or two)"
        # A clone that IS there is never removed to make room for one that may not arrive: the new one
        # is fetched beside it and only takes its place once it is complete (`_clone_command`).
        ok, out = _ssh_try(r.host, _clone_command())
        if !ok
            hint = occursin(r"resolve host|Could not resolve|unable to access|Connection timed out|Network is unreachable"i, out) ?
                " — this node looks like it has NO INTERNET ACCESS (common for HPC compute/GPU nodes). Try your LOGIN node instead, or clone SpaceStation to $(REMOTE_BOOTSTRAP_DIR) there manually." : ""
            r.state = "error"
            r.detail = "git clone failed on $(r.host): $(_tail(out))$(hint)"
            return nothing
        end
        _remote_bail(r) && return nothing
        prep = _prepare_remote_version(r.host)
    end
    if prep.state != :ok
        r.state = "error"
        r.detail = prep.state == :unknown ?
            "could not check the SpaceStation installation on $(r.host) (the SSH hop stalled) — retrying" :
            "could not prepare a SpaceStation version on $(r.host) from its clone at $(REMOTE_BOOTSTRAP_DIR) (is there room in the home directory, and does `git -C $(REMOTE_BOOTSTRAP_DIR) status` work there?)"
        return nothing
    end
    commit = prep.commit
    installed = prep.installed
    # The marker only says that an earlier instantiate completed. On HPC systems DEPOT_PATH is
    # commonly shared across nodes, and an artifact can later be garbage-collected, partially
    # written, or otherwise disappear while the marker remains. Validate the thing we actually
    # need before trusting it. A failed import invalidates it and falls through to the detached
    # repair/install below instead of repeatedly launching a server that crashes.
    if installed
        r.state = "checking"
        r.detail = "validating the SpaceStation installation on $(r.host)"
        healthy, _ = _ssh_try(r.host, "$(_shquote(r.julia)) --project=$(_version_dir_sh(commit)) -e 'import SpaceStation'")
        _remote_bail(r) && return nothing
        if !healthy
            installed = false
            r.detail = "repairing missing or damaged SpaceStation dependencies on $(r.host)"
        end
    end
    if !installed
        r.state = "installing"
        ok, out = _ssh_try(r.host, _install_version_script(r.julia, commit))
        if !ok || !(occursin("__LAUNCHED__", out) || occursin("__ATTACHED__", out))
            r.state = "error"
            r.detail = "could not start the install on $(r.host): $(_tail(out))"
            return nothing
        end
        started = time()
        while true
            sleep(5)
            _remote_bail(r) && return nothing
            elapsed = round(Int, (time() - started) / 60)
            # PROOF over promises: stream the live install log line into the banner.
            _, out = _ssh_try(r.host, _install_poll_script(commit))
            occursin("__DONE__", out) && break
            log_m = match(r"__LOG__(.*)", out)
            log_line = log_m === nothing ? "" : strip(String(log_m.captures[1]))
            if occursin("Juliaup configuration is locked", out)
                _ssh_try(r.host, "f=\"\$HOME/.spacestation/versions/.install-$(commit)-\$(hostname).pid\"; kill -9 \"\$(cat \"\$f\" 2>/dev/null)\" 2>/dev/null; rm -f \"\$f\"")
                r.state = "error"
                r.detail = "the juliaup shim deadlocked on its config lock on $(r.host) (often a hung self-update on an internet-less node) — retry: the real julia binary will be used directly"
                return nothing
            end
            # No answer is not "the install died": only a poll that came back whole can say that.
            if occursin("__LOG__", out) && !occursin("__ALIVE__", out)
                _, log = _ssh_try(r.host, "tail -n 6 ~/.spacestation/install.log 2>/dev/null")
                r.state = "error"
                r.detail = "Pkg.instantiate failed on $(r.host): $(_tail(log))"
                return nothing
            end
            r.detail = "installing on $(r.host) ($(elapsed) min): $(isempty(log_line) ? "starting up…" : last(log_line, 110))"
            if time() - started > 45 * 60
                r.state = "error"
                r.detail = "install on $(r.host) still not finished after 45 minutes — check ~/.spacestation/install.log there"
                return nothing
            end
        end
    end
    commit
end

"""
Start a hub on the node from the installed version `commit`, and wait until it answers there with
the secret in its own connection file. The candidate to tunnel to, or `nothing` with `r.state` set.
"""
function _launch_remote_hub!(r::RemoteSession, commit::AbstractString)::Union{Nothing,RemoteCandidate}
    r.state = "starting"
    r.detail = "starting the SpaceStation server on $(r.host)"
    # SPACESTATION_TUNNELED marks this server as reached over an SSH tunnel: its child workspace
    # ports aren't forwarded to the browser, so its frontend opens workspaces IN-PLACE instead of
    # spawning unreachable children (see serve_api_config + land.js).
    # A hub (SPACESTATION_HUB=1 before the import, hub=true for the run): it never opens a
    # notebook itself — each workspace gets a child on the node, relayed under /w/<id>/ — and
    # it never parses the registries.
    #
    # Everything it and its children WRITE goes to a node-local directory, not to $HOME or the
    # depot: on a cluster those are networked filesystems that stall for seconds to minutes,
    # and Julia's file I/O blocks the calling thread while they do. Worse, Pkg's usage log
    # takes a pidfile lock (a file watch) and the scratch spaces are walked with stat, and
    # both happen under Julia's process-wide libuv lock — held across a stall, that stops the
    # event loop of the whole process, sockets included, even on threads that have nothing
    # to do. So: a writable depot on the node in FRONT of the shared one (Julia's depot stack
    # is made for this — packages, registries and compiled caches are still read from the
    # shared depot, nothing is recompiled; usage logs, scratch spaces and new caches land
    # locally), and the log there too (a redirected stdout is a plain file stream), and the
    # servers' connection files (SPACESTATION_STATE_HOME: the hub walks that directory on every
    # status poll, and ~/.local/state is $HOME; the scans look in both places). The
    # directory is created once per node with mktemp (never a name someone else could
    # pre-create in a shared /tmp), remembered per node in $HOME, and reused while it exists
    # and is ours (a real directory, never a symlink: the marker is readable by other local
    # users). ~/.spacestation/server.log links to the live log; the previous run's log is
    # kept as server.log.1. The trailing ":" on the depot path keeps Julia's bundled depot
    # (the stdlib compile caches) on the stack. SLURM_TMPDIR is preferred when a job sets it:
    # /tmp on a compute node can be a small tmpfs, and packages a notebook adds land here.
    _ssh_run(r.host, _remote_launch_script(r.julia; app=_version_dir_sh(commit), commit))
    # The first launch of a version on a cluster builds the node-local runtime (a few minutes,
    # once); every later one restores or reuses it in seconds. The launch script does that before
    # it starts the hub, so this wait covers both.
    r.detail = "starting the SpaceStation server on $(r.host) (the first start of a new version prepares its runtime on the node's own disk: a few minutes, once)"
    for i in 1:480 # a little longer than node/runtime.sh waits for a build already under way
        sleep(2)
        _remote_bail(r) && return nothing
        # the server we just launched announces itself by answering on this node, with its own secret
        scanned, found = _find_remote_server(r.host, "")
        (scanned && found !== nothing && found.status == :live) && return found
        # ...unless it is no longer there to answer: say so now, with what it said, instead of waiting out the clock
        if i % 5 == 0 && scanned && found === nothing
            state, line = _launched_hub(r.host)
            if state == :gone
                r.state = "error"
                r.detail = _hub_gone_detail(r.host, line)
                return nothing
            end
        end
    end
    r.state = "error"
    r.detail = "the remote server did not come up — see ~/.spacestation/server.log (a link to its node-local log) on $(r.host)"
    nothing
end

"""
Tunnel to `remote` and call the host ready, but only with a secret the server at the other end of
that very tunnel accepted. This is the one place a session becomes "ready" after a discovery, so it
is the one place that has to hold: whatever a file on the node claimed, a secret that is refused is
never handed to the browser, remembered, or registered. A refusal means the file was not that
server's (the scan checks this on the node too; between the scan and the tunnel a server can be
replaced): the node is looked at again without it, a few times, and then the connect says what is
wrong instead of saying "connected". `true` when the host is ready.
"""
function _attach_verified!(r::RemoteSession, remote::RemoteCandidate; open_tunnel=_open_tunnel!, auth=_tunnel_auth,
        rescan=(refused -> _find_remote_server(r.host, ""; refused)), mark_ready=_mark_remote_ready!, pause::Real=2.0)::Bool
    refused = Set{String}()
    local_port = 0
    for _ in 1:3
        r.state = "tunneling"
        r.detail = "opening the SSH tunnel"
        outcome, local_port = open_tunnel(r, remote.port)
        outcome == :cancelled && return false
        if outcome != :ok
            r.state = "error"
            r.detail = "tunnel did not come up (local port $local_port → $(r.host):$(remote.port))"
            _hold_port!(r, local_port) # keep answering, so a reload is not a dead end
            return false
        end
        _remote_bail(r) && return false
        # (no answer is not a refusal: a server that is busy is still the server, as everywhere else here)
        if auth(local_port, remote.secret) != :denied
            _remote_bail(r) && return false # disconnected while we were asking: do not mark the host active
            mark_ready(r, local_port, remote.port, remote.secret, remote.node)
            return true
        end
        push!(refused, remote.secret)
        _kill_tunnel!(r)
        _remote_bail(r) && return false
        r.state = "checking"
        r.detail = "the server on $(r.host) did not accept the secret in its connection file: looking again"
        sleep(pause)
        scanned, again = rescan(refused)
        (scanned && again !== nothing) || break
        remote = again
    end
    _remote_bail(r) && return false
    r.state = "error"
    r.detail = "a server answers on $(r.host), port $(remote.port), and refuses the secret its connection file gives: the file is out of date. Connect again in a moment; if it stays like this, restart SpaceStation on $(r.host)."
    local_port > 0 && _hold_port!(r, local_port)
    false
end

function _remote_connect_task!(r::RemoteSession)
    try
        _remote_bail(r) && return
        _reconnect_known_remote!(r) && return
        _remote_bail(r) && return
        r.state = "connecting"
        r.detail = "reaching $(r.host) with your SSH keys"
        # Use _ssh_try (captures stderr) so we can tell a SLOW HOP from a real auth failure: a
        # ProxyJump banner timeout and a refused key produce very different fixes, and reporting
        # "check your SSH keys" for what is actually a busy login node sends the user down a dead end.
        ok, probe_out = _ssh_try(r.host, "true")
        if !ok
            r.state = "error"
            base = if occursin(r"banner exchange|timed out|timeout|Connection reset"i, probe_out)
                "timed out reaching $(r.host) — the SSH hop is slow right now (often a busy ProxyJump login node), not an auth problem. Try connecting again; it usually goes through on a retry."
            else
                "cannot reach $(r.host) with key-based SSH (check `ssh $(r.host)` works without a password prompt)"
            end
            # A stale duplicate entry produces exactly these two symptoms, and the advice above sends
            # you looking at keys or at the network instead of at the config. Say so when we can tell.
            conflict = ssh_config_conflict(r.host)
            r.detail = conflict === nothing ? base : base * "\n\n" * conflict
            return
        end

        r.state = "checking"
        r.detail = "looking for a running SpaceStation on $(r.host)"
        # Which version a hub started now would run: what `main` is, exported to a directory of its own
        # if it is not there yet. This changes nothing that runs (see "installed versions"), so it needs
        # no look at what is busy, here or on any other node that shares this home.
        prep = _prepare_remote_version(r.host)
        prep.state == :unknown && return _remote_unanswered!(r, "the SpaceStation installation")
        # The scan is an SSH round trip through whatever ProxyJump the node sits behind. When it
        # fails we know nothing about the node — and "nothing" must not become "no server", or the
        # node ends up running two. Say so; the watchdog retries a session that was connected before.
        scan = _scan_remote(r.host)
        scan.scanned || return _remote_unanswered!(r, "for a running SpaceStation server")
        remote = _choose_remote_server(scan.cands, r.secret)
        _remote_bail(r) && return

        # Auto-update: a server here that runs another version than `main` is replaced by one that runs
        # it, so reconnecting lands you on the latest. But only a server nobody is using (no notebook
        # open, nothing running in a terminal, on the whole node): one that is busy is attached to as it
        # is, on its own version, and is replaced the next time it is found idle. And only when the
        # version is known to be the newest (`fresh`): a node that could not reach `origin` this time
        # must not take a newer server down for an older one.
        outdated = remote !== nothing && remote.status == :live && scan.idle && prep.state == :ok && prep.fresh && remote.commit != prep.commit

        if remote === nothing || outdated
            # find julia (absolute path) — checks PATH, juliaup, ~/.local/bin, and an interactive shell (for module/.bashrc setups)
            r.julia = _find_remote_julia(r.host)
            commit = if isempty(r.julia)
                r.state = "error"
                r.detail = "julia not found on $(r.host) — tried the login-shell PATH, ~/.juliaup/bin, ~/.local/bin, and an interactive shell. Install juliaup there, or add 'module load julia' to your ~/.bash_profile."
                nothing
            else
                # The new version is made ready BEFORE anything running is stopped: if it cannot be
                # installed (no network for its packages, a damaged depot), the server that works stays.
                _ready_remote_version!(r, prep)
            end
            _remote_bail(r) && return
            if commit === nothing
                outdated || return # nothing is running here to fall back to: r.detail says what went wrong
                @info "SpaceStation: keeping the server already running on $(r.host): the current version could not be prepared there" detail = r.detail
            else
                if outdated
                    r.state = "checking"
                    r.detail = "updating SpaceStation on $(r.host) to the latest version"
                    _ssh_try(r.host, _retire_idle_servers_script(commit))
                    # Whatever survived (it became busy in between) is still the server to use.
                    scan = _scan_remote(r.host)
                    scan.scanned || return _remote_unanswered!(r, "for a running SpaceStation server")
                    remote = _choose_remote_server(scan.cands, r.secret)
                    _remote_bail(r) && return
                end
                if remote === nothing
                    remote = _launch_remote_hub!(r, commit)
                    remote === nothing && return
                end
            end
        end

        _attach_verified!(r, remote)
    catch e
        r.state = "error"
        r.detail = sprint(showerror, e)
        r.local_port > 0 && _hold_port!(r, r.local_port)
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
            # `:busy` counts as alive: a stalled server behind a working tunnel is not a reason to
            # rebuild anything (see _probe_port), least of all from a Connect click during the stall.
            if r.state == "ready" && r.tunnel !== nothing && !process_exited(r.tunnel) && _probe_port(r.local_port) != :dead
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
    _set_active_remote!(host, false) # an explicit disconnect must not come back on the next start
    host_disconnected!(host)
    if r !== nothing
        r.cancelled = true
        _kill_tunnel!(r) # and wait for it: a Connect right after ✕ must find the port free, not moving
        # see close_all_remote_tunnels: the tunnel's connection file outlives its dead port otherwise
        r.local_port > 0 && remove_collab_registry_file(r.local_port)
        _stop_placeholder!(host) # disconnecting means the port goes quiet, not that we keep waiting
    end
    lock(REMOTE_SESSIONS_LOCK) do
        delete!(REMOTE_SESSIONS, host)
        delete!(TUNNEL_AUTH_CHECKED, host)
        delete!(TUNNEL_DENIED_STREAK, host)
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
# 2s, not 5: this poll is the ONLY thing that notices the common failure. When a laptop sleeps, ssh
# is frozen rather than killed — on wake it is alive with dead TCP and can sit there for up to a
# minute (ServerAliveInterval 15 x CountMax 4) accepting connections and resetting them instantly,
# so waiting for the process to exit would be waiting for a signal that arrives far too late. Until
# we notice, a reload gets a browser error either way, so the period IS the exposure. It costs
# nothing to shorten: the probe is a local connect, and a dead one comes back refused in about a
# millisecond. A slow probe cannot pile up — iterations run one after another, never concurrently.
const TUNNEL_WATCHDOG_PERIOD = 2.0
const TUNNEL_RETRY_MIN = 5.0
const TUNNEL_RETRY_MAX = 120.0
const TUNNEL_RETRY = Dict{String,Tuple{Float64,Float64}}() # host => (next attempt at, current delay)
# A tunnel whose ssh is alive is only torn down after this many CONSECUTIVE dead probes — a single
# refused or reset connection can be ssh re-establishing something, and a rebuild is far more
# disruptive (every websocket drops) than one more 2s look. An ssh that has exited needs no second look.
const TUNNEL_DEAD_STRIKES = 2
const TUNNEL_DEAD_STREAK = Dict{String,Int}()
const TUNNEL_WATCHDOG = Ref{Union{Task,Nothing}}(nothing)
const MAX_RESTORED_REMOTES = 8
# A tunnel that answers /ping says the path is up. It does not say that the server at its end is
# still the one whose secret this session holds: a hub that was restarted on the node (by hand, by
# another computer's connect, after its job ended and a new one began) has a new secret, answers
# /ping all the same, and refuses everything the page asks through this hub. "Connected", and every
# request a 403, until somebody thought of Disconnect and Connect. So a healthy tunnel is also asked,
# now and then, with the session's secret; a server that REFUSES it twice in a row (not one that is
# slow to answer) is looked for again, the way a dead tunnel is.
const TUNNEL_AUTH_PERIOD = Ref(15.0)
const TUNNEL_AUTH_RECHECK = Ref(3.0)
const TUNNEL_AUTH_CHECKED = Dict{String,Float64}()
const TUNNEL_DENIED_STRIKES = 2
const TUNNEL_DENIED_STREAK = Dict{String,Int}()

"""
The periodic look at a healthy session's credentials. True when the server behind the tunnel has
refused the session's secret `TUNNEL_DENIED_STRIKES` times in a row: the session has to be rebuilt.
A session whose secret is accepted and whose host is not in the table yet (its hub was too busy to
say what it was when the connect finished) is put there now.
"""
function _credentials_refused!(host::AbstractString, r::RemoteSession; auth=_tunnel_auth, connected=host_connected!)::Bool
    now = time()
    due = lock(REMOTE_SESSIONS_LOCK) do
        now < get(TUNNEL_AUTH_CHECKED, host, 0.0) && return false
        TUNNEL_AUTH_CHECKED[host] = now + TUNNEL_AUTH_PERIOD[]
        true
    end
    due || return false
    verdict = auth(r.local_port, r.secret; timeout=5)
    if verdict == :denied
        return lock(REMOTE_SESSIONS_LOCK) do
            TUNNEL_AUTH_CHECKED[host] = now + TUNNEL_AUTH_RECHECK[] # the second look comes soon
            (TUNNEL_DENIED_STREAK[host] = get(TUNNEL_DENIED_STREAK, host, 0) + 1) >= TUNNEL_DENIED_STRIKES
        end
    end
    verdict == :ok || return false
    lock(() -> delete!(TUNNEL_DENIED_STREAK, host), REMOTE_SESSIONS_LOCK)
    if one_address_enabled() && remote_host(host) === nothing && _is_current_session(r)
        try
            connected(host, r.local_port, r.secret) && (r.detail = "connected — its workspaces open here")
        catch
        end
    end
    false
end

"""
What this session's path to the remote looks like right now: `:ok`, `:busy` (the tunnel is up and
the server behind it is not answering — a notebook has its thread), `:dead` (connections through it
are refused or torn down) or `:gone` (no ssh process). Only the last two mean there is anything to fix.
"""
function _tunnel_verdict(r::RemoteSession)::Symbol
    r.tunnel === nothing && return :gone
    process_exited(r.tunnel) && return :gone
    _probe_port(r.local_port)
end

"Is this session's path to the remote usable — or at least intact — right now?"
_tunnel_healthy(r::RemoteSession)::Bool = _tunnel_verdict(r) ∈ (:ok, :busy)

function _supervise_tunnels_once(; auth=_tunnel_auth)
    # Sessions worth looking after: the ones that are up, and the ones that WERE up (they have a port
    # and a secret) but whose last rebuild ended in an error — a scan that failed, a tunnel that did not
    # come up, a host that is off for the weekend. Those used to stay "error" until someone clicked
    # Connect; now they are retried with the same backoff as any dead tunnel.
    watched = lock(REMOTE_SESSIONS_LOCK) do
        [(h, r) for (h, r) in REMOTE_SESSIONS if !r.cancelled && (r.state == "ready" || (r.state == "error" && r.local_port > 0 && !isempty(r.secret)))]
    end
    for (host, r) in watched
        refused = false
        if r.state == "ready"
            verdict = _tunnel_verdict(r)
            if verdict ∈ (:ok, :busy)
                lock(REMOTE_SESSIONS_LOCK) do
                    delete!(TUNNEL_DEAD_STREAK, host)
                end
                # the path is fine; is the server at its end still ours? (only one that just answered is asked)
                refused = verdict == :ok && _credentials_refused!(host, r; auth)
                if !refused
                    lock(() -> delete!(TUNNEL_RETRY, host), REMOTE_SESSIONS_LOCK) # healthy: forget the backoff
                    continue
                end
                lock(() -> delete!(TUNNEL_DENIED_STREAK, host), REMOTE_SESSIONS_LOCK)
                _set_known_remote!(host, nothing) # what was remembered is what was refused: the rebuild is a discovery
            end
            if verdict == :dead
                strikes = lock(REMOTE_SESSIONS_LOCK) do
                    TUNNEL_DEAD_STREAK[host] = get(TUNNEL_DEAD_STREAK, host, 0) + 1
                end
                strikes < TUNNEL_DEAD_STRIKES && continue
            end
        end
        # That probe can take seconds. If the user reconnected meanwhile, this snapshot is stale, and
        # rebuilding it would race the new session for the port.
        _is_current_session(r) || continue

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

        # Say so in the UI rather than leaving a stale "ready" while nothing works — and on the hub's
        # own output, with the reason, so a drop can be explained after the fact.
        why = r.state == "error" ? "last attempt ended in an error ($(r.detail))" :
              refused ? "the server there no longer accepts this session's secret (it was restarted or replaced)" :
              r.tunnel === nothing ? "no tunnel process" :
              process_exited(r.tunnel) ? "the ssh tunnel process exited" :
              "connections through the tunnel were refused or reset $(TUNNEL_DEAD_STRIKES) times in a row"
        @info "SpaceStation: rebuilding the tunnel to $(host) — $(why)"
        r.state = "tunneling"
        r.detail = "connection lost — reconnecting to $(host)"
        try
            t = r.tunnel
            t === nothing || process_exited(t) || kill(t)
        catch
        end
        # Take the port over straight away: between here and the tunnel coming back is exactly the
        # window in which a reload would otherwise hit the browser's own error page.
        r.local_port > 0 && _hold_port!(r, r.local_port)
        lock(REMOTE_SESSIONS_LOCK) do
            delete!(TUNNEL_DEAD_STREAK, host) # the rebuilt tunnel starts with a clean record
            # only start a rebuild if one is not already running for this host
            if r.task === nothing || istaskdone(r.task)
                r.task = @asynclog _remote_connect_task!(r)
            end
        end
    end
end

"""
Re-attach to every host the user was connected to when the hub last ran.

Each host lands back on its stable local port, so a workspace tab that was left open across a
reboot answers a hard refresh normally instead of the browser's "site can't be reached". Failures
are quiet — the host may simply be off — and the watchdog then retries with backoff.
"""
function restore_remote_sessions!()
    hosts = _read_active_remotes()
    isempty(hosts) && return
    # Bounded: reconnecting is several SSH round trips per host, and a long-lived install can
    # accumulate hosts. The rest reattach on demand from homebase, as before.
    if length(hosts) > MAX_RESTORED_REMOTES
        @info "SpaceStation: reattaching to the $(MAX_RESTORED_REMOTES) most recent remote hosts; open the others from homebase" skipped = length(hosts) - MAX_RESTORED_REMOTES
        hosts = hosts[1:MAX_RESTORED_REMOTES]
    end
    @asynclog for host in hosts
        try
            open_remote_session!(host)
        catch e
            @debug "could not reattach to remote host" host exception = (e, catch_backtrace())
        end
    end
    nothing
end

# The tests drive `_supervise_tunnels_once` by hand and count its verdicts; a watchdog started by an
# earlier test file's server would race those counts (it did, on one CI runner). They pause it.
const TUNNEL_WATCHDOG_PAUSED = Ref(false)

"Start the tunnel watchdog once per server process."
function start_tunnel_watchdog!()
    TUNNEL_WATCHDOG[] === nothing || return
    TUNNEL_WATCHDOG[] = @asynclog while true
        sleep(TUNNEL_WATCHDOG_PERIOD)
        TUNNEL_WATCHDOG_PAUSED[] && continue
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
    if !is_file_helper_process() # a file helper (FileHelper.jl) has no business with anybody's tunnels
        start_tunnel_watchdog!()
        restore_remote_sessions!()
    end

    function remote_status_json(r::RemoteSession)
        _json(Pair[
            "host" => r.host,
            "state" => r.state,
            "detail" => r.detail,
            "url" => r.state == "ready" ? _remote_url(r) : nothing,
            # its workspaces are pages of this hub (/h/<host>/w/<id>/): the launcher browses it, and does not go to `url`
            "hosted" => r.state == "ready" && remote_host(r.host) !== nothing,
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
                    "hosted" => r.state == "ready" && remote_host(r.host) !== nothing,
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
    # so the 200 reaches the browser: close SSH tunnels, then run the server's shutdown hook (notebooks,
    # registry file) and stop the HTTP server, which unblocks `wait`, so a CLI launch exits.
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
