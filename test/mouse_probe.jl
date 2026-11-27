# A program that takes the mouse, the way Claude Code, vim and tmux do, and says what reaches it.
# Run in a terminal by test/conpty_windows.jl and by the shell walkthrough.
#
# It asks the terminal for mouse reports (`ESC [ ? 1000 h`, in the SGR form, `ESC [ ? 1006 h`), says
# MOUSE_PROBE_READY, and then reads its input as it comes:
#   wheel up        ESC [ < 64 ; col ; row M    -> "wheel-up-arrived"
#   a button press  ESC [ < 0 ; col ; row M     -> "press-arrived"
# After both (or `q`, or a minute) it gives the mouse back and says MOUSE_PROBE_DONE.
#
# Both halves of that can be lost between a program and a terminal, and on Windows 10 both were:
# the console host of that Windows keeps the request to itself, so the terminal never sends a
# report, and drops a report that is sent anyway.

const ESC = "\e"
const ASK = ESC * "[?1000h" * ESC * "[?1006h"
const GIVE_BACK = ESC * "[?1006l" * ESC * "[?1000l"

function watch(read_some::Function, say::Function)
    say(ASK * "MOUSE_PROBE_READY\r\n")
    seen = ""
    wheel = press = false
    deadline = time() + 60
    while time() < deadline && !(wheel && press)
        chunk = read_some()
        isempty(chunk) && continue
        seen *= String(copy(chunk))
        say("got:" * bytes2hex(chunk) * "\r\n")
        if !wheel && occursin(r"\e\[<64;\d+;\d+M", seen)
            wheel = true
            say("wheel-up-arrived\r\n")
        end
        if !press && occursin(r"\e\[<0;\d+;\d+M", seen)
            press = true
            say("press-arrived\r\n")
        end
        occursin('q', replace(seen, r"\e\[<[\d;]*[Mm]?" => "")) && break
    end
    say(GIVE_BACK)
    # what was already on its way when the mouse was given back (the release of that click) is read
    # here, and not left for the shell to find at its prompt
    quiet = time() + 0.5
    while time() < quiet
        read_some()
    end
    say("MOUSE_PROBE_DONE\r\n")
end

@static if Sys.iswindows()
    # The console itself, whatever this process was given as standard input and output. Input in the
    # terminal's own form (ENABLE_VIRTUAL_TERMINAL_INPUT) and nothing else: no line editing, no echo.
    # That is the mode Node, Bun and every program written for a terminal reads in.
    const K32 = "kernel32"
    open_console(name) = ccall((:CreateFileW, K32), Ptr{Cvoid},
        (Ptr{UInt16}, UInt32, UInt32, Ptr{Cvoid}, UInt32, UInt32, Ptr{Cvoid}),
        push!(transcode(UInt16, name), 0x0000), 0xC0000000, 0x00000003, C_NULL, 0x00000003, 0x00000000, C_NULL)
    const hin = open_console("CONIN\$")
    const hout = open_console("CONOUT\$")
    const mode_in = Ref{UInt32}(0)
    const mode_out = Ref{UInt32}(0)
    ccall((:GetConsoleMode, K32), Cint, (Ptr{Cvoid}, Ptr{UInt32}), hin, mode_in)
    ccall((:GetConsoleMode, K32), Cint, (Ptr{Cvoid}, Ptr{UInt32}), hout, mode_out)
    ccall((:SetConsoleMode, K32), Cint, (Ptr{Cvoid}, UInt32), hin, 0x00000200)
    ccall((:SetConsoleMode, K32), Cint, (Ptr{Cvoid}, UInt32), hout, mode_out[] | 0x00000004 | 0x00000001)
    function say(s::String)
        bytes = Vector{UInt8}(codeunits(s))
        n = Ref{UInt32}(0)
        ccall((:WriteFile, K32), Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}), hout, bytes, UInt32(length(bytes)), n, C_NULL)
        nothing
    end
    function read_some()
        # waits a moment for input, so the minute above is kept to
        ccall((:WaitForSingleObject, K32), UInt32, (Ptr{Cvoid}, UInt32), hin, UInt32(200)) == 0 || return UInt8[]
        buf = Vector{UInt8}(undef, 256)
        n = Ref{UInt32}(0)
        ok = ccall((:ReadFile, K32), Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32, Ptr{UInt32}, Ptr{Cvoid}), hin, buf, UInt32(length(buf)), n, C_NULL)
        ok == 0 ? UInt8[] : buf[1:n[]]
    end
    try
        watch(read_some, say)
    finally
        ccall((:SetConsoleMode, K32), Cint, (Ptr{Cvoid}, UInt32), hin, mode_in[])
        ccall((:SetConsoleMode, K32), Cint, (Ptr{Cvoid}, UInt32), hout, mode_out[])
    end
else
    run(`stty raw -echo`)
    try
        input = Channel{Vector{UInt8}}(64)
        @async while true
            put!(input, readavailable(stdin))
        end
        read_some() = timedwait(() -> isready(input), 0.2; pollint=0.02) === :ok ? take!(input) : UInt8[]
        say(s::String) = (write(stdout, s); flush(stdout); nothing)
        watch(read_some, say)
    finally
        run(`stty sane`)
    end
end
