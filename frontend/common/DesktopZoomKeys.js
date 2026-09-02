// Zoom shortcuts for the desktop app (issue #66).
//
// The zoom itself is the webview's own: on macOS the shell sets WKWebView's `pageZoom` (the
// engine's page zoom, the same thing Safari's ⌘= does) and turns on native trackpad
// magnification; on Windows WebView2 zooms by itself on Ctrl+= / Ctrl+- / Ctrl+0 and Ctrl+wheel.
// Nothing here scales, anchors or reflows anything.
//
// What this module does is the one thing a page has to: WKWebView delivers ⌘= / ⌘- / ⌘0 to the
// focused document, and every SpaceStation page is a frame — this notebook inside the workspace
// hub inside the deck — so the keystroke is forwarded to the top document (the deck, served by the
// shell), which asks the shell to zoom. macOS only, desktop only: on Windows the page must NOT
// touch these keys, or it would block WebView2's built-in zoom; in a real browser the browser's
// own zoom stays untouched.

const mac = navigator.platform.toUpperCase().includes("MAC")

const arm = () => {
    window.addEventListener(
        "keydown",
        (e) => {
            if (!e.metaKey || e.ctrlKey || e.altKey) return
            // e.key varies with layout and shift ("=", "+", "±"); e.code names the physical key.
            const action = e.code === "Equal" || e.key === "+" || e.key === "=" ? "in" : e.code === "Minus" || e.key === "-" ? "out" : e.code === "Digit0" || e.key === "0" ? "reset" : null
            if (action == null) return
            e.preventDefault()
            e.stopPropagation()
            try {
                window.top?.postMessage({ type: "spacestation:zoom", action }, "*")
            } catch {}
        },
        { capture: true }
    )
}

if (mac && window.top !== window) {
    // Desktop only, by the server's own signal. The fetch is relative, so each origin asks its own server.
    fetch("./api/v1/config")
        .then((r) => r.json())
        .then((c) => {
            if (c?.desktop === true) arm()
        })
        .catch(() => {})
}
