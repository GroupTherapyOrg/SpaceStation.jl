import HTTP
import Markdown: htmlesc
import Pkg
import MIMEs


# SpaceStation: an installed app should be snappy with zero CDN fetches, so the bundle is
# preferred whenever it exists — including dev/path installs (`Pkg.Apps.develop`), unlike
# upstream Pluto. Frontend devs who want live-editable JS can opt out with
# JULIA_PLUTO_FORCE_BUNDLED=nein (or delete frontend-dist/).
# Memoized: this used to be an `isdir` on the install directory per asset request, and on a cluster
# that directory can sit on a filesystem that stalls (see Offload.jl). Whether the bundle exists does
# not change while the server runs.
const _frontend_directory = Dict{Bool,String}()
function frontend_directory(; allow_bundled::Bool=true)
    get!(_frontend_directory, allow_bundled) do
        if allow_bundled && isdir(project_relative_path("frontend-dist")) && get(ENV, "JULIA_PLUTO_FORCE_BUNDLED", "ja") != "nein"
            "frontend-dist"
        else
            "frontend"
        end
    end
end

function should_cache(path::String)
    dir, filename = splitdir(path)
    endswith(dir, "frontend-dist") && occursin(r"\.[0-9a-f]{8}\.", filename)
end

const day = let 
    second = 1
    hour = 60second
    day = 24hour
end

function default_404_response(req = nothing)
    HTTP.Response(404, "Not found!")
end

# Frontend files are read off the serving thread and, when they come from the immutable bundle
# (`frontend-dist`), kept in memory after the first read: a server whose install lives on a networked
# filesystem must not have the thread that answers the browser wait on that filesystem for every
# script and stylesheet. The unbundled `frontend/` dir is not cached, so an edited file shows on reload.
const ASSET_CACHE = Dict{String,Vector{UInt8}}()
const ASSET_CACHE_LOCK = ReentrantLock()
# Cached: everything from the bundle (its files never change while the server runs), and in a hub
# (SPACESTATION_HUB=1, or `hub=true`) everything from the unbundled dir too — a cluster's clone has no
# bundle, and the hub's thread must not read the install directory per request. A dev server serving
# the unbundled dir keeps reading files, so an edited script shows on reload. A cached server keeps
# serving the bytes it started with even if the install is replaced underneath it (the remote
# auto-update does that): the running process IS the old code, and old code with new scripts would be
# worse. A restart picks up both.
const ASSET_CACHE_ALL = Ref(false)
_asset_cacheable_dir(path::AbstractString) = ASSET_CACHE_ALL[] || occursin("frontend-dist", path) || get(ENV, "SPACESTATION_HUB", "") == "1"

"The bytes of a frontend file, or `nothing` when there is no such file."
function asset_bytes(path::AbstractString)::Union{Nothing,Vector{UInt8}}
    if _asset_cacheable_dir(path)
        hit = lock(() -> get(ASSET_CACHE, path, nothing), ASSET_CACHE_LOCK)
        hit === nothing || return hit
    end
    data = offload_blocking() do
        isfile(path) ? read(path) : nothing
    end
    if data !== nothing && _asset_cacheable_dir(path)
        lock(() -> (ASSET_CACHE[path] = data), ASSET_CACHE_LOCK)
    end
    data
end

function asset_response(path; cacheable::Bool=false)
    data = asset_bytes(path)
    if data === nothing && !endswith(path, ".html")
        return asset_response(path * ".html"; cacheable)
    end
    if data !== nothing
        response = HTTP.Response(200, data)
        HTTP.setheader(response, "Content-Type" => MIMEs.contenttype_from_mime(MIMEs.mime_from_path(path, MIME"application/octet-stream"())))
        HTTP.setheader(response, "Content-Length" => string(length(data)))
        HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
        cacheable && HTTP.setheader(response, "Cache-Control" => "public, max-age=$(30day), immutable")
        response
    else
        default_404_response()
    end
end

function error_response(
    status_code::Integer, title, advice, body="")
    template = String(something(asset_bytes(project_relative_path(frontend_directory(), "error.jl.html")), UInt8[]))
    style = String(something(asset_bytes(project_relative_path("frontend", "error.css")), UInt8[]))

    body_title = body == "" ? "" : "Error message:"
    filled_in = replace(template, 
        "\$STYLE" => """<style>$(style)</style>""",
        "\$TITLE" => title,
        "\$ADVICE" => advice,
        "\$BODYTITLE" => body_title,
        "\$BODY" => htmlesc(body),
    )

    response = HTTP.Response(status_code, filled_in)
    HTTP.setheader(response, "Content-Type" => MIMEs.contenttype_from_mime(MIME"text/html"()))
    response
end

function notebook_response(notebook; home_url="./", as_redirect=true)
    if as_redirect
        response = HTTP.Response(302, "")
        HTTP.setheader(response, "Location" => home_url * "edit?id=" * string(notebook.notebook_id))
        return response
    else
        HTTP.Response(200, string(notebook.notebook_id))
    end
end

const found_is_pluto_dev = Ref{Union{Bool, Nothing}}()
"""
Is the Pluto package `dev`ed? Returns `false` for normal Pluto installation from the registry.
"""
function is_pluto_dev()
    if found_is_pluto_dev[] !== nothing
        return found_is_pluto_dev[]
    end

    found_is_pluto_dev[] = try
        # is the package located in .julia/packages ?
        if startswith(pkgdir(@__MODULE__), joinpath(get(DEPOT_PATH, 1, "zzz"), "packages"))
            false
        else
            deps = Pkg.dependencies()

            p_index = findfirst(p -> p.name == "SpaceStation" || p.name == "Pluto", deps)
            p = deps[p_index]

            p.is_tracking_path
        end
    catch e
        @debug "is_pluto_dev failed" e
        false
    end
end

