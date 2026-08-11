###
# The collab HTTP API: how external tools (coding agents, scripts, CI) talk to a LIVE SpaceStation server.
#
# Design constraints (deliberate):
#  - Plain HTTP + the existing Pluto secret for auth (`?secret=...` or cookie) — curl-able from
#    any terminal, no protocol stack, no registration. Works for any tool that can run curl.
#  - Input via query parameters, output as JSON (`format=json`, default) or plain text
#    (`format=text`) — so a thin shell client needs no JSON parser at all.
#  - Server discovery via a connection file (like Jupyter's kernel-*.json): every running server
#    writes `$XDG_STATE_HOME/pluto/servers/<node>-<port>.json` with its port and secret (the <node>
#    prefix keeps servers on a shared $HOME — one per HPC node — from colliding; see collab_registry_path).
#  - Runs are BLOCKING: the HTTP response is held open until the cells finish, so a client gets
#    success/failure from one request. Runs go through the same execution path (and the same
#    execution token) as browser clients — both sides see each other's runs live.
###

# --- a minimal JSON writer (Pluto has no JSON dependency; output only, no parsing needed) ---

function _json_string(s::AbstractString)
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif UInt32(c) < 0x20
            print(io, "\\u", string(UInt32(c), base=16, pad=4))
        else
            print(io, c)
        end
    end
    print(io, '"')
    String(take!(io))
end

_json(x::AbstractString) = _json_string(x)
_json(x::Bool) = x ? "true" : "false"
_json(x::Integer) = string(x)
_json(x::Real) = isfinite(x) ? string(x) : "null"
_json(::Nothing) = "null"
_json(x::AbstractVector) = "[" * join((_json(v) for v in x), ",") * "]"
_json(x::Vector{<:Pair}) = "{" * join(("$(_json_string(String(first(p)))):$(_json(last(p)))" for p in x), ",") * "}"

# --- server connection registry (Jupyter kernel-<id>.json idiom) ---

collab_registry_dir() = joinpath(get(ENV, "XDG_STATE_HOME", joinpath(homedir(), ".local", "state")), "pluto", "servers")

# Tag the registry filename with the node's hostname: "<node>-<port>.json".
# On a shared $HOME (an HPC cluster mounts the same NFS home on every compute node) this one
# directory is shared by every node's SpaceStation server. A bare "<port>.json" name collides across
# nodes — each node's server independently grabs the same default port (1234), so the second writer
# silently clobbers the first, and discovery/cleanup can't tell whose file is whose. The hostname
# prefix gives each node its own filenames; on a single local machine it's just a constant prefix.
# (Hostnames are filename-safe in practice; sanitize defensively. Readers glob "$(hostname)-*.json"
# on the SAME node, and Julia's gethostname() == the shell's `hostname` — same syscall — so they match.)
_registry_node() = replace(gethostname(), r"[^A-Za-z0-9._-]" => "_")
collab_registry_path(port::Integer) = joinpath(collab_registry_dir(), "$(_registry_node())-$(port).json")

"""
Create/replace a file that is mode 0o600 from the instant it exists — no world-readable window.
Plain `write(path, …)` creates at the umask (typically 0o644) and would need a follow-up chmod to
narrow it, and on a shared \$HOME (the NFS cluster home the node-tagging targets) a co-tenant can
read the secret in that create→chmod race. Passing the mode to the create closes the window: the
file is born 0o600 (umask only clears bits, and 0o600 has none to clear). libuv normalizes the
open flags across platforms; on Windows the mode maps to owner read/write (best effort).
"""
function _write_private_file(path::String, contents::AbstractString)
    # Write a sibling temp file (born 0o600), then rename over the target: readers (discovering
    # CLIs, possibly over NFS on the shared-$HOME clusters this targets) never see a partial or
    # momentarily-absent file, and the rename replaces any stale wider-permission file whole.
    tmp = path * "." * string(rand(UInt32), base=16) * ".tmp"
    flags = Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_TRUNC
    f = Base.Filesystem.open(tmp, flags, 0o600)
    try
        write(f, contents)
        close(f)
        try
            Base.Filesystem.rename(tmp, path)
        catch
            mv(tmp, path; force=true)
        end
    finally
        isopen(f) && close(f)
        isfile(tmp) && try rm(tmp) catch end
    end
    path
end

"Write the connection file that lets external tools discover this live server (port + secret). Flat JSON, greppable with sed — clients need no JSON parser. Mode 0o600: it holds the access secret."
function write_collab_registry_file(session::ServerSession, port::Integer)
    dir = collab_registry_dir()
    mkpath(dir)
    try
        Sys.iswindows() || chmod(dir, 0o700)  # the registry dir holds secrets; keep it owner-only
    catch
    end
    path = collab_registry_path(port)
    ws = session.options.server.workspace_folder
    _write_private_file(path, """{"pid": $(getpid()), "host": $(_json_string(session.options.server.host)), "port": $(port), "node": $(_json_string(gethostname())), "secret": $(_json_string(session.secret)), "workspace": $(ws === nothing ? "null" : _json_string(tamepath(ws))), "spacestation_version": $(_json_string(PLUTO_VERSION_STR)), "pluto_version": $(_json_string(PLUTO_VERSION_STR)), "started_at": $(time())}\n""")
    path
end

function remove_collab_registry_file(port::Integer)
    path = collab_registry_path(port)
    try
        isfile(path) && rm(path)
    catch end
end

# --- the workspace tree (SpaceStation) ---

"Does this file look like a Pluto notebook? (`.jl` extension + the Pluto header on line 1)"
function _is_pluto_notebook_file(path::String)::Bool
    endswith(path, ".jl") || return false
    try
        Base.open(io -> startswith(readline(io), _notebook_header), path, "r")
    catch
        false
    end
end

# Dotfiles ARE shown (you want to see .gitignore, .github/, env files…); we only skip the few
# entries that are pure noise or so large they'd blow the entry budget and bury real files.
const _WORKSPACE_SKIPLIST = (
    "node_modules", "frontend-dist", ".git", ".DS_Store",
    # dependency/build dirs with thousands of entries nobody browses from a notebook workspace
    ".venv", "venv", "__pycache__", ".tox", ".mypy_cache", ".pytest_cache", ".ipynb_checkpoints",
    ".parcel-cache", ".ruff_cache", ".jj",
)

# One entry in the workspace tree, and the listing of a folder: a node is a vector of pairs so it
# serializes as a JSON object, a listing is a vector of those so it serializes as a JSON array.
const _TreeNode = Vector{Pair}
const _TreeListing = Vector{_TreeNode}

"""
List one folder's own entries as JSON-able pairs — directories first, then files, like every file
browser — without recursing. Each directory node gets an empty `children` listing; the returned
`subdirs` vector pairs those listings with their paths so the caller can fill them in afterwards.
Decrements the shared `budget`; `truncated` says whether this folder had more entries than were left.
"""
function _list_dir_shallow(dir::String, budget::Ref{Int})
    entries = _TreeListing()
    subdirs = Tuple{_TreeListing,String}[]
    names = try
        sort(readdir(dir))
    catch
        return (entries, subdirs, false)
    end
    truncated = false
    for want_dir in (true, false), name in names
        name ∈ _WORKSPACE_SKIPLIST && continue
        p = joinpath(dir, name)
        isdir(p) == want_dir || continue
        if budget[] <= 0
            truncated = true
            break # both loops: we already know this folder is cut short
        end
        budget[] -= 1
        if want_dir
            children = _TreeListing()
            push!(entries, Pair["name" => name, "path" => p, "type" => "dir", "children" => children])
            push!(subdirs, (children, p))
        else
            push!(entries, Pair[
                "name" => name,
                "path" => p,
                "type" => _is_pluto_notebook_file(p) ? "notebook" : "file",
            ])
        end
    end
    (entries, subdirs, truncated)
end

"""
Is `path` inside `root`, or `root` itself? Both are expected absolute and normalized (`tamepath`).
The workspace listing endpoint answers only for folders under the workspace, so a client bug — or
a hand-written request — cannot walk the rest of the disk through it.
"""
_within(root::String, path::String) =
    path == root || startswith(path, endswith(root, "/") ? root : root * "/")

"""
Listing of a workspace folder as JSON-able pairs, depth- and entry-budgeted. Bulky tool directories
(and `.git`) are skipped, but dotfiles are shown.

`depth=0` lists just this folder, which is what the hub's lazy sidebar asks for — one folder per
request, only for folders the user has actually opened. Deeper values pre-walk the tree in one
response; nothing in the hub needs that any more, but `/api/v1/workspace?depth=N` still offers it
for scripts that want the whole shape at once.

The walk is **breadth-first**: every entry of a folder — directories AND files — is listed before
anything descends into a subfolder. A depth-first walk lets one fat subdirectory spend the whole
budget before its siblings, or even its parent's files, are looked at; a workspace containing a
`.venv` then showed two folders in the sidebar and nothing else. Level-by-level, the shallow
entries a person actually wants are the ones that fit in the budget.

A folder the budget stopped short of ends with a `"truncated"` marker entry, so the frontend can
say "not listed" instead of quietly showing a short — or empty — folder.

Once the budget is spent the walk stops immediately: the folders still queued are marked unlisted
without being read at all. This endpoint is polled every 10s by every open hub tab, so an
exhausted budget must cost nothing more, not one `readdir` per folder it declined to list.
"""
function _workspace_entries(dir::String; depth::Int=6, budget::Ref{Int}=Ref(2000))
    root = _TreeListing()
    isdir(dir) || return root
    mark_unlisted!(into, path) = push!(into, Pair["name" => "…", "path" => path, "type" => "truncated"])
    # the frontier: folders whose contents still have to be listed, as (fill this listing, path, depth left)
    frontier = Tuple{_TreeListing,String,Int}[(root, dir, depth)]
    while !isempty(frontier)
        next_frontier = Tuple{_TreeListing,String,Int}[]
        for (i, (into, path, d)) in enumerate(frontier)
            if budget[] <= 0
                # Nothing left to spend: flag every folder we never opened — the rest of this
                # level, plus everything already queued below it — and stop walking.
                unopened = Iterators.flatten((view(frontier, i:lastindex(frontier)), next_frontier))
                for (rest_into, rest_path, _) in unopened
                    mark_unlisted!(rest_into, rest_path)
                end
                return root
            end
            entries, subdirs, truncated = _list_dir_shallow(path, budget)
            append!(into, entries)
            truncated && mark_unlisted!(into, path)
            d <= 0 && continue
            for (children, child_path) in subdirs
                push!(next_frontier, (children, child_path, d - 1))
            end
        end
        frontier = next_frontier
    end
    root
end

# Walk up from `dir` to the repo's `.git` (a directory, or — for linked worktrees and
# submodules — a file holding "gitdir: <path>"), read its HEAD, and return the current
# branch. Reads the files directly: no `git` subprocess, no dependency on a git binary.
# → ("main", false) on a branch; ("a1b2c3d", true) on a detached HEAD; nothing if not a repo.
function _git_head_info(dir::String)
    git_path = nothing
    d = dir
    while true
        candidate = joinpath(d, ".git")
        if ispath(candidate)
            git_path = candidate
            break
        end
        parent = dirname(d)
        parent == d && break # reached the filesystem root
        d = parent
    end
    git_path === nothing && return nothing

    gitdir = if isdir(git_path)
        git_path
    else
        line = try
            strip(read(git_path, String))
        catch
            return nothing
        end
        startswith(line, "gitdir:") || return nothing
        p = strip(line[(ncodeunits("gitdir:") + 1):end])
        isabspath(p) ? p : normpath(joinpath(dirname(git_path), p))
    end

    head_file = joinpath(gitdir, "HEAD")
    isfile(head_file) || return nothing
    head = try
        strip(read(head_file, String))
    catch
        return nothing
    end
    if startswith(head, "ref:")
        ref = strip(replace(head, r"^ref:\s*" => ""))
        branch = replace(ref, r"^refs/heads/" => "")
        isempty(branch) ? nothing : (branch, false)
    else
        sha = first(head, 7) # detached HEAD: a raw commit sha
        isempty(sha) ? nothing : (sha, true)
    end
end

function _git_workspace_info(dir::String)::Union{Vector{Pair},Nothing}
    info = _git_head_info(dir)
    info === nothing && return nothing
    branch, detached = info
    Pair["branch" => branch, "detached" => detached]
end

# Serialize the API run path per notebook. Two concurrent `run --stale` requests would otherwise
# both snapshot the same stale set before either executes; the loser of the execute-token race then
# re-runs cells that are no longer stale — side effects fire twice and both report success. Holding
# this lock across sync → stale-set computation → run means the second caller computes staleness
# only after the first finished. (Browser runs don't take it — vanilla semantics — and `interrupt`
# stays lock-free so a stuck run can always be cancelled.)
const _API_RUN_LOCKS = Dict{UUID,ReentrantLock}()
const _API_RUN_LOCKS_LOCK = ReentrantLock()
_api_run_lock(notebook::Notebook) = lock(_API_RUN_LOCKS_LOCK) do
    get!(ReentrantLock, _API_RUN_LOCKS, notebook.notebook_id)
end

# --- the API routes ---

function _api_cell_pairs(cell::Cell)::Vector{Pair}
    Pair[
        "cell_id" => string(cell.cell_id),
        "code" => cell.code,
        "stale" => cell.stale,
        "workspace_cold" => cell.workspace_cold,
        "queued" => cell.queued,
        "running" => cell.running,
        "errored" => cell.errored,
        "runtime_ns" => cell.runtime === nothing ? nothing : Int64(min(cell.runtime, typemax(Int64) % UInt64)),
        "mime" => string(cell.output.mime),
        "output_text" => _text_representation(cell),
        "execution_key" => string(cell.execution_key_produced, base=16),
    ]
end

function _api_cell_text_line(notebook::Notebook, i::Integer, cell::Cell)::String
    flags = String[]
    cell.stale && push!(flags, "STALE")
    cell.workspace_cold && push!(flags, "COLD")
    cell.running && push!(flags, "RUNNING")
    cell.queued && push!(flags, "QUEUED")
    cell.errored && push!(flags, "ERRORED")
    flag_str = isempty(flags) ? "fresh" : join(flags, ",")
    first_line = first(split(cell.code, '\n'; limit=2))
    out_first = first(split(_text_representation(cell), '\n'; limit=2))
    "[$i] $(cell.cell_id) $flag_str\n    code: $first_line\n    output: $out_first"
end

function _api_notebook_text(notebook::Notebook, session::ServerSession)::String
    n_stale = count(c -> c.stale, notebook.cells)
    n_cold = count(c -> c.workspace_cold, notebook.cells)
    header = """
    notebook: $(notebook.path)
    notebook_id: $(notebook.notebook_id)
    process: $(notebook.process_status)
    mode: $(is_lazy(session) ? "lazy" : "autorun")
    cells: $(length(notebook.cells)) ($(n_stale) stale, $(n_cold) cold)
    """
    body = join((_api_cell_text_line(notebook, i, c) for (i, c) in enumerate(notebook.cells)), "\n")
    header * "\n" * body * "\n"
end

function _api_notebook_json(notebook::Notebook, session::ServerSession)::String
    _json(Pair[
        "notebook_id" => string(notebook.notebook_id),
        "path" => notebook.path,
        "process_status" => notebook.process_status,
        "mode" => is_lazy(session) ? "lazy" : "autorun",
        "cells" => [_api_cell_pairs(c) for c in notebook.cells],
    ])
end

_api_wants_text(query) = get(query, "format", "json") == "text"

_api_error(status, msg, fmt_text) = HTTP.Response(status,
    ["Content-Type" => fmt_text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8"],
    fmt_text ? "error: $msg\n" : _json(Pair["error" => msg]) * "\n")

"Find a notebook by `id` or by `path` (realpath comparison) from query parameters."
function _api_notebook_from_query(session::ServerSession, query)::Union{Notebook,Nothing}
    if haskey(query, "id")
        id = try
            UUID(query["id"])
        catch
            return nothing
        end
        return get(session.notebooks, id, nothing)
    elseif haskey(query, "path")
        requested = try
            realpath(query["path"])
        catch
            return nothing # path does not exist
        end
        for nb in values(session.notebooks)
            if isfile(nb.path) && realpath(nb.path) == requested
                return nb
            end
        end
    end
    nothing
end

function register_collab_api!(router, session::ServerSession)

    function serve_api_notebooks(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        if _api_wants_text(query)
            body = join(("$(id)\t$(nb.path)" for (id, nb) in session.notebooks), "\n")
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body * "\n")
        else
            body = _json([Pair["notebook_id" => string(id), "path" => nb.path] for (id, nb) in session.notebooks])
            HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
        end
    end
    HTTP.register!(router, "GET", "/api/v1/notebooks", serve_api_notebooks)

    function serve_api_notebook(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)
        # Sync from disk BEFORE reporting, so `status` reflects the current file — not whatever the
        # in-memory notebook was before the background watcher's ~0.4s debounce caught up. This makes
        # the agent flow deterministic: edit the .jl, then `status` immediately shows the right cells
        # STALE. save=false keeps it read-only (no .jl rewrite); in lazy mode a sync only marks stale,
        # never runs — the two-tier "edit stages, run applies" contract is preserved exactly.
        # allow_destructive=false: cell REMOVALS are left to the watcher/run syncs — on this
        # undebounced read they may be an artifact of catching the file mid-write, and applying
        # them escalates to a variable-deleting run that saves. Status must stay read-only.
        if !isempty(notebook.path) && isfile(notebook.path)
            try
                synced_update_from_file(session, notebook; save=false, run_async=false, allow_destructive=false)
            catch e
                @warn "notebook status: syncing from file before reporting failed" exception = (e, catch_backtrace())
            end
        end
        if fmt_text
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], _api_notebook_text(notebook, session))
        else
            HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _api_notebook_json(notebook, session) * "\n")
        end
    end
    HTTP.register!(router, "GET", "/api/v1/notebook", serve_api_notebook)

    # Read ONE cell's FULL output (the status digest caps each cell at 20k; this returns up to 200k
    # so an agent can pull a long result it saw truncated in `status`).
    function serve_api_cell(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)
        haskey(query, "cell") || return _api_error(400, "specify ?cell=<uuid>", fmt_text)
        cid = try
            UUID(strip(query["cell"]))
        catch
            return _api_error(400, "invalid cell id: $(query["cell"])", fmt_text)
        end
        haskey(notebook.cells_dict, cid) || return _api_error(404, "no cell with id $(query["cell"])", fmt_text)
        cell = notebook.cells_dict[cid]
        full = _text_representation(cell; limit=200_000)
        if fmt_text
            flags = String[]
            cell.stale && push!(flags, "STALE"); cell.workspace_cold && push!(flags, "COLD")
            cell.running && push!(flags, "RUNNING"); cell.queued && push!(flags, "QUEUED")
            cell.errored && push!(flags, "ERRORED")
            state = isempty(flags) ? "fresh" : join(flags, ",")
            body = "cell: $(cell.cell_id)\nstate: $(state)\nmime: $(cell.output.mime)\n\ncode:\n$(cell.code)\n\noutput:\n$(full)\n"
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body)
        else
            body = _json(Pair[
                "cell_id" => string(cell.cell_id),
                "code" => cell.code,
                "stale" => cell.stale, "workspace_cold" => cell.workspace_cold,
                "queued" => cell.queued, "running" => cell.running, "errored" => cell.errored,
                "mime" => string(cell.output.mime),
                "output_text" => full,
            ])
            HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
        end
    end
    HTTP.register!(router, "GET", "/api/v1/notebook/cell", serve_api_cell)

    # Read ONE cell's rendered figure as raw image bytes — opt-in (separate request), so figures
    # never bloat `status`. Only when the cell's output mime is image/* (png/svg/jpeg/…).
    function serve_api_figure(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open? (pass ?path= or ?id=)", true)
        haskey(query, "cell") || return _api_error(400, "specify ?cell=<uuid>", true)
        cid = try
            UUID(strip(query["cell"]))
        catch
            return _api_error(400, "invalid cell id: $(query["cell"])", true)
        end
        haskey(notebook.cells_dict, cid) || return _api_error(404, "no cell with id $(query["cell"])", true)
        cell = notebook.cells_dict[cid]
        mime = string(cell.output.mime)
        startswith(mime, "image/") || return _api_error(415, "cell $(cell.cell_id) output is $(mime), not an image — use `status`/the cell endpoint for text & rich results", true)
        body = cell.output.body
        bytes = body isa Vector{UInt8} ? body :
                body isa String ? Vector{UInt8}(codeunits(body)) :
                return _api_error(404, "cell $(cell.cell_id) has no image bytes", true)
        HTTP.Response(200, ["Content-Type" => mime], bytes)
    end
    HTTP.register!(router, "GET", "/api/v1/notebook/figure", serve_api_figure)

    function serve_api_run(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)
        lock(_api_run_lock(notebook)) do

        # Sync from disk BEFORE deciding what is stale and running. The documented agent workflow is
        # "edit the .jl, then `pluto-collab run --stale`" — but the background file watcher only syncs
        # after a ~0.4s debounce (SessionActions.jl), so an edit-then-immediately-run races it: we
        # would run the OLD in-memory cells and, because the run also saves, write them straight back
        # over the just-written file — silently losing the edit and returning success. Loading here
        # picks up the current file and marks the right cells stale (lazy) deterministically,
        # regardless of watcher timing. It is a no-op when already in sync, and idempotent with a
        # concurrent watcher load (which then sees no diff). Skipped when the file was never saved.
        if !isempty(notebook.path) && isfile(notebook.path)
            synced = try
                synced_update_from_file(session, notebook; run_async=false)
            catch e
                @warn "notebook/run: syncing the notebook from its file before running failed" exception = (e, catch_backtrace())
                false
            end
            if !synced
                # Never continue with the old in-memory notebook: the run path saves, so doing so
                # could overwrite the agent's newer (temporarily incomplete or invalid) file.
                return _api_error(409,
                    "cannot run because the notebook file could not be parsed completely; no code was run and the file was not changed. Finish the write, verify the Pluto cell markers/order block, then retry `status` and `run`.",
                    fmt_text)
            end
        end

        cells = if get(query, "stale", "") == "true"
            filter(c -> c.stale, notebook.cells)
        elseif haskey(query, "cells")
            ids = split(query["cells"], ',')
            resolved = Cell[]
            for id_str in ids
                id = try
                    UUID(strip(id_str))
                catch
                    return _api_error(400, "invalid cell id: $id_str", fmt_text)
                end
                haskey(notebook.cells_dict, id) || return _api_error(404, "no cell with id $id_str", fmt_text)
                push!(resolved, notebook.cells_dict[id])
            end
            resolved
        else
            return _api_error(400, "specify ?stale=true or ?cells=<id>,<id>,…", fmt_text)
        end

        requested_ids = Set(cell_id.(cells))
        if is_lazy(session)
            cells = expand_stale_ancestors(notebook, cells)
        end

        # Honesty check. When code execution is off — Safe Preview (waiting_for_permission: how the
        # workspace hub opens notebooks until a human clicks "Run notebook code") or a dead worker
        # (no_process) — update_save_run! silently skips execution, and this endpoint used to count
        # 0 errored cells and report "RESULT: ok (N cells ran)", exit 0. An unattended agent must
        # get a hard failure it can act on instead.
        if !isempty(cells) && !will_run_code(notebook)
            hint = notebook.process_status == ProcessStatus.waiting_for_permission ?
                "the notebook is in Safe Preview — a human must grant execution in the browser (\"Run notebook code\"), or the notebook must be opened with execution allowed" :
                "the worker process is not running — recover it with `restart`"
            return _api_error(409, "cannot run: code execution is disabled for this notebook (process: $(notebook.process_status)); $hint", fmt_text)
        end

        if !isempty(cells)
            # blocking: the same path as a browser run request, behind the same execution token
            update_save_run!(session, notebook, cells; run_async=false, save=true, auto_solve_multiple_defs=true)
        end

        n_errored = count(c -> c.errored, cells)
        headers = [
            "Content-Type" => fmt_text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
            "X-SpaceStation-Cells-Ran" => string(length(cells)),
            "X-SpaceStation-Cells-Errored" => string(n_errored),
            # Pre-release aliases for older pluto-collab clients.
            "X-Pluto-Cells-Ran" => string(length(cells)),
            "X-Pluto-Cells-Errored" => string(n_errored),
        ]
        if fmt_text
            lines = String[]
            for (i, c) in enumerate(cells)
                requested = cell_id(c) ∈ requested_ids ? "" : " (pulled in)"
                push!(lines, _api_cell_text_line(notebook, i, c) * requested)
            end
            push!(lines, n_errored == 0 ? "RESULT: ok ($(length(cells)) cells ran)" : "RESULT: errored ($(n_errored) of $(length(cells)) cells errored)")
            HTTP.Response(200, headers, join(lines, "\n") * "\n")
        else
            body = _json(Pair[
                "ok" => n_errored == 0,
                "cells_ran" => length(cells),
                "cells_errored" => n_errored,
                "cells" => [vcat(_api_cell_pairs(c), Pair["pulled_in" => cell_id(c) ∉ requested_ids]) for c in cells],
            ])
            HTTP.Response(200, headers, body * "\n")
        end

        end # lock(_api_run_lock(notebook))
    end
    HTTP.register!(router, "POST", "/api/v1/notebook/run", serve_api_run)

    function serve_api_browse(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        path = haskey(query, "path") ? tamepath(query["path"]) : homedir()
        isdir(path) || return _api_error(404, "not a directory: $path", false)
        dirs = String[]
        try
            for name in sort(readdir(path))
                startswith(name, ".") && continue
                isdir(joinpath(path, name)) && push!(dirs, name)
            end
        catch end
        body = _json(Pair["path" => path, "parent" => dirname(path), "dirs" => dirs])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/browse", serve_api_browse)

    function serve_api_workspace_open(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/folder", false)
        path = tamepath(query["path"])
        isdir(path) || return _api_error(400, "not a directory: $path", false)
        session.options.server.workspace_folder = path
        # refresh the connection file so external tools see the new workspace root
        port = session.options.server.port
        port isa Integer && try
            write_collab_registry_file(session, port)
        catch end
        # seed the newly-opened workspace's AGENTS.md/CLAUDE.md collab section (on by default;
        # SPACESTATION_AGENTS_MD=0 / --no-agents-md opts out)
        try
            maybe_write_agents_md(session)
        catch end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["ok" => true, "root" => path]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/workspace/open", serve_api_workspace_open)

    # Clear the workspace (back to the launcher) — the "home" button on a tunneled server switches
    # workspaces in-place rather than opening new tabs, so it needs a way to return to the homebase.
    function serve_api_workspace_close(request::HTTP.Request)
        session.options.server.workspace_folder = nothing
        port = session.options.server.port
        port isa Integer && try
            write_collab_registry_file(session, port)
        catch end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["ok" => true]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/workspace/close", serve_api_workspace_close)

    # Capabilities the frontend needs even before a workspace exists. `tunneled` = this server is reached
    # over an SSH tunnel (set at remote launch): its child workspace ports aren't forwarded to the browser,
    # so the launcher opens workspaces IN-PLACE instead of spawning unreachable child tabs.
    function serve_api_config(request::HTTP.Request)
        body = _json(Pair[
            "tunneled" => haskey(ENV, "SPACESTATION_TUNNELED") || haskey(ENV, "PLUTOSPACE_TUNNELED"),
            "pluto_version" => PLUTO_VERSION_STR,
            # the integrated terminal's pty is ConPTY here — xterm.js needs to know to enable
            # its Windows heuristics (see TerminalView in land.js)
            "windows" => Sys.iswindows(),
        ])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/config", serve_api_config)

    function serve_api_ssh_hosts(request::HTTP.Request)
        # the user's already-keyed remotes: Host entries from ~/.ssh/config (wildcards skipped)
        hosts = String[]
        config = joinpath(homedir(), ".ssh", "config")
        if isfile(config)
            for line in eachline(config)
                m = match(r"^\s*Host\s+(.+)$"i, line)
                m === nothing && continue
                for h in split(m.captures[1])
                    (occursin('*', h) || occursin('?', h) || occursin('!', h)) && continue
                    push!(hosts, String(h))
                end
            end
        end
        body = _json(unique(hosts))
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/ssh_hosts", serve_api_ssh_hosts)

    # The workspace root: its own entries, plus the git branch the sidebar header shows. `?depth=N`
    # (default 0, this folder only) pre-walks N levels into the response for a caller that wants the
    # whole shape in one go — the hub does not, it expands folders one at a time via /listing below.
    function serve_api_workspace(request::HTTP.Request)
        ws = session.options.server.workspace_folder
        ws === nothing && return _api_error(404, "this server has no workspace folder — start with SpaceStation.run(workspace=\"/path\")", false)
        root = tamepath(ws)
        isdir(root) || return _api_error(404, "workspace folder does not exist: $root", false)
        query = HTTP.queryparams(HTTP.URI(request.target))
        depth = if haskey(query, "depth")
            d = tryparse(Int, query["depth"])
            d === nothing && return _api_error(400, "depth must be an integer, got $(query["depth"])", false)
            max(0, d)
        else
            0
        end
        body = _json(Pair[
            "root" => root,
            "entries" => _workspace_entries(root; depth),
            "git" => _git_workspace_info(root),
        ])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/workspace", serve_api_workspace)

    # One folder's entries, nothing below it. This is what makes the sidebar's cost track what the
    # user has open rather than the size of the workspace: the hub asks for a folder when it is
    # expanded, and its 10s poll re-asks only for the folders currently on screen. The recursive
    # walk could not do that — it re-read (and re-serialized) the entire tree six times a minute,
    # and needed an entry budget to stay bounded, which is what used to hide files.
    function serve_api_workspace_listing(request::HTTP.Request)
        ws = session.options.server.workspace_folder
        ws === nothing && return _api_error(404, "this server has no workspace folder — start with SpaceStation.run(workspace=\"/path\")", false)
        root = tamepath(ws)
        query = HTTP.queryparams(HTTP.URI(request.target))
        path = haskey(query, "path") ? tamepath(query["path"]) : root
        _within(root, path) || return _api_error(403, "path is outside the workspace: $path", false)
        isdir(path) || return _api_error(404, "not a directory: $path", false)
        body = _json(Pair["path" => path, "entries" => _workspace_entries(path; depth=0)])
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], body * "\n")
    end
    HTTP.register!(router, "GET", "/api/v1/workspace/listing", serve_api_workspace_listing)

    function serve_api_file_get(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isfile(path) || return _api_error(404, "not a file: $path", false)
        filesize(path) > 2_000_000 && return _api_error(413, "file too large to edit here (> 2 MB)", false)
        content = try
            read(path, String)
        catch
            return _api_error(500, "could not read file", false)
        end
        isvalid(content) || return _api_error(415, "not a UTF-8 text file", false)
        HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], content)
    end
    HTTP.register!(router, "GET", "/api/v1/file", serve_api_file_get)

    function serve_api_file_save(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isdir(dirname(path)) || return _api_error(400, "no such directory: $(dirname(path))", false)
        try
            # atomic, like the notebook save path; unique tmp so concurrent saves of the same
            # path can't interleave writes into one temp file
            tmp = path * ".spacestation_tmp." * string(rand(UInt32), base=16)
            write(tmp, request.body)
            mv(tmp, path; force=true)
        catch e
            return _api_error(500, "could not save: $(sprint(showerror, e))", false)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/file/save", serve_api_file_save)

    function serve_api_file_new(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isfile(path) && return _api_error(409, "file already exists: $path", false)
        isdir(dirname(path)) || return _api_error(400, "no such directory: $(dirname(path))", false)
        try
            write(path, "")
        catch e
            return _api_error(500, "could not create: $(sprint(showerror, e))", false)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/file/new", serve_api_file_new)

    function serve_api_file_delete(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        haskey(query, "path") || return _api_error(400, "pass ?path=/abs/file", false)
        path = tamepath(query["path"])
        isfile(path) || return _api_error(404, "not a file: $path", false)
        # if it's a notebook running in this session, shut it down first
        for nb in collect(values(session.notebooks))
            if isfile(nb.path) && realpath(nb.path) == realpath(path)
                SessionActions.shutdown(session, nb; keep_in_session=false, async=false, verbose=false)
            end
        end
        try
            rm(path)
            # a notebook's output cache goes with it
            sidecar = path * OUTPUT_CACHE_SUFFIX
            isfile(sidecar) && rm(sidecar)
        catch e
            return _api_error(500, "could not delete: $(sprint(showerror, e))", false)
        end
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/file/delete", serve_api_file_delete)

    function serve_api_interrupt(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found", fmt_text)

        # same logic as the :interrupt_all websocket message
        session_notebook = (session, notebook)
        workspace = WorkspaceManager.get_workspace(session_notebook; allow_creation=false)
        anything_running = workspace !== nothing && !isready(workspace.dowork_token) && any(c -> c.running, notebook.cells)
        if !notebook.wants_to_interrupt && anything_running
            notebook.wants_to_interrupt = true
            WorkspaceManager.interrupt_workspace(session_notebook)
        end
        HTTP.Response(200, fmt_text ? "interrupt requested\n" : """{"ok": true}\n""")
    end
    HTTP.register!(router, "POST", "/api/v1/notebook/interrupt", serve_api_interrupt)

    # Restart the notebook's worker process and re-run every cell — the agent-facing equivalent of the
    # editor's "restart" button (see restart_notebook_process! in Dynamic.jl). This is the recovery path
    # for a worker that has died/exited (Malt.TerminatedWorkerException, "Process exited"): `interrupt`
    # only stops a running cell and `run` needs a live process, so neither can revive a crashed kernel —
    # `restart` can. Blocking like /run: the response is held until the fresh process has re-run the
    # notebook, then reports the resulting cell states (error-count header, exit 1 for clients).
    function serve_api_restart(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        fmt_text = _api_wants_text(query)
        notebook = _api_notebook_from_query(session, query)
        notebook === nothing && return _api_error(404, "notebook not found — is it open in this server? (pass ?path=/abs/path.jl or ?id=<uuid>)", fmt_text)

        # same execution path as the browser's restart; synchronous so the HTTP call blocks until the re-run finishes
        restart_notebook_process!(session, notebook; run_async=false) ||
            return _api_error(409, "a restart is already in progress — wait for it and check `status`", fmt_text)

        n_errored = count(c -> c.errored, notebook.cells)
        headers = [
            "Content-Type" => fmt_text ? "text/plain; charset=utf-8" : "application/json; charset=utf-8",
            "X-SpaceStation-Cells-Ran" => string(length(notebook.cells)),
            "X-SpaceStation-Cells-Errored" => string(n_errored),
            "X-Pluto-Cells-Ran" => string(length(notebook.cells)),
            "X-Pluto-Cells-Errored" => string(n_errored),
        ]
        if fmt_text
            lines = [_api_cell_text_line(notebook, i, c) for (i, c) in enumerate(notebook.cells)]
            push!(lines, n_errored == 0 ? "RESULT: restarted, $(length(notebook.cells)) cells ran ok" : "RESULT: restarted, $(n_errored) of $(length(notebook.cells)) cells errored")
            HTTP.Response(200, headers, join(lines, "\n") * "\n")
        else
            body = _json(Pair[
                "ok" => n_errored == 0,
                "restarted" => true,
                "cells_ran" => length(notebook.cells),
                "cells_errored" => n_errored,
                "process_status" => notebook.process_status,
                "cells" => [_api_cell_pairs(c) for c in notebook.cells],
            ])
            HTTP.Response(200, headers, body * "\n")
        end
    end
    HTTP.register!(router, "POST", "/api/v1/notebook/restart", serve_api_restart)

    # End an integrated-terminal shell for good (the tab's × button). Detaching a socket — hiding
    # the panel, switching dock, reloading — deliberately leaves the shell running for reattach, so
    # only an explicit tab close reaps it. Idempotent; a 200 either way (already-gone is success).
    function serve_api_terminal_close(request::HTTP.Request)
        query = HTTP.queryparams(HTTP.URI(request.target))
        tid = get(query, "tid", "")
        isempty(tid) && return _api_error(400, "pass ?tid=<terminal-id>", false)
        closed = close_terminal!(tid)
        HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8"], _json(Pair["ok" => true, "closed" => closed]) * "\n")
    end
    HTTP.register!(router, "POST", "/api/v1/terminal/close", serve_api_terminal_close)
end
