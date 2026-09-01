// Notebook zoom for the desktop app (issue #66), take two.
//
// The first version applied page zoom to EVERY document, which scaled the hub chrome, the
// sidebar and the terminal along with the notebook — in a browser those live in other tabs, so
// real browser zoom never feels like that — and it did nothing about scroll position, so the
// view lurched on every step. This version matches what zooming a standalone notebook tab in a
// real browser gives you:
//
//   * SCOPED: only the notebook (editor) document zooms. The hub — sidebar, tabs, terminal —
//     stays at 100%, like browser chrome does. Zoom.js is imported by editor.js only.
//   * ENGINE LAYOUT, NOT REINVENTED SCALING: the CSS `zoom` property on the notebook root is the
//     engine's own zoom implementation — lengths scale, the content reflows to the viewport.
//   * ANCHORED: browsers keep the visible content stable when zoom changes; CSS `zoom` alone
//     does not, so the scroll position is corrected to keep the viewport CENTER on the same
//     content, every step, exactly the anchoring a browser does.
//   * PER ORIGIN: remembered per workspace (each workspace is its own origin), like per-site
//     zoom in a browser; same-origin editor frames follow live through `storage` events.
//
// Desktop-only by the server signal (/api/v1/config desktop:true): in a real browser this module
// applies a stored zoom and otherwise stays inert, so it never fights the browser's own zoom.

import { t } from "./lang.js"

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

/** Apply the zoom AND keep the content at the viewport's center where it was.
 *
 *  The zoom goes on the notebook's <main> container, NOT the document root. Root-level zoom is
 *  the cursed path in WebKit: scroll coordinates and even the engine's own scrollIntoView
 *  mis-compute under it (both were measured drifting ~6000px in the key-event probe). Zooming a
 *  container with compensated width — zoom: z; width: calc(100%/z) — reflows the content to the
 *  viewport exactly like browser zoom, while the document scroller stays unzoomed and every
 *  scroll primitive keeps working. It also scopes tighter: the editor's own header stays 100%.
 */
const zoom_target = () => document.querySelector("main") ?? document.documentElement

const apply = (z) => {
    const el = zoom_target()
    if (!(el instanceof HTMLElement)) return
    el.style.zoom = z === 1 ? "" : String(z)
    el.style.width = z === 1 ? "" : `calc(100% / ${z})`
}

const apply_anchored = (z) => {
    // remember the element at the viewport center, let the engine re-center it afterwards
    let anchor = document.elementFromPoint(window.innerWidth / 2, window.innerHeight / 2)
    if (anchor != null && (anchor === document.documentElement || anchor === document.body || anchor.closest?.("#zoom-indicator") != null)) anchor = null
    apply(z)
    anchor?.scrollIntoView({ block: "center", inline: "nearest" })
}

// ---- the indicator, which doubles as the mouse-only control (− % +), browser-style ----
// While zoomed it stays on screen (dimmed when idle); clicking the percentage resets to 100%,
// so an accidental pinch always has a visible way back. At 100% it disappears.
let indicator_timer = null
const update_indicator = (z, flash) => {
    let el = document.getElementById("zoom-indicator")
    if (el == null) {
        // built into a local const: closures over a reassigned `let` defeat TS's null narrowing
        const made = document.createElement("div")
        made.id = "zoom-indicator"
        made.setAttribute("role", "status")
        const mk = (cls, text, title, action) => {
            const b = document.createElement("button")
            b.className = cls
            b.textContent = text
            b.title = title
            b.tabIndex = -1
            // the click must not steal focus from the cell being edited
            b.addEventListener("mousedown", (e) => e.preventDefault())
            b.addEventListener("click", action)
            made.appendChild(b)
        }
        mk("zoom-step-out", "−", t("t_zoom_out"), () => step(-1))
        mk("zoom-reset", "100%", t("t_zoom_reset"), () => set_zoom(1))
        mk("zoom-step-in", "+", t("t_zoom_in"), () => step(+1))
        document.body.appendChild(made)
        el = made
    }
    const reset = el.querySelector(".zoom-reset")
    if (reset != null) reset.textContent = `${Math.round(z * 100)}%`
    clearTimeout(indicator_timer)
    if (z === 1) {
        if (flash) {
            el.classList.add("visible")
            el.classList.remove("idle")
            indicator_timer = setTimeout(() => el.classList.remove("visible"), 1200)
        } else {
            el.classList.remove("visible")
        }
    } else {
        el.classList.add("visible")
        el.classList.remove("idle")
        indicator_timer = setTimeout(() => el.classList.add("idle"), 1600)
    }
}

export const set_zoom = (z) => {
    z = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z))
    try {
        localStorage.setItem(KEY, String(z))
    } catch {}
    apply_anchored(z)
    update_indicator(z, true)
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

// Apply the stored zoom on load (anchoring is a no-op at scrollTop 0), and surface the control
// if the notebook comes up zoomed. Harmless at 100%.
const boot = () => {
    apply_anchored(get_zoom())
    update_indicator(get_zoom(), false)
}
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot)
else boot()

// Another same-origin editor frame changed the zoom: follow it, chip synced, no flash.
window.addEventListener("storage", (e) => {
    if (e.key === KEY) {
        const z = get_zoom()
        apply_anchored(z)
        update_indicator(z, false)
    }
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
