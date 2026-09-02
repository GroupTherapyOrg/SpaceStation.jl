// Child processes, spawned without flashing a console window on Windows.
//
// A packaged SpaceStation.exe is a GUI-subsystem binary, and julia.exe, juliaup.exe and
// powershell.exe are all console-subsystem. Windows gives a console child its own console when the
// parent has none, so every `--version` probe, every `juliaup list`, and the Julia server itself
// popped a black window on screen — several during a single launch. The flag that suppresses it is
// CREATE_NO_WINDOW, which Deno.Command has no way to express; node:child_process does, as
// `windowsHide`.
//
// So Windows goes through the node path and every other platform keeps exactly the Deno.Command
// behaviour it already had. This is a Windows-only cosmetic fix, deliberately not a rewrite of how
// the app boots — the macOS and Linux code paths below are unchanged from what they replaced.

import { spawn as node_spawn } from "node:child_process"

const WINDOWS = Deno.build.os === "windows"

/** Split a byte stream into lines, tolerating CRLF (Windows tools emit it) and a trailing partial
 *  line at EOF. Shared so both paths log identically. */
const line_splitter = (on_line: (line: string) => void) => {
    const decoder = new TextDecoder()
    let buffer = ""
    return {
        push(chunk: Uint8Array) {
            buffer += decoder.decode(chunk, { stream: true })
            const lines = buffer.split("\n")
            buffer = lines.pop() ?? ""
            for (const line of lines) on_line(line.replace(/\r$/, ""))
        },
        flush() {
            if (buffer.trim() !== "") on_line(buffer.replace(/\r$/, ""))
            buffer = ""
        },
    }
}

/** Run to completion, capturing stdout; stderr is discarded. A binary that does not exist reports
 *  success: false rather than throwing, which is what every caller here wants. */
export const run_captured = async (cmd: string, args: string[]): Promise<{ success: boolean; stdout: string }> => {
    if (!WINDOWS) {
        try {
            const out = await new Deno.Command(cmd, { args, stdout: "piped", stderr: "null" }).output()
            return { success: out.success, stdout: new TextDecoder().decode(out.stdout) }
        } catch {
            return { success: false, stdout: "" }
        }
    }
    const child = node_spawn(cmd, args, { windowsHide: true, stdio: ["ignore", "pipe", "ignore"] })
    let stdout = ""
    child.stdout?.on("data", (chunk: unknown) => (stdout += String(chunk)))
    const code = await new Promise<number>((resolve) => {
        child.on("close", (c: number | null) => resolve(c ?? 1))
        child.on("error", () => resolve(1)) // not on PATH, not executable — same as a failed run
    })
    return { success: code === 0, stdout }
}

export interface Running {
    pid: number
    status: Promise<{ code: number; success: boolean }>
    kill: (signal: "SIGTERM" | "SIGKILL") => void
}

/** Start a process, streaming stdout+stderr into `on_line` a line at a time. Throws if the process
 *  cannot be started at all, matching Deno.Command's behaviour on both paths. */
export const spawn_logged = (cmd: string, args: string[], env: Record<string, string> | undefined, on_line: (line: string) => void): Running => {
    if (!WINDOWS) {
        const child = new Deno.Command(cmd, { args, ...(env ? { env } : {}), stdout: "piped", stderr: "piped" }).spawn()
        const pump = async (stream: ReadableStream<Uint8Array>) => {
            const split = line_splitter(on_line)
            try {
                for await (const chunk of stream) split.push(chunk)
            } catch {
                // stream closed with the process
            }
            split.flush()
        }
        void pump(child.stdout)
        void pump(child.stderr)
        return {
            pid: child.pid,
            status: child.status.then((s) => ({ code: s.code, success: s.success })),
            kill: (signal) => child.kill(signal),
        }
    }

    const child = node_spawn(cmd, args, {
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
        ...(env ? { env: { ...Deno.env.toObject(), ...env } } : {}),
    })
    for (const stream of [child.stdout, child.stderr]) {
        if (stream == null) continue
        const split = line_splitter(on_line)
        stream.on("data", (chunk: Uint8Array) => split.push(chunk))
        stream.on("end", () => split.flush())
    }
    const status = new Promise<{ code: number; success: boolean }>((resolve) => {
        child.on("close", (c: number | null) => resolve({ code: c ?? 1, success: c === 0 }))
        child.on("error", () => resolve({ code: 1, success: false }))
    })
    return { pid: child.pid ?? 0, status, kill: (signal) => void child.kill(signal) }
}
