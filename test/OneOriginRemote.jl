using Test
import SpaceStation as Pluto
import HTTP
import Sockets

# One address for local and remote workspaces (src/webserver/RemoteHosts.jl).
#
# The "remote machine" is a second, ordinary hub in its OWN process, with its own state directory,
# that this test knows nothing about except where its connection file is: what an SSH connect would
# learn from a node. The local hub H runs in this process. Everything is asserted through H.
#
# Run alone: cd("test"); include("helpers.jl"); include("OneOriginRemote.jl")

function oor_free_port()
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    close(server)
    port
end

"Stop whatever a hub's state directory still names: the hub, and the workspace servers it started."
function oor_reap(servers_dir)
    isdir(servers_dir) || return
    for name in readdir(servers_dir)
        m = match(r"\"pid\": (\d+)", try read(joinpath(servers_dir, name), String) catch; "" end)
        m === nothing && continue
        pid = parse(Int, m.captures[1])
        pid == getpid() && continue
        try
            Pluto._pid_alive(pid) && run(`kill $pid`; wait=false)
        catch
        end
    end
end

function oor_wait_for(f; timeout=120, every=0.5)
    deadline = time() + timeout
    while time() < deadline
        r = f()
        r === nothing || r === false || return r
        sleep(every)
    end
    nothing
end

const OOR_NOTEBOOK = """
### A Pluto.jl notebook ###
# v0.20.0

using Markdown
using InteractiveUtils

# ╔═╡ a1000000-0000-4000-8000-000000000001
answer = 123456 + 654321

# ╔═╡ Cell order:
# ╠═a1000000-0000-4000-8000-000000000001
"""

@testset "One origin: a remote workspace through the local hub" begin
    remote_state = mktempdir()
    local_state = mktempdir()
    remote_ws = joinpath(mktempdir(), "on-the-node")
    mkpath(joinpath(remote_ws, "data"))
    write(joinpath(remote_ws, "notes.txt"), "written on the node")
    write(joinpath(remote_ws, "nb.jl"), OOR_NOTEBOOK)
    local_ws = mktempdir()
    write(joinpath(local_ws, "here.txt"), "written on the laptop")

    # --- the remote hub: another process, another state directory ---------------------------------
    remote_port = oor_free_port()
    remote_log = joinpath(remote_state, "hub.log")
    remote_env = copy(ENV)
    remote_env["XDG_STATE_HOME"] = remote_state
    remote_env["SPACESTATION_HUB"] = "1"
    remote_env["SPACESTATION_FILE_HELPER"] = "0"
    remote_env["OOR_PORT"] = string(remote_port)
    for k in ("SPACESTATION_STATE_HOME", "SPACESTATION_DEV_REMOTE_HOSTS", "JULIA_LOAD_PATH")
        delete!(remote_env, k)
    end
    remote_code = "import SpaceStation; SpaceStation.run(hub=true, launch_browser=false, port=parse(Int, ENV[\"OOR_PORT\"]))"
    remote_proc = run(pipeline(setenv(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $(remote_code)`, remote_env); stdin=devnull, stdout=remote_log, stderr=remote_log); wait=false)
    remote_servers = joinpath(remote_state, "pluto", "servers")

    withenv("XDG_STATE_HOME" => local_state, "SPACESTATION_STATE_HOME" => nothing, "SPACESTATION_FILE_HELPER" => "0",
            "SPACESTATION_DEV_REMOTE_HOSTS" => "fake-node=$(remote_servers)") do
        # a local workspace beside the remote one, as test/Proxy.jl makes it: a child in this process
        child_session = Pluto.ServerSession(; options=Pluto.Configuration.from_flat_kwargs(;
            workspace_use_distributed=false, launch_browser=false, workspace=local_ws, port_hint=oor_free_port(), on_code_change="autorun"))
        child = Pluto.run!(child_session)
        hub_session = Pluto.ServerSession(; options=Pluto.Configuration.from_flat_kwargs(;
            workspace_use_distributed=false, launch_browser=false, hub=true, port_hint=oor_free_port()))
        hub = Pluto.run!(hub_session)   # reads the seam: fake-node is in the table, whether or not it is up yet
        H = hub_session.options.server.port
        hub_secret = hub_session.secret
        local_wid = Pluto.workspace_id(local_ws)
        lock(Pluto.LOCAL_SESSIONS_LOCK) do
            Pluto.LOCAL_SESSIONS[Pluto.tamepath(local_ws)] = Pluto.LocalSession(Pluto.tamepath(local_ws), "ready", "", child_session.options.server.port, child_session.secret, nothing, nothing, false)
        end

        # every answer H gives is kept: none may contain the remote's secret
        seen = Any[]
        keep(r) = (push!(seen, r); r)
        hub_url(path) = "http://127.0.0.1:$H$path"
        signed(path) = hub_url(path) * (occursin('?', path) ? "&" : "?") * "secret=$hub_secret"
        hget(url; kw...) = keep(HTTP.get(url; retry=false, redirect=false, status_exception=false, cookies=false, connect_timeout=5, readtimeout=60, kw...))
        hpost(url; body=UInt8[], kw...) = keep(HTTP.post(url, [], body; retry=false, redirect=false, status_exception=false, cookies=false, connect_timeout=5, readtimeout=60, kw...))
        body(r) = String(copy(r.body))
        field(text, name) = (m = match(Regex("\"$name\":\\s*\"([^\"]*)\""), text); m === nothing ? nothing : String(m.captures[1]))

        try
            @test Pluto.remote_host("fake-node") !== nothing
            connection = oor_wait_for(() -> Pluto._read_hub_connection(remote_servers); timeout=180)
            @test connection !== nothing
            connection === nothing && error("the remote hub did not start; its log:\n" * read(remote_log, String))
            remote_secret = connection.secret
            @test connection.port == remote_port

            @testset "the launcher sees the host, browses it, and opens a folder there" begin
                r = hget(signed("/api/v1/hosts"))
                @test r.status == 200
                @test occursin("\"host\":\"fake-node\"", body(r)) && occursin("\"state\":\"connected\"", body(r))
                @test hget(hub_url("/api/v1/hosts")).status == 403                       # H's own sign-in, as for every API

                r = hget(signed("/api/v1/browse?host=fake-node&path=$(HTTP.escapeuri(remote_ws))"))
                @test r.status == 200
                @test occursin("\"name\":\"data\"", body(r))                             # the node's folders, not the laptop's
                @test hget(signed("/api/v1/browse?host=nobody")).status == 404           # only a host in the table
                @test hget(signed("/api/v1/browse?host=..%2F..")).status == 404

                r = hpost(signed("/api/v1/local/open?host=fake-node&path=$(HTTP.escapeuri(remote_ws))"))
                @test r.status == 200
                status = oor_wait_for(; timeout=240, every=1) do
                    s = body(hget(signed("/api/v1/local/status?host=fake-node&path=$(HTTP.escapeuri(remote_ws))")))
                    field(s, "state") ∈ ("ready", "error") ? s : nothing
                end
                @test status !== nothing && field(status, "state") == "ready"
                global oor_wid = field(status, "wid")
                @test oor_wid == Pluto.workspace_id(remote_ws)
                @test field(status, "url") == "/h/fake-node/w/$(oor_wid)/"               # where H shows it, not the remote's own /w/
                # opening it again is the same workspace at the same address
                again = body(hpost(signed("/api/v1/local/open?host=fake-node&path=$(HTTP.escapeuri(remote_ws))")))
                @test field(again, "url") == "/h/fake-node/w/$(oor_wid)/" && field(again, "state") == "ready"
                listed = body(hget(signed("/api/v1/local/list?host=fake-node")))
                @test occursin("\"url\":\"/h/fake-node/w/$(oor_wid)/\"", listed)
                # H's own list is only H's
                mine = body(hget(signed("/api/v1/local/list")))
                @test occursin(local_wid, mine) && !occursin(oor_wid, mine)
            end
            wid = oor_wid
            base = "/h/fake-node/w/$wid"

            @testset "the page is the local hub's own" begin
                r = hget(signed(base))
                @test r.status == 302 && startswith(HTTP.header(r, "Location"), "$base/?")
                page = hget(signed("$base/"))
                @test page.status == 200
                @test body(page) == body(hget(signed("/")))                              # H's land.html, byte for byte
                @test body(hget(hub_url("$base/land.js"))) == body(hget(hub_url("/land.js")))
                @test hget(hub_url("$base/api/v1/workspace")).status == 403              # no sign-in, no relay
                config = body(hget(signed("$base/api/v1/config")))
                @test field(config, "host") == "fake-node" && field(config, "wid") == wid
                global oor_content = field(config, "content_base")
                @test occursin(Regex("^http://fake-node\\.localhost:$H/[0-9a-f]{48}/\$"), oor_content)
                @test field(body(hget(signed("$base/api/v1/config"))), "content_base") == oor_content   # one per workspace, stable
                @test hget(signed("/h/fake-node/w/$("f"^16)/api/v1/workspace")).status == 404            # relayed: the remote does not know it
                @test hget(signed("/h/nobody/w/$wid/api/v1/workspace")).status == 404                    # a lookup, nothing is connected
            end

            @testset "files of the remote workspace: list, read, write, new, rename, delete" begin
                r = hget(signed("$base/api/v1/workspace"))
                @test r.status == 200
                @test occursin(Pluto._json_string(Pluto.tamepath(remote_ws)), body(r)) && occursin("notes.txt", body(r)) && !occursin("here.txt", body(r))
                @test HTTP.header(r, "Content-Security-Policy") == "sandbox"            # relayed data is never a page on H's origin
                @test occursin("\"entries\"", body(hget(signed("$base/api/v1/workspace/listing?path=$(HTTP.escapeuri(joinpath(remote_ws, "data")))"))))
                notes = joinpath(remote_ws, "notes.txt")
                @test body(hget(signed("$base/api/v1/file?path=$(HTTP.escapeuri(notes))"))) == "written on the node"
                @test hpost(signed("$base/api/v1/file/save?path=$(HTTP.escapeuri(notes))"); body="saved through the hub").status == 200
                @test read(notes, String) == "saved through the hub"
                made = joinpath(remote_ws, "data", "made.txt")
                @test hpost(signed("$base/api/v1/file/new?path=$(HTTP.escapeuri(made))")).status == 200
                @test isfile(made)
                moved = joinpath(remote_ws, "data", "moved.txt")
                @test hpost(signed("$base/api/v1/file/rename?path=$(HTTP.escapeuri(made))&newpath=$(HTTP.escapeuri(moved))")).status == 200
                @test isfile(moved) && !isfile(made)
                @test hpost(signed("$base/api/v1/file/delete?path=$(HTTP.escapeuri(moved))")).status == 200
                @test !isfile(moved)
                # H's CSRF gate applies before anything is relayed
                @test hpost(signed("$base/api/v1/file/save?path=$(HTTP.escapeuri(notes))"); body="x", headers=["Origin" => "http://fake-node.localhost:$H"]).status == 403
                @test read(notes, String) == "saved through the hub"
            end

            content_host = "fake-node.localhost:$H"
            cap = String(match(r"/([0-9a-f]{48})/$", oor_content).captures[1])
            cget(path; host=content_host, kw...) = hget(hub_url(path); headers=["Host" => host], kw...)
            cpost(path; host=content_host, kw...) = hpost(hub_url(path); headers=["Host" => host], kw...)

            @testset "a notebook: opened through the hub, served and run on the content origin" begin
                r = hpost(signed("$base/open?path=$(HTTP.escapeuri(joinpath(remote_ws, "nb.jl")))&execution_allowed=true"))
                @test r.status == 200
                nb_id = strip(body(r))
                @test length(nb_id) == 36
                @test occursin(nb_id, body(hget(signed("$base/api/v1/notebooks"))))
                @test hget(signed("$base/edit?id=$nb_id")).status == 409                 # never on H's origin
                editor = cget("/$cap/edit?id=$nb_id")
                @test editor.status == 200 && occursin("editor.js", body(editor))        # the remote's editor page
                @test isempty([h for h in editor.headers if lowercase(h.first) == "set-cookie"])   # no cookie on a content origin
                @test cget("/$cap/editor.js").status == 200
                @test occursin("close-notebook-tab", body(cget("/$cap/")))               # "back to the menu" closes the tab: no second launcher

                frames = Any[]
                cell = "a1000000-0000-4000-8000-000000000001"
                HTTP.WebSockets.open("ws://127.0.0.1:$H/$cap/?id=$nb_id"; headers=["Host" => content_host, "Origin" => "http://$content_host"], suppress_close_error=true, pool=HTTP.Pool(4)) do sock
                    send(type, payload) = HTTP.WebSockets.send(sock, Pluto.pack(Dict("type" => type, "client_id" => "oor", "request_id" => type, "notebook_id" => nb_id, "body" => payload)))
                    send("connect", Dict())
                    hello = Pluto.unpack(HTTP.WebSockets.receive(sock))
                    push!(frames, hello)
                    send("run_multiple_cells", Dict("cells" => [cell]))
                    reader = @async try
                        for msg in sock
                            push!(frames, Pluto.unpack(msg))
                        end
                    catch
                    end
                    # the answer arrives as live pushes on this socket, and is 42
                    oor_wait_for(() -> any(f -> occursin("777777", repr(f)), frames); timeout=180, every=0.2)
                end
                @test string(get(frames[1], "type", "")) == "👋"
                @test get(get(frames[1], "message", Dict()), "notebook_exists", false) == true
                @test any(f -> string(get(f, "type", "")) == "notebook_diff", frames)     # pushed while the cell ran
                @test any(f -> occursin("777777", repr(f)), frames)                       # the output itself came over the relay
            end

            # (typed in sh: on Windows the shell is PowerShell, and this is about the relay, which the other tests cover there)
            Sys.isunix() && @testset "the terminal is a shell in the remote hub's process, with scrollback" begin
                term = "ws://127.0.0.1:$H$base/terminal?tid=oor-term&cwd=$(HTTP.escapeuri(remote_ws))&rows=24&cols=120&secret=$hub_secret"
                function attach(send_text; until, timeout=30)
                    out = IOBuffer()
                    texts = String[]
                    HTTP.WebSockets.open(term; suppress_close_error=true, pool=HTTP.Pool(4)) do sock
                        reader = @async try
                            for msg in sock
                                msg isa String ? push!(texts, msg) : write(out, msg)
                            end
                        catch
                        end
                        oor_wait_for(() -> any(t -> occursin("replayed", t), texts); timeout=20, every=0.1)
                        send_text === nothing || HTTP.WebSockets.send(sock, "0:" * send_text)
                        oor_wait_for(() -> occursin(until, String(copy(out.data[1:out.size]))); timeout, every=0.1)
                    end
                    (String(take!(out)), texts)
                end
                out, texts = attach("echo relayed-\$((6*7)) in \$(pwd) under \$PPID\n"; until="relayed-42")
                @test any(t -> occursin("\"rows\"", t), texts)                             # the attach protocol survived two relays
                @test occursin("relayed-42", out)
                @test occursin(basename(remote_ws), out)                                   # it started in the remote folder
                @test occursin("under $(getpid(remote_proc))", out)                        # and its parent is the REMOTE hub, not this process
                replay, _ = attach(nothing; until="relayed-42")
                @test occursin("relayed-42", replay)                                         # a reload gets the scrollback back
                @test occursin("\"running\"", body(hget(signed("$base/api/v1/terminal/running?tid=oor-term"))))
                @test hpost(signed("$base/api/v1/terminal/close?tid=oor-term")).status == 200
            end

            @testset "a content origin reaches the notebook and nothing else" begin
                # this hub's API is not on a content origin, whatever the request carries
                @test cget("/api/v1/local/list?secret=$hub_secret").status == 403
                @test cget("/api/v1/local/list"; cookies=Dict("pluto_secret_$H" => hub_secret)).status == 403
                @test cget("/?secret=$hub_secret").status == 403
                @test cget("/w/$local_wid/api/v1/workspace?secret=$hub_secret").status == 403
                @test cget("$base/api/v1/workspace?secret=$hub_secret").status == 403
                @test cget("/land.js").status == 403                                       # not even an asset without the capability
                @test cpost("/api/v1/local/open?path=$(HTTP.escapeuri(local_ws))&secret=$hub_secret").status == 403
                # the capability is the only way in, on the host it was minted for
                @test cget("/edit?id=x").status == 403
                @test cget("/$("0"^48)/edit?id=x").status == 403
                @test cget("/$cap/edit?id=x"; host="other-node.localhost:$H").status == 403
                @test cget("/$(cap)0/edit?id=x").status == 403
                # with it: the notebook's routes, not the remote hub's files, launcher or terminal
                @test cget("/$cap/api/v1/notebooks").status == 200
                @test cget("/$cap/api/v1/workspace").status == 403
                @test cget("/$cap/api/v1/file?path=$(HTTP.escapeuri(joinpath(remote_ws, "notes.txt")))").status == 403
                @test cpost("/$cap/api/v1/file/save?path=$(HTTP.escapeuri(joinpath(remote_ws, "pwned.txt")))"; body="x").status == 403
                @test !isfile(joinpath(remote_ws, "pwned.txt"))
                @test cget("/$cap/api/v1/local/list").status == 403
                @test cget("/$cap/api/v1/browse").status == 403
                @test cpost("/$cap/api/v1/shutdown").status == 403
                @test_throws Exception HTTP.WebSockets.open(identity, "ws://127.0.0.1:$H/$cap/terminal?tid=evil"; headers=["Host" => content_host], suppress_close_error=true, pool=HTTP.Pool(4))
                # and script on a content origin cannot open this hub's terminal or notebook socket: Origin is not Host
                for target in ("/terminal?tid=evil&secret=$hub_secret", "$base/terminal?tid=evil&secret=$hub_secret", "/w/$local_wid/terminal?tid=evil&secret=$hub_secret")
                    @test_throws Exception HTTP.WebSockets.open(identity, "ws://127.0.0.1:$H$target"; headers=["Origin" => "http://$content_host"], suppress_close_error=true, pool=HTTP.Pool(4))
                end
                @test isempty(lock(() -> filter(tid -> occursin("evil", tid), collect(keys(Pluto.COLLAB_TERMINALS))), Pluto.COLLAB_TERMINALS_LOCK))
            end

            @testset "what the remote is sent: its own secret in a header, and nothing of this hub's" begin
                got = Channel{HTTP.Request}(8)
                stub_port = oor_free_port()
                stub = HTTP.serve!("127.0.0.1", stub_port) do req
                    HTTP.URI(req.target).path == "/ping" || put!(got, req)
                    HTTP.Response(200, ["Set-Cookie" => "pluto_secret_$(stub_port)=stub-secret; Path=/", "Content-Type" => "text/html"], "<script>parent.x=1</script>")
                end
                try
                    Pluto.register_remote_host!("stub.node"; port=stub_port, secret="stub-secret")
                    r = hget(signed("/h/stub.node/w/$("a"^16)/api/v1/workspace?depth=1"); headers=["Referer" => "http://localhost:$H/?secret=$hub_secret", "Cookie" => "pluto_secret_$H=$hub_secret", "Authorization" => "Bearer $hub_secret"])
                    @test r.status == 200
                    req = take!(got)
                    @test req.target == "/w/$("a"^16)/api/v1/workspace?depth=1"            # the hub's secret is not in the URL the remote sees
                    sent = join(["$(h.first): $(h.second)" for h in req.headers], "\n")
                    @test !occursin(hub_secret, sent) && !occursin(hub_secret, req.target)
                    @test HTTP.header(req, "Authorization") == "Bearer stub-secret"
                    @test isempty(HTTP.header(req, "Referer")) && isempty(HTTP.header(req, "Origin"))
                    # and what comes back: not the remote's cookie, and not a page that could run here
                    @test !occursin("stub-secret", join([h.second for h in r.headers], "\n"))
                    @test HTTP.header(r, "Content-Security-Policy") == "sandbox" && HTTP.header(r, "X-Content-Type-Options") == "nosniff"
                    @test Pluto.host_label("stub.node") != "stub.node" && occursin(r"^[a-z0-9-]+$", Pluto.host_label("stub.node"))
                    @test Pluto.host_label("a.b") != Pluto.host_label("a-b")               # two names never share an origin
                finally
                    Pluto.unregister_remote_host!("stub.node")
                    close(stub)
                end
            end

            @testset "a local workspace works beside it, as before" begin
                r = hget(signed("/w/$local_wid/api/v1/workspace"))
                @test r.status == 200 && occursin("here.txt", body(r)) && !occursin("notes.txt", body(r))
                @test hget(signed("/w/$local_wid/edit?id=whatever")).status == 200        # a local workspace's editor is still the hub's
                @test isempty(HTTP.header(r, "Content-Security-Policy"))
                config = body(hget(signed("/w/$local_wid/api/v1/config")))
                @test occursin("\"host\":null", config) && occursin("\"content_base\":null", config)
                @test hget(signed("/api/v1/local/list")).status == 200
            end

            @testset "the remote's secret never left the hub" begin
                @test length(seen) > 60
                for r in seen
                    @test !occursin(remote_secret, body(r))
                    @test !any(h -> occursin(remote_secret, h.second), r.headers)
                end
            end

            @testset "the remote goes away: an answer at once, and the rest keeps working" begin
                HTTP.post("http://127.0.0.1:$(remote_port)/api/v1/shutdown", ["Authorization" => "Bearer $remote_secret"]; retry=false, status_exception=false, cookies=false, readtimeout=10)
                @test oor_wait_for(() -> process_exited(remote_proc); timeout=40) == true
                t = @elapsed r = hget(signed("$base/api/v1/workspace"))
                @test r.status == 503 && occursin("host_down", body(r)) && t < 8
                @test occursin("\"state\":\"unreachable\"", body(hget(signed("/api/v1/hosts"))))
                @test hget(signed("$base/")).status == 200                                 # the page is the hub's: it still loads
                @test hget(signed("/w/$local_wid/api/v1/workspace")).status == 200
            end
        finally
            oor_reap(remote_servers)
            process_exited(remote_proc) || kill(remote_proc)
            lock(() -> delete!(Pluto.LOCAL_SESSIONS, Pluto.tamepath(local_ws)), Pluto.LOCAL_SESSIONS_LOCK)
            Pluto.unregister_remote_host!("fake-node")
            try close(child) catch end
            try close(hub) catch end
            timedwait(() -> process_exited(remote_proc), 15.0)
            process_exited(remote_proc) || kill(remote_proc, Base.SIGKILL)
        end
    end
end
