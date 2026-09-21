using Test
import SpaceStation as Pluto

@testset "Pinning program code mapped from network filesystems" begin
    mountinfo = """
    22 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
    40 22 0:35 / /data/homezvol2/dale rw,relatime shared:20 - nfs4 10.0.0.1:/homezvol2/dale rw,vers=4.2
    41 22 0:45 / /dfs6b rw,relatime shared:21 - beegfs beegfs_dfs6b rw
    42 22 0:46 / /mnt/with\\040space rw - lustre fs rw
    43 22 259:2 / /tmp rw - xfs /dev/nvme1n1p1 rw
    """
    devices = Pluto._network_devices(mountinfo)
    @test devices == Set(["0:35", "0:45", "0:46"])            # by device, never by asking about a path

    # maps prints devices in hex: 0:45 is 00:2d, 0:35 is 00:23
    maps = """
    7f0000000000-7f0000200000 r-xp 00000000 00:2d 123 /dfs6b/pub/x/lib/julia/sys.so
    7f0000200000-7f0000300000 rw-p 00200000 00:2d 123 /dfs6b/pub/x/lib/julia/sys.so
    7f0000300000-7f0000400000 ---p 00300000 00:2d 123 /dfs6b/pub/x/lib/julia/sys.so
    7f0000400000-7f0000500000 r--p 00000000 08:01 9 /usr/lib64/libc.so.6
    7f0000500000-7f0000600000 r--p 00000000 103:02 7 /tmp/depot/compiled/v1.12/A/b.so
    7f0000600000-7f0000700000 r--p 00000000 00:23 5 /data/homezvol2/dale/a dir/d.so (deleted)
    7f0000800000-7f0000900000 rw-p 00000000 00:00 0
    7f0000900000-7f0000a00000 rw-p 00000000 00:00 0 [heap]
    """
    @test Pluto._network_mappings(maps, devices) == [
        (0x7f0000000000, 0x7f0000200000, false),
        (0x7f0000200000, 0x7f0000300000, true),                # a data segment: read, never locked
        (0x7f0000600000, 0x7f0000700000, false),               # spaces and "(deleted)" in the path do not matter
    ]

    MB = 2^20
    regions = Pluto._network_mappings(maps, devices)
    function policy(limit; lockable=true)
        locked = UInt[]; read = UInt[]
        totals = Pluto._pin_regions(regions, limit; lock_region=(a, len) -> lockable ? (push!(locked, a); Cint(0)) : Cint(-1), read_region=(a, len) -> (push!(read, a); Cint(0)))
        locked, read, totals
    end
    l, r, totals = policy(100MB)
    @test l == [0x7f0000000000, 0x7f0000600000] && r == [0x7f0000200000]   # the writable one is only read
    @test totals == (3MB, 1MB)
    l, r, _ = policy(100MB; lockable=false)
    @test isempty(l) && length(r) == 3                       # no permission to lock: everything is still read once
    l, r, _ = policy(2MB)
    @test l == [0x7f0000000000] && length(r) == 2            # over the job's budget: read, not locked
    @test Pluto._pin_regions(regions, 100MB; lock_region=(a, len) -> error("boom"), read_region=(a, len) -> error("boom")) == (0, 0) # never throws

    if Sys.islinux()
        # /proc files have no size: one bulk read can return only the first chunk (5 of 833 mounts, on a real node)
        @test count(==('\n'), Pluto._read_proc("/proc/self/maps")) + 1 == length(readlines("/proc/self/maps")) > 10
        @test ncodeunits(Pluto._read_proc("/proc/self/mountinfo")) >= ncodeunits(read("/proc/self/mountinfo", String))
        # a real file mapping, one page of file and two pages of mapping: asking never faults, touching would
        path, io = mktemp(); write(io, zeros(UInt8, 100)); close(io)
        fd = ccall(:open, Cint, (Cstring, Cint), path, 0)
        page = Int(ccall(:getpagesize, Cint, ()))
        addr = ccall(:mmap, Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int64), C_NULL, 2page, 1, 2, fd, 0)
        @test addr != Ptr{Cvoid}(-1)
        @test Pluto._prefault(UInt(addr), UInt(2page)) isa Cint    # returns, whatever the kernel says about the hole
        ccall(:munmap, Cint, (Ptr{Cvoid}, Csize_t), addr, 2page); ccall(:close, Cint, (Cint,), fd); rm(path)
    end
    if Sys.islinux()
        locked, touched = Pluto.pin_network_code!(; lock_region=(a, len) -> Cint(-1), read_region=(a, len) -> Cint(0))
        @test locked == 0 && touched >= 0                    # the real maps of this machine, whatever they are
        withenv("SPACESTATION_PIN_CODE" => "0") do
            @test Pluto.pin_network_code!(; lock_region=(a, len) -> error("disabled")) == (0, 0)
        end
    else
        @test Pluto.pin_network_code!() == (0, 0)            # no /proc: nothing to do, nothing thrown
    end
    @test Pluto.keep_code_pinned!() === nothing
end

@testset "the job's memory limit is found on an ancestor cgroup" begin
    mktempdir() do root
        leaf = joinpath(root, "slurm", "uid_1", "job_9", "step_0")
        mkpath(leaf)
        write(joinpath(leaf, "memory.max"), "max\n")
        write(joinpath(root, "slurm", "uid_1", "job_9", "memory.max"), "$(40 * 2^30)\n")
        write(joinpath(root, "slurm", "memory.max"), "$(200 * 2^30)\n")
        @test Pluto._job_memory_budget(; root, group="/slurm/uid_1/job_9/step_0", group_v1="") == 4 * 2^30   # the job's 40 GB, not the leaf's "max"
        @test Pluto._job_memory_budget(; root, group="/", group_v1="") === nothing
        @test Pluto._job_memory_budget(; root, group="/not/there", group_v1="") === nothing
        v1 = joinpath(root, "memory", "slurm", "job_9"); mkpath(v1)
        write(joinpath(v1, "memory.limit_in_bytes"), "$(10 * 2^30)\n")
        @test Pluto._job_memory_budget(; root, group="", group_v1="/slurm/job_9") == 2^30
    end
end
