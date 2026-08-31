// Browser-style zoom for the desktop app (issue #66). In a browser, Cmd/Ctrl+= / - / 0 and
// pinch are chrome features; the desktop shell is a bare webview with no chrome, so none of it
// existed there. This module recreates it the way Chrome behaves: the familiar zoom ladder,
// remembered PER ORIGIN — which, since every workspace is its own origin, gives per-workspace
// zoom for free, exactly like per-site zoom in a real browser.
//
// Desktop-only by a server signal, not by guesswork: /api/v1/config reports desktop:true when the
// server was launched by the shell. In a real browser that's false and this module does nothing,
// so the browser's own zoom keeps working without us double-zooming on top of it. (Pages CAN
// preempt browser zoom via preventDefault — that is why gating matters.)
//
// Importing applies the stored zoom; the keyboard/trackpad wiring arms only in desktop mode.
// Same-origin frames (the hub's editor iframes) stay in sync through `storage` events, the same
// mechanism ColorScheme.js uses.

const KEY = "spacestation zoom"
// Chrome's ladder, for muscle-memory-compatible steps.
const MIN_ZOOM = 0.25
const MAX_ZOOM = 5
const LADDER = [MIN_ZOOM, 1 / 3, 0.5, 2 / 3, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, MAX_ZOOM]

export const get_zoom = () => {
    try {
        const z = Number(localStorage.getItem(KEY))
        return Number.isFinite(z) && z >= MIN_ZOOM && z <= MAX_ZOOM ? z : 1
    } catch {
        return 1
    }
}

const apply = (z) => {
    // Standard CSS `zoom` (WebKit has shipped it forever; standardized 2024): layout-affecting,
    // so clientWidth changes and ResizeObservers fire — the terminal refits, CodeMirror reflows,
    // exactly as they do under real browser zoom.
    document.documentElement.style.zoom = z === 1 ? "" : String(z)
}

let indicator_timer = null
const show_indicator = (z) => {
    let el = document.getElementById("zoom-indicator")
    if (el == null) {
        el = document.createElement("div")
        el.id = "zoom-indicator"
        el.setAttribute("role", "status")
        document.body.appendChild(el)
    }
    el.textContent = `${Math.round(z * 100)}%`
    el.classList.add("visible")
    clearTimeout(indicator_timer)
    indicator_timer = setTimeout(() => el.classList.remove("visible"), 1200)
}

export const set_zoom = (z) => {
    z = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))
    try {
        localStorage.setItem(KEY, String(z))
    } catch {}
    apply(z)
    show_indicator(z)
}

const step = (direction) => {
    const current = get_zoom()
    // nearest ladder rung, then move one step — so continuous pinch and discrete keys interleave sanely
    let nearest = 0
    let best = Infinity
    LADDER.forEach((v, i) => {
        const d = Math.abs(v - current)
        if (d < best) {
            best = d
            nearest = i
        }
    })
    const next = LADDER[Math.min(LADDER.length - 1, Math.max(0, nearest + direction))]
    if (next !== undefined) set_zoom(next)
}

// Apply the stored zoom on load in every context (harmless at 1). The event wiring below is
// desktop-gated; applying isn't, so a same-origin frame opened later starts at the right zoom
// even before the config answer arrives.
apply(get_zoom())

window.addEventListener("storage", (e) => {
    if (e.key === KEY) apply(get_zoom())
})

const arm = () => {
    const mac = navigator.platform.toUpperCase().includes("MAC")
    window.addEventListener(
        "keydown",
        (e) => {
            const mod = mac ? e.metaKey && !e.ctrlKey : e.ctrlKey
            if (!mod || e.altKey) return
            // e.key varies with layout and shift ("=", "+", "±"); e.code names the physical key.
            if (e.code === "Equal" || e.key === "+" || e.key === "=") {
                e.preventDefault()
                step(+1)
            } else if (e.code === "Minus" || e.key === "-") {
                e.preventDefault()
                step(-1)
            } else if (e.code === "Digit0" || e.key === "0") {
                e.preventDefault()
                set_zoom(1)
            }
        },
        { capture: true }
    )
    // Ctrl+wheel is how Chromium delivers both the keyboard-modifier scroll AND trackpad pinch.
    let wheel_accum = 0
    window.addEventListener(
        "wheel",
        (e) => {
            if (!e.ctrlKey) return
            e.preventDefault()
            wheel_accum += -e.deltaY
            if (Math.abs(wheel_accum) > 30) {
                step(wheel_accum > 0 ? +1 : -1)
                wheel_accum = 0
            }
        },
        { capture: true, passive: false }
    )
    // WebKit delivers trackpad pinch as proprietary gesture events (not ctrl+wheel like Chromium).
    let gesture_base = 1
    window.addEventListener("gesturestart", (e) => {
        e.preventDefault()
        gesture_base = get_zoom()
    })
    window.addEventListener("gesturechange", (e) => {
        e.preventDefault()
        // @ts-ignore — e.scale is the WebKit gesture event's own property
        set_zoom(gesture_base * e.scale)
    })
    window.addEventListener("gestureend", (e) => e.preventDefault())
}

// Desktop only — see the header. The fetch is relative, so each origin asks its own server.
fetch("./api/v1/config")
    .then((r) => r.json())
    .then((c) => {
        if (c?.desktop === true) arm()
    })
    .catch(() => {})
