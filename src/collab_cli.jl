# collab_cli.jl — `spacestation collab …`: a cross-platform, dependency-free twin of `bin/pluto-collab`.
#
# The bash `pluto-collab` needs bash + curl + sed, which a Windows SpaceStation terminal (PowerShell
# or cmd) doesn't have. This reimplements the same commands in Julia over HTTP.jl (already a dep), so
# a coding agent gets an identical collab surface on every platform. Same connection-file discovery,
# same SPACESTATION_PORT/SECRET fast path, same endpoints, same exit codes (0 ok · 1 cells errored ·
# 2 no server / bad usage). Dispatched from `(@main)` in cli.jl when the first arg is `collab`.

import HTTP

_collab_registry_dir() = joinpath(get(ENV, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state")), "pluto", "servers")

# Flat connection JSON (written by write_collab_registry_file): "key": value | "key": "value".
function _collab_cf_field(content::AbstractString, key::AbstractString)::String
    m = match(Regex("\"" * key * "\"\\s*:\\s*\"?([^\",}]*)\"?"), content)
    m === nothing ? "" : strip(String(m.captures[1]))
end

# Candidate live servers from the connection files, newest first. No pid check (there's no portable
# one) — reachability is proven by the HTTP probe each command does anyway.
function _collab_candidate_servers()::Vector{Tuple{String,String}}
    dir = _collab_registry_dir()
    out = Tuple{String,String}[]
    isdir(dir) || return out
    files = sort(filter(f -> endswith(f, ".json"), readdir(dir; join=true)); by=mtime, rev=true)
    for f in files
        content = try
            read(f, String)
        catch
            continue
        end
        port = _collab_cf_field(content, "port")
        isempty(port) && continue
        # Shared HPC homes contain connection files from many compute nodes. A loopback address in
        # a sibling node's file means that sibling, not this machine; probing it here is both slow
        # and can accidentally hit an unrelated local process using the same port.
        node = _collab_cf_field(content, "node")
        !isempty(node) && node != gethostname() && continue
        host = _collab_cf_field(content, "host")
        host in ("", "0.0.0.0", "*") && (host = "127.0.0.1")
        push!(out, ("http://$host:$port", _collab_cf_field(content, "secret")))
    end
    out
end

function _collab_get(base, path; query=Dict{String,String}(), readtimeout=30)
    HTTP.get(base * path; query=query, status_exception=false, connect_timeout=4, readtimeout=readtimeout, retry=false)
end
function _collab_post(base, path; query=Dict{String,String}(), readtimeout=0)  # 0 = no read timeout: runs block
    HTTP.post(base * path; query=query, status_exception=false, connect_timeout=4, readtimeout=readtimeout, retry=false)
end

"Is a server reachable? (unauthenticated /ping)"
function _collab_alive(base)::Bool
    try
        _collab_get(base, "/ping"; readtimeout=4).status == 200
    catch
        false
    end
end

# The server that has `nb_abspath` open → (base, secret). Fast path: the integrated-terminal env.
function _collab_find_server(nb_abspath::String)
    candidates = Tuple{String,String}[]
    let p = get(ENV, "SPACESTATION_PORT", get(ENV, "PLUTOSPACE_PORT", "")),
        s = get(ENV, "SPACESTATION_SECRET", get(ENV, "PLUTOSPACE_SECRET", ""))
        (isempty(p) || isempty(s)) || push!(candidates, ("http://127.0.0.1:$p", s))
    end
    append!(candidates, _collab_candidate_servers())
    for (base, secret) in candidates
        r = try
            _collab_get(base, "/api/v1/notebook"; query=Dict("path" => nb_abspath, "format" => "text", "secret" => secret), readtimeout=6)
        catch
            continue
        end
        r.status == 200 && return (base, secret)
    end
    nothing
end

_collab_abspath(p, cwd) = isabspath(p) ? normpath(p) : normpath(joinpath(cwd, p))

function _collab_require_server(nb, cwd)
    nbp = _collab_abspath(nb, cwd)
    isfile(nbp) || (println(stderr, "spacestation collab: no such file: $nb"); exit(2))
    found = _collab_find_server(nbp)
    if found === nothing
        println(stderr, "spacestation collab: no live SpaceStation server has '$nb' open.")
        println(stderr, "start one with:  spacestation \"$nb\"")
        exit(2)
    end
    (found[1], found[2], nbp)
end

const _COLLAB_HELP = """
spacestation collab — talk to a LIVE SpaceStation server from any terminal (cross-platform).

Edit a notebook .jl directly to change code — in lazy mode (the default) edits only mark cells
STALE; nothing runs until you ask. This is how you inspect state and run what's stale.

Commands:
  spacestation collab servers                         list live SpaceStation servers
  spacestation collab notebooks                       list open notebooks on all live servers
  spacestation collab status <nb.jl> [--json]         per-cell state: STALE / COLD / ERRORED / output
  spacestation collab output <nb.jl> --cell <id> [--json]    one cell's FULL output (untruncated)
  spacestation collab figure <nb.jl> --cell <id> [--out f]   write one cell's rendered image to a file
  spacestation collab run <nb.jl> --stale             run all stale cells (and their dependents)
  spacestation collab run <nb.jl> --cell <id>…        run specific cells
  spacestation collab interrupt <nb.jl>               interrupt a running notebook
  spacestation collab restart <nb.jl> [--json]        restart the kernel + re-run everything
                                                      (only to recover a dead/exited worker)

Inside a SpaceStation terminal, SPACESTATION_PORT/SPACESTATION_SECRET target the live session
automatically. Exit codes: 0 ok · 1 cells errored · 2 no server / bad usage.
  agents-md                seed ./AGENTS.md + ./CLAUDE.md with the collab block (kept out of git status via .git/info/exclude)
"""

# Parse `--cell <id>` (repeatable), `--json`, `--out <f>`, `--stale` out of a tail arg list.
function _collab_flags(rest::Vector{String})
    fmt = "text"; cells = String[]; out = ""; stale = false; i = 1
    while i <= length(rest)
        a = rest[i]
        if a == "--json"; fmt = "json"
        elseif a == "--stale"; stale = true
        elseif a == "--cell"; i += 1; i <= length(rest) && push!(cells, rest[i])
        elseif a == "--out"; i += 1; i <= length(rest) && (out = rest[i])
        else
            println(stderr, "spacestation collab: unknown argument: $a"); exit(2)
        end
        i += 1
    end
    (; fmt, cells, out, stale)
end

_collab_errored(r) = something(tryparse(Int,
    HTTP.header(r, "X-SpaceStation-Cells-Errored", HTTP.header(r, "X-Pluto-Cells-Errored", "0"))), 0)

"""
    collab_cli_main(args, cwd) -> Int

Entry point for `spacestation collab …`. `args` is everything after `collab`; `cwd` is the user's
working directory (for resolving relative notebook paths). Returns the process exit code.
"""
function collab_cli_main(args::Vector{String}, cwd::String)::Int
    (isempty(args) || args[1] in ("help", "--help", "-h")) && (print(_COLLAB_HELP); return isempty(args) ? 2 : 0)

    # Explicit, on-demand opt-in for the agent surface files (issue #73: never seeded silently).
    # Needs no live server — it writes the managed block into ./AGENTS.md + ./CLAUDE.md and adds
    # both to .git/info/exclude so they stay out of git status.
    if args[1] == "agents-md"
        ensure_agents_md(cwd)
        ensure_git_exclude(cwd)
        println("seeded AGENTS.md and CLAUDE.md in $(cwd) (git status stays clean: both are in .git/info/exclude)")
        return 0
    end
    cmd = args[1]

    if cmd == "servers"
        for (base, _) in _collab_candidate_servers()
            _collab_alive(base) && println(base)
        end
        return 0

    elseif cmd == "notebooks"
        for (base, secret) in _collab_candidate_servers()
            _collab_alive(base) || continue
            println("# ", base)
            r = try
                _collab_get(base, "/api/v1/notebooks"; query=Dict("format" => "text", "secret" => secret))
            catch
                continue
            end
            r.status == 200 && print(String(r.body))
        end
        return 0
    end

    # everything below needs <nb.jl> as args[2]
    length(args) >= 2 || (println(stderr, "spacestation collab: usage: spacestation collab $cmd <nb.jl> …"); return 2)
    base, secret, nbp = _collab_require_server(args[2], cwd)
    f = _collab_flags(args[3:end])

    if cmd == "status"
        (!isempty(f.cells) || !isempty(f.out) || f.stale) &&
            (println(stderr, "spacestation collab: status only accepts --json"); return 2)
        r = _collab_get(base, "/api/v1/notebook"; query=Dict("path" => nbp, "format" => f.fmt, "secret" => secret))
        r.status == 200 || (println(stderr, "request failed ($(r.status))"); return 2)
        print(String(r.body)); return 0

    elseif cmd == "output"
        length(f.cells) == 1 && isempty(f.out) && !f.stale ||
            (println(stderr, "spacestation collab: output needs exactly one --cell <id> and optional --json"); return 2)
        r = _collab_get(base, "/api/v1/notebook/cell"; query=Dict("path" => nbp, "cell" => f.cells[1], "format" => f.fmt, "secret" => secret))
        r.status == 200 || (print(stderr, String(r.body)); return 2)
        print(String(r.body)); return 0

    elseif cmd == "figure"
        length(f.cells) == 1 && !f.stale ||
            (println(stderr, "spacestation collab: figure needs exactly one --cell <id> and optional --out <file>"); return 2)
        r = _collab_get(base, "/api/v1/notebook/figure"; query=Dict("path" => nbp, "cell" => f.cells[1], "secret" => secret))
        if r.status != 200
            print(stderr, String(r.body)); return 2
        end
        out = f.out
        if isempty(out)
            ct = lowercase(HTTP.header(r, "Content-Type", ""))
            ext = occursin("png", ct) ? "png" : occursin("jpeg", ct) ? "jpg" : occursin("svg", ct) ? "svg" : occursin("gif", ct) ? "gif" : "img"
            out = "cell-$(first(f.cells[1], 8)).$ext"
        end
        write(out, r.body)
        println("wrote $out"); return 0

    elseif cmd == "run"
        isempty(f.out) && xor(f.stale, !isempty(f.cells)) ||
            (println(stderr, "spacestation collab: choose exactly one of --stale or --cell <id>"); return 2)
        query = Dict("path" => nbp, "format" => f.fmt, "secret" => secret)
        if f.stale
            query["stale"] = "true"
        elseif !isempty(f.cells)
            query["cells"] = join(f.cells, ",")
        else
            println(stderr, "spacestation collab: specify --stale or --cell <id>"); return 2
        end
        r = _collab_post(base, "/api/v1/notebook/run"; query=query)
        r.status == 200 || (println(stderr, "request failed ($(r.status))"); return 2)
        f.fmt == "text" && print(String(r.body))
        return _collab_errored(r) > 0 ? 1 : 0

    elseif cmd == "interrupt"
        (!isempty(f.cells) || !isempty(f.out) || f.stale || f.fmt != "text") &&
            (println(stderr, "spacestation collab: interrupt does not accept additional options"); return 2)
        r = _collab_post(base, "/api/v1/notebook/interrupt"; query=Dict("path" => nbp, "format" => "text", "secret" => secret), readtimeout=30)
        r.status == 200 || (println(stderr, "request failed ($(r.status))"); return 2)
        print(String(r.body)); return 0

    elseif cmd == "restart"
        (!isempty(f.cells) || !isempty(f.out) || f.stale) &&
            (println(stderr, "spacestation collab: restart only accepts --json"); return 2)
        r = _collab_post(base, "/api/v1/notebook/restart"; query=Dict("path" => nbp, "format" => f.fmt, "secret" => secret))
        r.status == 200 || (println(stderr, "request failed ($(r.status))"); return 2)
        f.fmt == "text" && print(String(r.body))
        return _collab_errored(r) > 0 ? 1 : 0
    end

    println(stderr, "spacestation collab: unknown command: $cmd (try `spacestation collab help`)")
    return 2
end
