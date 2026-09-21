# The user's environment, as opposed to this server's.
#
# On a cluster a hub runs from a runtime staged on the node's own disk (webserver/node/runtime.sh),
# with an environment cut down to match: a PATH without directories on shared storage (looking a
# program up walks PATH, and each entry is a question to a filesystem), no LD_LIBRARY_PATH, its own
# depot and TMPDIR. What the hub STARTS for the user is another matter: a terminal, a workspace
# server and its notebooks must see the environment the user launched from (their PATH, their
# modules, their scheduler variables, their Julia and depot). The launcher saves that environment
# to a file on the node before it cuts it down (`env -0`), and names the file in
# SPACESTATION_USER_ENV_FILE. Without the variable this is simply the process environment.

const _user_env_cache = Ref{Union{Nothing,Dict{String,String}}}(nothing)
const _user_env_lock = ReentrantLock()

"Parse `env -0` output: NUL-separated `NAME=value` entries (values may contain newlines and `=`)."
function parse_env0(bytes::AbstractVector{UInt8})::Dict{String,String}
    env = Dict{String,String}()
    for entry in split(String(copy(bytes)), '\0'; keepempty=false)
        i = findfirst('=', entry)
        (i === nothing || i == firstindex(entry)) && continue
        env[String(entry[1:prevind(entry, i)])] = String(entry[nextind(entry, i):end])
    end
    env
end

"A fresh copy of the environment to give to what the user runs. Read once (the file is on the node's disk)."
function user_env()::Dict{String,String}
    lock(_user_env_lock) do
        if _user_env_cache[] === nothing
            file = get(ENV, "SPACESTATION_USER_ENV_FILE", "")
            _user_env_cache[] = try
                isempty(file) ? nothing : parse_env0(read(file))
            catch e
                @warn "SpaceStation: the saved user environment could not be read; terminals and notebooks get this server's own, reduced environment" file error = sprint(showerror, e) maxlog = 1
                nothing
            end
            _user_env_cache[] === nothing && return Dict{String,String}(ENV) # not cached: ENV can change
        end
        copy(_user_env_cache[])
    end
end

"The user's home directory: this server's own HOME is inside its runtime when it was started from one."
user_home()::String = (h = get(ENV, "SPACESTATION_USER_HOME", ""); isempty(h) ? homedir() : h)

"The julia and the project a workspace server runs with: the user's own when the launcher named them, else this process's."
function user_julia_command()::Cmd
    julia = get(ENV, "SPACESTATION_USER_JULIA", "")
    isempty(julia) ? Base.julia_cmd() : `$julia`
end
function user_project_dir()::String
    dir = get(ENV, "SPACESTATION_USER_PROJECT", "")
    isempty(dir) || return dir
    proj = something(Base.active_project(), "")
    isempty(proj) ? pkgdir(@__MODULE__) : dirname(proj)
end
