// The shell's UI server: the boot splash (with live Julia log), the Launch Station picker, and
// the deck — all served from Deno.serve, which the desktop runtime wires to the startup window.
// Styling is shared with the SpaceStation launcher (theme.ts) so every screen reads as one product.

import type { BootOptions, BootState } from "./boot.ts"
import { deck_html } from "./deck.ts"
import { launch_html } from "./launch.ts"
import { base_css, logo_svg } from "./theme.ts"

export const splash_html = /* html */ `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>SpaceStation</title>
<style>
${base_css}
    .card { text-align: center; }
    .spinner {
        width: 22px; height: 22px; margin: 1.1rem auto 0; border: 3px solid var(--rule-color);
        border-top-color: var(--accent); border-radius: 50%; animation: spin 0.9s linear infinite;
    }
    .spinner.hidden { display: none; }
    @keyframes spin { to { transform: rotate(360deg); } }
    #phase { font-size: 0.95rem; opacity: 0.75; margin-top: 0.9rem; line-height: 1.5; }
    #phase.error { color: #ff8a8a; opacity: 1; }
    #log {
        text-align: left; max-height: 32vh; overflow-y: auto; margin-top: 1.1rem; padding: 0.7rem 0.9rem;
        background-color: var(--main-bg-color); border-radius: 0.5rem;
        font-family: JuliaMono, ui-monospace, Menlo, Consolas, monospace;
        font-size: 0.72rem; line-height: 1.45; opacity: 0.75; white-space: pre-wrap; word-break: break-word;
    }
    #pick { display: none; margin-top: 0.9rem; font-size: 0.85rem; color: inherit; opacity: 0.65; }
</style>
</head>
<body>
    <div class="dragbar"></div>
    <div class="bubble card">
        ${logo_svg}
        <h1>Space<span class="land-accent">Station</span></h1>
        <div class="spinner" id="spinner"></div>
        <div id="phase">starting…</div>
        <pre id="log"></pre>
        <a id="pick" href="/launch?change=1">choose a different Julia version…</a>
    </div>
    <script>
        // WKWebView has no CSS drag regions — mousedown here asks the shell to start a native
        // window drag (AppKit tracks it from there)
        document.querySelector(".dragbar").addEventListener("mousedown", (e) => {
            if (e.button === 0) fetch("./api/drag", { method: "POST" }).catch(() => {})
        })

        const tick = async () => {
            try {
                const s = await (await fetch("./status")).json()
                document.getElementById("phase").textContent = s.detail || s.phase
                document.getElementById("phase").className = s.phase === "error" ? "error" : ""
                document.getElementById("spinner").className = s.phase === "error" ? "spinner hidden" : "spinner"
                document.getElementById("pick").style.display = s.phase === "error" ? "inline-block" : "none"
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

export interface UiHandlers {
    state: () => BootState
    julia_info: () => Promise<unknown>
    on_launch: (opts: BootOptions & { remember?: boolean }) => Promise<void>
    on_appearance?: (scheme: "light" | "dark" | "system") => void
    on_drag?: () => void
    window_state?: () => { fullscreen: boolean }
    /** The native zoom: "in" / "out" step Chrome's ladder, "reset" is 100%; returns the factor now in effect. */
    on_zoom?: (action: "in" | "out" | "reset") => number
    zoom?: () => number
    /** Fired once, on the first request from the window. main.ts uses it as proof of life: a webview
     *  that never came up never asks for a page, and the shell must not sit there pretending. */
    on_first_request?: () => void
}

export const serve_ui = ({ state, julia_info, on_launch, on_appearance, on_drag, window_state, on_zoom, zoom, on_first_request }: UiHandlers) => {
    let announced = false
    return Deno.serve(async (req) => {
        if (!announced) {
            announced = true
            on_first_request?.()
        }
        const path = new URL(req.url).pathname
        const json = (body: unknown) => new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } })
        const page = (html: string) => new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
        if (path === "/status") return json(state())
        if (path === "/api/julia") return json(await julia_info())
        // fired on mousedown in a page's drag area: the shell starts a native window drag
        if (path === "/api/drag" && req.method === "POST") {
            on_drag?.()
            return json({ ok: true })
        }
        // the deck asks after every resize: fullscreen hides the traffic lights, so the strip
        // drops the gap it reserves for them
        if (path === "/api/window") return json({ ...(window_state?.() ?? { fullscreen: false }), zoom: zoom?.() ?? 1 })
        if (path === "/api/zoom" && req.method === "GET") return json({ zoom: zoom?.() ?? 1 })
        if (path === "/api/zoom" && req.method === "POST") {
            let action: unknown = null
            try {
                action = (await req.json())?.action
            } catch {
                // no body
            }
            if (action !== "in" && action !== "out" && action !== "reset") return new Response("bad action", { status: 400 })
            return json({ zoom: on_zoom?.(action) ?? 1 })
        }
        if (path === "/api/appearance" && req.method === "POST") {
            try {
                const { scheme } = await req.json()
                if (scheme !== "light" && scheme !== "dark" && scheme !== "system") return new Response("bad scheme", { status: 400 })
                on_appearance?.(scheme)
                return json({ ok: true })
            } catch (e) {
                return new Response(String(e), { status: 500 })
            }
        }
        if (path === "/api/julia/launch" && req.method === "POST") {
            try {
                await on_launch(await req.json())
                return json({ ok: true })
            } catch (e) {
                return new Response(String(e), { status: 500 })
            }
        }
        if (path === "/launch") return page(launch_html)
        if (path === "/deck") {
            const url = state().url
            if (url == null) return new Response(null, { status: 302, headers: { location: "/" } })
            return page(deck_html(url))
        }
        // "/": the Launch Station until a boot begins; the live splash while one is under way
        return page(state().phase === "idle" ? launch_html : splash_html)
    })
}
