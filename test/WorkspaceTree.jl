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

    @testset "a missing folder is empty, not an error" begin
        @test isempty(Pluto._workspace_entries(joinpath(root, "nope")))
    end
end
