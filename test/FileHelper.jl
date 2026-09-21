using Test
import HTTP
import SpaceStation as Pluto

# A hub hands every read and write of the user's files to a disposable helper process (FileHelper.jl),
# because one file call on a hung filesystem would stop the hub's whole process.
@testset "A hub's file helpers" begin
    state = mktempdir(); ws = mktempdir()
    write(joinpath(ws, "a.jl"), "x = 1\n"); mkdir(joinpath(ws, "sub"))
    withenv("XDG_STATE_HOME" => state, "SPACESTATION_STATE_HOME" => nothing, "SPACESTATION_FILE_HELPER" => "1") do
        Pluto.FILE_HELPER_COUNT[] = 2
        session = Pluto.ServerSession(; options=Pluto.Configuration.from_flat_kwargs(;
            workspace_use_distributed=false, launch_browser=false, hub=true, port_hint=2465,
            require_secret_for_access=false, require_secret_for_open_links=false))
        server = Pluto.run!(session)
        port = session.options.server.port
        base = "http://127.0.0.1:$port"
        get(url; kw...) = HTTP.get(url; retry=false, status_exception=false, cookies=false, connect_timeout=5, readtimeout=30, kw...)
        try
            @test Pluto.file_helpers_active()                                           # decided at start, before any helper is up
            early = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))")
            @test early.status in (200, 504)                                             # never served by the hub itself
            @test timedwait(() -> lock(() -> length(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK) == 2, 240) == :ok
            helpers = lock(() -> copy(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK)
            @test all(h -> !process_exited(h.proc), helpers)
            # a helper is nobody's server but its hub's: it does not announce itself
            @test readdir(Pluto.collab_registry_dir()) == [basename(Pluto.collab_registry_path(port))]
            # nobody without its secret gets anything from it, and WITH the secret only the forwarded routes exist
            h1 = helpers[1]
            @test get("http://127.0.0.1:$(h1.port)/api/v1/browse?path=$(HTTP.escapeuri(ws))").status == 403
            @test get("http://127.0.0.1:$(h1.port)/api/v1/local/list?secret=$(h1.secret)").status == 404
            @test get("http://127.0.0.1:$(h1.port)/api/v1/helper/stat?secret=$(h1.secret)&path=$(HTTP.escapeuri(ws))").status == 200
            @test get("$base/api/v1/helper/stat?path=$(HTTP.escapeuri(ws))").status == 404  # the hub has no such route to offer
            # files that hold a secret, in the shared home, are written and removed by a helper, not by the hub
            private = joinpath(ws, "deep", "conn.json")
            wrote = Pluto.relay_to_file_helper(HTTP.Request("POST", "/api/v1/helper/private_file?path=" * HTTP.escapeuri(private), Pair{String,String}[], Vector{UInt8}("{\"secret\": 1}")))
            @test wrote.status == 200 && read(private, String) == "{\"secret\": 1}"
            Sys.iswindows() || @test filemode(private) & 0o077 == 0
            @test Pluto.relay_to_file_helper(HTTP.Request("DELETE", "/api/v1/helper/private_file?path=" * HTTP.escapeuri(private))).status == 200
            @test !isfile(private)

            r = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))")
            @test r.status == 200 && occursin("\"sub\"", String(r.body))
            @test get("$base/api/v1/browse?path=/no/such/dir").status == 404          # the helper's answer, relayed as it is
            @test String(get("$base/api/v1/file?path=$(HTTP.escapeuri(joinpath(ws, "a.jl")))").body) == "x = 1\n"
            saved = HTTP.post("$base/api/v1/file/save?path=$(HTTP.escapeuri(joinpath(ws, "b.txt")))", [], "y = 2"; retry=false, status_exception=false, cookies=false)
            @test saved.status == 200 && read(joinpath(ws, "b.txt"), String) == "y = 2"
            @test Pluto.hub_isdir(ws) === true && Pluto.hub_isdir(joinpath(ws, "nope")) === false && Pluto.hub_isdir(joinpath(ws, "a.jl")) === false

            # the workspace a forwarded request is about travels in a header only a helper believes
            request = HTTP.Request("GET", "/api/v1/workspace/listing"); request.context[:workspace_root] = ws
            listing = Pluto.relay_to_file_helper(request)
            @test listing.status == 200 && occursin("a.jl", String(listing.body))
            spoofed = get("$base/api/v1/workspace/listing"; headers=[Pluto.WORKSPACE_ROOT_HEADER => HTTP.escapeuri(ws)])
            @test !occursin("a.jl", String(spoofed.body))                               # from a browser it means nothing

            # What hangs is a filesystem, not a helper. A request that gets no answer marks its ROOT as hung,
            # held by the helper that is stuck on it; it is never tried on the other helper (which would stick too)
            other = mktempdir(); mkdir(joinpath(other, "inner"))
            real_ports = [h.port for h in helpers]
            for h in helpers; h.port = 9; end                                            # neither answers
            key = Pluto.filesystem_key(Pluto.tamepath(ws))
            t = time(); busy = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))"); took = time() - t
            @test busy.status == 504 && occursin("filesystem_busy", String(busy.body)) && took < 20 # (Windows takes seconds to refuse a closed port)
            # a first miss is a suspicion (a big healthy listing is slow too): the same helper gets one longer try
            suspect = lock(() -> Pluto.SUSPECT_ROOTS[key], Pluto.FILE_HELPERS_LOCK)
            @test lock(() -> isempty(Pluto.HUNG_ROOTS), Pluto.FILE_HELPERS_LOCK)
            @test get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))").status == 504
            stuck, _, probe_path = lock(() -> Pluto.HUNG_ROOTS[key], Pluto.FILE_HELPERS_LOCK)
            @test stuck === suspect && probe_path == Pluto.tamepath(ws)                   # the same helper, and the very path to ask about
            @test lock(() -> length(Pluto.HUNG_ROOTS) == 1 && isempty(Pluto.SUSPECT_ROOTS), Pluto.FILE_HELPERS_LOCK)
            free = only(h for h in helpers if h !== stuck)
            free.port = real_ports[findfirst(h -> h === free, helpers)]                  # the other helper is fine
            t = time(); again = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))"); took = time() - t
            @test again.status == 504 && took < 3                                        # known to be hung: refused at once
            @test get("$base/api/v1/browse?path=$(HTTP.escapeuri(other))").status == 200 # another filesystem is served meanwhile
            @test get("$base/ping").status == 200
            @test Pluto.hub_isdir(ws) === nothing
            # it comes back when the helper that stuck on it can stat that root again
            stuck.port = real_ports[findfirst(h -> h === stuck, helpers)]
            sleep(1.2)
            @test get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))").status == 200
            @test lock(() -> isempty(Pluto.HUNG_ROOTS), Pluto.FILE_HELPERS_LOCK)

            # a helper that died is replaced: one start at a time, after a pause, however many requests notice
            Pluto.FILE_HELPER_RESPAWN_PAUSE[] = 0.0
            kill(helpers[1].proc); wait(helpers[1].proc)
            statuses = fetch.([@async(get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))").status) for _ in 1:6])
            @test all(==(200), statuses)
            @test timedwait(() -> lock(() -> length(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK) == 2, 240) == :ok
            sleep(1); @test lock(() -> length(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK) == 2   # two, not seven

            # with no helper at all the hub still never reads the files itself
            lifelines = lock(() -> copy(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK)
            Pluto.FILE_HELPER_RESPAWN_PAUSE[] = 1e9
            foreach(h -> kill(h.proc), lifelines); foreach(h -> wait(h.proc), lifelines)
            none = get("$base/api/v1/browse?path=$(HTTP.escapeuri(ws))")
            @test none.status == 504 && occursin("filesystem_busy", String(none.body))
        finally
            Pluto.FILE_HELPER_RESPAWN_PAUSE[] = 10.0
            procs = [h.proc for h in lock(() -> copy(Pluto.FILE_HELPERS), Pluto.FILE_HELPERS_LOCK)]
            close(server)
            @test timedwait(() -> all(process_exited, procs), 30) == :ok               # they go with their hub
            @test !Pluto.file_helpers_active()
        end
    end
    Pluto.FILE_HELPER_COUNT[] = Sys.islinux() ? 2 : 1
    @testset "hung-ness belongs to a filesystem" begin
        mounts = ["/data/homezvol2/dale", "/dfs6b", "/data", "/tmp", "/"]
        @test Pluto.filesystem_key("/data/homezvol2/dale/dev/a", mounts) == "/data/homezvol2/dale"
        @test Pluto.filesystem_key("/data/homezvol2/dale/dev/b", mounts) == "/data/homezvol2/dale"   # a second folder there costs no helper
        @test Pluto.filesystem_key("/dfs6bother/x", mounts) == "/dfs6bother/x"                       # a prefix is not a parent
        @test Pluto.filesystem_key("/home/me/x", mounts) == "/home/me/x"                             # "/" says nothing
        @test Pluto._unescape_mountinfo("/mnt/with\\040space") == "/mnt/with space"
        request = HTTP.Request("GET", "/api/v1/ssh_hosts")
        @test Pluto._request_path(request) == Pluto.tamepath(homedir())                               # no path named: the home directory, never ""
        withenv("SPACESTATION_USER_HOME" => "/real/home") do
            @test Pluto._request_path(request) == "/real/home"                                         # the USER's, when this hub runs from a staged runtime
        end
        request = HTTP.Request("GET", "/api/v1/workspace/listing?path=%2Fa%2Fb"); request.context[:workspace_root] = "/a"
        @test Pluto._request_path(request) == Pluto.tamepath("/a/b")                                  # the most specific path wins
    end
    withenv("SPACESTATION_FILE_HELPER" => "0") do
        Pluto.start_file_helpers!()
        @test !Pluto.file_helpers_active()                                              # the switch
    end
end
