// The deck: the desktop app's own chrome — a Warp-style tab strip in the title bar area with the
// Launcher pinned first and each workspace as a tab, every tab a live iframe underneath. The hub
// pages inside detect they're framed (window.self !== window.top) and ask the deck to open
// workspaces via postMessage instead of navigating anywhere, so nothing can ever escape the
// window. Tabs stay alive when inactive (display toggling, like the hub's own notebook tabs) and
// survive a ⌘R via sessionStorage.

export const deck_html = (launcher_url: string) => /* html */ `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>SpaceStation</title>
<style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; height: 100vh; display: flex; flex-direction: column; background: #0f0d16; font-family: system-ui, -apple-system, sans-serif; }
    /* Two layouts. Default: the strip sits under the (blended, untitled) native bar. Inset
       (?inset=1 — macOS with content extended under the title bar): the strip IS the title-bar
       row — Warp-style — so it leaves room for the traffic lights and centers the tabs. */
    #strip {
        height: 30px; flex-shrink: 0; display: flex; align-items: stretch; gap: 2px;
        padding: 0 8px 0 10px; background: #0f0d16; -webkit-app-region: drag; user-select: none;
    }
    /* 28px = the native title bar height, so the tab pills center on the traffic lights' row */
    body.inset #strip { height: 28px; padding: 3px 8px 3px 84px; transition: padding-left 0.12s ease-out; }
    /* fullscreen hides the traffic lights, so the gap reserved for them would just be dead
       space — reclaim it and let the tabs sit where every other row starts */
    body.inset.fullscreen #strip { padding-left: 10px; }
    body.inset .tab { border-radius: 6px; }
    .tab {
        -webkit-app-region: no-drag; display: flex; align-items: center; gap: 0.45rem; max-width: 15rem;
        padding: 0 0.65rem; border-radius: 7px 7px 0 0; color: #9a93b8; font-size: 12.5px; cursor: pointer;
        white-space: nowrap; overflow: hidden;
    }
    .tab .title { overflow: hidden; text-overflow: ellipsis; }
    .tab:hover { background: #1a1725; }
    .tab.active { background: #16141f; color: #e8e4f5; }
    .tab .close {
        -webkit-app-region: no-drag; border: 0; background: none; color: #6a6485; font-size: 13px;
        padding: 1px 4px; border-radius: 4px; cursor: pointer; line-height: 1;
    }
    .tab .close:hover { background: #2b2740; color: #e8e4f5; }
    #stage { flex: 1; position: relative; background: #16141f; }
    #stage iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; display: none; }
    #stage iframe.active { display: block; }
</style>
</head>
<body>
    <div id="strip"></div>
    <div id="stage"></div>
    <script>
        const LAUNCHER_URL = ${JSON.stringify(launcher_url)}
        const strip = document.getElementById("strip")
        const stage = document.getElementById("stage")
        document.body.classList.toggle("inset", new URLSearchParams(location.search).has("inset"))
        // The strip's -webkit-app-region CSS is inert in WKWebView (a Chromium feature), so the
        // window was never draggable from it. Instead: mousedown on strip background (not a tab)
        // asks the shell to start a native window drag.
        strip.addEventListener("mousedown", (e) => {
            if (e.button === 0 && e.target.closest(".tab") == null) fetch("./api/drag", { method: "POST" }).catch(() => {})
        })

        // Entering/leaving fullscreen always resizes the window, so ask the shell then (rather
        // than polling): it reads the window's own NSWindowStyleMaskFullScreen bit. Geometry
        // heuristics were tried for this and lost to notch/menu-bar edge cases. Non-macOS shells
        // answer false and the inset layout never applies there anyway.
        const sync_fullscreen = async () => {
            try {
                const s = await (await fetch("./api/window")).json()
                document.body.classList.toggle("fullscreen", s.fullscreen === true)
            } catch {}
        }
        let fs_timer = null
        addEventListener("resize", () => {
            clearTimeout(fs_timer)
            // after the transition animation settles, so we read the final state once
            fs_timer = setTimeout(sync_fullscreen, 150)
        })
        sync_fullscreen()
        // NOTE: no fullscreen special-casing, deliberately. Auto-hiding the strip in sync with the
        // native fullscreen overlay was tried and looked broken more ways than it looked native
        // (notch geometry, the overlay stealing the mouse, unrelated helper windows). The strip is
        // simply always there, windowed or fullscreen — fixed, predictable chrome.

        /** @type {Array<{id: string, title: string, url: string}>} */
        let tabs = [{ id: "launcher", title: "Launcher", url: LAUNCHER_URL }]
        let active = "launcher"
        // Survive a reload (⌘R): same page origin for the whole app run, so sessionStorage holds
        // the open tabs. (The shell's port changes per launch, which conveniently resets this.)
        try {
            const saved = JSON.parse(sessionStorage.getItem("spacestation deck") ?? "null")
            if (saved && Array.isArray(saved.tabs) && saved.tabs.length > 0) {
                tabs = saved.tabs
                tabs[0] = { id: "launcher", title: "Launcher", url: LAUNCHER_URL } // launcher is pinned
                active = saved.active ?? "launcher"
            }
        } catch {}
        const persist = () => {
            try {
                sessionStorage.setItem("spacestation deck", JSON.stringify({ tabs, active }))
            } catch {}
        }

        // the launcher's appearance choice, rebroadcast to every workspace tab (other origins —
        // their own ports — so localStorage can't reach them)
        let scheme = null
        try {
            scheme = sessionStorage.getItem("spacestation deck scheme")
        } catch {}
        const send_scheme = (f) => {
            if (scheme == null) return
            try {
                f.contentWindow.postMessage({ type: "spacestation:color-scheme", scheme }, "*")
            } catch {}
        }

        const frame_for = (tab) => {
            let f = document.getElementById("frame-" + tab.id)
            if (f == null) {
                f = document.createElement("iframe")
                f.id = "frame-" + tab.id
                f.src = tab.url
                // clipboard inside the frames: the terminal and notebook copy/paste need this
                f.allow = "clipboard-read; clipboard-write; fullscreen"
                f.addEventListener("load", () => send_scheme(f))
                stage.appendChild(f)
            }
            return f
        }

        const render = () => {
            for (const el of strip.querySelectorAll(".tab")) el.remove()
            for (const tab of tabs) {
                const el = document.createElement("div")
                el.className = "tab" + (tab.id === active ? " active" : "")
                el.title = tab.url
                const title = document.createElement("span")
                title.className = "title"
                title.textContent = tab.title
                el.appendChild(title)
                if (tab.id !== "launcher") {
                    const close = document.createElement("button")
                    close.className = "close"
                    close.textContent = "×"
                    close.title = "Close tab (the workspace keeps running — reopen it from the Launcher)"
                    close.onclick = (e) => {
                        e.stopPropagation()
                        document.getElementById("frame-" + tab.id)?.remove()
                        tabs = tabs.filter((t) => t.id !== tab.id)
                        if (active === tab.id) active = "launcher"
                        persist()
                        render()
                    }
                    el.appendChild(close)
                }
                el.onclick = () => activate(tab.id)
                strip.appendChild(el)
            }
            for (const tab of tabs) frame_for(tab).className = tab.id === active ? "active" : ""
        }

        const activate = (id) => {
            active = id
            persist()
            render()
        }
        window.focus_launcher = () => activate("launcher") // the app menu's "Back to Launcher" calls this

        // A tab is one server (one origin/port): opening the same workspace again focuses its tab.
        const open_tab = (url, title) => {
            let u
            try {
                u = new URL(url)
            } catch {
                return
            }
            // Keep every tab SAME-SITE with the deck: the servers' auth cookie is SameSite=Strict,
            // and "localhost" vs "127.0.0.1" are different sites — a mismatched iframe still loads
            // (the URL carries ?secret) but the cookie is withheld and every API call 403s. Child
            // and SSH-tunnel URLs are loopback by construction, so unify the hostname on ours.
            if (u.hostname === "localhost" || u.hostname === "127.0.0.1") u.hostname = location.hostname
            const origin = u.origin
            const existing = tabs.find((t) => t.id !== "launcher" && new URL(t.url).origin === origin)
            if (existing) return activate(existing.id)
            const tab = { id: "ws-" + origin.replace(/\\W/g, "-"), title: String(title || origin), url: u.href }
            tabs.push(tab)
            activate(tab.id)
        }

        // The hub pages inside the iframes drive the deck: open-workspace when a workspace is
        // ready or clicked, focus-launcher for their Home button.
        window.addEventListener("message", (e) => {
            const d = e.data
            if (d == null || typeof d !== "object") return
            if (d.type === "spacestation:open-workspace" && typeof d.url === "string") open_tab(d.url, d.title)
            if (d.type === "spacestation:focus-launcher") activate("launcher")
            if (d.type === "spacestation:color-scheme" && typeof d.scheme === "string") {
                scheme = d.scheme
                try {
                    sessionStorage.setItem("spacestation deck scheme", scheme)
                } catch {}
                for (const f of stage.querySelectorAll("iframe")) send_scheme(f)
                // The shell flips the native window appearance to match (macOS): WKWebView's own
                // chrome (scrollbars, form controls) follows the window, not the page's CSS, and
                // repaints reliably only through this native path. Also persists the choice.
                fetch("./api/appearance", {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ scheme }),
                }).catch(() => {})
            }
        })
        render()
    </script>
</body>
</html>`
