using Test
import SpaceStation as Pluto

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
        runtime = joinpath(pkgdir(Pluto), "src", "webserver", "node", "runtime.sh")
        @test isfile(runtime) && success(`bash -n $runtime`)
        @test startswith(read(`bash $runtime /no/such/julia /tmp`, String), "NORUNTIME")        # a refusal is an answer, never an error
    end
end
