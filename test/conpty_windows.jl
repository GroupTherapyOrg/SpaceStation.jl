# Standalone Windows ConPTY smoke test for src/webserver/PTYWindows.jl.
#
# Runs the ConPTY PTY layer directly (no SpaceStation package load, no deps to instantiate —
# PTYWindows.jl only needs Base + kernel32), so Windows CI iterates fast and pinpoints where
# terminal output is lost: the ConPTY core (Test 1) vs. the PowerShell/banner invocation the
# real _spawn_workspace_shell uses (Tests 2–3). Rich diagnostics are printed either way.

import Base64
import SHA

if !Sys.iswindows()
    println("Not Windows — skipping ConPTY tests (this file only means anything on Windows).")
    exit(0)
end

const REPO = normpath(joinpath(@__DIR__, ".."))
module W end
Base.include(W, joinpath(REPO, "src", "webserver", "PTYWindows.jl"))
println("Included PTYWindows.jl OK on ", Sys.MACHINE)

"Read from a PTY's output channel until `want` is seen or `timeout` seconds pass."
function drain(pty; timeout = 6.0, want = "")
    got = UInt8[]
    t0 = time()
    while time() - t0 < timeout
        if isready(pty.output)
            append!(got, take!(pty.output))
            (!isempty(want) && occursin(want, String(copy(got)))) && break
        else
            (!pty.alive && !isready(pty.output)) && break  # child gone + drained
            sleep(0.02)
        end
    end
    got
end

fails = String[]
check(cond, msg) = (println(cond ? "  PASS  " : "  FAIL  ", msg); cond || push!(fails, msg))
ps_exe() = something(Sys.which("pwsh"), Sys.which("powershell"), "powershell.exe")

println("\n== Test 1: cmd.exe echo — ConPTY core (spawn + read) ==")
try
    pty = W.pty_spawn(["cmd.exe", "/c", "echo hello_conpty_marker"]; dir = "C:\\")
    println("  spawned child_pid=", pty.child_pid, " alive=", pty.alive)
    out = drain(pty; timeout = 10, want = "hello_conpty_marker")
    println("  received ", length(out), " bytes: ", repr(String(copy(out))))
    check(occursin("hello_conpty_marker", String(out)), "cmd.exe output reached the reader")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "cmd.exe spawn threw")
end

println("\n== Test 2: PowerShell interactive — write + read echo ==")
try
    exe = ps_exe()
    pty = W.pty_spawn([exe, "-NoLogo", "-NoExit", "-Command", "Write-Host READY_MARKER"]; dir = "C:\\")
    println("  spawned ", exe, " child_pid=", pty.child_pid)
    out = drain(pty; timeout = 15, want = "READY_MARKER")
    println("  startup: ", length(out), " bytes: ", repr(String(copy(out))))
    check(occursin("READY_MARKER", String(out)), "powershell produced startup output")
    W.pty_write(pty, "echo write_roundtrip_123\r\n")
    out2 = drain(pty; timeout = 10, want = "write_roundtrip_123")
    println("  after write: ", length(out2), " bytes: ", repr(String(copy(out2))))
    check(occursin("write_roundtrip_123", String(out2)), "powershell echoed our written command")
    W.pty_resize!(pty, 40, 100)
    check(pty.rows == 40 && pty.cols == 100, "pty_resize! resized and recorded the new size")
    W.pty_resize!(pty, 40, 100)  # same size again → must hit the no-op early return (no repaint)
    check(pty.rows == 40 && pty.cols == 100, "same-size pty_resize! is a no-op and did not throw")
    W.pty_close!(pty);            check(true, "pty_close! did not throw")
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "powershell interactive test threw")
end

println("\n== Test 3: exact banner path _spawn_workspace_shell builds (UTF-8 console + base64 -Command) ==")
try
    # Mirrors CollabTerminal.jl's setup string: switch the console to UTF-8 BEFORE writing, then
    # write the base64'd banner. The emoji is the regression check — on Windows PowerShell 5.1
    # without the encoding switch, the legacy OEM codepage turns it into "??".
    banner = "\e[1m🟢 BANNER_MARKER\e[0m\r\n"
    b64 = Base64.base64encode(banner)
    setup = string(
        "\$e=[Text.UTF8Encoding]::new(\$false); ",
        "try{[Console]::OutputEncoding=\$e; [Console]::InputEncoding=\$e}catch{}; \$OutputEncoding=\$e; ",
        "\$b=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$(b64)')); [Console]::Write(\$b)",
    )
    exe = ps_exe()
    pty = W.pty_spawn([exe, "-NoLogo", "-NoExit", "-Command", setup]; dir = "C:\\")
    out = drain(pty; timeout = 15, want = "BANNER_MARKER")
    s = String(copy(out))  # copy: String(::Vector{UInt8}) steals the buffer, and we check twice
    println("  ", length(out), " bytes: ", repr(s))
    check(occursin("BANNER_MARKER", s), "base64 -Command banner rendered")
    check(occursin("🟢", s), "banner emoji survived (UTF-8 console, no ?? mojibake)")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "banner path threw")
end

println("\n== Test 4: exact cmd.exe fallback path (/K chcp 65001 through _win_cmdline quoting) ==")
try
    # Mirrors CollabTerminal.jl's cmd branch. The argv element "chcp 65001 >nul" gets quoted by
    # _win_cmdline into `cmd.exe /K "chcp 65001 >nul"` — this asserts cmd actually executes it
    # (quoting is where this breaks) by asking cmd which codepage it ended up on.
    pty = W.pty_spawn(["cmd.exe", "/K", "chcp 65001 >nul"]; dir = "C:\\")
    println("  spawned cmd child_pid=", pty.child_pid)
    W.pty_write(pty, "chcp\r\n")
    out = drain(pty; timeout = 10, want = "65001")
    println("  ", length(out), " bytes: ", repr(String(copy(out))))
    check(occursin("65001", String(out)), "cmd fallback switched the console to UTF-8 (chcp reports 65001)")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "cmd /K chcp path threw")
end

println("\n== Test: what the shell is running (so closing a terminal can ask first) ==")
try
    exe = ps_exe()
    pty = W.pty_spawn([exe, "-NoLogo", "-NoExit", "-Command", "Write-Host READY_MARKER"]; dir = "C:\\")
    drain(pty; timeout = 20, want = "READY_MARKER")
    sleep(1)
    idle = W.pty_running_child(pty)
    println("  at the prompt: ", repr(idle))
    check(idle === nothing, "a shell at its prompt runs nothing")
    W.pty_write(pty, "ping -n 60 127.0.0.1\r")
    drain(pty; timeout = 10, want = "Reply")
    busy = W.pty_running_child(pty)
    println("  with ping running: ", repr(busy))
    check(busy == "ping", "the program the shell started is named")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "pty_running_child threw")
end

println("\n== Test: a line feed is not Enter; a carriage return is ==")
try
    exe = ps_exe()
    pty = W.pty_spawn([exe, "-NoLogo", "-NoExit", "-Command", "Write-Host READY_MARKER"]; dir = "C:\\")
    drain(pty; timeout = 20, want = "READY_MARKER")
    sleep(1)
    W.pty_write(pty, "echo typed_ahead_\$(40+2)\r")
    out = drain(pty; timeout = 10, want = "typed_ahead_42")
    println("  ", repr(String(copy(out))))
    check(occursin("typed_ahead_42", String(out)), "a command ended by a carriage return runs")
    W.pty_close!(pty)
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "carriage-return test threw")
end

println("\n== Test: closing a terminal while its program prints, with nobody reading ==")
try
    # (before Windows 11 24H2 the close waits for the console host's last frame; with the pipe full
    # and no reader it waited for ever, on the thread that serves every request)
    pty = W.pty_spawn(["cmd.exe", "/c", "for /L %i in (1,1,2000000) do @echo line %i of output that fills the pipe"]; dir = "C:\\")
    drain(pty; timeout = 5, want = "line 50 ")
    sleep(2) # nothing is taken from the channel now: it fills, the reader blocks, the pipe fills
    closing = @async W.pty_close!(pty)
    ticks = Ref(0)
    ticker = @async while !istaskdone(closing)
        ticks[] += 1
        sleep(0.05)
    end
    done = timedwait(() -> istaskdone(closing), 30.0)
    println("  close returned: ", done, "; other tasks ran ", ticks[], " times meanwhile")
    check(done == :ok, "pty_close! returned while the program was printing")
    check(!istaskfailed(closing), "pty_close! did not throw")
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "close-while-printing test threw")
end

println("\n== Test: terminals start on the console host we ship, and it is the one we say it is ==")
try
    dir = W._conpty_bundle_dir()
    for (file, sha) in W.CONPTY_BUNDLE_SHA256
        path = joinpath(dir, file)
        check(isfile(path), "$file is in the tree")
        isfile(path) && check(bytes2hex(SHA.sha256(read(path))) == sha, "$file is the file conpty/README.md names (SHA-256)")
    end
    host = W._console_host()
    println("  console host: ", host === nothing ? "none" : host.kind)
    check(host !== nothing && host.kind === :bundled, "the console host we ship loads")
    hosts() = count("OpenConsole.exe", read(`tasklist /FI "IMAGENAME eq OpenConsole.exe" /FO CSV /NH`, String))
    before = hosts()
    pty = W.pty_spawn(["cmd.exe", "/K", "echo bundled_host_marker"]; dir = "C:\\")
    out = drain(pty; timeout = 10, want = "bundled_host_marker")
    check(occursin("bundled_host_marker", String(out)), "a shell on it prints through to us")
    check(pty.console.kind === :bundled, "a terminal is started on it without being asked to")
    println("  OpenConsole.exe processes: ", before, " before, ", hosts(), " with the terminal open")
    check(hosts() == before + 1, "its OpenConsole.exe is what runs the terminal (not Windows' conhost.exe)")
    W.pty_close!(pty)
    withenv("SPACESTATION_INBOX_CONPTY" => "1") do
        check(W._console_host().kind === :inbox, "SPACESTATION_INBOX_CONPTY=1 is Windows' own console host")
    end
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "console host test threw")
end

# The wheel and a click in a program that takes the mouse (Claude Code, vim, tmux). On Windows 10
# neither worked, and nothing here noticed: every test ran on the Windows of the CI machine, whose
# console host is newer than the one most people have. What is tested now is the console host we
# ship, which is the same on every Windows; Windows' own is run too, and what it does is printed
# (it differs by Windows version, so it is the record, not a requirement).
function mouse_reaches_a_program(console::Symbol)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    pty = W.pty_spawn([julia, "--startup-file=no", joinpath(@__DIR__, "mouse_probe.jl")]; dir = "C:\\", console)
    result = (; asked = false, wheel = false, press = false)
    try
        out = drain(pty; timeout = 90, want = "MOUSE_PROBE_READY")
        s = String(copy(out))
        ready = occursin("MOUSE_PROBE_READY", s)
        # what a terminal has to be told, or it never sends a mouse report at all
        asked = occursin(r"\e\[\?[\d;]*1000[\d;]*h", s) && occursin(r"\e\[\?[\d;]*1006[\d;]*h", s)
        println("  [", console, "] probe ready: ", ready, "; its request for the mouse reached the terminal: ", asked)
        ready || println("  [", console, "] output: ", repr(s))
        W.pty_write(pty, "\e[<64;10;5M")                    # the wheel, one notch up, at column 10, row 5
        w = String(drain(pty; timeout = 10, want = "wheel-up-arrived"))
        W.pty_write(pty, "\e[<0;10;5M\e[<0;10;5m")           # the left button, down and up
        c = String(drain(pty; timeout = 10, want = "press-arrived"))
        result = (; asked, wheel = occursin("wheel-up-arrived", w), press = occursin("press-arrived", w * c))
        println("  [", console, "] the wheel reached the program: ", result.wheel, "; a click did: ", result.press)
        result.wheel && result.press || println("  [", console, "] output after the reports: ", repr(w * c))
    finally
        W.pty_close!(pty)
    end
    result
end

println("\n== Test: the mouse reaches a program that takes it (the wheel scrolls, a click clicks) ==")
try
    r = mouse_reaches_a_program(:bundled)
    check(r.asked, "a program's request for the mouse reaches the terminal")
    check(r.wheel, "the wheel reaches the program")
    check(r.press, "a click reaches the program")
catch e
    println("  EXCEPTION: ", sprint(showerror, e))
    push!(fails, "mouse test threw")
end
try
    r = mouse_reaches_a_program(:inbox)
    println("  for the record, Windows' own console host on this machine (", Sys.windows_version(), "): ", r)
catch e
    println("  Windows' own console host: EXCEPTION: ", sprint(showerror, e))
end

println("\n", isempty(fails) ? "ALL CONPTY TESTS PASSED ✅" : "FAILURES ($(length(fails))) ❌:")
foreach(f -> println("  - ", f), fails)
exit(isempty(fails) ? 0 : 1)
