// App-wide light/dark override. Pluto's themes are `@media (prefers-color-scheme: …)` blocks
// (themes/light.css + themes/dark.css, plus scattered blocks in other sheets), which JS cannot
// toggle with a class — but CSSOM lets us rewrite each rule's media condition: forcing dark turns
// the dark blocks into `all` and the light blocks into `not all` (and back). One stored choice —
// "system" | "light" | "dark" — applies to every same-origin page: the hub, the editor iframes
// inside it, and standalone editor tabs, kept live via `storage` events. (The integrated
// terminal's own scheme toggle is deliberately separate — a light UI with a dark terminal is a
// legitimate preference.)
//
// Importing this module applies the stored choice; the hub renders the toggle button.

const KEY = "spacestation color scheme"

// Workspaces run on their own ports — separate localStorage origins — so the launcher's choice
// reaches them two ways: a ?scheme= seed stamped on workspace links (browser tabs), and
// "spacestation:color-scheme" postMessages rebroadcast by the desktop deck (live switching).
const seed = new URLSearchParams(window.location.search).get("scheme")
if (seed === "light" || seed === "dark" || seed === "system") {
    try {
        localStorage.setItem(KEY, seed)
    } catch (e) {}
}

export const get_color_scheme = () => {
    try {
        const s = localStorage.getItem(KEY)
        return s === "light" || s === "dark" ? s : "system"
    } catch (e) {
        return "system"
    }
}

/** For JS that needs the effective answer (e.g. CodeMirror dark flags) — the override first,
 *  the OS preference otherwise. */
export const prefers_dark = () => {
    const s = get_color_scheme()
    if (s !== "system") return s === "dark"
    return window.matchMedia("(prefers-color-scheme: dark)").matches
}

// A rule's original identity (dark-block or light-block) is unrecoverable once its condition has
// been rewritten to all/not all — remember it the first time we see the rule.
const identity = new WeakMap()

const apply = (scheme) => {
    const walk = (sheet) => {
        let rules
        try {
            rules = sheet.cssRules
        } catch (e) {
            return // cross-origin sheet: not ours, not our themes
        }
        for (const rule of rules) {
            if (rule.styleSheet != null) {
                walk(rule.styleSheet) // @import
                continue
            }
            if (rule.media == null) continue
            let kind = identity.get(rule)
            if (kind == null && /prefers-color-scheme/.test(rule.media.mediaText)) {
                kind = rule.media.mediaText.includes("dark") ? "dark" : "light"
                identity.set(rule, kind)
            }
            if (kind == null) continue
            rule.media.mediaText = scheme === "system" ? `(prefers-color-scheme: ${kind})` : scheme === kind ? "all" : "not all"
        }
    }
    for (const sheet of document.styleSheets) walk(sheet)
}

export const set_color_scheme = (scheme) => {
    try {
        localStorage.setItem(KEY, scheme)
    } catch (e) {}
    apply(scheme)
}

export const cycle_color_scheme = () => {
    const order = ["system", "light", "dark"]
    const next = order[(order.indexOf(get_color_scheme()) + 1) % order.length]
    set_color_scheme(next)
    return next
}

// Apply on load (sheets must be parsed first), and follow changes made in any other same-origin
// page — the hub toggling re-themes every open editor iframe and tab live.
const init = () => apply(get_color_scheme())
if (document.readyState === "complete") init()
else window.addEventListener("load", init)
window.addEventListener("storage", (e) => {
    if (e.key === KEY) apply(get_color_scheme())
})
window.addEventListener("message", (e) => {
    const d = e.data
    if (d != null && d.type === "spacestation:color-scheme" && (d.scheme === "light" || d.scheme === "dark" || d.scheme === "system")) {
        set_color_scheme(d.scheme)
    }
})
