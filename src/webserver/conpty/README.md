# The console host SpaceStation ships for Windows

`win-x64/conpty.dll` and `win-x64/OpenConsole.exe` are Microsoft's own, unmodified and signed by
Microsoft, from the Windows Terminal project (MIT, see `LICENSE`). `PTYWindows.jl` starts every
terminal on them instead of on the console host that is part of Windows.

## Why

The terminal on a Windows machine is only as good as the console host between the program and us,
and the one in Windows is as old as the Windows it came with. The one in every Windows 10 never
tells the terminal that a program asked for the mouse, and throws away the mouse reports a terminal
sends: in Claude Code, vim or anything else that takes the mouse, the wheel did nothing and nothing
could be clicked (found 2026-11-27, on a Windows 10 machine). There is no setting for it and no way
around it from outside. A program that hosts terminals ships the console host for that reason
(VS Code, Windows Terminal, WezTerm and Zed do); with it a terminal behaves the same on every
Windows from 10 1809 on.

## What is here

| | |
|---|---|
| Package | `Microsoft.Windows.Console.ConPTY` 1.25.260303002-preview, from nuget.org |
| The same files as | `third_party/conpty/1.25.260303002/win10-x64` in microsoft/node-pty (what VS Code ships) |
| Package SHA-256 | `7e477694e4095717c29725f7191ef13a5dda125e3a4d28a5fcc765a13dc9d967` |
| `conpty.dll` | `runtimes/win-x64/native/conpty.dll`, 110152 bytes, SHA-256 `3319b484b80bb53d1f4d0a9eb0ea60fd0f61da69db7280ca43b84215f19245ff` |
| `OpenConsole.exe` | `build/native/runtimes/x64/OpenConsole.exe`, 1062472 bytes, SHA-256 `7f68c840226505004215c0b82d4e502c24b5bc3f4b93c4baaaa19bd679c0def8` |

`conpty.dll` starts the `OpenConsole.exe` that lies beside it. The two belong together: never one
from one version and one from another.

## To take a newer one

1. Download `https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty/<version>/microsoft.windows.console.conpty.<version>.nupkg`
   (a zip), take the two files named above, and put them here unchanged.
2. Put the new version and hashes in this file and in `CONPTY_BUNDLE_SHA256` in `PTYWindows.jl`.
3. `test/conpty_windows.jl` (the "Windows terminal (ConPTY)" workflow) and the shell walkthrough
   say whether a terminal still works on it.

`SPACESTATION_INBOX_CONPTY=1` in the server's environment is the console host of Windows again.
