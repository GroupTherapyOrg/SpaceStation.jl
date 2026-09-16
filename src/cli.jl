# cli.jl — the `spacestation` command (a proper Julia app via Pkg.Apps).
#
# Install:  julia> import Pkg; Pkg.Apps.add(url="https://github.com/GroupTherapyOrg/SpaceStation.jl")
# Then:     $ spacestation                     # workspace opener (pick a folder)
#           $ spacestation .                   # current folder as workspace
#           $ spacestation ~/project           # that folder as workspace
#           $ spacestation notebook.jl         # open one notebook
#           $ spacestation --autorun …         # classic Pluto reactivity instead of lazy
#           $ spacestation --port 1234 …
#           $ spacestation --no-browser …

function main(args)
    args = filter(a -> a != "--", collect(String, args))

    # `spacestation collab …` — the cross-platform agent CLI (works where bash/curl don't, e.g. a
    # Windows PowerShell terminal). Dispatched before the launch parsing so `collab` is never
    # mistaken for a folder to open.
    if !isempty(args) && args[1] == "collab"
        return collab_cli_main(args[2:end], pwd())
    end

    if "--help" in args || "-h" in args
        println("""
        SpaceStation 🟢🟣🔴 — a workspace for Pluto.jl notebooks, for humans and agents together.

        Usage:
          spacestation                    open the workspace picker in your browser
          spacestation <folder>           open a folder as the workspace
          spacestation <notebook.jl>      open a single notebook
          spacestation --port <n>         pick a port
          spacestation --autorun          classic Pluto reactivity (default is lazy/collab mode)
          spacestation --no-browser       don't open the browser
          spacestation --agents-md        seed the workspace's AGENTS.md/CLAUDE.md collab block
                                       (default: only REFRESH the block where it already exists —
                                       a fresh folder is never touched; --no-agents-md disables
                                       even that). Seeded files are added to .git/info/exclude,
                                       so git status stays clean either way.
          spacestation collab <cmd> …     talk to a live session from any terminal (status / run
                                       --stale / output / figure / …); cross-platform, no bash needed.
                                       See: spacestation collab help

        In lazy mode (the default), file edits — yours or an agent's — mark cells stale
        instead of running them; outputs are cached in <notebook>.jl.pluto-cache.toml and
        survive restarts. The `pluto-collab` CLI is installed on your PATH next to `spacestation`,
        and any terminal opened inside SpaceStation exports SPACESTATION_PORT / SPACESTATION_SECRET so a
        coding agent's `pluto-collab` targets this live session automatically.
        """)
        return 0
    end

    user_cwd = pwd() # Pkg.Apps shims may change cwd before invoking julia

    port = nothing
    on_code_change = "lazy"
    launch_browser = true
    target = nothing

    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--port"
            i += 1
            i <= length(args) || (println("--port needs a number"); return 1)
            port = tryparse(Int, args[i])
            port === nothing && (println("--port needs a number"); return 1)
        elseif a == "--autorun"
            on_code_change = "autorun"
        elseif a == "--no-browser"
            launch_browser = false
        elseif a == "--agents-md"
            ENV["SPACESTATION_AGENTS_MD"] = "1"
        elseif a == "--no-agents-md"
            ENV["SPACESTATION_AGENTS_MD"] = "0"
        elseif startswith(a, "-")
            println("unknown option: $a (see --help)")
            return 1
        else
            target = a
        end
        i += 1
    end

    workspace = nothing
    notebook = nothing
    if target !== nothing
        resolved = isabspath(target) ? target : normpath(joinpath(user_cwd, target))
        if isdir(resolved)
            workspace = resolved
        elseif isfile(resolved)
            notebook = resolved
        else
            println("no such file or folder: $resolved")
            return 1
        end
    end

    if notebook !== nothing
        # a single notebook: a plain server, as always
        run(; on_code_change, launch_browser, (port === nothing ? () : (port=port,))..., notebook=notebook)
        return 0
    end
    # The launcher, and `spacestation <folder>`: a workspace HUB (src/webserver/Proxy.jl). It never
    # runs a notebook itself; each folder gets a child server it relays to, at /w/<id>/.
    #
    # A hub is marked in its environment BEFORE `import SpaceStation` (SPACESTATION_HUB=1 skips the
    # registry parse at import) and serves with `--threads=4,1`; this process is neither, so it
    # starts one that is and waits for it, forwarding its exit code. Ctrl-C reaches the child
    # through the terminal's process group.
    if !PkgCompat.is_hub_process()
        cmd = `$(Base.julia_cmd()) --startup-file=no $(SERVER_THREAD_FLAGS) --project=$(something(Base.active_project(), pkgdir(@__MODULE__))) -e "import SpaceStation; exit(SpaceStation.main(ARGS))" -- $(args)`
        proc = Base.run(setenv(cmd, "SPACESTATION_HUB" => "1"); wait=false)
        try
            wait(proc)
        catch e
            e isa InterruptException || rethrow()
            # The child sits in the terminal's foreground process group, so it got the same Ctrl-C and
            # is shutting down (reaping its workspace children, up to a few seconds each). A second
            # interrupt would abort that cleanup and orphan them: give it a grace period first.
            timedwait(() -> process_exited(proc), 15.0; pollint=0.2)
            process_exited(proc) || (try kill(proc, Base.SIGTERM) catch end)
            wait(proc)
        end
        return proc.exitcode
    end
    session = ServerSession(; options=Configuration.from_flat_kwargs(; on_code_change, launch_browser=false, hub=true, (port === nothing ? () : (port=port,))...))
    server = run!(session)
    launcher_url = "http://localhost:$(session.options.server.port)/?secret=$(session.secret)"
    try
        if workspace !== nothing
            s = open_local_session!(workspace)
            deadline = time() + 240
            while s.state ∉ ("ready", "error") && time() < deadline
                sleep(0.5)
            end
            if s.state == "ready"
                url = "http://localhost:$(session.options.server.port)$(_local_session_url(s))?secret=$(session.secret)"
                @info "\nWorkspace $(workspace) is at $(url)\n"
                launch_browser && open_in_default_browser(url; wait=false)
            else
                @warn "the workspace server for $(workspace) did not start: $(s.detail) — opening the launcher instead"
                launch_browser && open_in_default_browser(launcher_url; wait=false)
            end
        elseif launch_browser
            open_in_default_browser(launcher_url; wait=false)
        end
        Base.wait(server)
    catch e
        # Ctrl-C while the first workspace is still starting: stop the hub the ordinary way, which
        # reaps the child it just spawned (on_shutdown → close_all_local_sessions)
        e isa InterruptException || rethrow()
        close(server)
    end
    return 0
end

# Mark `main` as the entry point (`julia -m SpaceStation`, Pkg.Apps). `Base.@main` only exists on
# Julia ≥ 1.11 — on 1.10 there is no app entry point, but the package must still precompile.
@static if isdefined(Base, Symbol("@main"))
    @eval (@main)
end
