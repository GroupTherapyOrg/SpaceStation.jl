// App-wide light/dark override. Pluto's themes are `@media (prefers-color-scheme: …)` blocks
// (themes/light.css + themes/dark.css, plus scattered blocks in other sheets), which JS cannot
// toggle with a class — but CSSOM lets us rewrite each rule's media condition: the color-scheme
// CLAUSE (and only that clause) becomes always-true or never-true, so a compound condition like
// `(max-width: 700px) and (prefers-color-scheme: dark)` keeps its other clauses. One stored choice —
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

// A rewritten condition no longer contains prefers-color-scheme, so remember each rule's
// ORIGINAL condition the first time we see it; every later pass rewrites from that string.
const original_condition = new WeakMap()

// Substituted for the color-scheme clause ONLY — never the whole condition. A compound query
// like (max-width: 700px) and (prefers-color-scheme: dark) must keep its width clause, or
// forcing dark turns mobile-only rules on at desktop width.
const ALWAYS = "(min-width: 0px)"
const NEVER = "(min-width: 999999px)"

const rewrite = (rule, scheme) => {
    let orig = original_condition.get(rule)
    if (orig == null) {
        if (!/prefers-color-scheme/i.test(rule.media.mediaText)) return
        orig = rule.media.mediaText
        original_condition.set(rule, orig)
    }
    const next =
        scheme === "system"
            ? orig
            : orig.replace(/\(\s*prefers-color-scheme\s*:\s*(light|dark)\s*\)/gi, (_, want) => (want.toLowerCase() === scheme ? ALWAYS : NEVER))
    if (rule.media.mediaText !== next) rule.media.mediaText = next
}

// WKWebView keeps drawing the page's scroller with its pre-flip state after a color-scheme
// change — on a dark OS, forcing light left the notebook with no visible scrollbar at all.
// Destroying and recreating the scroller is the reliable fix: hide the root's overflow for one
// frame, then restore it along with the scroll position.
const recreate_scrollbars = () => {
    const de = document.documentElement
    const x = window.scrollX
    const y = window.scrollY
    const prev = de.style.overflow
    de.style.overflow = "hidden"
    requestAnimationFrame(() => {
        de.style.overflow = prev
        window.scrollTo(x, y)
    })
}

let last_applied = null

const apply = (scheme) => {
    // The media rewrite below only governs AUTHOR styles — the UA still colors its own defaults
    // (default text, form controls, scrollbars) from the page's declared color-scheme and the OS.
    // With a dark OS and a forced-light page that meant white UA text on light backgrounds
    // (invisible buttons, washed-out logs). The color-scheme PROPERTY on :root overrides the
    // meta and pins the UA side too. (The desktop shell additionally flips the native window
    // appearance to match, so WKWebView's own chrome follows along.)
    document.documentElement.style.colorScheme = scheme === "system" ? "" : scheme
    // apply() re-runs constantly (new stylesheets arrive with cell output) — only nudge the
    // scroller when the scheme actually changed, or it would flicker on every mutation.
    if (last_applied !== scheme) {
        last_applied = scheme
        recreate_scrollbars()
    }
    const walk_rules = (rules) => {
        for (const rule of rules) {
            if (rule.styleSheet != null) {
                walk(rule.styleSheet) // @import
                continue
            }
            if (rule.media != null) rewrite(rule, scheme)
            // grouping rules (@media, @supports, @layer) can nest more media rules
            if (rule.cssRules != null && rule.cssRules.length > 0) walk_rules(rule.cssRules)
        }
    }
    const walk = (sheet) => {
        try {
            walk_rules(sheet.cssRules)
        } catch (e) {
            return // cross-origin sheet: not ours, not our themes
        }
    }
    // Shadow roots keep their own stylesheets (some components render in shadow DOM) — walk them
    // too, along with any adopted (constructed) stylesheets.
    const walk_root = (root) => {
        for (const sheet of root.styleSheets ?? []) walk(sheet)
        for (const sheet of root.adoptedStyleSheets ?? []) walk(sheet)
        const walker = document.createTreeWalker(root === document ? document.documentElement : root, NodeFilter.SHOW_ELEMENT)
        let node
        while ((node = walker.nextNode())) {
            if (node instanceof Element && node.shadowRoot != null) walk_root(node.shadowRoot)
        }
    }
    walk_root(document)
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

// Stylesheets keep ARRIVING after load: notebook cell outputs inject their own <style> tags with
// their own prefers-color-scheme blocks (PlutoUI's TableOfContents is the canonical case), and
// they'd otherwise follow the OS instead of the override. Re-apply (idempotent — the WeakMap
// remembers rules already seen) whenever style/link nodes enter the document.
let reapply_timer = null
const schedule_reapply = () => {
    clearTimeout(reapply_timer)
    reapply_timer = setTimeout(() => apply(get_color_scheme()), 100)
}
new MutationObserver((mutations) => {
    for (const m of mutations) {
        for (const node of m.addedNodes) {
            if (!(node instanceof Element)) continue
            if (node.tagName === "STYLE" || node.tagName === "LINK" || node.querySelector("style, link[rel=stylesheet]") != null) {
                // a <link>'s rules exist only after it loads — re-apply then, too
                if (node.tagName === "LINK") node.addEventListener("load", schedule_reapply, { once: true })
                schedule_reapply()
                return
            }
        }
    }
}).observe(document.documentElement, { childList: true, subtree: true })
window.addEventListener("storage", (e) => {
    if (e.key === KEY) apply(get_color_scheme())
})
window.addEventListener("message", (e) => {
    const d = e.data
    if (d != null && d.type === "spacestation:color-scheme" && (d.scheme === "light" || d.scheme === "dark" || d.scheme === "system")) {
        set_color_scheme(d.scheme)
    }
})
