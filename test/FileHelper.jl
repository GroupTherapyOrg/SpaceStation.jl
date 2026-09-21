using Test
import HTTP
import SpaceStation as Pluto

# A hub hands every read and write of the user's files to a disposable helper process (FileHelper.jl),
# because one file call on a hung filesystem would stop the hub's whole process.
@testset "A hub's file helpers" begin
    state = mktempdir(); ws = mktempdir()
    write(joinpath(ws, "a.jl"), "x = 1\n"); mkdir(joinpath(ws, "sub"))
    withenv("XDG_STATE_HOME" => state, "SPACESTATION_STATE_HOME" => nothing, "SPACESTATION_FILE_HELPER" => "1") do
        session = Pluto.ServerSession(; options=Pluto.Configuration.from_flat_kwargs(;
            workspace_use_distributed=false, launch_browser=false, hub=true, port_hint=2465,
            require_secret_for_access=false, require_secret_for_open_links=false))
        server = Pluto.run!(session)
        port = session.options.server.port
        base = "http://127.0.0.1:$port"
        get(url; kw...) = HTTP.get(url; retry=false, status_exception=false, cookies=false, connect_timeout=5, readtimeout=30, kw...)
        try
            @test Pluto.file_helpers_active()
            helpers = lock(() -> copy(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK)
            @test length(helpers) == 2 && all(h -> !process_exited(h.proc), helpers)
            # a helper is nobody's server but its hub's: it does not announce itself
            @test readdir(Pluto.collab_registry_dir()) == [basename(Pluto.collab_registry_path(port))]
            # and nobody without its secret gets anything from it
            @test get("http://127.0.0.1:$(helpers[1].port)/api/v1/browse?path=$(HTTP.escapeuri(ws))").status == 403

            r = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))")
            @test r.status == 200 && occursin("\"sub\"", String(r.body))
            @test get("$base/api/v1/browse?path=/no/such/dir").status == 404          # the helper's answer, relayed as it is
            @test String(get("$base/api/v1/file?path=$(HTTP.escapeuri(joinpath(ws, "a.jl")))").body) == "x = 1\n"
            saved = HTTP.post("$base/api/v1/file/save?path=$(HTTP.escapeuri(joinpath(ws, "b.txt")))", [], "y = 2"; retry=false, status_exception=false, cookies=false)
            @test saved.status == 200 && read(joinpath(ws, "b.txt"), String) == "y = 2"
            @test Pluto.hub_isdir(ws) === true && Pluto.hub_isdir(joinpath(ws, "nope")) === false

            # the workspace a forwarded request is about travels in a header only a helper believes
            request = HTTP.Request("GET", "/api/v1/workspace/listing"); request.context[:workspace_root] = ws
            listing = Pluto.relay_to_file_helper(request)
            @test listing.status == 200 && occursin("a.jl", String(listing.body))
            spoofed = get("$base/api/v1/workspace/listing"; headers=[Pluto.WORKSPACE_ROOT_HEADER => HTTP.escapeuri(ws)])
            @test !occursin("a.jl", String(spoofed.body))                               # from a browser it means nothing

            # both helpers stuck (here: unreachable): file requests are refused at once, everything else is served
            real_ports = [h.port for h in helpers]
            for h in helpers; h.port = 9; end
            t = time(); busy = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))"); took = time() - t
            @test busy.status == 504 && occursin("filesystem_busy", String(busy.body)) && took < 8
            @test all(h -> h.busy_since > 0, helpers)
            @test get("$base/ping").status == 200
            @test Pluto.hub_isdir(ws) === nothing
            # they come back by themselves once they answer again
            for (h, p) in zip(helpers, real_ports); h.port = p; end
            @test get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))").status == 200
            @test any(h -> h.busy_since == 0.0, helpers)

            # one that died is replaced
            kill(helpers[1].proc); wait(helpers[1].proc)
            @test get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))").status == 200
            @test timedwait(() -> lock(() -> length(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK) == 2, 120) == :ok
        finally
            procs = [h.proc for h in lock(() -> copy(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK)]
            close(server)
            @test timedwait(() -> all(process_exited, procs), 30) == :ok               # they go with their hub
            @test !Pluto.file_helpers_active()
        end
    end
    withenv("SPACESTATION_FILE_HELPER" => "0") do
        @test Pluto.start_file_helpers!() == 0                                          # the switch
    end
end
