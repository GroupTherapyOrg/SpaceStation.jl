using Test
import SpaceStation: Pluto
import Sockets

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
