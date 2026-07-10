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
          spacestation --no-agents-md     do NOT seed the workspace's AGENTS.md/CLAUDE.md (seeding
                                       the managed, idempotent collab block is ON by default)
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

    run(; on_code_change, launch_browser,
        (port === nothing ? () : (port=port,))...,
        (workspace === nothing ? () : (workspace=workspace,))...,
        (notebook === nothing ? () : (notebook=notebook,))...)
    return 0
end

# Mark `main` as the entry point (`julia -m SpaceStation`, Pkg.Apps). `Base.@main` only exists on
# Julia ≥ 1.11 — on 1.10 there is no app entry point, but the package must still precompile.
@static if isdefined(Base, Symbol("@main"))
    @eval (@main)
end
