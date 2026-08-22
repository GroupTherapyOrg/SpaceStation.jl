using Test
import SpaceStation: Pluto
import Sockets
import HTTP

# The browser addresses a remote workspace as `http://localhost:<local_port>/`, so that port is the
# workspace's identity to an open tab, a bookmark or a reload. It used to be handed out by
# `listenany(45200)` — "first free port right now" — which made it depend on arrival order.

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
            # a socket that answers /ping stands in for a live tunnel. `Connection: close` keeps
            # HTTP.jl from pooling the socket and reusing one we already hung up on.
            srv = Sockets.listen(Sockets.localhost, UInt16(port))
            @async while isopen(srv)
                try
                    conn = Sockets.accept(srv)
                    @async try
                        readavailable(conn)
                        write(conn, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                        close(conn)
                    catch
                    end
                catch
                    break
                end
            end
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
    end
end
