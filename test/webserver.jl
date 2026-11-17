using HTTP
using Test
using SpaceStation; import SpaceStation as Pluto
import SpaceStation: ServerSession, ClientSession, SessionActions, WorkspaceManager
using SpaceStation.Configuration
using SpaceStation.Configuration: notebook_path_suggestion, from_flat_kwargs, _convert_to_flags
using SpaceStation.WorkspaceManager: WorkspaceManager, poll

@testset "Web server" begin

# An SSH tunnel makes the port the browser dialled differ from the port we bound, and every
# SpaceStation binds port_hint 1234 by default — so a local hub and every tunnelled remote node all
# used to claim the cookie name `pluto_secret_1234` on `localhost` and clobber each other. Opening a
# second workspace 403'd the first; refreshing the first 403'd the second.
@testset "auth cookie is scoped by the port the browser used" begin
    req(headers...) = HTTP.Request("GET", "/", collect(headers))

    @test Pluto.browser_visible_port(req("Host" => "localhost:45200"), 1234) == 45200
    @test Pluto.browser_visible_port(req("Host" => "127.0.0.1:1236"), 1234) == 1236
    @test Pluto.browser_visible_port(req("Host" => "[::1]:45201"), 1234) == 45201
    # a colon inside the brackets is part of the address, not a port
    @test Pluto.browser_visible_port(req("Host" => "[::1]"), 1234) == 1234
    # no port, no Host, or an unparseable port: fall back to the port we bound
    @test Pluto.browser_visible_port(req("Host" => "example.com"), 1234) == 1234
    @test Pluto.browser_visible_port(req(), 1234) == 1234
    @test Pluto.browser_visible_port(req("Host" => "localhost:not-a-port"), 1234) == 1234

    # two servers that both bound 1234 (a local hub and a remote reached through `ssh -L 45200:…`)
    # must not share a cookie name, because the browser keeps one jar for all of `localhost`
    session = ServerSession()
    session.options.server.port = 1234
    @test Pluto.secret_cookie_name(session, req("Host" => "localhost:1234")) !=
          Pluto.secret_cookie_name(session, req("Host" => "localhost:45200"))
    @test Pluto.secret_cookie_name(session, req("Host" => "localhost:45200")) == "pluto_secret_45200"
end

# A URL opened in the system browser carries `&secret=…` after its first parameter. On Windows it once
# went through `cmd /c start`, and cmd.exe splits a command line at `&`: the browser got `/edit?id=…`
# alone and showed "Not yet authenticated".
@testset "the default-browser command keeps the whole URL" begin
    url = "http://127.0.0.1:1234/edit?id=abc&secret=S3cr3t&x=1"

    # What Windows actually receives is this one command-line string. The URL must sit inside a single
    # PowerShell-quoted token, so no `&` is ever exposed to a shell.
    line = sprint(Base.escape_microsoft_c_args, Pluto.default_browser_cmd(url; os=:windows).exec...)
    @test startswith(line, "powershell.exe ")
    @test occursin(" '$(url)'", line)
    @test !occursin("cmd", line)
    # a quote in the URL cannot end the string early
    @test occursin("'http://h/?q=it''s'", sprint(Base.escape_microsoft_c_args, Pluto.default_browser_cmd("http://h/?q=it's"; os=:windows).exec...))

    # elsewhere there is no shell in between: the URL is one intact argument
    @test Pluto.default_browser_cmd(url; os=:apple).exec == ["open", url]
    @test Pluto.default_browser_cmd(url; os=:linux).exec == ["xdg-open", url]
    @test Pluto.default_browser_cmd(url; os=:unknown) === nothing
end

@testset "base_url" begin
    port = 13433
    host = "localhost"

    n_components = rand(2:6)
    base_url = "/"
    for _ in 1:n_components
        base_url *= String(rand(collect('a':'z') ∪ collect('0':'9'), rand(5:10))) * "/"
    end
    local_url(suffix) = "http://$host:$port$base_url$suffix"

    @show local_url("favicon.ico")
    server_running() = HTTP.get(local_url("favicon.ico")).status == 200 && HTTP.get(local_url("edit")).status == 200

    # without notebook at startup
    options = Pluto.Configuration.from_flat_kwargs(;
        port,
        launch_browser=false,
        workspace_use_distributed=true,
        require_secret_for_access=false,
        require_secret_for_open_links=false,
        base_url,
    )
    🍭 = Pluto.ServerSession(; options)
    server = Pluto.run!(🍭)

    @test server_running()

    sleep(3)
    @test poll(20) do
        # should not exist because of the base url setting
        HTTP.get("http://$host:$port/edit"; status_exception=false).status == 404
    end

    for notebook in values(🍭.notebooks)
        SessionActions.shutdown(🍭, notebook; keep_in_session=false)
    end

    close(server)
end

@testset "HTTP.jl $(pkgversion(HTTP).major).x" begin
    # Pluto supports both HTTP.jl 1.x and 2.x, see src/webserver/HTTPCompat.jl. The two
    # differ in the parts exercised below: response framing, reading a request body, the
    # WebSocket upgrade, and closing a server that still has a WebSocket connected.
    @test Pluto.HTTP_IS_V2 == (pkgversion(HTTP) ≥ v"2")
    # CI runs this file against several HTTP.jl versions, see .github/workflows/Test.yml
    let pinned = get(ENV, "PLUTO_TEST_HTTP_VERSION", "")
        # `pinned` is a version prefix, like "1" or "2.7.0"
        isempty(pinned) || @test startswith("$(pkgversion(HTTP)).", "$pinned.")
    end

    port = 13434
    local_url(suffix) = "http://localhost:$port/$suffix"
    ws_url(suffix) = "ws://localhost:$port/$suffix"

    options = Pluto.Configuration.from_flat_kwargs(;
        port, launch_browser=false,
        workspace_use_distributed=true,
        require_secret_for_access=false,
        require_secret_for_open_links=false,
    )
    🍭 = Pluto.ServerSession(; options)
    server = Pluto.run!(🍭)

    try
        @testset "responses" begin
            r = HTTP.get(local_url("ping"))
            @test r.status == 200
            @test String(r.body) == "OK!"
            # Pluto sends every response as one non-chunked body, and adds its own headers.
            @test HTTP.header(r, "Content-Length") == "3"
            @test !HTTP.hasheader(r, "Transfer-Encoding")
            @test HTTP.header(r, "Referrer-Policy") == "same-origin"
            @test startswith(HTTP.header(r, "Server"), "Pluto.jl/")

            r = HTTP.get(local_url("edit"))
            @test r.status == 200
            @test HTTP.header(r, "Content-Length") == string(length(r.body))
            @test startswith(HTTP.header(r, "Content-Type"), "text/html")

            r = HTTP.get(local_url("nonexistent-path-🌡"); status_exception=false)
            @test r.status == 404
        end

        @testset "request body" begin
            # `POST /notebookupload` is the only route that reads the request body.
            codes = ["x = 1 + 1", "y = x * 3 # 🐧"]
            contents = sprint(Pluto.save_notebook, Pluto.Notebook(Pluto.Cell.(codes)))
            r = HTTP.post(local_url("notebookupload?name=uploaded"); body=contents)
            @test r.status == 200

            @test poll(20) do
                length(🍭.notebooks) == 1
            end
            notebook = only(values(🍭.notebooks))
            # `numbered_until_new` appends a number if `uploaded.jl` already exists
            @test startswith(basename(notebook.path), "uploaded")
            @test [c.code for c in notebook.cells] == codes
        end

        @testset "handler error" begin
            # The upload cannot be saved in a directory that does not exist, so the route handler throws.
            r = HTTP.post(local_url("notebookupload?name=directory-that-does-not-exist/uploaded"); body="x = 1", status_exception=false)
            @test r.status == 500
            @test startswith(HTTP.header(r, "Content-Type"), "text/html")
            @test HTTP.header(r, "Content-Length") == string(length(r.body))
            @test length(🍭.notebooks) == 1
        end

        @testset "websocket" begin
            notebook = only(values(🍭.notebooks))
            reply = Ref{Any}(nothing)
            # Upstream Pluto accepts any `Origin` here (for reverse proxies that rewrite the scheme and
            # host). SpaceStation does not: an upgrade whose `Origin` does not match its `Host` is
            # refused (`origin_matches_host`), which is checked below. So this is the page's own origin.
            HTTP.WebSockets.open(ws_url(""); headers=["Origin" => "http://localhost:$port"]) do ws
                HTTP.WebSockets.send(ws, Pluto.pack(Dict(
                    "type" => "connect",
                    "client_id" => "test_client",
                    "request_id" => "test_request",
                    "notebook_id" => string(notebook.notebook_id),
                    "body" => Dict(),
                )))
                reply[] = Pluto.unpack(HTTP.WebSockets.receive(ws))
            end

            @test reply[]["type"] == "👋"
            @test reply[]["message"]["notebook_exists"]
            @test reply[]["message"]["version_info"]["pluto"] == Pluto.PLUTO_VERSION_STR
            @test reply[]["initiator_id"] == "test_client"

            # A cross-site `Origin` gets a 403 instead of an upgrade. (Its own connection pool: the
            # server closes this connection, and a later request must not be handed it again.)
            r = HTTP.get(local_url(""); headers=[
                "Connection" => "Upgrade", "Upgrade" => "websocket",
                "Sec-WebSocket-Version" => "13", "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
                "Origin" => "https://proxy.example.com",
            ], status_exception=false, retry=false, pool=HTTP.Pool(1))
            @test r.status == 403
        end
    finally
        close(server)
    end

    # closing the server shuts down the notebooks it was running
    @test isempty(🍭.notebooks)
end

@testset "pretty_address" begin
    make_session(; kwargs...) = Pluto.ServerSession(;
        options=Pluto.Configuration.from_flat_kwargs(;
            launch_browser=false,
            require_secret_for_access=false,
            require_secret_for_open_links=false,
            kwargs...,
        ),
    )
    call(session) = Pluto.pretty_address(session, Sockets.IPv4("127.0.0.1"), 1234)

    clean_env(f) = withenv(f, "JULIAHUB_APP_URL" => nothing, "JH_APP_URL" => nothing)

    clean_env() do
        @test call(make_session()) == "http://localhost:1234/"
    end

    clean_env() do
        session = make_session(; root_url="https://x.example/{PORT}/")
        @test call(session) == "https://x.example/1234/"
    end

    withenv("JULIAHUB_APP_URL" => "https://x.juliahub.com/", "JH_APP_URL" => nothing) do
        @test call(make_session()) == "https://x.juliahub.com/proxy/1234/"
    end

    withenv("JULIAHUB_APP_URL" => nothing, "JH_APP_URL" => "https://legacy.juliahub.com/") do
        @test call(make_session()) == "https://legacy.juliahub.com/proxy/1234/"
    end

    withenv("JULIAHUB_APP_URL" => "https://new.juliahub.com/", "JH_APP_URL" => "https://legacy.juliahub.com/") do
        @test call(make_session()) == "https://new.juliahub.com/proxy/1234/"
    end

    withenv("JULIAHUB_APP_URL" => "https://x.juliahub.com/", "JH_APP_URL" => nothing) do
        session = make_session(; root_url="https://override.example/{PORT}/")
        @test call(session) == "https://override.example/1234/"
    end
end

@testset "UTF-8 to Codemirror UTF-16 byte mapping" begin
    # range ends are non inclusives
    tests = [
        (" aaaa", (2, 4), (1, 3)), # cm is zero based
        (" 🍕🍕", (2, 6), (1, 3)), # a 🍕 is two UTF16 codeunits
        (" 🍕🍕", (6, 10), (3, 5)), # a 🍕 is two UTF16 codeunits
    ]
    for (s, (start_byte, end_byte), (from, to)) in tests
        @test Pluto.PlutoRunner.map_byte_range_to_utf16_codepoints(s, start_byte, end_byte) == (from, to)
    end
end


@testset "Exports" begin
    port, socket = 
        @inferred Pluto.port_serversocket(Sockets.ip"0.0.0.0", nothing, 5543)

    close(socket)
    @test 5543 <= port < 5600

    port = 13432
    host = "localhost"
    local_url(suffix) = "http://$host:$port/$suffix"


    server_running() = HTTP.get(local_url("favicon.ico")).status == 200 && HTTP.get(local_url("edit")).status == 200


    # without notebook at startup
    options = Pluto.Configuration.from_flat_kwargs(; 
        port, launch_browser=false, 
        workspace_use_distributed=true, 
        require_secret_for_access=false, 
        require_secret_for_open_links=false
    )
    🍭 = Pluto.ServerSession(; options)
    server = Pluto.run!(🍭)
    
    @test server_running()
    
    @test isempty(🍭.notebooks)
    
    HTTP.get(local_url("sample/JavaScript.jl"); retry=false)
    
    # wait for the notebook to be added to the session
    @test poll(10) do
        length(🍭.notebooks) == 1
    end
    
    notebook = only(values(🍭.notebooks))
    
    # right now, the notebook was only added to the session and assigned an ID. Let's wait for it to get a process:
    @test poll(60) do
        haskey(WorkspaceManager.active_workspaces, notebook.notebook_id)
    end
    sleep(2)
    
    # Note that the notebook is running async right now! It's not finished yet. But we can already run these tests:
    
    fileA = try
        download(local_url("notebookfile?id=$(notebook.notebook_id)"))
    catch
        # try again :)
        sleep(1)
        download(local_url("notebookfile?id=$(notebook.notebook_id)"))
    end

    fileB = tempname()
    write(fileB, sprint(Pluto.save_notebook, notebook))
    
    @test Pluto.only_versions_or_lineorder_differ(fileA, fileB)
    
    export_contents = read(download(local_url("notebookexport?id=$(notebook.notebook_id)")), String)
    
    @test occursin(string(Pluto.PLUTO_VERSION), export_contents)
    @test occursin("</html>", export_contents)
    @test occursin("insertion-spot", export_contents)
    # The export's assets must come from THIS fork's repo: upstream has no tags for SpaceStation's
    # versions, so the old (?:fonsp|JuliaPluto)/Pluto.jl root 404'd on every asset and exports
    # opened blank (#60). This regex previously pinned that broken root — the test encoded the bug.
    # (Upstream's comment here said pluto.land greps for its pattern; this fork's upload flow leans
    # on the offline bundle, which embeds assets, so that concern does not transfer.)
    plutoland_regex = r"href=\"(https://cdn\.jsdelivr\.net/gh/GroupTherapyOrg/SpaceStation\.jl@([\d.]+)/)[\w/.\\d\-]*\""
    @test occursin(plutoland_regex, export_contents)
    
    
    export_offline_contents = read(download(local_url("notebookexport?offline_bundle=true&id=$(notebook.notebook_id)")), String)
    # We can't test if the offline_bundle is working (and that it is different from the regular bundle), because the tests are probably running on an unbundled Pluto (the directories frontend-dist and frontend-dist-offline are not generated). In that case, Pluto falls back to using the unbundled editor.html with CDN pointing to /frontend/, for example:
    ### https://cdn.jsdelivr.net/gh/JuliaPluto/Pluto.jl@0.20.21/frontend/img/favicon_unsaturated.svg
    @test occursin(string(Pluto.PLUTO_VERSION), export_offline_contents)
    @test occursin("</html>", export_offline_contents)
    @test occursin("insertion-spot", export_offline_contents)
    @test occursin(plutoland_regex, export_offline_contents)
    
    t = tempname(; cleanup=false)
    write(@show(t), export_offline_contents)
    
    
    if isdir(joinpath(pkgdir(Pluto), "frontend-dist")) && isdir(joinpath(pkgdir(Pluto), "frontend-dist-offline"))
        @test hash(export_offline_contents) != hash(export_contents)
        @test length(export_offline_contents) > 4 * length(export_contents) # the offline bundle is much larger than the regular export
        
        https_count = count("https://", export_contents)
        https_count_offline = count("https://", export_offline_contents)
        @test https_count > https_count_offline + 5
    else
        @info "Skipping offline bundle tests because there are no bundle files. That's fine, but if you want to run these tests then you should run the frontend bundlers before, and run with the JULIA_PLUTO_FORCE_BUNDLED=ja env variable."
    end
    
    
    # wait for Pkg to finish
    for _ in 1:10
        Pluto.withtoken(Pluto.pkg_token) do
            sleep(0.01)
        end
    end
    
    for notebook in values(🍭.notebooks)
        SessionActions.shutdown(🍭, notebook; keep_in_session=false, async=false)
    end
    
    close(server)
end
sleep(2)

end # testset

# Closing a terminal asks first when that would stop something: for that the server can say what a
# terminal's shell is running. At its prompt: nothing. With a program started from it: its name.
@testset "A folder's names are listed by letter, not by case" begin
    mktempdir() do dir
        for name in ["README.md", "fatou.jl", "Project.toml", "comparator.md", "AGENTS.md", ".gitignore"]
            write(joinpath(dir, name), "")
        end
        for name in ["results", "Papers", "cluster"]
            mkdir(joinpath(dir, name))
        end
        entries, _, truncated = Pluto._list_dir_shallow(dir, Ref(100))
        @test !truncated
        # folders first, then files; within each, capitals and small letters together
        @test [Dict(e)["name"] for e in entries] == ["cluster", "Papers", "results", ".gitignore", "AGENTS.md", "comparator.md", "fatou.jl", "Project.toml", "README.md"]
        @test Pluto._in_name_order(["b", "B", "a", "A"]) == ["A", "a", "B", "b"] # the same every time
    end
end

@testset "A folder as it is typed, and one way to write it" begin
    mktempdir() do tmp
        dir = joinpath(realpath(tmp), "My Project")
        mkpath(joinpath(dir, "Sub Folder"))
        # pasted from a file manager: in quotes, with a separator at the end
        @test Pluto._typed_path("\"$(dir)\"") == dir
        @test Pluto._typed_path("  $(dir)  ") == dir
        @test Pluto._one_spelling(joinpath(dir, "Sub Folder", "")) == joinpath(dir, "Sub Folder")
        @test Pluto._one_spelling(dir) == dir
        if Sys.iswindows() || Sys.isapple()
            # the same folder, written in another case, is the same workspace
            other = joinpath(dir, "sub folder")
            if isdir(other) # (a volume can be set up to tell case apart)
                @test Pluto._one_spelling(other) == joinpath(dir, "Sub Folder")
                @test Pluto.workspace_id(Pluto._one_spelling(other)) == Pluto.workspace_id(joinpath(dir, "Sub Folder"))
            end
        end
        if Sys.iswindows()
            drive = dir[1:2]
            @test Pluto._typed_path(drive) == drive * "\\"
            @test Pluto._one_spelling(lowercase(dir)) == dir
            @test (drive * "\\") in Pluto._drive_roots()
            for bad in ["con", "NUL.txt", "notes 10:30.md", "what?.jl", "ends.", "ends ", "a<b"]
                @test Pluto._name_complaint(bad) isa String
            end
            for fine in ["notes.txt", "My File (2).jl", "console.log", "com10.txt", ".gitignore"]
                @test Pluto._name_complaint(fine) === nothing
            end
        else
            @test isempty(Pluto._drive_roots())
            @test Pluto._name_complaint("notes 10:30.md") === nothing # a fine name here
        end
    end
end

Sys.isunix() && @testset "Ctrl+C reaches the program a terminal runs" begin
    # This server keeps SIGINT blocked in its threads; a shell that inherits that hands it to every
    # program it starts, and Ctrl+C prints ^C and stops nothing. bash keeps the mask it is given.
    shell = something(Sys.which("bash"), "/bin/sh")
    pty = Pluto.pty_spawn(["/bin/sh", "-c", "exec $(shell)"])
    got = UInt8[]
    reader = @async for data in pty.output
        append!(got, data)
    end
    seen(text) = occursin(text, String(copy(got)))
    try
        sleep(2)
        Pluto.pty_write(pty, "sleep 60\n")
        sleep(1.5)
        Pluto.pty_write(pty, "\x03")
        sleep(1)
        Pluto.pty_write(pty, "echo after-\$((40+2))\n")
        @test timedwait(() -> seen("after-42"), 15.0) == :ok
    finally
        Pluto.pty_close!(pty)
    end
end

Sys.isunix() && @testset "What a terminal is running" begin
    port = 13000 + rand(1:999)
    options = Pluto.Configuration.from_flat_kwargs(; port, launch_browser=false, require_secret_for_access=false, require_secret_for_open_links=false, workspace_use_distributed=false, workspace=mktempdir())
    session = Pluto.ServerSession(; options)
    server = Pluto.run!(session)
    try
        @test Pluto.terminal_running("no-such-terminal") === nothing
        asked(tid) = String(HTTP.get("http://127.0.0.1:$port/api/v1/terminal/running?tid=$tid"; retry=false).body)
        HTTP.WebSockets.open("ws://127.0.0.1:$port/terminal?tid=busy-test&rows=24&cols=80"; headers=["Origin" => "http://127.0.0.1:$port"]) do ws
            @test timedwait(() -> haskey(Pluto.COLLAB_TERMINALS, "busy-test"), 20) == :ok
            @test timedwait(() -> Pluto.terminal_running("busy-test") === nothing, 20) == :ok   # a shell at its prompt
            @test occursin("null", asked("busy-test"))
            # the shell knows where its server is, from its environment; and the secret is on no command
            # line (anybody on a shared machine can read those)
            shell_pid = Int(Pluto.COLLAB_TERMINALS["busy-test"].pty.child_pid)
            @test !occursin(session.secret, read(`ps -o args= -p $shell_pid`, String))
            marker = joinpath(mktempdir(), "seen")
            HTTP.WebSockets.send(ws, "0:printf %s \"\$SPACESTATION_SECRET\" > $marker\n")
            @test timedwait(() -> isfile(marker) && read(marker, String) == session.secret, 20) == :ok
            HTTP.WebSockets.send(ws, "0:sleep 30\n")
            @test timedwait(() -> Pluto.terminal_running("busy-test") == "sleep", 20) == :ok
            @test occursin("\"sleep\"", asked("busy-test"))
        end
        # the server says which terminals exist, and in which workspace: a page asks, it does not remember
        listed(q="") = String(HTTP.get("http://127.0.0.1:$port/api/v1/terminals$q"; retry=false).body)
        home = Pluto.COLLAB_TERMINALS["busy-test"].cwd
        @test occursin("\"tid\":\"busy-test\"", listed()) && occursin("\"tid\":\"busy-test\"", listed("?root=$(HTTP.escapeuri(home))"))
        @test !occursin("busy-test", listed("?root=$(HTTP.escapeuri(joinpath(home, "elsewhere")))"))
        @test Pluto.list_terminals(dirname(home)) == [["tid" => "busy-test", "cwd" => home]]       # started below it
        # A terminal is its workspace's: one opened from a workspace on a folder inside this one (the
        # same hub holds both) is in that one's list and not in this one's, although its folder is below.
        inner = mkpath(joinpath(home, "inner"))
        HTTP.WebSockets.open("ws://127.0.0.1:$port/terminal?tid=inner-test&rows=24&cols=80&cwd=$(HTTP.escapeuri(inner))&root=$(HTTP.escapeuri(inner))"; headers=["Origin" => "http://127.0.0.1:$port"]) do ws
            @test timedwait(() -> haskey(Pluto.COLLAB_TERMINALS, "inner-test"), 20) == :ok
        end
        @test Pluto.list_terminals(inner) == [["tid" => "inner-test", "cwd" => Pluto.COLLAB_TERMINALS["inner-test"].cwd]]
        @test Pluto.list_terminals(inner * "/") == Pluto.list_terminals(inner)
        @test Pluto.list_terminals(home) == [["tid" => "busy-test", "cwd" => home]]
        @test first.(Pluto.list_terminals()) == ["tid" => "busy-test", "tid" => "inner-test"]   # in the order opened
        @test Pluto.close_terminal!("inner-test")
        # A page coming back to a terminal that has gone is told so. It used to get a new shell under
        # the old name: a terminal closed in one page came back in every other page that showed it.
        said = String[]
        HTTP.WebSockets.open("ws://127.0.0.1:$port/terminal?tid=inner-test&rows=24&cols=80&attach=1"; headers=["Origin" => "http://127.0.0.1:$port"]) do ws
            for msg in ws
                msg isa AbstractString && push!(said, msg)
            end
        end
        @test said == ["{\"exited\":true}"]
        @test !haskey(Pluto.COLLAB_TERMINALS, "inner-test")
        # and one that is there is attached to as before
        HTTP.WebSockets.open("ws://127.0.0.1:$port/terminal?tid=busy-test&rows=24&cols=80&attach=1"; headers=["Origin" => "http://127.0.0.1:$port"]) do ws
            @test occursin("\"rows\"", HTTP.WebSockets.receive(ws))
        end
        @test Pluto.close_terminal!("busy-test")
        @test listed() == "{\"terminals\":[]}\n"
        @test Pluto.terminal_running("busy-test") === nothing
    finally
        close(server)
    end
end
