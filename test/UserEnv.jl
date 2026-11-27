using Test
import SpaceStation as Pluto
import SHA

# A hub on a cluster runs with a cut-down environment of its own; what it starts FOR the user gets the
# environment the user launched from, saved by the launcher as `env -0` (webserver/UserEnv.jl).
@testset "The user's environment, as opposed to the server's" begin
    @test Pluto.parse_env0(Vector{UInt8}("A=1\0B=x=y\nz\0=bad\0nothing\0C=\0")) == Dict("A" => "1", "B" => "x=y\nz", "C" => "")

    reset() = lock(() -> (Pluto._user_env_cache[] = nothing), Pluto._user_env_lock)
    mktempdir() do dir
        file = joinpath(dir, "user-env")
        write(file, "PATH=/home/me/bin:/usr/bin\0HOME=/home/me\0JULIA_DEPOT_PATH=/shared/depot\0MODULEPATH=/apps/modules\0")
        withenv("SPACESTATION_USER_ENV_FILE" => file, "SPACESTATION_USER_HOME" => "/home/me", "SPACESTATION_USER_JULIA" => "/shared/julia/bin/julia",
                "SPACESTATION_USER_PROJECT" => "/home/me/.spacestation/Pluto.jl", "SPACESTATION_USER_DEPOT_PATH" => "/node/depot:/shared/depot:",
                "SPACESTATION_STATE_HOME" => "/node/state", "SPACESTATION_HUB" => "1", "PATH" => "/rt/julia/bin:/usr/bin", "HOME" => "/rt/home") do
            reset()
            env = Pluto.user_env()
            @test env["PATH"] == "/home/me/bin:/usr/bin" && env["HOME"] == "/home/me" && env["MODULEPATH"] == "/apps/modules"
            env["PATH"] = "changed"; @test Pluto.user_env()["PATH"] == "/home/me/bin:/usr/bin"   # a fresh copy each time
            @test Pluto.user_home() == "/home/me"
            @test Pluto.user_julia_command() == `/shared/julia/bin/julia`
            @test Pluto.user_project_dir() == "/home/me/.spacestation/Pluto.jl"

            child = Pluto._child_env("/home/me/work")
            @test child["PATH"] == "/home/me/bin:/usr/bin" && child["HOME"] == "/home/me"         # the user's, not the hub's
            @test child["JULIA_DEPOT_PATH"] == "/node/depot:/shared/depot:"                       # their depot behind a node-local writable one
            @test child["SPACESTATION_STATE_HOME"] == "/node/state"                               # where this hub keeps its connection files
            @test !haskey(child, "SPACESTATION_HUB") && child["SPACESTATION_CHILD_WORKSPACE"] == "/home/me/work"

            helper = Dict(String(k) => String(v) for (k, v) in (split(x, "="; limit=2) for x in Pluto._file_helper_command("s").env))
            @test helper["HOME"] == "/home/me"                                                    # it reads the user's files…
            @test helper["PATH"] == "/rt/julia/bin:/usr/bin"                                      # …but runs from the staged runtime
        end
        # a file that cannot be read: the process environment, never an error
        withenv("SPACESTATION_USER_ENV_FILE" => joinpath(dir, "missing"), "SPACESTATION_USER_HOME" => nothing, "SPACESTATION_USER_JULIA" => nothing, "SPACESTATION_USER_PROJECT" => nothing) do
            reset()
            @test Pluto.user_env()["PATH"] == ENV["PATH"]
            @test Pluto.user_home() == homedir()
            @test Pluto.user_julia_command() == Base.julia_cmd()
        end
        reset()
    end

    script = Pluto._remote_launch_script("/opt/my julia/bin/julia")
    @test occursin("julia='/opt/my julia/bin/julia'\n", script)                                  # quoted, and on a line of its own
    saved = findfirst("env -0", script); hub_marker = findfirst("SPACESTATION_TUNNELED=1 SPACESTATION_HUB=1", script)
    @test saved !== nothing && hub_marker !== nothing && first(saved) < first(hub_marker)        # the saved environment does not say "hub"
    if Sys.isunix()
        path, io = mktemp(); write(io, script); close(io)
        @test success(`bash -n $path`)                                                           # a valid shell script
        # RUN it, against stand-ins for julia and for the staging script: what command line and what
        # environment does the hub really get? (`bash -n` cannot see a command split in two.)
        for staged in (true, false)
            mktempdir() do fake
                fake = realpath(fake)
                home = joinpath(fake, "home"); app = joinpath(home, ".spacestation", "Pluto.jl"); rt = joinpath(fake, "rt")
                mkpath(joinpath(app, "src", "webserver", "node")); mkpath(joinpath(rt, "julia", "bin")); mkpath(joinpath(fake, "tmp"))
                stub = "#!/bin/sh\nenv -0 > \"$fake/seen-env\"\nprintf '%s\\n' \"\$@\" > \"$fake/seen-args\"\npwd > \"$fake/seen-cwd\"\n"
                for bin in (joinpath(rt, "julia", "bin", "julia"), joinpath(fake, "userjulia")); write(bin, stub); chmod(bin, 0o755); end
                write(joinpath(rt, "cpu-target"), "generic\n")
                write(joinpath(app, "src", "webserver", "node", "runtime.sh"), staged ? "echo 'RUNTIME $rt'\n" : "echo 'NORUNTIME testing'\n")
                version = "0123456789abcdef0123456789abcdef01234567"
                launch = Pluto._remote_launch_script(joinpath(fake, "userjulia"); app, commit=version, code="run_the_hub()")
                withenv("HOME" => home, "TMPDIR" => joinpath(fake, "tmp"), "LD_LIBRARY_PATH" => "/shared/lib", "JULIA_DEPOT_PATH" => "/shared/depot",
                        "SLURM_TMPDIR" => nothing, "SPACESTATION_LAUNCH_WRAPPER" => nothing, "SPACESTATION_HUB" => nothing, "SPACESTATION_TUNNELED" => nothing) do
                    @test success(pipeline(`bash -c $launch`; stdout=devnull, stderr=devnull))
                end
                @test timedwait(() -> isfile(joinpath(fake, "seen-cwd")) && filesize(joinpath(fake, "seen-cwd")) > 0, 20) == :ok
                seen = Pluto.parse_env0(read(joinpath(fake, "seen-env"))); args = readlines(joinpath(fake, "seen-args"))
                @test seen["SPACESTATION_HUB"] == "1" && seen["SPACESTATION_TUNNELED"] == "1"      # one command, markers included
                @test seen["SPACESTATION_APP_COMMIT"] == version                                   # the hub is told which installed version it is
                @test args[end-1:end] == ["-e", "run_the_hub()"] && "--threads=4,1" in args
                @test startswith(seen["SPACESTATION_STATE_HOME"], joinpath(fake, "tmp"))           # node-local state either way
                if staged
                    @test seen["HOME"] == joinpath(rt, "home") && seen["JULIA_DEPOT_PATH"] == "$rt/depot:" && seen["JULIA_CPU_TARGET"] == "generic"
                    @test !haskey(seen, "LD_LIBRARY_PATH") && !occursin("/shared", seen["PATH"])
                    @test strip(read(joinpath(fake, "seen-cwd"), String)) == rt                     # not the launch directory
                    @test seen["SPACESTATION_USER_JULIA"] == joinpath(fake, "userjulia") && seen["SPACESTATION_USER_HOME"] == home
                    user = Pluto.parse_env0(read(seen["SPACESTATION_USER_ENV_FILE"]))
                    @test user["LD_LIBRARY_PATH"] == "/shared/lib" && user["HOME"] == home         # what the user had, for what runs for them
                    @test !haskey(user, "SPACESTATION_HUB")                                        # and it does not say "hub"
                    @test filemode(seen["SPACESTATION_USER_ENV_FILE"]) & 0o077 == 0
                    @test seen["SPACESTATION_RUNTIME_DIR"] == rt                                    # what the hub keeps from aging in /tmp
                else
                    @test seen["HOME"] == home && endswith(seen["JULIA_DEPOT_PATH"], ":/shared/depot:") # the old way, from the shared install
                end
                # The launch leaves the hub's pid behind, so a connect can tell a hub that is still starting
                # from one that died doing so, and say what it said. (The stand-in has exited: it is "gone".)
                nd = strip(read(joinpath(home, ".spacestation", only(filter(startswith("nodedir-"), readdir(joinpath(home, ".spacestation"))))), String))
                @test timedwait(() -> isfile(joinpath(nd, "hub.pid")) && filesize(joinpath(nd, "hub.pid")) > 0, 20) == :ok
                ask(wrapper=nothing) = withenv("HOME" => home, "SPACESTATION_LAUNCH_WRAPPER" => wrapper) do
                    Pluto._parse_launched_hub(read(`bash -c $(Pluto._LAUNCHED_HUB_SNIPPET)`, String))
                end
                @test timedwait(() -> first(ask()) == :gone, 20) == :ok
                write(joinpath(nd, "server.log"), "\na notice\nERROR: LoadError: ArgumentError: Package LRUCache [8ac3fa9e] is required but does not seem to be installed:\n - Run `Pkg.instantiate()`\n\nStacktrace:\n")
                @test ask() == (:gone, "ERROR: LoadError: ArgumentError: Package LRUCache [8ac3fa9e] is required but does not seem to be installed:")
                write(joinpath(nd, "server.log"), "first\nlast words\n\n"); @test ask() == (:gone, "last words")   # no error line: the last thing it said
                rm(joinpath(nd, "server.log")); @test ask() == (:gone, "")
                @test ask("some-wrapper --") == (:unknown, "")                                     # the pid may be the wrapper's: no verdict
                write(joinpath(nd, "hub.pid"), string(getpid())); @test ask() == (:alive, "")
                rm(joinpath(nd, "hub.pid")); @test ask() == (:unknown, "")
            end
        end
        cmd = Pluto._via_local_shell(`/shared/julia --project=/p -e code`)
        @test cmd.exec[1] == "/bin/sh" && cmd.exec[end-3:end] == ["/shared/julia", "--project=/p", "-e", "code"]
        @test read(Pluto._via_local_shell(`echo "a b" c`), String) == "a b c\n"                     # the shell becomes the program, arguments intact
        @test Pluto._parse_launched_hub("") == (:unknown, "")                                     # an SSH failure is not a verdict
        @test Pluto._parse_launched_hub("motd\n__HUB_GONE__\n\n  ERROR: boom  \nmore\n") == (:gone, "ERROR: boom")
        detail = Pluto._hub_gone_detail("node7", "ERROR: " * "x"^400)
        @test startswith(detail, "the SpaceStation server on node7 stopped while starting: ERROR: xxx") && length(detail) < 320 && occursin("server.log", detail)
        @test !occursin(": —", Pluto._hub_gone_detail("node7", ""))
        # What lives under /tmp on the node is marked as READ, never as changed: a cleaner goes by the first,
        # the compiled caches are checked against the second.
        mktempdir() do dir
            dir = realpath(dir); src = joinpath(dir, "pkg", "src.jl"); mkpath(dirname(src)); write(src, "x"); symlink("src.jl", joinpath(dir, "pkg", "link")); symlink("nowhere", joinpath(dir, "dangling"))
            Base.run(`touch -a -t 200001010000 $src`); read_lately() = !isempty(read(`find $src -atime -1`, String))
            before = stat(src).mtime
            @test !read_lately()
            @test success(Pluto.freshen_command([dir]))
            @test read_lately() && stat(src).mtime == before
            withenv("SPACESTATION_RUNTIME_DIR" => dir, "SPACESTATION_NODE_DIR" => joinpath(dir, "gone")) do
                @test Pluto.node_dirs_to_keep_fresh() == [dir]
                timer = Pluto.keep_node_files_fresh(; every=3600); @test timer isa Timer; close(timer)
            end
            withenv("SPACESTATION_RUNTIME_DIR" => nothing, "SPACESTATION_NODE_DIR" => nothing) do
                @test Pluto.keep_node_files_fresh() === nothing                                    # a laptop: nothing of ours is in /tmp
            end
        end
        runtime = joinpath(pkgdir(Pluto), "src", "webserver", "node", "runtime.sh")
        @test isfile(runtime) && success(`bash -n $runtime`)
        @test startswith(read(`bash $runtime /no/such/julia /tmp`, String), "NORUNTIME")        # a refusal is an answer, never an error
    end
end

# `spacestation` starts its hub as a second process. That process is where terminals, SSH tunnels and
# workspace servers come from, so it has to have the environment the command was typed in: it once
# got `SPACESTATION_HUB=1` and nothing else (no PATH, no HOME, no SSH_AUTH_SOCK, no LANG), and its
# output, the address included, went nowhere.
@testset "The hub runs in the environment the command was run in" begin
    unwrap(c) = c isa Cmd ? c : unwrap(c.cmd)
    redirects(c) = c isa Cmd ? Int[] : push!(redirects(c.cmd), c.stream_no)
    withenv("SPACESTATION_TEST_MARKER" => "kept", "SPACESTATION_HUB" => nothing) do
        command = Pluto._hub_process_command(["--no-browser", "some folder"])
        cmd = unwrap(command)
        @test cmd.env !== nothing
        @test "SPACESTATION_HUB=1" in cmd.env                                    # the marker…
        @test "SPACESTATION_TEST_MARKER=kept" in cmd.env                         # …added to what was there
        @test any(startswith("PATH="), cmd.env)
        @test cmd.exec[end-2:end] == ["--", "--no-browser", "some folder"]
        @test sort(redirects(command)) == [0, 1, 2]                              # its output is this command's
    end
end

# A terminal on Windows runs on the console host that is shipped in the package (webserver/conpty):
# the one in Windows 10 does not let the mouse through to a program. Two files, Microsoft's own, that
# must arrive on every machine exactly as they were published, whatever git, a tarball or an
# installer did on the way. Checked on every system, so a change that loses or alters them fails
# where it is made and not only on Windows. (That terminals really start on it, and that the wheel and
# a click reach a program, is test/conpty_windows.jl and the shell walkthrough.)
@testset "The console host for Windows is shipped whole" begin
    source = read(joinpath(pkgdir(Pluto), "src", "webserver", "PTYWindows.jl"), String)
    dir = joinpath(pkgdir(Pluto), "src", "webserver", "conpty", "win-x64")
    named = collect(eachmatch(r"\"(conpty\.dll|OpenConsole\.exe)\" => \"([0-9a-f]{64})\"", source))
    @test length(named) == 2
    for m in named
        file, sha = m.captures
        @test isfile(joinpath(dir, file))
        @test bytes2hex(SHA.sha256(read(joinpath(dir, file)))) == sha
    end
    @test sort(readdir(dir)) == ["OpenConsole.exe", "conpty.dll"]
    readme = read(joinpath(dirname(dir), "README.md"), String)
    @test all(m -> occursin(m.captures[2], readme), named)        # the README names the same files
    @test isfile(joinpath(dirname(dir), "LICENSE"))
    if Sys.iswindows()
        @test Pluto._console_host().kind === :bundled
    end
end
