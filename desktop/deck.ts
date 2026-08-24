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
    /* The strip sits where the (transparent) macOS title bar is: leave room for the traffic
       lights, and let the bar act as the drag area where the platform supports it. */
    #strip {
        height: 38px; flex-shrink: 0; display: flex; align-items: stretch; gap: 2px;
        padding: 5px 8px 0 84px; background: #0f0d16; -webkit-app-region: drag; user-select: none;
    }
    .tab {
        -webkit-app-region: no-drag; display: flex; align-items: center; gap: 0.45rem; max-width: 15rem;
        padding: 0 0.65rem; border-radius: 7px 7px 0 0; color: #9a93b8; font-size: 12.5px; cursor: default;
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
    #newtab {
        -webkit-app-region: no-drag; border: 0; background: none; color: #9a93b8; font-size: 16px;
        padding: 0 0.55rem; border-radius: 7px 7px 0 0; cursor: pointer; align-self: stretch;
    }
    #newtab:hover { background: #1a1725; color: #e8e4f5; }
    #stage { flex: 1; position: relative; background: #16141f; }
    #stage iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; display: none; }
    #stage iframe.active { display: block; }
</style>
</head>
<body>
    <div id="strip"><button id="newtab" title="Open another workspace (from the Launcher)">＋</button></div>
    <div id="stage"></div>
    <script>
        const LAUNCHER_URL = ${JSON.stringify(launcher_url)}
        const strip = document.getElementById("strip")
        const stage = document.getElementById("stage")
        const newtab = document.getElementById("newtab")

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

        const frame_for = (tab) => {
            let f = document.getElementById("frame-" + tab.id)
            if (f == null) {
                f = document.createElement("iframe")
                f.id = "frame-" + tab.id
                f.src = tab.url
                // clipboard inside the frames: the terminal and notebook copy/paste need this
                f.allow = "clipboard-read; clipboard-write; fullscreen"
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
                strip.insertBefore(el, newtab)
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
            let origin
            try {
                origin = new URL(url).origin
            } catch {
                return
            }
            const existing = tabs.find((t) => t.id !== "launcher" && new URL(t.url).origin === origin)
            if (existing) return activate(existing.id)
            const tab = { id: "ws-" + origin.replace(/\\W/g, "-"), title: String(title || origin), url }
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
        })
        newtab.onclick = () => activate("launcher")
        render()
    </script>
</body>
</html>`
