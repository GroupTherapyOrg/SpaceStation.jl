// SpaceStation as a desktop app: a Deno Desktop (`deno desktop`) shell that boots the Julia
// server and shows it in a native window. The startup window lands on the shell's own pages
// (served by Deno.serve): the Launch Station (pick a Julia — or install one) unless a saved
// preference skips it, then the boot splash, then the deck (tab chrome) framing SpaceStation.
//
//   deno task dev        run from this checkout (HMR)
//   deno task build      package a redistributable app (see deno.json tasks for all platforms)
//
// The Julia side sees SPACESTATION_DESKTOP=1 and serves `desktop: true` from /api/v1/config; the
// hub pages also detect the deck structurally (framed) — see land.js.

// FIRST — before anything that could construct a window. Module bodies run in import order, and on
// Windows this one has to win the race against the first WebView2 environment. See webview2.ts.
import "./webview2.ts"

import { SpaceStationServer, type BootOptions } from "./boot.ts"
import { serve_ui } from "./splash.ts"
import { begin_window_drag, extend_under_titlebar, is_fullscreen, main_screen_size, set_app_appearance } from "./macos_titlebar.ts"
import { has_plain_julia, julia_catalog, juliaup_info, load_settings, save_settings } from "./julia.ts"

// Deno.BrowserWindow only exists inside the desktop runtime host. Fail with a hint, not a crash,
// when someone runs this with plain `deno run` (use smoke.ts for that).
const BrowserWindow = (Deno as any).BrowserWindow
if (BrowserWindow == null) {
    console.error("Deno.BrowserWindow is unavailable — run with `deno task dev` (deno desktop), not `deno run`. For a headless check use smoke.ts.")
    Deno.exit(1)
}

// One app, one instance. Every click on the icon used to start an independent copy with its own
// Julia server and its own port — harmless-looking until the window fails to appear, at which point
// #55's reporter had five invisible SpaceStation.exe processes stacked up. Holding a loopback port
// IS the lock: the OS releases it when the process dies, so there is no stale lockfile to reap.
// This runs BEFORE the window is constructed, so a duplicate never flashes one up.
const INSTANCE_PORT = 47823
const INSTANCE_MARKER = "spacestation-desktop-instance"

let instance_lock: Deno.Listener | null = null
try {
    instance_lock = Deno.listen({ hostname: "127.0.0.1", port: INSTANCE_PORT })
} catch (e) {
    if (e instanceof Deno.errors.AddrInUse) {
        // Something holds the port. Stand down only if it answers as another SpaceStation — an
        // unrelated program squatting on this port must never stop the app from starting, so every
        // uncertain outcome (no answer, wrong answer, slow answer) falls through and launches.
        let ours = false
        try {
            const conn = await Deno.connect({ hostname: "127.0.0.1", port: INSTANCE_PORT })
            const buf = new Uint8Array(64)
            const read = conn.read(buf)
            const n = await Promise.race([read, new Promise<null>((r) => setTimeout(() => r(null), 1500))])
            if (n != null) ours = new TextDecoder().decode(buf.subarray(0, n)).startsWith(INSTANCE_MARKER)
            conn.close()
        } catch {
            // nothing listening any more, or it refused to talk — treat as not ours
        }
        if (ours) {
            console.error("SpaceStation is already running — raising that window instead of starting a second copy.")
            Deno.exit(0)
        }
    }
    // Any other listen failure: run without the lock rather than refuse to start.
}

// The first construction adopts the implicit startup window. On macOS the FFI tweak then extends
// the content under the title bar, so the deck's tab strip shares the traffic lights' row.
// Never open larger than the screen: on smaller or scaled-down displays the fixed default
// overflowed the visible area, cutting off the bottom of every page. (Margins leave room for
// the menu bar and a bit of breathing space; off-macOS the defaults stand.)
const screen = main_screen_size()
// An empty title is a macOS choice: the deck draws its own chrome under the traffic lights, so the
// system caption should stay blank. Windows has no such arrangement — there the title IS the taskbar
// button's label, the Alt+Tab entry and the window caption, and leaving it empty gave the app a
// nameless entry in all three (part of why #55's reporter reported "no icon in my dock"). Likewise
// transparentTitlebar is a macOS affordance that Windows silently ignores, so asking for it there
// only sets up a layout that assumes chrome it will never get.
const mac = Deno.build.os === "darwin"
const win = new BrowserWindow({
    title: mac ? "" : "SpaceStation",
    width: screen ? Math.min(1280, screen.width - 32) : 1280,
    height: screen ? Math.min(878, screen.height - 80) : 878,
    transparentTitlebar: mac,
})
const under_titlebar = extend_under_titlebar()

// The launcher's theme choice pins the native window appearance (macOS — a no-op elsewhere), so
// WKWebView's prefers-color-scheme and its own chrome follow it like a real OS dark-mode switch.
const saved_scheme = load_settings().color_scheme
if (saved_scheme === "light" || saved_scheme === "dark") set_app_appearance(saved_scheme)

// Now that there IS a window, answer later launches: identify ourselves so they exit, and bring
// this window forward so the click the user just made does something visible.
if (instance_lock != null) {
    const lock = instance_lock
    void (async () => {
        for await (const conn of lock) {
            try {
                win.show()
                win.focus()
            } catch {
                // window already gone — still answer, so the newcomer doesn't start a duplicate
            }
            try {
                await conn.write(new TextEncoder().encode(INSTANCE_MARKER))
            } catch {
                // the other copy gave up waiting
            }
            try {
                conn.close()
            } catch {
                // already closed
            }
        }
    })()
}

const shell_port = Deno.env.get("DENO_SERVE_ADDRESS")?.split(":").pop()
const shell_url = (path: string) => `http://127.0.0.1:${shell_port}${path}`

// OS-standard menu roles ONLY — no app-specific shortcuts (that design is deliberately deferred;
// anything Pluto ships itself works inside the webview untouched). The Edit roles are required
// plumbing: macOS routes Cmd+C/V through the menu, so without them clipboard shortcuts never
// reach the webview. "Julia Version…" is a plain menu item (no accelerator): it reopens the
// Launch Station to switch versions (which restarts the server).
// macOS only. These are macOS menu ROLES living in the system menu bar; on Windows the same call
// renders a Win32 menu bar strip INSIDE the window, stacking a second, redundant chrome row on top
// of the deck's own tab strip. The Edit roles exist to route Cmd+C/V into the webview, which is a
// macOS need — Windows delivers Ctrl+C/V to the webview without any menu.
if (mac) {
    try {
        win.setApplicationMenu([
            {
                submenu: {
                    label: "SpaceStation",
                    items: [{ item: { label: "Julia Version…", id: "julia-version", enabled: true } }, "separator", { role: { role: "quit" } }],
                },
            },
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
}
win.addEventListener("menuclick", (e: any) => {
    if (e.detail?.id === "julia-version") win.navigate(shell_url("/launch?change=1"))
})

// The server object is replaced when the user switches Julia versions; everything reaches it
// through these closures so the swap is invisible to the UI server and the window.
let server = new SpaceStationServer()
const wire = () => {
    server.onchange = () => {
        if (server.state.phase === "ready" && server.state.url != null) {
            win.navigate(shell_url(under_titlebar ? "/deck?inset=1" : "/deck"))
        }
        // On a post-ready crash the splash shows the error and log tail instead of a dead page.
        if (server.state.phase === "error" && server.state.url != null) {
            win.navigate(shell_url("/"))
            server.state.url = null
        }
    }
}
wire()

// Proof of life for the window. The runtime navigates the startup window to this server as soon as
// it is listening, so a healthy webview fetches a page within seconds. If nothing ever arrives, the
// window never came up — and because Deno.serve pins the event loop, the process would otherwise sit
// there forever: alive, invisible, and unkillable except through Task Manager. That is exactly what
// issue #55 looked like, five stacked copies deep. Fail loudly instead.
const WINDOW_WATCHDOG_MS = 60_000
const watchdog = setTimeout(() => {
    console.error(
        `no window after ${WINDOW_WATCHDOG_MS / 1000}s — the webview never loaded a page.\n` +
            (Deno.build.os === "windows"
                ? `WEBVIEW2_USER_DATA_FOLDER=${Deno.env.get("WEBVIEW2_USER_DATA_FOLDER") ?? "(unset)"}\n` +
                  `If WebView2 could not create its profile there, that is https://github.com/GroupTherapyOrg/SpaceStation.jl/issues/55.\n`
                : "") +
            `Exiting rather than running on with no user interface.`
    )
    Deno.exit(1)
}, WINDOW_WATCHDOG_MS)

serve_ui({
    on_first_request: () => clearTimeout(watchdog),
    state: () => server.state,
    julia_info: async () => ({
        juliaup: juliaup_info(),
        plain_julia: await has_plain_julia(),
        settings: load_settings().julia ?? { channel: null, ask: true },
        catalog: await julia_catalog(),
    }),
    on_launch: async (opts: BootOptions & { remember?: boolean }) => {
        // Remember the pick either way (it preselects next time); `remember` is the VS Code-style
        // "don't ask again" — with it set, future launches boot straight into this channel.
        save_settings({ julia: { channel: opts.channel ?? opts.add_channel ?? null, ask: !opts.remember } })
        if (server.state.phase !== "idle") {
            await server.stop()
            server = new SpaceStationServer()
            wire()
        }
        // Fire and return: start() leaves "idle" synchronously, so the page's redirect to "/"
        // lands on the live splash; progress (installs included) streams there.
        void server.start({ channel: opts.channel, add_channel: opts.add_channel, update: opts.update, bootstrap: opts.bootstrap })
    },
    on_appearance: (scheme) => {
        save_settings({ color_scheme: scheme })
        set_app_appearance(scheme)
    },
    on_drag: () => void begin_window_drag(),
    window_state: () => ({ fullscreen: is_fullscreen() }),
})

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

// A saved "don't ask" preference boots straight in; otherwise the window stays on the Launch
// Station (the runtime navigates it to "/" once the UI server is listening).
const pref = load_settings().julia
if (pref != null && pref.ask === false) {
    await server.start({ channel: pref.channel })
}
