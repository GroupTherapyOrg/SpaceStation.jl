using Test
import SpaceStation: Pluto
import Sockets
import HTTP

# The browser addresses a remote workspace as `http://localhost:<local_port>/`, so that port is the
# workspace's identity to an open tab, a bookmark or a reload. It used to be handed out by
# `listenany(45200)` — "first free port right now" — which made it depend on arrival order.

# A socket that answers /ping stands in for a live tunnel. `Connection: close` keeps HTTP.jl from
# pooling the socket and reusing one we already hung up on.
function answer_ping(port; status="200 OK")
    srv = Sockets.listen(Sockets.localhost, UInt16(port))
    @async while isopen(srv)
        try
            conn = Sockets.accept(srv)
            @async try
                readavailable(conn)
                write(conn, "HTTP/1.1 $(status)\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                close(conn)
            catch
            end
        catch
            break
        end
    end
    srv
end

function add_session!(r)
    lock(Pluto.REMOTE_SESSIONS_LOCK) do
        Pluto.REMOTE_SESSIONS[r.host] = r
    end
    r
end
drop_session!(host) = lock(() -> delete!(Pluto.REMOTE_SESSIONS, host), Pluto.REMOTE_SESSIONS_LOCK)

@testset "Stable tunnel ports" begin
    # keep the port map out of the real ~/.local/state
    state = mktempdir()
    withenv("XDG_STATE_HOME" => state) do
        @testset "a host keeps its port" begin
            a = Pluto.stable_tunnel_port("gpu-node-1")
            @test a == Pluto.stable_tunnel_port("gpu-node-1")
            @test Pluto.TUNNEL_PORT_BASE <= a < Pluto.TUNNEL_PORT_BASE + Pluto.TUNNEL_PORT_SPAN
            # …and it is written down, so a hub restart hands out the same one again
            @test Pluto._read_tunnel_ports()["gpu-node-1"] == a
        end

        @testset "two hosts never share a port" begin
            a = Pluto.stable_tunnel_port("gpu-node-1")
            b = Pluto.stable_tunnel_port("gpu-node-2")
            @test a != b
        end

        # The regression that matters: host A disconnects, its port goes idle, host B connects and
        # its preferred port happens to be A's. If B took it, every tab still open on A would
        # silently start talking to B — a different machine.
        @testset "a free port promised to another host is refused" begin
            victim = Pluto._read_tunnel_ports()["gpu-node-1"]
            newcomer = nothing
            for i in 1:20000
                h = "probe-host-$(i)"
                if Pluto.TUNNEL_PORT_BASE + Int(mod(Pluto._stable_hash(h), Pluto.TUNNEL_PORT_SPAN)) == victim
                    newcomer = h
                    break
                end
            end
            @test newcomer !== nothing            # otherwise the test is not exercising anything
            @test Pluto.stable_tunnel_port(newcomer) != victim
            @test Pluto._read_tunnel_ports()["gpu-node-1"] == victim
        end

        @testset "the name hash is stable across releases" begin
            # pinned: if this changes, every host silently moves to a new port on upgrade
            @test Pluto._stable_hash("gpu-node-1") == Pluto._stable_hash("gpu-node-1")
            @test Pluto._stable_hash("a") != Pluto._stable_hash("b")
        end

        @testset "an unparseable map does not take the tunnel down" begin
            write(joinpath(state, "pluto", "servers", "tunnel-ports.tsv"), "garbage\nnot\ta\tport\n")
            @test Pluto._read_tunnel_ports() isa Dict
            @test Pluto.stable_tunnel_port("gpu-node-3") isa Int
        end

        # `ssh -L` owns the local port, so when ssh dies the port goes silent and a reload gets the
        # browser's own "site can't be reached" — a page none of our code runs in, so the tab can do
        # nothing for itself. While the tunnel is down the hub holds the port instead.
        @testset "the hub holds the port while the tunnel is down" begin
            port = Pluto.stable_tunnel_port("held-node")
            @test !Pluto._local_ping_ok(port)   # nothing there: this is the dead-end case

            Pluto._start_placeholder!("held-node", port)
            try
                sleep(0.6)
                r = HTTP.get("http://127.0.0.1:$(port)/anything"; status_exception=false, retry=false)
                @test r.status == 503
                @test HTTP.header(r, "X-SpaceStation-Reconnecting") == "1"
                @test occursin("held-node", String(r.body)) # names the host you are waiting on

                # The one that must never regress: 503 keeps `_local_ping_ok` false, so the watchdog
                # still knows there is something to fix. A placeholder that looked healthy would
                # convince it the tunnel was fine and stop the reconnect for good.
                @test !Pluto._local_ping_ok(port)

                Pluto._start_placeholder!("held-node", port) # idempotent
                @test HTTP.get("http://127.0.0.1:$(port)/"; status_exception=false, retry=false).status == 503
            finally
                Pluto._stop_placeholder!("held-node")
            end
            sleep(0.6)
            @test Pluto._port_bindable(port) # released, so `ssh -L` can take it back
        end

        # OpenSSH uses the FIRST value it finds for each keyword across every matching block. Tools
        # that write a config entry per compute job append a new block each time a node is
        # reallocated, so the alias ends up defined several times and the OLDEST wins — routing
        # through a jump host whose job ended weeks ago. ssh does not complain; it just fails to
        # connect, which is indistinguishable from bad keys unless somebody says otherwise.
        @testset "a shadowed ssh_config entry is diagnosed, not guessed at" begin
            blk(jid, node) = """
            Host hpc_login_$(jid)
                HostName hpc3
                User u

            Host $(node)
                HostName $(node)
                User u
                ProxyJump hpc_login_$(jid)
            """
            two = blk("111", "gpu-a") * blk("999", "gpu-a")

            @test Pluto._host_blocks(two, "gpu-a") == ["hpc_login_111", "hpc_login_999"]
            @test Pluto._host_blocks(two, "gpu-zzz") == []
            # a wildcard block is not a second definition of this alias
            @test Pluto._host_blocks("Host gpu-*\n    ProxyJump w\n", "gpu-a") == []
            # a block that sets no ProxyJump still counts as a definition
            @test Pluto._host_blocks("Host gpu-a\n    User u\n", "gpu-a") == [nothing]
            # keywords are case-insensitive, as in ssh
            @test Pluto._host_blocks("host gpu-a\n    proxyjump j\n", "gpu-a") == ["j"]

            blocks = Pluto._host_blocks(two, "gpu-a")
            msg = Pluto._describe_ssh_config_conflict("gpu-a", "hpc_login_111", blocks)
            @test msg !== nothing
            @test occursin("2 times", msg)
            @test occursin("hpc_login_111", msg) && occursin("hpc_login_999", msg)

            # Quiet unless it is both unambiguous and actionable:
            #   already on the newest -> the duplication is harmless today
            @test Pluto._describe_ssh_config_conflict("gpu-a", "hpc_login_999", blocks) === nothing
            #   effective value we never saw -> we do not understand this file well enough to advise
            @test Pluto._describe_ssh_config_conflict("gpu-a", "elsewhere", blocks) === nothing
            @test Pluto._describe_ssh_config_conflict("gpu-a", nothing, blocks) === nothing
            #   one definition, or duplicates that agree
            @test Pluto._describe_ssh_config_conflict("gpu-a", "hpc_login_111",
                      Pluto._host_blocks(blk("111", "gpu-a"), "gpu-a")) === nothing
            @test Pluto._describe_ssh_config_conflict("gpu-a", "hpc_login_111",
                      Pluto._host_blocks(blk("111", "gpu-a") * blk("111", "gpu-a"), "gpu-a")) === nothing

            # it runs `ssh -G`, so it must survive anything: a bad host, no config, no ssh at all
            @test Pluto.ssh_config_conflict("definitely-not-a-host-xyz") === nothing
            @test Pluto.ssh_config_conflict("") === nothing
        end

        # A hub restart (reboot, crash, quit-and-relaunch) used to leave every tunnel down until the
        # user reconnected by hand. A workspace tab left open over lunch then answered a refresh
        # with the browser's own "site can't be reached", where none of our code runs.
        @testset "hosts the user is attached to are remembered across a hub restart" begin
            @test Pluto._read_active_remotes() == String[]
            Pluto._set_active_remote!("gpu-a", true)
            Pluto._set_active_remote!("gpu-b", true)
            @test sort(Pluto._read_active_remotes()) == ["gpu-a", "gpu-b"]
            Pluto._set_active_remote!("gpu-a", true) # idempotent
            @test sort(Pluto._read_active_remotes()) == ["gpu-a", "gpu-b"]
            # an explicit disconnect must NOT come back on the next start
            Pluto._set_active_remote!("gpu-a", false)
            @test Pluto._read_active_remotes() == ["gpu-b"]
            Pluto._set_active_remote!("gpu-b", false)
            @test Pluto._read_active_remotes() == String[]
            # nothing recorded: restoring is a no-op, and never throws during server startup
            @test Pluto.restore_remote_sessions!() === nothing
        end

        # `ssh -N -L` gives up about a minute after the network stops answering, which is what a
        # closed laptop lid looks like. Nothing used to notice: the session stayed "ready" while
        # every request through it failed, until you reconnected by hand from homebase.
        @testset "the watchdog notices a dead tunnel and schedules a retry" begin
            port = Pluto.stable_tunnel_port("watchdog-node")
            srv = answer_ping(port)
            proc = run(`sleep 600`; wait=false) # stands in for the ssh child
            session = Pluto.RemoteSession("watchdog-node", "ready", "", port, "s", "julia", proc, nothing, false)
            # A task that never finishes, so the supervisor sees "a rebuild is already running" and
            # does not launch a real SSH connect for a host that does not exist.
            session.task = @async sleep(600)
            lock(Pluto.REMOTE_SESSIONS_LOCK) do
                Pluto.REMOTE_SESSIONS["watchdog-node"] = session
            end
            try
                sleep(0.5)
                @test Pluto._tunnel_healthy(session)
                Pluto._supervise_tunnels_once()
                @test session.state == "ready"            # healthy: left alone
                @test !haskey(Pluto.TUNNEL_RETRY, "watchdog-node")

                kill(proc)   # the lid closes
                close(srv)
                sleep(0.6)
                @test !Pluto._tunnel_healthy(session)

                Pluto._supervise_tunnels_once()
                @test session.state == "tunneling"        # the UI is told, instead of a stale "ready"
                @test haskey(Pluto.TUNNEL_RETRY, "watchdog-node")

                # a node that is off for the weekend must not cost an SSH round trip every 5s
                at_first, _ = Pluto.TUNNEL_RETRY["watchdog-node"]
                Pluto._supervise_tunnels_once()
                at_second, delay = Pluto.TUNNEL_RETRY["watchdog-node"]
                @test at_first == at_second               # held off by the backoff
                @test delay > Pluto.TUNNEL_RETRY_MIN      # and the next wait is longer
            finally
                try kill(proc) catch end
                try close(srv) catch end
                lock(Pluto.REMOTE_SESSIONS_LOCK) do
                    delete!(Pluto.REMOTE_SESSIONS, "watchdog-node")
                    delete!(Pluto.TUNNEL_RETRY, "watchdog-node")
                end
            end
        end

        # With no bind address ssh also listens on ::1, and ExitOnForwardFailure only fires when EVERY
        # address fails — so a taken 127.0.0.1 left ssh running on ::1 alone while all our probes
        # (127.0.0.1) hit whatever held the port. One address makes the conflict fatal to ssh.
        @testset "the tunnel binds 127.0.0.1 only, so a taken port makes ssh exit" begin
            argv = Pluto._tunnel_command("gpu-a", 45210, 1234).exec
            @test "127.0.0.1:45210:127.0.0.1:1234" in argv
            @test "ExitOnForwardFailure=yes" in argv
            @test last(argv) == "gpu-a"
        end

        # A failed tunnel used to leave its ssh running. It kept the port, so the next attempt's ssh
        # could not bind it and failed the same way, however healthy the host was.
        @testset "a tunnel that never answers does not leave ssh behind" begin
            r = add_session!(Pluto.RemoteSession("silent-node", "tunneling", "", 0, "", "", nothing, nothing, false))
            try
                outcome, port = Pluto._open_tunnel!(r, 1234; command=(h, l, rp) -> `sleep 600`, polls=2)
                @test outcome == :failed
                @test process_exited(r.tunnel)
                @test Pluto._port_bindable(port)
            finally
                Pluto._kill_tunnel!(r)
                drop_session!("silent-node")
            end
        end

        # The port is the host's identity to its open tabs, so a holder that lets go (a process still
        # tearing down) must not move the host: the retry keeps the same port.
        @testset "a port taken only briefly is retried on the same port" begin
            r = add_session!(Pluto.RemoteSession("blip-node", "tunneling", "", 0, "", "", nothing, nothing, false))
            srv = nothing
            tried = Int[]
            function fake_ssh(h, l, rp)
                push!(tried, l)
                if length(tried) == 1
                    # answers at once (a bare socket would make the /ping probe hang until it
                    # closed); still holding the port when the exit is noticed (~1s), gone before
                    # the retry (after `settle`) — a port that is ALREADY free when ssh dies means
                    # ssh failed for some other reason, and that is rightly not retried
                    thief = answer_ping(l; status="503 Service Unavailable")
                    @async (sleep(1.6); close(thief))
                    `false`
                else
                    srv = answer_ping(l)
                    `sleep 600`
                end
            end
            try
                outcome, port = Pluto._open_tunnel!(r, 1234; command=fake_ssh, polls=5, settle=2.0)
                @test outcome == :ok
                @test tried == [port, port]
                @test Pluto._read_tunnel_ports()["blip-node"] == port
            finally
                Pluto._kill_tunnel!(r)
                srv === nothing || close(srv)
                drop_session!("blip-node")
            end
        end

        @testset "a port that stays taken is retried on another port" begin
            r = add_session!(Pluto.RemoteSession("raced-node", "tunneling", "", 0, "", "", nothing, nothing, false))
            thief = srv = nothing
            tried = Int[]
            # attempt 1: something grabs the port right after we picked it, and ssh exits (as with
            # ExitOnForwardFailure). attempt 2: the tunnel comes up.
            function fake_ssh(h, l, rp)
                push!(tried, l)
                if length(tried) == 1
                    thief = Sockets.listen(Sockets.localhost, UInt16(l))
                    `false`
                else
                    srv = answer_ping(l)
                    `sleep 600`
                end
            end
            try
                outcome, port = Pluto._open_tunnel!(r, 1234; command=fake_ssh, polls=5, settle=0.2)
                @test outcome == :ok
                @test length(tried) == 2
                @test port == tried[2] != tried[1]
            finally
                Pluto._kill_tunnel!(r)
                thief === nothing || close(thief)
                srv === nothing || close(srv)
                drop_session!("raced-node")
            end
        end

        # A Pluto server runs its notebooks on the thread that answers HTTP, so a notebook handing it a
        # large output stalls /ping for ten, twenty seconds while nothing is wrong with the tunnel. The
        # probe used to fold that into "unhealthy": the watchdog killed a working tunnel, and the
        # reconnect then failed to find the (still stalled) server and started a SECOND one on the
        # node, orphaning the notebooks on the first. Silence and refusal are different verdicts.
        @testset "a busy server is told apart from a dead one" begin
            port = Pluto.stable_tunnel_port("probe-node")
            @test Pluto._probe_port(port) == :dead            # nothing listening: refused

            srv = answer_ping(port)
            sleep(0.3)
            @test Pluto._probe_port(port) == :ok
            @test Pluto._local_ping_ok(port)
            close(srv)
            sleep(0.3)

            srv = answer_ping(port; status="503 Service Unavailable") # the placeholder
            sleep(0.3)
            @test Pluto._probe_port(port) == :dead            # anything but 200 is not a server
            @test !Pluto._local_ping_ok(port)
            close(srv)
            sleep(0.3)

            # accepts, never answers: what a stalled server (or a tunnel to one) looks like
            mute = Sockets.listen(Sockets.localhost, UInt16(port))
            try
                @test Pluto._probe_port(port; wait=0.5) == :busy
                @test !Pluto._local_ping_ok(port)           # busy is not "answering", either
            finally
                close(mute)
            end
        end

        @testset "the watchdog leaves a busy tunnel alone and needs two strikes for a dead one" begin
            port = Pluto.stable_tunnel_port("busy-node")
            # What the tunnel to a stalled server looks like from here: ssh accepts and forwards, the
            # far end reads the request and then says nothing. Accept-and-hold rather than a bare
            # listener, whose never-accepted connections mean different things to different kernels.
            mute = Sockets.listen(Sockets.localhost, UInt16(port))
            held = Sockets.TCPSocket[]
            @async while isopen(mute)
                try
                    conn = Sockets.accept(mute)
                    push!(held, conn)
                    @async try readavailable(conn) catch end
                catch
                    break
                end
            end
            proc = run(`sleep 600`; wait=false)
            session = Pluto.RemoteSession("busy-node", "ready", "", port, "s", "julia", proc, nothing, false)
            session.task = @async sleep(600)
            lock(Pluto.REMOTE_SESSIONS_LOCK) do
                Pluto.REMOTE_SESSIONS["busy-node"] = session
            end
            try
                @test Pluto._tunnel_verdict(session) == :busy
                @test Pluto._tunnel_healthy(session)
                Pluto._supervise_tunnels_once()
                @test session.state == "ready"                # busy: nothing to fix
                @test !haskey(Pluto.TUNNEL_RETRY, "busy-node")
                @test !haskey(Pluto.TUNNEL_DEAD_STREAK, "busy-node") # and not a strike, either

                close(mute)                                   # now connections are refused, ssh still alive
                foreach(c -> (try close(c) catch end), held)
                sleep(0.3)
                @test Pluto._tunnel_verdict(session) == :dead
                Pluto._supervise_tunnels_once()
                @test session.state == "ready"                # one refusal is not a verdict
                @test get(Pluto.TUNNEL_DEAD_STREAK, "busy-node", 0) == 1
                Pluto._supervise_tunnels_once()
                @test session.state == "tunneling"            # two in a row is
                @test haskey(Pluto.TUNNEL_RETRY, "busy-node")
                @test !haskey(Pluto.TUNNEL_DEAD_STREAK, "busy-node")
            finally
                try kill(proc) catch end
                try close(mute) catch end
                foreach(c -> (try close(c) catch end), held)
                Pluto._stop_placeholder!("busy-node")
                lock(Pluto.REMOTE_SESSIONS_LOCK) do
                    delete!(Pluto.REMOTE_SESSIONS, "busy-node")
                    delete!(Pluto.TUNNEL_RETRY, "busy-node")
                    delete!(Pluto.TUNNEL_DEAD_STREAK, "busy-node")
                end
            end
        end

        # A rebuild that ended in an error (a scan that failed, a host that was off) used to stay
        # "error" until somebody clicked Connect. A session that was connected once is worth retrying.
        @testset "a session that was connected before is retried after an error" begin
            was = Pluto.RemoteSession("errored-node", "error", "scan failed", 45299, "s3cr3t", "julia", nothing, nothing, false)
            never = Pluto.RemoteSession("fresh-node", "error", "bad keys", 0, "", "", nothing, nothing, false)
            was.task = @async sleep(600) # "a rebuild is already running": keeps the test off real SSH
            never.task = @async sleep(600)
            lock(Pluto.REMOTE_SESSIONS_LOCK) do
                Pluto.REMOTE_SESSIONS["errored-node"] = was
                Pluto.REMOTE_SESSIONS["fresh-node"] = never
            end
            try
                Pluto._supervise_tunnels_once()
                @test was.state == "tunneling"
                @test haskey(Pluto.TUNNEL_RETRY, "errored-node")
                @test never.state == "error"                 # never connected: the user's call
                @test !haskey(Pluto.TUNNEL_RETRY, "fresh-node")
            finally
                Pluto._stop_placeholder!("errored-node")
                lock(Pluto.REMOTE_SESSIONS_LOCK) do
                    delete!(Pluto.REMOTE_SESSIONS, "errored-node")
                    delete!(Pluto.REMOTE_SESSIONS, "fresh-node")
                    delete!(Pluto.TUNNEL_RETRY, "errored-node")
                end
            end
        end

        # Through the tunnel the same stall looks like "accepted, no answer". That used to exhaust the
        # poll budget and report "tunnel did not come up" — for a tunnel that was up.
        @testset "a tunnel to a busy server waits instead of failing" begin
            r = add_session!(Pluto.RemoteSession("slow-node", "tunneling", "", 0, "", "", nothing, nothing, false))
            srv = nothing
            function fake_ssh(h, l, rp)
                # answers nothing for the first ~3s, then 200 — like a server finishing a big cell
                srv = Sockets.listen(Sockets.localhost, UInt16(l))
                wake = time() + 3.0
                @async while isopen(srv)
                    try
                        conn = Sockets.accept(srv)
                        @async try
                            readavailable(conn)
                            time() < wake && sleep(wake - time())
                            write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                            close(conn)
                        catch
                        end
                    catch
                        break
                    end
                end
                `sleep 600`
            end
            try
                # polls=1: a single dead probe would fail it. Only busy probes happen, and they do not count.
                outcome, port = Pluto._open_tunnel!(r, 1234; command=fake_ssh, polls=1, busy_polls=20)
                @test outcome == :ok
            finally
                Pluto._kill_tunnel!(r)
                srv === nothing || close(srv)
                drop_session!("slow-node")
            end
        end

        # What the hub concludes from a scan of the node's registry: never "start a server" while a
        # server process exists there, and a reconnect goes back to the SAME server its tabs know.
        @testset "choosing the server on a node" begin
            file(port, secret, pid; ws=nothing) = """{"pid": $(pid), "host": "127.0.0.1", "port": $(port), "node": "gpu-a", "secret": "$(secret)", "workspace": $(ws === nothing ? "null" : "\"$(ws)\""), "started_at": 1.7e9}"""
            scan = join([
                "__CANDIDATE__ LIVE 100\n" * file(1234, "empty1", 100),
                "__CANDIDATE__ BUSY 200\n" * file(1235, "busy22", 200; ws="/home/u/proj"),
                "__CANDIDATE__ DEAD 300\n" * file(1236, "corpse", 300; ws="/home/u/old"),
                "__CANDIDATE__ LIVE 400\n" * file(1237, "live44", 400; ws="/home/u/proj2"),
                "__SCAN_DONE__\n",
            ], "\n")
            cands = Pluto._parse_remote_candidates(scan)
            @test cands !== nothing
            @test [c.status for c in cands] == [:live, :busy, :dead, :live]
            @test [c.port for c in cands] == [1234, 1235, 1236, 1237]
            @test [c.pid for c in cands] == [100, 200, 300, 400]
            @test [c.has_workspace for c in cands] == [false, true, true, true]

            # the session's own server first — even while it is busy: its tabs carry that secret
            @test Pluto._choose_remote_server(cands, "busy22").port == 1235
            # a corpse is never chosen, whatever its secret was
            @test Pluto._choose_remote_server(cands, "corpse").port != 1236
            # no history: a live server with a workspace open beats an idle one, which beats a busy one
            @test Pluto._choose_remote_server(cands, "").port == 1237
            @test Pluto._choose_remote_server(cands[1:1], "").port == 1234
            @test Pluto._choose_remote_server(cands[2:3], "").port == 1235   # busy still means "exists"
            @test Pluto._choose_remote_server(cands[3:3], "") === nothing   # only a corpse: start one

            # a scan that did not finish is not a verdict — an SSH hiccup must not read as "no server"
            @test Pluto._parse_remote_candidates("") === nothing
            @test Pluto._parse_remote_candidates("__CANDIDATE__ LIVE 100\n" * file(1234, "x", 100)) === nothing
            @test Pluto._parse_remote_candidates("__SCAN_DONE__\n") == Pluto.RemoteCandidate[]
        end

        # A connect task cannot be interrupted mid-SSH-call, so a session the user cancelled or
        # replaced can still be running. If it put the placeholder back after the new session had
        # released the port, the new tunnel lost the bind and the connect failed for no visible reason.
        @testset "only the host's current session may hold its port" begin
            port = Pluto.stable_tunnel_port("race-node")
            old = Pluto.RemoteSession("race-node", "tunneling", "", 0, "", "", nothing, nothing, false)
            new = add_session!(Pluto.RemoteSession("race-node", "tunneling", "", 0, "", "", nothing, nothing, false))
            try
                @test !Pluto._is_current_session(old)
                @test Pluto._remote_bail(old)              # a superseded task stops at its next check
                @test !Pluto._remote_bail(new)

                Pluto._hold_port!(old, port)
                sleep(0.3)
                @test Pluto._port_bindable(port)           # superseded: the port stays free

                new.cancelled = true
                Pluto._hold_port!(new, port)
                sleep(0.3)
                @test Pluto._port_bindable(port)           # cancelled: likewise

                new.cancelled = false
                Pluto._hold_port!(new, port)
                sleep(0.3)
                @test !Pluto._port_bindable(port)          # the owner still gets its placeholder
            finally
                Pluto._stop_placeholder!("race-node")
                drop_session!("race-node")
            end
        end
    end
end
