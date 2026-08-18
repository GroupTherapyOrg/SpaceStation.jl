using Test
import SpaceStation: Pluto

# The sidebar's file tree (`GET /api/v1/workspace`). It is entry-budgeted, so the interesting
# question is always *which* entries survive the budget — a workspace with one huge subfolder
# must still show its own notebooks.

nodes(listing) = [Dict(n) for n in listing]
names_of(listing) = [d["name"] for d in nodes(listing)]
find_node(listing, name) = only(d for d in nodes(listing) if d["name"] == name)

"A folder with `nfiles` files, `nsubdirs` subfolders, each of those holding `nfiles` files too."
function make_fat_dir(path, nsubdirs, nfiles)
    mkpath(path)
    for i in 1:nfiles
        write(joinpath(path, "f$(i).txt"), "")
    end
    for i in 1:nsubdirs
        sub = joinpath(path, "sub$(i)")
        mkpath(sub)
        for j in 1:nfiles
            write(joinpath(sub, "g$(j).txt"), "")
        end
    end
end

@testset "Workspace file tree" begin
    root = mktempdir()

    # ".big" sorts before every letter, so a depth-first walk reaches it first and — before the
    # tree became breadth-first — spent the whole budget inside it, leaving the workspace's own
    # notebooks and folders invisible. This is the regression.
    make_fat_dir(joinpath(root, ".big"), 40, 40) # ≫ the budget used below
    mkpath(joinpath(root, "zzz_folder"))
    write(joinpath(root, "notebook.jl"), "### A Pluto.jl notebook ###\n# v0.19.0\n")
    write(joinpath(root, "plain.jl"), "x = 1\n")
    write(joinpath(root, "readme.md"), "hi\n")

    # a budget far smaller than `.big`: every top-level entry must still make it into the listing
    @testset "a fat subfolder does not starve its siblings" begin
        listing = Pluto._workspace_entries(root; budget=Ref(40))
        @test names_of(listing) == [".big", "zzz_folder", "notebook.jl", "plain.jl", "readme.md"]
        # directories first, then files — the usual file-browser order
        types = [d["type"] for d in nodes(listing)]
        @test types[1:2] == ["dir", "dir"]
        @test find_node(listing, "notebook.jl")["type"] == "notebook" # has the Pluto header
        @test find_node(listing, "plain.jl")["type"] == "file"        # .jl, but not a notebook
        @test find_node(listing, "readme.md")["type"] == "file"
    end

    @testset "the budget cuts the deeper levels, and says so" begin
        listing = Pluto._workspace_entries(root; budget=Ref(40))
        big = find_node(listing, ".big")
        # `.big` got listed, but not exhaustively — and the cut is marked, not silent
        @test 0 < length(big["children"]) < 40 + 40
        @test last(names_of(big["children"])) == "…"
        @test last(nodes(big["children"]))["type"] == "truncated"
        # `zzz_folder` was queued but never opened, so it is marked unlisted rather than read.
        # It happens to be empty — we accept saying "not listed" about an empty folder in exchange
        # for not spending a readdir per folder once the budget is gone.
        @test names_of(find_node(listing, "zzz_folder")["children"]) == ["…"]
        # the root itself is always listed in full, so it never carries a marker
        @test "truncated" ∉ [d["type"] for d in nodes(listing)]
    end

    @testset "an exhausted budget stops the walk instead of reading on" begin
        # every folder is either listed or marked — never silently empty
        listing = Pluto._workspace_entries(root; budget=Ref(40))
        function check(ns)
            for d in nodes(ns)
                d["type"] == "dir" || continue
                @test !isempty(d["children"]) # listed, or carrying the marker
                check(d["children"])
            end
        end
        check(listing)
    end

    @testset "a generous budget lists everything" begin
        listing = Pluto._workspace_entries(root; budget=Ref(10_000))
        big = find_node(listing, ".big")
        @test length(big["children"]) == 80 # 40 subfolders + 40 files, no marker
        @test "truncated" ∉ [d["type"] for d in nodes(big["children"])]
        @test length(find_node(big["children"], "sub1")["children"]) == 40
    end

    @testset "skiplist and depth limit" begin
        for skipped in ("node_modules", ".git", ".venv", "__pycache__")
            mkpath(joinpath(root, skipped, "junk"))
        end
        listing = Pluto._workspace_entries(root; budget=Ref(10_000))
        @test isempty(intersect(names_of(listing), ["node_modules", ".git", ".venv", "__pycache__"]))

        deep = joinpath(root, "d1", "d2", "d3")
        mkpath(deep)
        write(joinpath(deep, "deep.txt"), "")
        shallow = Pluto._workspace_entries(root; depth=1, budget=Ref(10_000))
        d1 = find_node(shallow, "d1")
        @test names_of(d1["children"]) == ["d2"]     # depth=1 → two levels of entries
        @test isempty(find_node(d1["children"], "d2")["children"])
    end

    # `depth=0` is what the hub's sidebar asks for: one folder, nothing below it. The budget then
    # bounds a single folder rather than a whole tree, so the size of the workspace stops mattering.
    @testset "depth=0 lists one folder and stops" begin
        listing = Pluto._workspace_entries(root; depth=0, budget=Ref(10_000))
        @test issubset([".big", "zzz_folder", "notebook.jl"], names_of(listing))
        for d in nodes(listing)
            d["type"] == "dir" && @test isempty(d["children"])
        end
        # each folder is asked for on its own, so a tree of any depth is reachable one step at a time
        deep = joinpath(root, "e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8")
        mkpath(deep)
        write(joinpath(deep, "buried.jl"), "### A Pluto.jl notebook ###\n")
        at = root
        for step in ("e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8")
            here = Pluto._workspace_entries(at; depth=0)
            @test step ∈ names_of(here)
            at = joinpath(at, step)
        end
        # 8 levels down — past anything the recursive walk's depth limit would have reached
        @test find_node(Pluto._workspace_entries(at; depth=0), "buried.jl")["type"] == "notebook"
    end

    @testset "the listing endpoint stays inside the workspace" begin
        @test Pluto._within(root, root)
        @test Pluto._within(root, joinpath(root, "zzz_folder"))
        @test Pluto._within(root, joinpath(root, "a", "b", "c"))
        @test !Pluto._within(root, dirname(root))
        @test !Pluto._within(root, "/etc")
        # `..` is resolved by tamepath before the check, so it cannot escape
        @test !Pluto._within(root, Pluto.tamepath(joinpath(root, "..", "..")))
        # a sibling whose name merely starts with the root's is not inside it
        @test !Pluto._within(root, root * "_other")
    end

    # Confinement is a question about path components, so `_within` asks it with `splitpath` rather
    # than by comparing strings — that is what keeps `/ws_other` out of `/ws`, and it leaves every
    # separator question to Base. Before that, the check compared against `root * "/"`, which on
    # Windows — where `tamepath` and `joinpath` produce `\` — rejected every folder below the root,
    # so the sidebar could not expand anything.
    @testset "confinement compares path components" begin
        @test Pluto._within("/ws", "/ws/a")
        @test Pluto._within("/ws/", "/ws")        # a trailing separator on the root changes nothing
        @test Pluto._within("/ws", "/ws//a/b")    # nor do repeated ones inside the path
        @test !Pluto._within("/ws", "/ws_other")  # a name that merely starts the same
        @test !Pluto._within("/ws", "/")
        if Sys.iswindows()
            # the shape that actually reaches the endpoint on Windows
            win = "C:\\Users\\me\\ws"
            @test Pluto._within(win, win)
            @test Pluto._within(win, "C:\\Users\\me\\ws\\sub\\deeper")
            @test Pluto._within("C:\\", "C:\\Users")
            @test !Pluto._within(win, "C:\\Users\\me")
            @test !Pluto._within(win, "C:\\Users\\me\\ws_other")
        else
            # `\` is an ordinary character in a unix filename, not a separator: `/ws\x` names an
            # entry in `/`, not one inside `/ws`, and must not be treated as confined
            @test !Pluto._within("/ws", "/ws\\x")
        end
    end

    # The folder picker's breadcrumbs. They are built here rather than in the browser because the
    # browser would have to know what a path looks like on the server's platform — splitting one on
    # "/" turned `C:\\Users\\me` into a single bogus crumb, and rejoining it put a `/` in front.
    @testset "breadcrumbs come apart and back together" begin
        crumbs = [Dict(c) for c in Pluto._path_crumbs(joinpath(root, "a", "b"))]
        @test [c["name"] for c in crumbs][end-1:end] == ["a", "b"]
        @test crumbs[end]["path"] == joinpath(root, "a", "b")
        # every crumb is a real prefix of the path, and one you can browse to
        @test all(Pluto._within(crumbs[1]["path"], c["path"]) for c in crumbs)
        @test crumbs[end-1]["path"] == joinpath(root, "a")
        # the first crumb is the root of the filesystem, which is where the picker starts
        @test Dict(Pluto._path_crumbs(homedir())[1])["path"] == splitpath(homedir())[1]
    end

    @testset "a missing folder is empty, not an error" begin
        @test isempty(Pluto._workspace_entries(joinpath(root, "nope")))
    end
end
