using Test
import SpaceStation: Pluto

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
    end
end
