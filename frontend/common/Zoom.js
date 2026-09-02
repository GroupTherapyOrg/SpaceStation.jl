// Notebook zoom for the desktop app (issue #66).
//
// The desktop shell is a bare webview: no browser chrome, so none of Cmd/Ctrl+`=`/`-`/`0`,
// Ctrl+wheel or trackpad pinch existed. This module gives the NOTEBOOK document (the editor page,
// which is its own frame inside the workspace) the zoom a standalone notebook tab gets in a
// browser, and nothing else: the hub — sidebar, tabs, terminal — stays at 100%, like browser
// chrome does. Zoom.js is imported by editor.js only.
//
//   * ENGINE LAYOUT, NOT REINVENTED SCALING. The CSS `zoom` property (CSS Viewport Module Level 1;
//     Chromium, WebKit and Gecko all ship it) is the engine's own layout-affecting zoom: every
//     absolute length is pre-multiplied, the content reflows to the viewport. The property lives
//     on <body>, whose `width: auto` still fills the viewport at every factor, so the page reflows
//     to the window exactly like browser zoom does. (The spec: "The zoom property has no effect on
//     <length> property values with computed values that are auto or <percentage>." That is also
//     why earlier versions' `width: calc(100% / z)` compensation was wrong — a percentage is NOT
//     scaled back up by zoom, so the compensated body only ever covered 1/z of the window,
//     leaving a growing empty band on the right when zooming in and an over-wide, clipped page
//     that shifted sideways when zooming out.)
//   * NOT THE DOCUMENT ROOT. Zooming <html> puts the scrolling element itself under zoom, and
//     WebKit then reports scroll offsets and rects in different coordinate spaces; with the zoom on
//     <body> the scroller stays unzoomed and every scroll primitive keeps working.
//   * ANCHORED. Browsers keep the content you were looking at in place when zoom changes; CSS
//     `zoom` alone does not. The cell under the viewport's center is kept under the center through
//     every step, using the engine's own hit-testing and rect reporting so it holds in both WebKit
//     and Chromium, whose rect conventions under zoom differ.
//   * PER ORIGIN: remembered per workspace (each workspace is its own origin), like per-site zoom
//     in a browser; same-origin editor frames follow live through `storage` events.
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

/** The zoom currently applied to the page (what the DOM says, not what storage says). */
const applied_zoom = () => {
    const z = Number(document.body?.style.zoom)
    return Number.isFinite(z) && z > 0 ? z : 1
}

const apply = (z) => {
    const el = document.body
    if (!(el instanceof HTMLElement)) return
    el.style.zoom = z === 1 ? "" : String(z)
    // width stays `auto` — see the header: auto fills the viewport at every factor, percentages do not
    el.style.width = ""
}

/** Document-space rect of `el` (top relative to the document, in the unzoomed scroller's pixels),
 *  whichever convention the engine uses for rects under `zoom`. The spec says getBoundingClientRect
 *  returns scaled lengths (Chromium: plain viewport pixels); WebKit divides sizes AND the document
 *  position by the element's zoom while the scroll offset it subtracts stays unzoomed, so its client
 *  `top` is `doc_top / z - scrollTop`. Working in document space (`top + scrollTop`) makes both a
 *  single scale factor away from the truth, and the body calibrates that factor: its layout width IS
 *  the viewport width, so the width it reports tells us what the engine divides by. */
const doc_rect = (el) => {
    const scroll_top = document.scrollingElement?.scrollTop ?? 0
    const bw = document.body.getBoundingClientRect().width
    const k = bw > 0 ? bw / window.innerWidth : 1
    const r = el.getBoundingClientRect()
    return { top: (r.top + scroll_top) / k, height: r.height / k }
}

/** The cell under the viewport's center row (a few x positions, so a narrow or off-center layout
 *  still finds one); never a page-level container, whose "center" is meaningless. */
const anchor_cell = () => {
    const y = window.innerHeight / 2
    for (const fx of [0.5, 0.35, 0.65, 0.2, 0.8]) {
        const hit = document.elementFromPoint(window.innerWidth * fx, y)
        const cell = hit?.closest?.("pluto-cell")
        if (cell != null) return cell
    }
    return null
}

/** Apply the zoom AND keep the content at the viewport's center where it was. */
const apply_anchored = (z) => {
    const previous = applied_zoom()
    const se = document.scrollingElement
    const cy = window.innerHeight / 2
    const anchor = anchor_cell()
    // where inside the anchor the center line falls, as a fraction, so a tall cell stays put too
    let fraction = 0
    if (anchor != null && se != null) {
        const r0 = doc_rect(anchor)
        fraction = r0.height > 0 ? (se.scrollTop + cy - r0.top) / r0.height : 0
    }
    apply(z)
    if (se == null) return
    if (anchor != null) {
        const r1 = doc_rect(anchor)
        se.scrollTop = r1.top + fraction * r1.height - cy
    } else if (previous !== z) {
        // nothing anchorable under the center (the header, an empty page): scale the scroll offset
        se.scrollTop = (se.scrollTop + cy) * (z / previous) - cy
    }
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
    // the control is chrome, not content: nested zoom multiplies, so 1/z keeps it at 100%
    el.style.zoom = z === 1 ? "" : String(1 / z)
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
