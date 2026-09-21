# Keeping the program itself off the cluster's filesystems.
#
# On a cluster, julia and the depot live on a network filesystem (NFS, BeeGFS, Lustre…), and a
# process does not read its program once: the binary, libjulia, the system image and every package
# image are memory-MAPPED, and a page is fetched from the file server the first time it is touched,
# and again whenever the kernel has dropped it to make room. Measured on a node: a hub maps 843 MB
# of code from BeeGFS, and 39 MB of it is in memory. So any code path that has not run lately is a
# read from the file server, at the moment it runs. When that filesystem hangs — they do, for
# seconds to minutes — the thread that touched the page sits in the kernel.
#
# One stuck thread is the whole process, because of the garbage collector. A collection stops every
# thread, and a thread that is stuck in the kernel (in a page fault, or in any ordinary system call:
# every file function in Base is one) cannot be stopped, so the collector waits for it, and every
# other thread waits at its safepoint for the collector. Reproduced: one thread blocked 8 s in a
# plain foreign call while another allocates, and an otherwise idle serving thread stalls for 8.2 s;
# with the same call made `gc_safe` it stalls 0.26 s. This is why moving file I/O to other threads
# (Offload.jl) keeps the serving thread free only until the next collection.
#
# It is worse than "until the next collection": the fault can land on the serving thread itself, or
# on a collector thread with the world already stopped.
#
# For the program's own pages the cure is old and simple: read them all once, at start, and lock
# them into memory (`mlock`), as databases and real-time programs do. Details that matter:
#   • Only mappings of files on a network filesystem, recognised by the DEVICE NUMBER that
#     /proc/self/maps prints, matched against /proc/self/mountinfo. Never by asking about the path:
#     that would be a call to the very filesystem this is about.
#   • Read-only and executable mappings are locked. Writable private ones (a library's data segment)
#     are only read once: locking those would copy them into anonymous memory, per process.
#   • Where the system allows little locked memory (RLIMIT_MEMLOCK is a few MB on many clusters;
#     ones with InfiniBand set it to unlimited) the pages are still read once. Most of them were
#     never touched rather than evicted, so that alone removes most of the exposure.
#   • Once, before the server announces itself. A hang during it delays the start; a repeat later
#     could sit inside the kernel holding the process's memory map while the collector needs it.
#   • The total is capped at a tenth of the job's memory limit (cgroup), and at PIN_CODE_LIMIT.
# Linux only (that is where the clusters are, and where /proc exists). `SPACESTATION_PIN_CODE=0`
# turns it off.

const _NETWORK_FILESYSTEMS = Set(["nfs", "nfs4", "beegfs", "lustre", "gpfs", "cifs", "smb3", "ceph", "afs", "9p", "panfs", "pvfs2", "glusterfs", "fuse.sshfs", "fuse.glusterfs", "fuse.beegfs"])

"The most this process will lock, whatever the job's memory limit says: a guard against a surprise, not a budget (a server maps well under 1 GB)."
const PIN_CODE_LIMIT = Ref(4 * 2^30)

"Device numbers (`major:minor`, as /proc/self/maps prints them) of the mounted network filesystems, from `/proc/self/mountinfo`-style text."
function _network_devices(mountinfo::AbstractString)::Set{String}
    devices = Set{String}()
    for line in eachline(IOBuffer(mountinfo))
        halves = split(line, " - "; limit=2)
        length(halves) == 2 || continue
        left = split(halves[1]); right = split(halves[2])
        (length(left) >= 3 && !isempty(right)) || continue
        right[1] in _NETWORK_FILESYSTEMS && push!(devices, _device_key(left[3]))
    end
    devices
end

# maps prints the device in hex ("00:2d"), mountinfo in decimal ("0:45")
_device_key(dev::AbstractString; base::Integer=10) = (p = split(dev, ":"); length(p) == 2 || return String(dev);
    a = tryparse(Int, p[1]; base); b = tryparse(Int, p[2]; base); (a === nothing || b === nothing) ? String(dev) : "$a:$b")

"File-backed readable mappings on those devices, from `/proc/self/maps`-style text: `(start, stop, writable)`."
function _network_mappings(maps::AbstractString, devices::Set{String})::Vector{Tuple{UInt,UInt,Bool}}
    regions = Tuple{UInt,UInt,Bool}[]
    for line in eachline(IOBuffer(maps))
        fields = split(line; limit=6)
        length(fields) >= 5 || continue
        perms = fields[2]
        startswith(perms, "r") || continue
        fields[5] == "0" && continue                       # inode 0: anonymous
        _device_key(fields[4]; base=16) in devices || continue
        bounds = split(fields[1], "-")
        length(bounds) == 2 || continue
        a = tryparse(UInt, bounds[1]; base=16); b = tryparse(UInt, bounds[2]; base=16)
        (a === nothing || b === nothing || b <= a) && continue
        push!(regions, (a, b, length(perms) >= 2 && perms[2] == 'w'))
    end
    regions
end

_mlock(addr::UInt, len::UInt) = ccall(:mlock, Cint, (Ptr{Cvoid}, Csize_t), Ptr{Cvoid}(addr), len)

"Read one byte of every page: the page is fetched now, and stays while memory is not short."
function _prefault(addr::UInt, len::UInt)
    page = UInt(4096)
    acc = 0x00
    for p in addr:page:(addr + len - 1)
        acc ⊻= unsafe_load(Ptr{UInt8}(p))
    end
    Cint(acc & 0x00) # always 0; `acc` keeps the loads from being optimised away
end

"A tenth of the job's memory limit (cgroup v2, then v1), or `nothing` when there is none."
function _job_memory_budget()::Union{Nothing,Int}
    for path in ("/sys/fs/cgroup" * _own_cgroup() * "/memory.max", "/sys/fs/cgroup/memory" * _own_cgroup(; controller="memory") * "/memory.limit_in_bytes")
        try
            v = tryparse(Int, strip(read(path, String)))
            (v !== nothing && 0 < v < 2^50) && return v ÷ 10
        catch
        end
    end
    nothing
end
function _own_cgroup(; controller::String="")::String
    try
        for line in eachline("/proc/self/cgroup")
            parts = split(line, ":"; limit=3)
            length(parts) == 3 || continue
            (isempty(controller) ? parts[1] == "0" : controller in split(parts[2], ",")) && return String(parts[3])
        end
    catch
    end
    ""
end

pin_code_enabled() = Sys.islinux() && get(ENV, "SPACESTATION_PIN_CODE", "1") != "0"

"""
Bring this process's code that is mapped from a network filesystem into memory, and lock what may be
locked. Returns `(locked_bytes, read_bytes)`. Meant to run once, before the server announces itself.
Never throws.
"""
function pin_network_code!(; lock_region=_mlock, read_region=_prefault, budget=_job_memory_budget())::Tuple{Int,Int}
    pin_code_enabled() || return (0, 0)
    regions = try
        _network_mappings(read("/proc/self/maps", String), _network_devices(read("/proc/self/mountinfo", String)))
    catch
        return (0, 0)
    end
    limit = budget === nothing ? PIN_CODE_LIMIT[] : min(PIN_CODE_LIMIT[], budget)
    _pin_regions(regions, limit; lock_region, read_region)
end

"The policy, apart from where the regions come from: lock the read-only ones while the limit allows and the system agrees, read the rest."
function _pin_regions(regions, limit::Integer; lock_region, read_region)::Tuple{Int,Int}
    locked = 0; touched = 0
    for (a, b, writable) in regions
        len = UInt(b - a)
        try
            if !writable && locked + Int(len) <= limit && lock_region(a, len) == 0
                locked += Int(len)
            else
                read_region(a, len); touched += Int(len)
            end
        catch
        end
    end
    (locked, touched)
end

const _pin_done = Threads.Atomic{Bool}(false)
"Once per process: see the top of this file."
function keep_code_pinned!()
    pin_code_enabled() || return nothing
    Threads.atomic_cas!(_pin_done, false, true) == false || return nothing
    locked, touched = pin_network_code!()
    (locked + touched) > 0 && @info "SpaceStation: this program is mapped from a network filesystem; $(locked ÷ 2^20) MB of it is now locked in memory and $(touched ÷ 2^20) MB read ahead, so that running it never waits on that filesystem"
    nothing
end
