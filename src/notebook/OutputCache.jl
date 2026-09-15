import TOML
import Base64: base64encode, base64decode

###
# The output cache sidecar: `<notebook>.jl.pluto-cache.toml`
#
# A pure, deletable cache of cell outputs, written after every reactive run in lazy mode.
# It serves two purposes:
#
#  1. Restart-surviving outputs: when a notebook is opened in lazy mode, cached outputs are
#     restored and verified against each cell's execution key — cells whose code (and upstream
#     results) are unchanged show their old output immediately, marked "cold" rather than re-run.
#  2. An agent-readable view of the notebook's results: the sidecar is plain TOML with a
#     truncated text representation, error message, and timing per cell, so any external tool
#     can read outputs by reading a file. (Full-fidelity output data is in `output_packed`.)
#
# The notebook file itself stays byte-compatible with vanilla Pluto. Deleting the sidecar
# costs nothing but cached outputs.
###

const OUTPUT_CACHE_FORMAT = 1
const OUTPUT_CACHE_SUFFIX = ".pluto-cache.toml"
const TEXT_REPRESENTATION_LIMIT = 20_000

output_cache_path(notebook::Notebook) = notebook.path * OUTPUT_CACHE_SUFFIX

function _output_to_dict(output::CellOutput)::Dict{String,Any}
    Dict{String,Any}(
        "body" => output.body,
        "mime" => string(output.mime),
        "rootassignee" => output.rootassignee === nothing ? nothing : string(output.rootassignee),
        "last_run_timestamp" => output.last_run_timestamp,
        "persist_js_state" => output.persist_js_state,
        "has_pluto_hook_features" => output.has_pluto_hook_features,
    )
end

function _output_from_dict(d::Dict)::CellOutput
    CellOutput(
        body=get(d, "body", nothing),
        mime=MIME(get(d, "mime", "text/plain")),
        rootassignee=let r = get(d, "rootassignee", nothing)
            r === nothing ? nothing : Symbol(r)
        end,
        last_run_timestamp=get(d, "last_run_timestamp", 0.0),
        persist_js_state=get(d, "persist_js_state", false),
        has_pluto_hook_features=get(d, "has_pluto_hook_features", false),
    )
end

"A plain-text view of a cell's output, for humans and external tools (the sidecar digest, and the
agent API). `limit` caps the length — the status digest uses the default; the per-cell API endpoint
passes a larger limit so an agent can read a cell's full result."
function _text_representation(cell::Cell; limit::Integer=TEXT_REPRESENTATION_LIMIT)::String
    body = cell.output.body
    if cell.errored && body isa Dict
        msg = get(body, :msg, get(body, "msg", ""))
        msg isa String ? first(msg, limit) : "[error]"
    elseif body isa String
        length(body) > limit ?
            first(body, limit) * "\n…[truncated $(length(body) - limit) characters — full output in output_packed]" :
            body
    elseif body isa Vector{UInt8}
        "[binary output: $(cell.output.mime), $(length(body)) bytes — fetch it with `pluto-collab figure`]"
    elseif body isa Dict
        # rich (tree/table) output: use the plain-text repr captured in the worker
        isempty(cell.output_text) ?
            "[rich output: $(cell.output.mime) — open in Pluto, or unpack output_packed]" :
            first(cell.output_text, limit)
    else
        ""
    end
end

"""
Write the output cache sidecar for this notebook (atomic). Includes, per cell: the execution key and result hash (for verification on load), agent-readable text, and a MsgPack+Base64 packed copy of the full output for exact restore.
"""
function save_output_cache(notebook::Notebook)
    # Snapshot on the calling thread — references only, plus the short text digest — so that the
    # serialisation and the write below can run on another thread (see `offload_blocking`) without
    # reading cells that the next run may already be changing. Only cells that have produced output
    # are worth caching.
    snapshot = [
        (
            id = string(cell.cell_id),
            execution_key = cell.execution_key_produced,
            result_hash = cell.result_hash,
            errored = cell.errored,
            output = cell.output,
            published_objects = copy(cell.published_objects),
            runtime = cell.runtime,
            text = _text_representation(cell),
        ) for cell in notebook.cells if cell.execution_key_produced != 0
    ]
    cell_order = string.(notebook.cell_order)
    path = output_cache_path(notebook)

    # A sidecar can be hundreds of MB (every output, packed and base64'd): encoding it is seconds of CPU
    # and writing it to a networked home directory is seconds more, or minutes on a slow day. Neither
    # may hold the thread that answers the browser and the hub.
    offload_blocking() do
        cells_dict = Dict{String,Any}()
        for c in snapshot
            packed = try
                base64encode(pack(Dict{String,Any}(
                    "output" => _output_to_dict(c.output),
                    "published_objects" => c.published_objects,
                )))
            catch e
                @debug "Could not pack cell output for cache" c.id exception = e
                nothing
            end
            entry = Dict{String,Any}(
                "execution_key" => string(c.execution_key, base=16),
                "result_hash" => string(c.result_hash, base=16),
                "errored" => c.errored,
                "mime" => string(c.output.mime),
                "text_representation" => c.text,
            )
            c.runtime === nothing || (entry["runtime_ns"] = Int64(min(c.runtime, typemax(Int64) % UInt64)))
            packed === nothing || (entry["output_packed"] = packed)
            cells_dict[c.id] = entry
        end

        content_dict = Dict{String,Any}(
            "format" => OUTPUT_CACHE_FORMAT,
            "pluto_version" => PLUTO_VERSION_STR,
            "julia_version" => JULIA_VERSION_STR,
            "cell_order" => cell_order,
            "cells" => cells_dict,
        )

        tmp = path * ".tmp"
        Base.open(tmp, "w") do io
            TOML.print(io, content_dict; sorted=true)
        end
        mv(tmp, path; force=true)
    end
    nothing
end

"""
Restore cell outputs, execution keys and result hashes from the output cache sidecar, if present. Restored cells are flagged `workspace_cold`: their *display* is current, but their variables do not exist in the (fresh) workspace, so they are pulled in like stale cells when something downstream runs. Best-effort: a missing or unreadable cache restores nothing.
"""
function load_output_cache!(notebook::Notebook)::Bool
    path = output_cache_path(notebook)
    isfile(path) || return false
    wanted = Set(string(cell.cell_id) for cell in notebook.cells)
    # Reading and decoding (TOML, base64, MsgPack — seconds for a large sidecar, off a networked
    # disk) happens off the serving thread; only the cheap assignment into the cells happens on it.
    decoded = try
        offload_blocking() do
            data = TOML.parsefile(path)
            get(data, "format", 0) == OUTPUT_CACHE_FORMAT || return nothing
            cells_data = get(data, "cells", Dict{String,Any}())
            out = Dict{String,Any}()
            for (id, entry) in cells_data
                id ∈ wanted || continue
                try
                    unpacked = haskey(entry, "output_packed") ? unpack(base64decode(entry["output_packed"])) : nothing
                    out[id] = (
                        execution_key = parse(UInt64, entry["execution_key"], base=16),
                        result_hash = parse(UInt64, entry["result_hash"], base=16),
                        errored = get(entry, "errored", false),
                        runtime = haskey(entry, "runtime_ns") ? UInt64(entry["runtime_ns"]) : nothing,
                        output = unpacked === nothing ? nothing : _output_from_dict(unpacked["output"]),
                        published_objects = unpacked === nothing ? nothing : let po = get(unpacked, "published_objects", nothing)
                            po isa Dict ? Dict{String,Any}(po) : Dict{String,Any}()
                        end,
                        text = get(entry, "text_representation", nothing),
                    )
                catch e
                    @debug "Skipping unreadable cache entry" id exception = e
                end
            end
            out
        end
    catch e
        @warn "Output cache exists but could not be read — ignoring it. (It is a cache: you can safely delete it.)" path exception = e
        return false
    end
    decoded === nothing && return false

    for cell in notebook.cells
        d = get(decoded, string(cell.cell_id), nothing)
        d === nothing && continue
        cell.execution_key_produced = d.execution_key
        cell.result_hash = d.result_hash
        cell.errored = d.errored
        d.runtime === nothing || (cell.runtime = d.runtime)
        if d.output !== nothing
            cell.output = d.output
            cell.published_objects = d.published_objects
        end
        d.text === nothing || !isempty(cell.output_text) || (cell.output_text = d.text)
        cell.workspace_cold = true
    end
    return true
end
