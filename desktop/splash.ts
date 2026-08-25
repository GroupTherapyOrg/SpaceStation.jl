// The boot screen the window shows while Julia starts (or fails). Served by Deno.serve — the
// desktop runtime points the startup window at it automatically; main.ts navigates away to the
// real SpaceStation URL once the server is ready.

import type { BootState } from "./boot.ts"
import { deck_html } from "./deck.ts"

export const splash_html = /* html */ `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>SpaceStation</title>
<style>
    :root { color-scheme: dark; }
    body {
        margin: 0; height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center;
        background: #16141f; color: #ddd; font-family: system-ui, -apple-system, sans-serif; gap: 1.2rem;
    }
    .mark { font-size: 2.6rem; letter-spacing: 0.3rem; }
    h1 { font-size: 1.3rem; font-weight: 600; margin: 0; }
    #phase { font-size: 0.95rem; color: #9a93b8; max-width: 34rem; text-align: center; line-height: 1.5; }
    #phase.error { color: #ff8a8a; }
    .spinner { width: 22px; height: 22px; border: 3px solid #3a3455; border-top-color: #9a86ff; border-radius: 50%; animation: spin 0.9s linear infinite; }
    .spinner.hidden { display: none; }
    @keyframes spin { to { transform: rotate(360deg); } }
    #log {
        width: min(44rem, 86vw); max-height: 32vh; overflow-y: auto; padding: 0.7rem 0.9rem; box-sizing: border-box;
        background: #0f0d16; border-radius: 0.5rem; font-family: ui-monospace, Menlo, Consolas, monospace;
        font-size: 0.72rem; line-height: 1.45; color: #7d7796; white-space: pre-wrap; word-break: break-word;
    }
</style>
</head>
<body>
    <div class="mark">🟢🟣🔴</div>
    <h1>SpaceStation</h1>
    <div class="spinner" id="spinner"></div>
    <div id="phase">starting…</div>
    <pre id="log"></pre>
    <script>
        const tick = async () => {
            try {
                const s = await (await fetch("./status")).json()
                document.getElementById("phase").textContent = s.detail || s.phase
                document.getElementById("phase").className = s.phase === "error" ? "error" : ""
                document.getElementById("spinner").className = s.phase === "error" ? "spinner hidden" : "spinner"
                const log = document.getElementById("log")
                const at_bottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 4
                log.textContent = s.log.join("\\n")
                if (at_bottom) log.scrollTop = log.scrollHeight
            } catch {}
            setTimeout(tick, 500)
        }
        tick()
    </script>
</body>
</html>`

/** Serve the shell UI: the splash (+ /status it polls) while booting, and /deck — the tabbed
 *  chrome main.ts navigates to once the server is ready. Deno.serve with no options binds to
 *  DENO_SERVE_ADDRESS, which is how the desktop runtime knows where to point the window. */
export const serve_splash = (state: () => BootState, fullscreen_state: () => { fullscreen: boolean; overlay_px: number } = () => ({ fullscreen: false, overlay_px: 0 })) =>
    Deno.serve((req) => {
        const path = new URL(req.url).pathname
        if (path === "/status") {
            return new Response(JSON.stringify(state()), { headers: { "content-type": "application/json" } })
        }
        if (path === "/fullscreen") {
            // Polled by the deck: size heuristics can't tell notched-Mac fullscreen from a zoomed
            // window (the NSWindow style bit can), and overlay_px lets the tab strip ride WITH the
            // native fullscreen overlay instead of fighting it.
            return new Response(JSON.stringify(fullscreen_state()), { headers: { "content-type": "application/json" } })
        }
        if (path === "/deck") {
            const url = state().url
            if (url == null) return new Response(null, { status: 302, headers: { location: "/" } })
            return new Response(deck_html(url), { headers: { "content-type": "text/html; charset=utf-8" } })
        }
        return new Response(splash_html, { headers: { "content-type": "text/html; charset=utf-8" } })
    })
