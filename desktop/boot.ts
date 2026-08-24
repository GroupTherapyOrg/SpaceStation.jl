// Julia server lifecycle for the SpaceStation desktop shell. GUI-free on purpose: main.ts wires
// this to a Deno.BrowserWindow, smoke.ts drives it from a plain `deno run` for headless testing.

export type Phase = "finding-julia" | "installing" | "starting" | "ready" | "error"

export interface BootState {
    phase: Phase
    detail: string
    log: string[]
    url: string | null
    port: number | null
}

const LOG_LINES = 200

export class SpaceStationServer {
    state: BootState = { phase: "finding-julia", detail: "", log: [], url: null, port: null }
    private child: Deno.ChildProcess | null = null
    private stopping = false
    onchange: (() => void) | null = null

    private set(phase: Phase, detail: string) {
        this.state.phase = phase
        this.state.detail = detail
        this.onchange?.()
    }

    private log_line(line: string) {
        if (line.trim() === "") return
        this.state.log.push(line)
        if (this.state.log.length > LOG_LINES) this.state.log.splice(0, this.state.log.length - LOG_LINES)
        // First-run `Pkg.add`/precompile is the long pole; surface it as its own phase so the
        // splash can set expectations ("minutes, once") instead of looking hung.
        if (this.state.phase === "starting" && /Installing SpaceStation|Precompiling|Updating registry/i.test(line)) {
            this.set("installing", "installing Julia packages (first run only — this can take a few minutes)")
        }
        this.onchange?.()
    }

    /** Locate a runnable `julia`. A compiled .app launched from Finder has a minimal PATH, so the
     *  well-known install locations are checked explicitly, juliaup first. */
    async find_julia(): Promise<string | null> {
        const home = Deno.env.get("HOME") ?? Deno.env.get("USERPROFILE") ?? ""
        const exe = Deno.build.os === "windows" ? "julia.exe" : "julia"
        const candidates = [
            Deno.env.get("SPACESTATION_JULIA"),
            `${home}/.juliaup/bin/${exe}`,
            "julia", // PATH, when launched from a terminal
            "/opt/homebrew/bin/julia",
            "/usr/local/bin/julia",
        ].filter((c): c is string => !!c)
        for (const candidate of candidates) {
            try {
                const out = await new Deno.Command(candidate, { args: ["--version"], stdout: "piped", stderr: "null" }).output()
                if (out.success) {
                    this.log_line(`found ${new TextDecoder().decode(out.stdout).trim()} at ${candidate}`)
                    return candidate
                }
            } catch {
                // not here — try the next candidate
            }
        }
        return null
    }

    /** The Julia project to run. Priority: explicit override → the repo this file sits in (dev
     *  checkout) → a managed environment in the platform app-data dir (compiled app; SpaceStation
     *  is installed from the General registry on first run). */
    resolve_project(): { project: string; managed: boolean } {
        const override = Deno.env.get("SPACESTATION_PROJECT")
        if (override) return { project: override, managed: false }
        try {
            const here = new URL(".", import.meta.url)
            if (here.protocol === "file:") {
                const repo = new URL("..", here).pathname
                const toml = Deno.readTextFileSync(`${repo}/Project.toml`)
                if (/name\s*=\s*"SpaceStation"/.test(toml)) return { project: repo, managed: false }
            }
        } catch {
            // not running from a source checkout — fall through to the managed environment
        }
        const home = Deno.env.get("HOME") ?? Deno.env.get("USERPROFILE") ?? "."
        const data_dir =
            Deno.build.os === "darwin"
                ? `${home}/Library/Application Support/SpaceStation`
                : Deno.build.os === "windows"
                  ? `${Deno.env.get("APPDATA") ?? home}/SpaceStation`
                  : `${Deno.env.get("XDG_DATA_HOME") ?? `${home}/.local/share`}/spacestation`
        return { project: `${data_dir}/julia-env`, managed: true }
    }

    /** Ask the OS for a free port. (Tiny race between close and Julia binding it — acceptable.) */
    pick_port(): number {
        const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 })
        const port = (listener.addr as Deno.NetAddr).port
        listener.close()
        return port
    }

    /** SpaceStation writes a connection file per server (port + access secret) exactly so external
     *  tools can find it — flat JSON in the state dir, keyed `<node>-<port>.json`. */
    read_secret(port: number): string | null {
        const home = Deno.env.get("HOME") ?? Deno.env.get("USERPROFILE") ?? "."
        const dir = `${Deno.env.get("XDG_STATE_HOME") ?? `${home}/.local/state`}/pluto/servers`
        try {
            for (const entry of Deno.readDirSync(dir)) {
                if (!entry.name.endsWith(`-${port}.json`)) continue
                const parsed = JSON.parse(Deno.readTextFileSync(`${dir}/${entry.name}`))
                if (typeof parsed.secret === "string") return parsed.secret
            }
        } catch {
            // no registry (yet) — the caller falls back to an unauthenticated URL check
        }
        return null
    }

    async start(): Promise<void> {
        const julia = await this.find_julia()
        if (julia == null) {
            this.set(
                "error",
                "Julia was not found. Install it from https://julialang.org/downloads (juliaup is recommended), or set SPACESTATION_JULIA to the julia binary."
            )
            return
        }
        const { project, managed } = this.resolve_project()
        const port = this.pick_port()
        this.state.port = port
        this.set("starting", managed ? `starting SpaceStation (managed environment)` : `starting SpaceStation from ${project}`)

        // One -e script covers both modes: a managed env bootstraps itself from the General
        // registry on first run; a dev checkout just imports the local package.
        const boot = managed
            ? `import Pkg; Pkg.activate(ENV["SPACESTATION_DESKTOP_ENV"]);
               try @eval import SpaceStation
               catch; println("Installing SpaceStation into the managed environment..."); flush(stdout);
                   Pkg.add("SpaceStation"); @eval import SpaceStation
               end;
               SpaceStation.run(port=${port}, launch_browser=false)`
            : `import SpaceStation; SpaceStation.run(port=${port}, launch_browser=false)`
        const args = managed ? ["--startup-file=no", "-e", boot] : [`--project=${project}`, "--startup-file=no", "-e", boot]
        if (managed) Deno.mkdirSync(project, { recursive: true })

        const child = new Deno.Command(julia, {
            args,
            env: {
                // the hub reads this via /api/v1/config: one webview window, so open workspaces
                // in-place instead of spawning browser tabs
                SPACESTATION_DESKTOP: "1",
                ...(managed ? { SPACESTATION_DESKTOP_ENV: project } : {}),
            },
            stdout: "piped",
            stderr: "piped",
        }).spawn()
        this.child = child
        this.pipe(child.stdout)
        this.pipe(child.stderr)
        child.status.then((status) => {
            this.child = null
            if (!this.stopping) this.set("error", `the SpaceStation server exited unexpectedly (code ${status.code})`)
        })

        // Readiness = /ping answers. First run can legitimately take minutes (Pkg + precompile).
        const deadline = Date.now() + 15 * 60 * 1000
        while (Date.now() < deadline) {
            if (this.child == null) return // exited; phase already set to error above
            try {
                const res = await fetch(`http://127.0.0.1:${port}/ping`, { signal: AbortSignal.timeout(1000) })
                await res.body?.cancel()
                if (res.ok) {
                    const secret = this.read_secret(port)
                    this.state.url = secret ? `http://127.0.0.1:${port}/?secret=${secret}` : `http://127.0.0.1:${port}/`
                    this.set("ready", "")
                    return
                }
            } catch {
                // not up yet
            }
            await new Promise((r) => setTimeout(r, 500))
        }
        this.set("error", "timed out waiting for the SpaceStation server to start")
        this.stop()
    }

    private async pipe(stream: ReadableStream<Uint8Array>) {
        const decoder = new TextDecoder()
        let buffer = ""
        try {
            for await (const chunk of stream) {
                buffer += decoder.decode(chunk, { stream: true })
                const lines = buffer.split("\n")
                buffer = lines.pop() ?? ""
                for (const line of lines) this.log_line(line)
            }
        } catch {
            // stream closed with the process
        }
        if (buffer.trim() !== "") this.log_line(buffer)
    }

    /** Graceful shutdown: SIGTERM lets the server reap terminals, tunnels, and child workspace
     *  servers (its on_shutdown handler); escalate only if it lingers. */
    async stop(): Promise<void> {
        const child = this.child
        if (child == null) return
        this.stopping = true
        try {
            child.kill("SIGTERM")
        } catch {
            return
        }
        const killed = await Promise.race([child.status.then(() => true), new Promise<boolean>((r) => setTimeout(() => r(false), 5000))])
        if (!killed) {
            try {
                child.kill("SIGKILL")
            } catch {
                // already gone
            }
        }
    }
}
