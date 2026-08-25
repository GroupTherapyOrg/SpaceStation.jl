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
import { extend_under_titlebar, fullscreen_state } from "./macos_titlebar.ts"

const server = new SpaceStationServer()
serve_splash(() => server.state, fullscreen_state)

// Deno.BrowserWindow only exists inside the desktop runtime host. Fail with a hint, not a crash,
// when someone runs this with plain `deno run` (use smoke.ts for that).
const BrowserWindow = (Deno as any).BrowserWindow
if (BrowserWindow == null) {
    console.error("Deno.BrowserWindow is unavailable — run with `deno task dev` (deno desktop), not `deno run`. For a headless check use smoke.ts.")
    Deno.exit(1)
}

// The first construction adopts the implicit startup window (already showing the splash).
// On macOS the FFI tweak below then extends the content under the title bar, so the deck's tab
// strip shares the traffic lights' row — the Warp look. (+28px height compensates the window
// re-normalizing when the style bit lands.)
const win = new BrowserWindow({ title: "", width: 1280, height: 878, transparentTitlebar: true })
const under_titlebar = extend_under_titlebar()

// The shell's own pages (splash and deck) live on the Deno.serve address the runtime wired the
// window to. Once the Julia server is ready we navigate to the deck, whose Launcher tab frames it.
const shell_port = Deno.env.get("DENO_SERVE_ADDRESS")?.split(":").pop()
const shell_url = (path: string) => `http://127.0.0.1:${shell_port}${path}`

// OS-standard menu roles ONLY — no app-specific shortcuts (that design is deliberately deferred;
// anything Pluto ships itself works inside the webview untouched). The Edit roles are required
// plumbing, not additions: macOS routes Cmd+C/V through the menu, so without them clipboard
// shortcuts never reach the webview — parity with what the browser gives Pluto for free.
try {
    win.setApplicationMenu([
        { submenu: { label: "SpaceStation", items: [{ role: { role: "quit" } }] } },
        {
            submenu: {
                label: "Edit",
                items: [
                    { role: { role: "undo" } },
                    { role: { role: "redo" } },
                    "separator",
                    { role: { role: "cut" } },
                    { role: { role: "copy" } },
                    { role: { role: "paste" } },
                    { role: { role: "selectAll" } },
                ],
            },
        },
        { submenu: { label: "Window", items: [{ role: { role: "minimize" } }] } },
    ])
} catch (e) {
    console.warn("could not install the application menu:", e)
}

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
        // ?inset=1 → the deck lays its tab strip out ON the traffic-light row (content extends
        // under the title bar); without it the strip sits just below the native bar.
        win.navigate(shell_url(under_titlebar ? "/deck?inset=1" : "/deck"))
    }
    // On a post-ready crash the splash server is still running — bring the window back to it so
    // the error and log tail are visible instead of a dead page.
    if (server.state.phase === "error" && server.state.url != null) {
        win.navigate(shell_url("/"))
        server.state.url = null
    }
}
await server.start()
