// SpaceStation as a desktop app: a Deno Desktop (`deno desktop`) shell that boots the Julia
// server and shows it in a native window. The window starts on a local splash page (served by
// Deno.serve, auto-wired to the startup window by the desktop runtime) and navigates to the
// SpaceStation URL — secret included — once the server answers /ping.
//
//   deno task dev        run from this checkout (HMR)
//   deno task build      package a redistributable app (see deno.json tasks for all platforms)
//
// The Julia side sees SPACESTATION_DESKTOP=1 and serves `desktop: true` from /api/v1/config,
// which makes the hub open workspaces in-place (one window, no browser tabs) while keeping the
// SSH sections visible — see land.js.

import { SpaceStationServer } from "./boot.ts"
import { serve_splash } from "./splash.ts"

const server = new SpaceStationServer()
serve_splash(() => server.state)

// Deno.BrowserWindow only exists inside the desktop runtime host. Fail with a hint, not a crash,
// when someone runs this with plain `deno run` (use smoke.ts for that).
const BrowserWindow = (Deno as any).BrowserWindow
if (BrowserWindow == null) {
    console.error("Deno.BrowserWindow is unavailable — run with `deno task dev` (deno desktop), not `deno run`. For a headless check use smoke.ts.")
    Deno.exit(1)
}

// The first construction adopts the implicit startup window (already showing the splash).
const win = new BrowserWindow({ title: "SpaceStation", width: 1280, height: 850 })

let closing = false
const shutdown = async () => {
    if (closing) return
    closing = true
    await server.stop()
    Deno.exit(0)
}
win.addEventListener("close", () => void shutdown())
for (const signal of ["SIGINT", "SIGTERM"] as const) {
    try {
        Deno.addSignalListener(signal, () => void shutdown())
    } catch {
        // not all signals exist on all platforms (Windows has no SIGTERM listener)
    }
}

server.onchange = () => {
    if (server.state.phase === "ready" && server.state.url != null) {
        win.navigate(server.state.url)
    }
    // On a post-ready crash the splash server is still running — bring the window back to it so
    // the error and log tail are visible instead of a dead page.
    if (server.state.phase === "error" && server.state.url != null) {
        const base = Deno.env.get("DENO_SERVE_ADDRESS")?.split(":").pop()
        if (base) win.navigate(`http://127.0.0.1:${base}/`)
        server.state.url = null
    }
}
await server.start()
