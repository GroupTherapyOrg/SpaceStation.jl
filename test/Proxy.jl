using Test
import SpaceStation as Pluto
import HTTP
import Sockets

# The workspace hub never runs a notebook: a workspace is served at /w/<id>/ and its notebook
# traffic is relayed to a child server (src/webserver/Proxy.jl). Two real servers in this process:
# a hub (no workspace, `hub=true`) and a child that owns a workspace folder, registered with the hub
# the way `open_local_session!` would register it.

function wait_for_server(port; timeout=30)
    deadline = time() + timeout
    while time() < deadline
        try
            HTTP.get("http://127.0.0.1:$port/ping"; retry=false, connect_timeout=2, readtimeout=5).status == 200 && return true
        catch
        end
        sleep(0.3)
    end
    false
end

@testset "Workspace hub proxy" begin
    state = mktempdir()
    ws = mktempdir()
    write(joinpath(ws, "notes.txt"), "hello")
    withenv("XDG_STATE_HOME" => state) do
        child_session = Pluto.ServerSession(; options=Pluto.Configuration.from_flat_kwargs(;
            workspace_use_distributed=false, launch_browser=false, workspace=ws, port_hint=2450, on_code_change="autorun"))
        child = Pluto.run!(child_session)
        child_port = child_session.options.server.port
        child_secret = child_session.secret
        @test wait_for_server(child_port)

        hub_session = Pluto.ServerSession(; options=Pluto.Configuration.from_flat_kwargs(;
            workspace_use_distributed=false, launch_browser=false, hub=true, port_hint=2460))
        hub = Pluto.run!(hub_session)
        hub_port = hub_session.options.server.port
        hub_secret = hub_session.secret
        @test wait_for_server(hub_port)

        wid = Pluto.workspace_id(ws)
        lock(Pluto.LOCAL_SESSIONS_LOCK) do
            Pluto.LOCAL_SESSIONS[Pluto.tamepath(ws)] = Pluto.LocalSession(Pluto.tamepath(ws), "ready", "", child_port, child_secret, nothing, nothing, false)
        end
        base = "http://127.0.0.1:$hub_port/w/$wid"
        # cookies=false: HTTP.jl's client keeps a cookie jar by default, and the hub's Set-Cookie would
        # then authenticate every later request — the "no secret" checks below must really send none
        hget(url; kw...) = HTTP.get(url; retry=false, redirect=false, status_exception=false, cookies=false, connect_timeout=5, readtimeout=30, kw...)
        hpost(url; kw...) = HTTP.post(url; retry=false, redirect=false, status_exception=false, cookies=false, connect_timeout=5, readtimeout=30, kw...)
        cookies(r) = [h.second for h in r.headers if lowercase(h.first) == "set-cookie"]
        body(r) = String(copy(r.body)) # String(::Vector{UInt8}) takes the buffer; read it more than once

        try
            @testset "the hub answers its own routes under the prefix" begin
                @test hget("$base/ping").status == 200
                r = hget("$base/api/v1/workspace?secret=$hub_secret")
                @test r.status == 200
                @test occursin(Pluto._json_string(Pluto.tamepath(ws)), body(r)) # the request's workspace, not the hub's (which has none); JSON-escaped (Windows paths have backslashes)
                @test occursin("notes.txt", body(r))
                r = hget("$base/api/v1/config?secret=$hub_secret")
                @test occursin("\"hub\": true", body(r)) || occursin("\"hub\":true", body(r))
                @test occursin(wid, body(r))
                r = hget("$base/edit?id=whatever&secret=$hub_secret")
                @test r.status == 200                                   # the editor page is served by the hub itself
                @test occursin("<html", lowercase(body(r)))
            end

            @testset "/w/<id> without a slash redirects, keeping the query" begin
                r = hget("$base?secret=$hub_secret")
                @test r.status == 302
                @test HTTP.header(r, "Location") == "/w/$wid/?secret=$hub_secret"
            end

            @testset "notebook routes are relayed to the child, with the hub's secret only" begin
                r = hget("$base/api/v1/notebooks?secret=$hub_secret")
                @test r.status == 200
                @test strip(body(r)) == "[]"
                @test !any(c -> occursin(child_secret, c), cookies(r))  # the child's cookie never reaches the browser
                @test any(c -> occursin(hub_secret, c), cookies(r))     # the hub's does
                @test !occursin(child_secret, body(r))

                @test hget("$base/api/v1/notebooks").status == 403                       # no secret
                @test hget("$base/api/v1/notebooks?secret=$child_secret").status == 403  # the CHILD's secret does not open the hub
                @test hget("http://127.0.0.1:$hub_port/w/0123456789abcdef/ping").status == 200  # /ping needs no workspace
                @test hget("http://127.0.0.1:$hub_port/w/0123456789abcdef/api/v1/notebooks?secret=$hub_secret").status == 404  # unknown workspace
            end

            @testset "the child's redirect is passed through, not followed" begin
                # GET /new answers with a redirect to the editor; the hub must hand that to the browser
                # (which resolves the relative Location under /w/<id>/), not follow it into the child
                r = hget("$base/new?secret=$hub_secret")
                @test r.status == 302
                loc = HTTP.header(r, "Location")
                @test startswith(loc, "./edit?id=")
                @test !any(c -> occursin(child_secret, c), cookies(r))
                # POST /new (what the launcher uses) answers with the id itself
                r = hpost("$base/new?secret=$hub_secret")
                @test r.status == 200
                @test length(strip(body(r))) == 36
                r = hget("$base/api/v1/notebooks?secret=$hub_secret")
                @test occursin("notebook_id", body(r))                  # they opened in the child
                @test length(child_session.notebooks) == 2
                @test isempty(hub_session.notebooks)                    # and never in the hub
            end

            @testset "the hub's CSRF gate applies before relaying" begin
                r = hpost("$base/new?secret=$hub_secret"; headers=["Origin" => "http://evil.example"])
                @test r.status == 403
                @test length(child_session.notebooks) == 2               # nothing was relayed
            end

            @testset "the websocket is relayed frame for frame" begin
                got = Ref{Any}(nothing)
                HTTP.WebSockets.open("ws://127.0.0.1:$hub_port/w/$wid/?secret=$hub_secret"; suppress_close_error=true) do sock
                    HTTP.WebSockets.send(sock, Pluto.pack(Dict("type" => "connect", "client_id" => "proxytest", "request_id" => "r1", "body" => Dict())))
                    got[] = Pluto.unpack(HTTP.WebSockets.receive(sock))
                end
                @test got[] isa Dict
                @test string(get(got[], "type", "")) == "👋"
                @test length(child_session.connected_clients) <= 1
                @test isempty(hub_session.connected_clients)            # the hub relayed; it did not become a Pluto client
            end

            @testset "bodies and paths round-trip; a closed relay frees the child's client" begin
                spaced = joinpath(ws, "with space")
                mkdir(spaced)
                nb_path = joinpath(spaced, "café.jl")
                write(nb_path, "### A Pluto.jl notebook ###\n# v0.20.0\n\n# ╔═╡ a1000000-0000-4000-8000-000000000001\nx = 1\n\n# ╔═╡ Cell order:\n# ╠═a1000000-0000-4000-8000-000000000001\n")
                r = hget("$base/open?path=$(HTTP.escapeuri(nb_path))&secret=$hub_secret")
                @test r.status == 302
                @test startswith(HTTP.header(r, "Location"), "./edit?id=")
                @test any(nb -> nb.path == nb_path, values(child_session.notebooks))   # the spaced, non-ASCII path survived the hop
                HTTP.WebSockets.open("ws://127.0.0.1:$hub_port/w/$wid/?secret=$hub_secret"; suppress_close_error=true) do sock
                    HTTP.WebSockets.send(sock, Pluto.pack(Dict("type" => "connect", "client_id" => "closeme", "request_id" => "r2", "body" => Dict())))
                    HTTP.WebSockets.receive(sock)
                end
                @test timedwait(() -> !haskey(child_session.connected_clients, :closeme), 5.0) == :ok
            end

            @testset "the hub adopts a live child from the registry and refuses a mismatched version" begin
                lock(() -> empty!(Pluto.LOCAL_SESSIONS), Pluto.LOCAL_SESSIONS_LOCK)
                lock(() -> empty!(Pluto._adopt_misses), Pluto._adopt_misses_lock)
                # the child wrote its own connection file at startup (this version, this workspace)
                r = hget("$base/api/v1/notebooks?secret=$hub_secret")
                @test r.status == 200
                adopted = lock(() -> get(Pluto.LOCAL_SESSIONS, Pluto.tamepath(ws), nothing), Pluto.LOCAL_SESSIONS_LOCK)
                @test adopted !== nothing && adopted.proc === nothing && adopted.port == child_port

                # an older child is not adopted: the hub-served editor and its protocol would disagree
                regfile = Pluto.collab_registry_path(child_port)
                original = read(regfile, String)
                write(regfile, replace(original, "\"spacestation_version\": \"$(Pluto.PLUTO_VERSION_STR)\"" => "\"spacestation_version\": \"v0.0.1\""))
                lock(() -> empty!(Pluto.LOCAL_SESSIONS), Pluto.LOCAL_SESSIONS_LOCK)
                lock(() -> empty!(Pluto._adopt_misses), Pluto._adopt_misses_lock)
                @test hget("$base/api/v1/notebooks?secret=$hub_secret").status == 404
                write(regfile, original)
                lock(() -> empty!(Pluto._adopt_misses), Pluto._adopt_misses_lock)
                @test hget("$base/api/v1/notebooks?secret=$hub_secret").status == 200

                # an id nobody has is answered from the miss cache, not a registry walk per request
                hget("http://127.0.0.1:$hub_port/w/ffffffffffffffff/api/v1/notebooks?secret=$hub_secret")
                t = @elapsed r = hget("http://127.0.0.1:$hub_port/w/ffffffffffffffff/api/v1/notebooks?secret=$hub_secret")
                @test r.status == 404
                @test t < 0.5
            end

            @testset "a stalled child: polls time out, the cap holds, the hub stays responsive" begin
                # a stand-in child that answers /ping but never answers the notebook list in time
                stub_port = 2480 + rand(0:15)
                stub = HTTP.serve!("127.0.0.1", stub_port) do req
                    if HTTP.URI(req.target).path == "/api/v1/notebooks"
                        sleep(6)
                    end
                    HTTP.Response(200, "[]")
                end
                stalled_ws = mktempdir()
                stalled_wid = Pluto.workspace_id(stalled_ws)
                lock(() -> (Pluto.LOCAL_SESSIONS[Pluto.tamepath(stalled_ws)] = Pluto.LocalSession(Pluto.tamepath(stalled_ws), "ready", "", stub_port, "stubsecret", nothing, nothing, false)), Pluto.LOCAL_SESSIONS_LOCK)
                old_timeout = Pluto.PROXY_READ_TIMEOUT[]
                Pluto.PROXY_READ_TIMEOUT[] = 1
                try
                    sbase = "http://127.0.0.1:$hub_port/w/$stalled_wid"
                    n = Pluto.PROXY_PARKED_MAX + 6
                    statuses = Channel{Int}(n)
                    wide = HTTP.Pool(n + 10) # the test client's own pool must not be the throttle
                    @sync for _ in 1:n
                        @async put!(statuses, hget("$sbase/api/v1/notebooks?secret=$hub_secret"; readtimeout=20, pool=wide).status)
                    end
                    close(statuses)
                    got = collect(statuses)
                    @test count(==(503), got) >= 1                       # past the cap: refused at once
                    @test count(==(504), got) >= Pluto.PROXY_PARKED_MAX - 5 # the rest: the poll deadline
                    @test all(x -> x ∈ (503, 504), got)
                    # …and none of that touched the hub's own thread
                    t = @elapsed r = hget("$sbase/ping")
                    @test r.status == 200 && t < 0.5
                    t = @elapsed r = hget("$base/api/v1/workspace?secret=$hub_secret")
                    @test r.status == 200 && t < 2
                finally
                    Pluto.PROXY_READ_TIMEOUT[] = old_timeout
                    close(stub)
                    lock(() -> delete!(Pluto.LOCAL_SESSIONS, Pluto.tamepath(stalled_ws)), Pluto.LOCAL_SESSIONS_LOCK)
                end
            end

            @testset "a dead child is a 503 at once, and the hub keeps answering" begin
                for nb in collect(values(child_session.notebooks))
                    Pluto.SessionActions.shutdown(child_session, nb; keep_in_session=false)
                end
                # Both servers live in this one process, so the child's shutdown hook would reap "its"
                # local sessions — the entry pointing at the child itself, through the process-wide
                # running-server slot, which is the hub's. Take the entry out for the close, put it
                # back (now pointing at a dead port) for the check. In real use these are two processes.
                entry = lock(() -> pop!(Pluto.LOCAL_SESSIONS, Pluto.tamepath(ws)), Pluto.LOCAL_SESSIONS_LOCK)
                close(child)
                sleep(0.5)
                lock(() -> (Pluto.LOCAL_SESSIONS[Pluto.tamepath(ws)] = entry), Pluto.LOCAL_SESSIONS_LOCK)
                t = @elapsed r = hget("$base/api/v1/notebooks?secret=$hub_secret")
                @test r.status == 503
                @test occursin("workspace_down", body(r))
                @test t < 10
                @test hget("$base/ping").status == 200
                @test hget("$base/api/v1/workspace?secret=$hub_secret").status == 200
            end
        finally
            try close(child) catch end
            close(hub)
            lock(Pluto.LOCAL_SESSIONS_LOCK) do
                delete!(Pluto.LOCAL_SESSIONS, Pluto.tamepath(ws))
            end
        end
    end
end
