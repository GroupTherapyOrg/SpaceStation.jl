# PTYWindows.jl — ConPTY-backed PTY for the SpaceStation integrated terminal.
#
# The Windows counterpart to PTY.jl (which is openpty()/posix_spawnp() and Unix-only).
# Windows has no openpty; its pseudo-console API is ConPTY (CreatePseudoConsole,
# introduced in Windows 10 1809 / Server 2019), the same primitive VS Code's integrated
# terminal uses under the hood (via node-pty). This module drives it directly through
# kernel32 with `ccall`, exposing the exact same surface as PTY.jl — pty_spawn, pty_write,
# pty_resize!, pty_close!, pty_alive, and a `pty.output` Channel{Vector{UInt8}} — so
# CollabTerminal.jl works identically on both platforms. Exactly one of PTY.jl /
# PTYWindows.jl is included, chosen by `@static Sys.iswindows()` in SpaceStation.jl.
#
# Wiring (mirrors Microsoft's EchoCon sample):
#   • Two anonymous pipes: one we WRITE keystrokes into, one we READ shell output from.
#   • CreatePseudoConsole(size, in_read, out_write) attaches the ConPTY to the PTY ends. It is the
#     one in the console host we ship (`conpty/`, see "Which console host" below), not the one in
#     Windows.
#   • CreateProcessW with a PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE attribute launches the
#     shell attached to that console; conhost translates its console calls into the VT/ANSI
#     bytes xterm.js expects and writes them to our output pipe.
#
# Output is drained by a cooperative @async reader that polls PeekNamedPipe (non-blocking,
# works on anonymous pipes) and ReadFiles only what's already buffered — so it never blocks
# the Julia scheduler and needs no dedicated OS thread per terminal.

# ── Win32 constants (x64) ──

const _EXTENDED_STARTUPINFO_PRESENT       = UInt32(0x00080000)
const _CREATE_UNICODE_ENVIRONMENT         = UInt32(0x00000400)
const _PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = Csize_t(0x00020016)
const _WAIT_OBJECT_0                       = UInt32(0x00000000)
const _STARTF_USESTDHANDLES                = UInt32(0x00000100)
const _INVALID_HANDLE                      = Ptr{Cvoid}(typemax(UInt))
# STARTUPINFOEXW is STARTUPINFOW (104 bytes on x64) + lpAttributeList pointer → 112 bytes.
const _STARTUPINFOEXW_SIZE = 112
const _STARTUPINFOW_DWFLAGS_OFFSET = 60    # dwFlags within STARTUPINFOW (x64)
const _STARTUPINFOEXW_ATTRLIST_OFFSET = 104
const _PROCESS_INFORMATION_SIZE = 24  # HANDLE hProcess; HANDLE hThread; DWORD pid; DWORD tid

"Null-terminated UTF-16 for a Win32 wide-string argument."
_cwstr(s::AbstractString) = push!(transcode(UInt16, String(s)), UInt16(0))

# ── Which console host ──
#
# Between a program in a terminal and us sits a console host: it turns what the program does with
# its console into the bytes a terminal reads, and the bytes a terminal sends into the program's
# input. Windows has one built in (`conhost.exe`, reached through kernel32), and it is as old as the
# Windows it came with. The one in every Windows 10 never passes on a program's request for the
# mouse and drops the mouse reports a terminal sends: with Claude Code, vim, or anything else that
# takes the mouse, the wheel did nothing and nothing could be clicked, and no setting changes that.
#
# So a terminal is started on the console host we ship: Microsoft's own `conpty.dll` and the
# `OpenConsole.exe` beside it, from the Windows Terminal project (`conpty/README.md` says which
# version and where from). VS Code, Windows Terminal, WezTerm and Zed do the same, for the same
# reason; with it a terminal behaves alike on every Windows from 10 1809 on. `conpty.dll` exports the
# three calls of kernel32 under a `Conpty` prefix, with the same arguments, and its handle is the
# same kind of handle (it goes into the same process attribute).
#
# The one in Windows is still the fallback, when ours is not there or does not load (and a warning
# says so, once), and `SPACESTATION_INBOX_CONPTY=1` asks for it.

"The files of the console host we ship, with the SHA-256 each must have (`conpty/README.md`)."
const CONPTY_BUNDLE_SHA256 = (
    "conpty.dll" => "3319b484b80bb53d1f4d0a9eb0ea60fd0f61da69db7280ca43b84215f19245ff",
    "OpenConsole.exe" => "7f68c840226505004215c0b82d4e502c24b5bc3f4b93c4baaaa19bd679c0def8",
)

"A console host, as the calls we make into it."
struct ConsoleHost
    kind::Symbol            # :bundled (conpty.dll, and the OpenConsole.exe beside it) or :inbox (Windows' own)
    create::Ptr{Cvoid}      # CreatePseudoConsole
    resize::Ptr{Cvoid}      # ResizePseudoConsole
    close::Ptr{Cvoid}       # ClosePseudoConsole
    release::Ptr{Cvoid}     # ConptyReleasePseudoConsole, or C_NULL: Windows' own has none
end

"Where the console host we ship lies. Found when it is asked for, never at compile time: an installed package can be moved."
function _conpty_bundle_dir()
    root = try Base.pkgdir(@__MODULE__) catch; nothing end
    joinpath(root === nothing ? (@__DIR__) : joinpath(root, "src", "webserver"), "conpty", "win-x64")
end

_proc_address(lib::Ptr{Cvoid}, name::String) =
    ccall((:GetProcAddress, "kernel32"), Ptr{Cvoid}, (Ptr{Cvoid}, Cstring), lib, name)

"The console host of that kind, or `nothing` when it cannot be had."
function _load_console_host(kind::Symbol)::Union{Nothing,ConsoleHost}
    if kind === :bundled
        Sys.ARCH === :x86_64 || return nothing
        dir = _conpty_bundle_dir()
        dll = joinpath(dir, "conpty.dll")
        # both or neither: a conpty.dll without its OpenConsole.exe quietly starts Windows' own host
        (isfile(dll) && isfile(joinpath(dir, "OpenConsole.exe"))) || return nothing
        lib = ccall((:LoadLibraryW, "kernel32"), Ptr{Cvoid}, (Ptr{UInt16},), _cwstr(dll))
        lib == C_NULL && return nothing
        calls = (_proc_address(lib, "ConptyCreatePseudoConsole"), _proc_address(lib, "ConptyResizePseudoConsole"),
                 _proc_address(lib, "ConptyClosePseudoConsole"))
        any(==(C_NULL), calls) && return nothing
        ConsoleHost(:bundled, calls..., _proc_address(lib, "ConptyReleasePseudoConsole"))
    else
        lib = ccall((:GetModuleHandleW, "kernel32"), Ptr{Cvoid}, (Ptr{UInt16},), _cwstr("kernel32.dll"))
        lib == C_NULL && return nothing
        calls = (_proc_address(lib, "CreatePseudoConsole"), _proc_address(lib, "ResizePseudoConsole"),
                 _proc_address(lib, "ClosePseudoConsole"))
        any(==(C_NULL), calls) && return nothing   # before Windows 10 1809
        ConsoleHost(:inbox, calls..., C_NULL)
    end
end

# Filled when a terminal is first started, never while the package is compiled: these are addresses
# in this process.
const _CONSOLE_HOSTS = Dict{Symbol,Union{Nothing,ConsoleHost}}()

"""
The console host to start a terminal on: the one we ship, or Windows' own when ours cannot be had
or `SPACESTATION_INBOX_CONPTY=1` asks for it. `want` (`:bundled`, `:inbox`) names one, for the tests.
"""
function _console_host(want::Symbol=:auto)::Union{Nothing,ConsoleHost}
    want === :auto && (want = get(ENV, "SPACESTATION_INBOX_CONPTY", "") == "1" ? :inbox : :bundled)
    first_ask = !haskey(_CONSOLE_HOSTS, want)
    host = get!(() -> _load_console_host(want), _CONSOLE_HOSTS, want)
    if host === nothing && want === :bundled
        first_ask && @warn "SpaceStation's own console host could not be loaded; terminals use the one in Windows, in which (on Windows 10) the mouse does not reach programs" dir=_conpty_bundle_dir()
        return _console_host(:inbox)
    end
    host
end

# ── PTY struct (same interface fields as PTY.jl's) ──

mutable struct PTY
    console::ConsoleHost     # the console host this one was made by: it is resized and closed by the same
    hpc::Ptr{Cvoid}          # HPCON (pseudo-console handle)
    input_write::Ptr{Cvoid}  # we write keystrokes here → shell stdin
    output_read::Ptr{Cvoid}  # we read shell output here
    hprocess::Ptr{Cvoid}
    hthread::Ptr{Cvoid}
    child_pid::Cint
    rows::Int
    cols::Int
    alive::Bool
    output::Channel{Vector{UInt8}}
    reader_task::Task
    on_data::Union{Function, Nothing}
end

# ── Small Win32 helpers ──

_last_error() = ccall((:GetLastError, "kernel32"), UInt32, ())

function _close_handle(h::Ptr{Cvoid})
    (h == C_NULL || h == _INVALID_HANDLE) && return
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), h)
    nothing
end

function _create_pipe()
    rd = Ref{Ptr{Cvoid}}(C_NULL)
    wr = Ref{Ptr{Cvoid}}(C_NULL)
    ok = ccall((:CreatePipe, "kernel32"), Cint,
               (Ptr{Ptr{Cvoid}}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, UInt32),
               rd, wr, C_NULL, UInt32(0))
    ok == 0 && error("CreatePipe failed: error=$(_last_error())")
    (rd[], wr[])
end

# Pack a COORD {SHORT X=cols; SHORT Y=rows} into the DWORD it occupies by value in the
# x64 calling convention — sidesteps by-value struct ABI concerns for CreatePseudoConsole.
_coord(rows::Integer, cols::Integer) = UInt32(cols % UInt16) | (UInt32(rows % UInt16) << 16)

"Quote one argv element per CommandLineToArgvW's rules (spaces, quotes, trailing backslashes)."
function _win_quote(arg::AbstractString)
    s = String(arg)
    (!isempty(s) && !occursin(r"[ \t\"]", s)) && return s
    buf = IOBuffer()
    write(buf, '"')
    bs = 0
    for c in s
        if c == '\\'
            bs += 1
        elseif c == '"'
            write(buf, repeat("\\", 2bs + 1)); write(buf, '"'); bs = 0
        else
            write(buf, repeat("\\", bs)); write(buf, c); bs = 0
        end
    end
    write(buf, repeat("\\", 2bs)); write(buf, '"')
    String(take!(buf))
end

_win_cmdline(argv::Vector{String}) = join(_win_quote.(argv), ' ')

"Build a CREATE_UNICODE_ENVIRONMENT block: sorted, each `K=V` NUL-terminated, a trailing NUL."
function _env_block(extra::Dict{String,String})
    merged = Dict{String,String}()
    for (k, v) in ENV; merged[String(k)] = String(v); end
    for (k, v) in extra; merged[k] = v; end
    block = UInt16[]
    for k in sort!(collect(keys(merged)); by = uppercase)
        append!(block, transcode(UInt16, string(k, "=", merged[k])))
        push!(block, UInt16(0))
    end
    push!(block, UInt16(0))
    block
end

# ── Background reader ──
#
# Cooperative, no dedicated OS thread: PeekNamedPipe tells us how many bytes are buffered
# (and, by returning FALSE, when the write end has closed = shell gone); ReadFile then reads
# only that much, so it never blocks. Idle polling yields to the scheduler every few ms.

function _start_pty_reader(pty::PTY)
    @async begin
        buf   = Vector{UInt8}(undef, 8192)
        avail = Ref{UInt32}(0)
        nread = Ref{UInt32}(0)
        try
            while pty.alive
                ok = ccall((:PeekNamedPipe, "kernel32"), Cint,
                           (Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{UInt32}, Ptr{UInt32}, Ptr{UInt32}),
                           pty.output_read, C_NULL, UInt32(0), C_NULL, avail, C_NULL)
                if ok == 0            # broken pipe → the shell (and its ConPTY) is gone
                    pty.alive = false
                    break
                end
                if avail[] == 0
                    sleep(0.008)      # idle: yield to the scheduler (~8ms echo latency)
                    continue
                end
                want = min(UInt32(length(buf)), avail[])
                rok = GC.@preserve buf ccall((:ReadFile, "kernel32"), Cint,
                    (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}),
                    pty.output_read, pointer(buf), want, nread, C_NULL)
                if rok == 0 || nread[] == 0
                    pty.alive = false
                    break
                end
                put!(pty.output, buf[1:nread[]])
                pty.on_data !== nothing && pty.on_data()
            end
        catch e
            e isa InvalidStateException || e isa Base.IOError ||
                (pty.alive && @debug "PTY reader error" exception=(e, catch_backtrace()))
        end
        pty.alive = false
        # Close the output channel so consumers iterating `for data in pty.output` terminate —
        # without this, a naturally-exiting shell leaves its pump task blocked forever (clients
        # never told, handles never cleaned up). Mirrors PTY.jl.
        try close(pty.output) catch end
    end
end

# ── Spawn ──

"""
    pty_spawn(cmd::Vector{String}; rows=24, cols=80, env=nothing, dir=nothing) → PTY

Spawn `cmd` attached to a new ConPTY. `dir` becomes the child's working directory
(CreateProcessW's lpCurrentDirectory). Output is delivered via `pty.output`; write input
via `pty_write`. `console` names the console host (`:bundled`, `:inbox`); left alone it is the one
we ship (see "Which console host").
"""
function pty_spawn(cmd::Vector{String}; rows::Int=24, cols::Int=80,
                   env::Union{Dict{String,String}, Nothing}=nothing,
                   dir::Union{String, Nothing}=nothing,
                   console::Symbol=:auto)
    isempty(cmd) && error("pty_spawn: cmd must not be empty")
    host = _console_host(console)
    host === nothing && error("no pseudo-console on this Windows (needs Windows 10 1809+ / Server 2019+)")

    (in_rd,  in_wr)  = _create_pipe()   # shell reads stdin from in_rd; we write to in_wr
    (out_rd, out_wr) = _create_pipe()   # shell writes stdout to out_wr; we read from out_rd

    # Create the pseudo-console attached to the PTY ends of the pipes.
    hpc = Ref{Ptr{Cvoid}}(C_NULL)
    create(h::ConsoleHost) = ccall(h.create, Clong,
               (UInt32, Ptr{Cvoid}, Ptr{Cvoid}, UInt32, Ptr{Ptr{Cvoid}}),
               _coord(rows, cols), in_rd, out_wr, UInt32(0), hpc)
    hr = create(host)
    if hr < 0 && host.kind === :bundled && console === :auto
        # ours would not start (its OpenConsole.exe kept from running, say): a terminal on Windows'
        # own console host is better than no terminal
        inbox = _console_host(:inbox)
        if inbox !== nothing
            @warn "SpaceStation's own console host did not start; this terminal uses the one in Windows" hresult=string(reinterpret(UInt32, Int32(hr)); base=16)
            host = inbox
            hpc[] = C_NULL
            hr = create(host)
        end
    end
    if hr < 0
        foreach(_close_handle, (in_rd, in_wr, out_rd, out_wr))
        error("CreatePseudoConsole failed: HRESULT=0x$(string(reinterpret(UInt32, Int32(hr)); base=16)) " *
              "(needs Windows 10 1809+ / Server 2019+)")
    end
    # ConPTY dup'd the PTY ends into conhost; drop our copies. Keep in_wr and out_rd.
    _close_handle(in_rd); _close_handle(out_wr)

    # PROC_THREAD_ATTRIBUTE_LIST carrying the pseudo-console (two-call size idiom).
    sz = Ref{Csize_t}(0)
    ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
          (Ptr{Cvoid}, UInt32, UInt32, Ptr{Csize_t}), C_NULL, UInt32(1), UInt32(0), sz)
    attr = Vector{UInt8}(undef, sz[])

    si = zeros(UInt8, _STARTUPINFOEXW_SIZE)
    pi = zeros(UInt8, _PROCESS_INFORMATION_SIZE)
    cmdline   = _cwstr(_win_cmdline(cmd))                       # writable wide command line
    cwstr_dir = dir === nothing ? UInt16[] : _cwstr(dir)
    flags     = _EXTENDED_STARTUPINFO_PRESENT
    envblock  = UInt16[]
    if env !== nothing
        envblock = _env_block(env)
        flags |= _CREATE_UNICODE_ENVIRONMENT
    end

    ret = GC.@preserve attr si pi cmdline cwstr_dir envblock begin
        ok = ccall((:InitializeProcThreadAttributeList, "kernel32"), Cint,
                   (Ptr{UInt8}, UInt32, UInt32, Ptr{Csize_t}), attr, UInt32(1), UInt32(0), sz)
        ok == 0 && (ccall(host.close, Cvoid, (Ptr{Cvoid},), hpc[]);
                    _close_handle(in_wr); _close_handle(out_rd);
                    error("InitializeProcThreadAttributeList failed: error=$(_last_error())"))
        ok2 = ccall((:UpdateProcThreadAttribute, "kernel32"), Cint,
                    (Ptr{UInt8}, UInt32, Csize_t, Ptr{Cvoid}, Csize_t, Ptr{Cvoid}, Ptr{Csize_t}),
                    attr, UInt32(0), _PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                    hpc[], Csize_t(sizeof(Ptr{Cvoid})), C_NULL, C_NULL)
        ok2 == 0 && (ccall((:DeleteProcThreadAttributeList, "kernel32"), Cvoid, (Ptr{UInt8},), attr);
                     ccall(host.close, Cvoid, (Ptr{Cvoid},), hpc[]);
                     _close_handle(in_wr); _close_handle(out_rd);
                     error("UpdateProcThreadAttribute failed: error=$(_last_error())"))

        # STARTUPINFOEXW: cb = full extended size, and lpAttributeList at its trailing slot.
        unsafe_store!(Ptr{UInt32}(pointer(si)), UInt32(_STARTUPINFOEXW_SIZE))
        unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(si) + _STARTUPINFOEXW_ATTRLIST_OFFSET),
                      Ptr{Cvoid}(pointer(attr)))
        # Critical for a redirected parent: SpaceStation's own stdout/stderr are usually a
        # pipe/log, not a real console. Without this the child inherits THOSE handles instead
        # of attaching to the pseudo-console, so its output never reaches us — a blank terminal.
        # STARTF_USESTDHANDLES with the std handles left NULL (they're zero-filled here) blocks
        # that inheritance, so the pseudo-console becomes the child's console. Verified on CI:
        # without it the child renders to the parent console; with it, output flows to our pipe.
        unsafe_store!(Ptr{UInt32}(pointer(si) + _STARTUPINFOW_DWFLAGS_OFFSET), _STARTF_USESTDHANDLES)

        dirp = isempty(cwstr_dir) ? C_NULL : pointer(cwstr_dir)
        envp = env === nothing   ? C_NULL : Ptr{Cvoid}(pointer(envblock))
        r = ccall((:CreateProcessW, "kernel32"), Cint,
                  (Ptr{UInt16}, Ptr{UInt16}, Ptr{Cvoid}, Ptr{Cvoid}, Cint, UInt32,
                   Ptr{Cvoid}, Ptr{UInt16}, Ptr{UInt8}, Ptr{UInt8}),
                  C_NULL, pointer(cmdline), C_NULL, C_NULL, Cint(0), flags,
                  envp, dirp, pointer(si), pointer(pi))
        ccall((:DeleteProcThreadAttributeList, "kernel32"), Cvoid, (Ptr{UInt8},), attr)
        r
    end

    if ret == 0
        err = _last_error()
        ccall(host.close, Cvoid, (Ptr{Cvoid},), hpc[])
        _close_handle(in_wr); _close_handle(out_rd)
        error("CreateProcessW failed: error=$err")
    end

    # Ours keeps its console host alive for as long as we hold the handle, whatever is still attached
    # to it. Released, the host goes when the last program on it has gone, which closes our end of
    # the output pipe: that is how the reader learns that a shell which exited by itself is gone.
    host.release == C_NULL || ccall(host.release, Clong, (Ptr{Cvoid},), hpc[])

    hprocess = GC.@preserve pi unsafe_load(Ptr{Ptr{Cvoid}}(pointer(pi)))
    hthread  = GC.@preserve pi unsafe_load(Ptr{Ptr{Cvoid}}(pointer(pi) + 8))
    pid      = GC.@preserve pi unsafe_load(Ptr{UInt32}(pointer(pi) + 16))

    output = Channel{Vector{UInt8}}(64)
    pty = PTY(host, hpc[], in_wr, out_rd, hprocess, hthread, Cint(pid), rows, cols, true,
              output, (@async nothing), nothing)
    pty.reader_task = _start_pty_reader(pty)
    pty
end

# ── Write ──

function pty_write(pty::PTY, data::Vector{UInt8})
    isempty(data) && return
    n = Ref{UInt32}(0)
    GC.@preserve data ccall((:WriteFile, "kernel32"), Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}),
                pty.input_write, pointer(data), UInt32(length(data)), n, C_NULL)
    nothing
end

pty_write(pty::PTY, s::String) = pty_write(pty, Vector{UInt8}(codeunits(s)))

# ── Resize ──

function pty_resize!(pty::PTY, rows::Int, cols::Int)
    # ConPTY repaints the entire viewport on EVERY resize — a same-size resize (e.g. the client
    # re-sending its geometry on attach) would stack a duplicate frame into the scrollback.
    (rows == pty.rows && cols == pty.cols) && return
    pty.rows = rows
    pty.cols = cols
    ccall(pty.console.resize, Clong,
          (Ptr{Cvoid}, UInt32), pty.hpc, _coord(rows, cols))
    nothing
end

# ── Alive check ──

function pty_alive(pty::PTY)
    pty.alive || return false
    pty.hprocess == C_NULL && return pty.alive
    r = ccall((:WaitForSingleObject, "kernel32"), UInt32,
              (Ptr{Cvoid}, UInt32), pty.hprocess, UInt32(0))
    if r == _WAIT_OBJECT_0   # signaled → process exited
        pty.alive = false
        return false
    end
    true
end

# ── What the shell is running ──

"""
The program the shell has started and that is still running (`ping`, `julia`, `claude`), or `nothing`
when it sits at its prompt or it cannot be told. So that closing a terminal can ask first when that
would stop something, as it does on the other systems. Windows has no foreground process group to ask
for; the shell's own children are what it is waiting on (PowerShell and cmd keep none at the prompt).
"""
function pty_running_child(pty::PTY)::Union{Nothing,String}
    (Sys.WORD_SIZE == 64 && pty.alive && pty.child_pid > 0) || return nothing
    shell = UInt32(pty.child_pid)
    snap = ccall((:CreateToolhelp32Snapshot, "kernel32"), Ptr{Cvoid}, (UInt32, UInt32), UInt32(0x00000002), UInt32(0)) # TH32CS_SNAPPROCESS
    (snap == C_NULL || snap == Ptr{Cvoid}(typemax(UInt))) && return nothing
    try
        # PROCESSENTRY32W on 64-bit Windows: 568 bytes, the parent's id at byte 32, the file name
        # (260 UTF-16 units) at byte 44. Its first field must hold the size.
        entry = zeros(UInt8, 568)
        GC.@preserve entry unsafe_store!(Ptr{UInt32}(pointer(entry)), UInt32(length(entry)))
        ok = ccall((:Process32FirstW, "kernel32"), Cint, (Ptr{Cvoid}, Ptr{UInt8}), snap, entry)
        while ok != 0
            parent = GC.@preserve entry unsafe_load(Ptr{UInt32}(pointer(entry) + 32))
            if parent == shell
                units = collect(reinterpret(UInt16, entry[45:564]))
                stop = something(findfirst(==(0x0000), units), length(units) + 1)
                name = lowercase(transcode(String, units[1:stop-1]))
                endswith(name, ".exe") && (name = name[1:end-4])
                (name == "conhost" || name == "openconsole") || return isempty(name) ? "a program" : name
            end
            ok = ccall((:Process32NextW, "kernel32"), Cint, (Ptr{Cvoid}, Ptr{UInt8}), snap, entry)
        end
    finally
        _close_handle(snap)
    end
    nothing
end

# ── Close ──

function pty_close!(pty::PTY)
    # Idempotent + concurrency-safe (mirrors PTY.jl): two tasks can call this on the same PTY at
    # once (the workspace-switch retire path's @async pty_close! and the shell's own pump cleanup),
    # and double-closing a HANDLE that Windows may have recycled would corrupt an unrelated object.
    # Claim the close by nulling every handle field into locals BEFORE any yield (the ccalls and
    # wait(reader_task) below yield); the read-then-null has no yield between, so under cooperative
    # @async scheduling exactly one caller wins and the rest return at the guard.
    hpc = pty.hpc
    hpc == C_NULL && return
    input_write = pty.input_write
    output_read = pty.output_read
    hprocess = pty.hprocess
    hthread = pty.hthread
    pty.hpc = C_NULL
    pty.input_write = C_NULL
    pty.output_read = C_NULL
    pty.hprocess = C_NULL
    pty.hthread = C_NULL
    pty.alive = false
    # The reader stops first (`alive` is false, and its channel is closed so a `put!` it is blocked
    # in unwinds), and the read end of the output pipe is closed BEFORE the pseudo-console is.
    # Before Windows 11 24H2 `ClosePseudoConsole` does not return until the console host has
    # written its last frame, and it writes into that pipe: with a program still printing the pipe
    # is full, nobody reads it any more, and the call never returned. It ran on the serving thread,
    # so that was the whole hub, for ever, from closing one terminal tab. With no reader left on the
    # pipe the host's write fails at once instead of waiting. The call also runs on another thread
    # (`@threadcall`): however long Windows takes over it, the server goes on answering.
    try close(pty.output) catch end
    if !istaskdone(pty.reader_task)
        try timedwait(() -> istaskdone(pty.reader_task), 2.0; pollint=0.005) catch end
    end
    _close_handle(output_read)
    close_console = pty.console.close
    @threadcall(close_console, Cvoid, (Ptr{Cvoid},), hpc)
    _close_handle(input_write)
    if hprocess != C_NULL
        ccall((:TerminateProcess, "kernel32"), Cint, (Ptr{Cvoid}, UInt32), hprocess, UInt32(1))
        ccall((:WaitForSingleObject, "kernel32"), UInt32, (Ptr{Cvoid}, UInt32), hprocess, UInt32(2000))
        _close_handle(hprocess)
    end
    _close_handle(hthread)
    nothing
end
