# Starts a hub the way the `spacestation` command does, and walks through it in a real browser
# (test/frontend/walkthrough/walkthrough.mjs): the launcher, the folder browser, a workspace's file
# tree, a text file, a notebook that runs, a terminal. Screenshots and a report land in
# test/frontend/artifacts. The same walk on every system; what it is for is the systems nobody sits
# in front of.
import SpaceStation

port = parse(Int, get(ENV, "WALKTHROUGH_PORT", "2468"))
# a folder as a user has one: capitals and small letters, a space, a notebook, a script, text
workspace = joinpath(realpath(mktempdir()), "My Project") # (realpath: the long name, where the system has a short one too)
mkpath(joinpath(workspace, "Papers", "drafts"))
mkpath(joinpath(workspace, "cluster"))
mkpath(joinpath(workspace, "results 2026"))
write(joinpath(workspace, "README.md"), "# My Project\n\nA line.\n")
write(joinpath(workspace, "notes.txt"), "first line\r\nsecond line\r\n") # as an editor on Windows saves it
write(joinpath(workspace, "fatou.jl"), "println(\"a plain script\")\n")
write(joinpath(workspace, "Project.toml"), "name = \"MyProject\"\n")
write(joinpath(workspace, "hello.jl"), """
### A Pluto.jl notebook ###
# v0.20.4

using Markdown
using InteractiveUtils

# ╔═╡ 3f1c2a10-0000-4000-8000-000000000001
answer = 20 + 22

# ╔═╡ 3f1c2a10-0000-4000-8000-000000000002
where = Sys.iswindows() ? "windows" : "unix"

# ╔═╡ Cell order:
# ╠═3f1c2a10-0000-4000-8000-000000000001
# ╠═3f1c2a10-0000-4000-8000-000000000002
""")

options = SpaceStation.Configuration.from_flat_kwargs(; port, hub=true, launch_browser=false)
session = SpaceStation.ServerSession(; options)
server = SpaceStation.run!(session)

dir = joinpath(@__DIR__, "frontend")
shots = joinpath(dir, "artifacts")
mkpath(shots)
node = Sys.iswindows() ? "node.exe" : "node"
p = cd(dir) do
    # the julia that runs this, by its full path: a step runs a script in the terminal, whose shell may not have it on its PATH
    walk = addenv(`$node walkthrough/walkthrough.mjs http://localhost:$port/ $(session.secret) $workspace $shots`,
        "WALKTHROUGH_JULIA" => joinpath(Sys.BINDIR, Base.julia_exename()))
    run(ignorestatus(walk))
end
close(server)
exit(p.exitcode)
