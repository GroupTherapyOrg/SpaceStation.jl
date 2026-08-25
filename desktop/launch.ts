// The Launch Station: pick which Julia powers this launch. Mirrors the SpaceStation launcher's
// design (same card, pills, headings — theme.ts) so it reads as the first screen of the same
// product. Three audiences, one page:
//   • power users — every installed juliaup channel, one click launches it
//   • one-click installs — curated channels not yet installed (juliaup add, progress on splash)
//   • complete newbies — no Julia at all: a single "Install Julia" button (juliaup bootstrap)
//
// EVERY control here is the action it names — click a version to launch it, click an update
// chip to update-then-launch, click an install row to install-then-launch. There is no separate
// confirm button: a row that says "1.12.6" plus a chip that says "update to 1.12.7" are two
// different one-click actions, not a selection waiting for a second decision below the fold.
// The "always use this" checkbox is the VS Code-style don't-ask-again: it applies to whichever
// action you click (SpaceStation menu → "Julia Version…" brings the picker back).

import { base_css, logo_svg } from "./theme.ts"

export const launch_html = /* html */ `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>SpaceStation</title>
<style>
${base_css}
    .rows { display: flex; flex-direction: column; gap: 0.45rem; }
    h2 .hint { font-weight: normal; text-transform: none; letter-spacing: normal; font-size: 0.78rem; opacity: 0.55; margin-left: 0.6rem; }
    /* The footer bar owns the card's bottom edge: the card gives up its bottom padding and the
       full-bleed sticky bar supplies it, so the scrolling list disappears cleanly under the bar
       instead of peeking out through the padding gap beneath it. */
    .card { padding-bottom: 0; }
    .footer {
        display: flex; align-items: center; gap: 1rem;
        position: sticky; bottom: 0; margin: 1.6rem -2rem 0; padding: 0.8rem 2rem 1.4rem;
        background: var(--code-background); border-top: 1px solid var(--rule-color);
    }
    .remember { display: flex; align-items: center; gap: 0.45rem; font-size: 0.85rem; opacity: 0.8; cursor: pointer; user-select: none; }
    .remember input { accent-color: var(--accent); }
    .note { font-size: 0.78rem; opacity: 0.55; margin: 0.9rem 0 1.4rem; }
    .cancel { margin-left: auto; font-size: 0.85rem; opacity: 0.6; color: inherit; }
    #error { color: #ff8a8a; font-size: 0.85rem; margin-top: 0.8rem; }
    .pill.busy { box-shadow: inset 0 0 0 2px var(--accent); opacity: 1; }
    body.launching .pill:not(.busy), body.launching input.anyver { opacity: 0.45; pointer-events: none; }
    .update-badge {
        margin-left: auto; border: none; font: inherit; font-size: 0.68rem; text-transform: uppercase;
        letter-spacing: 0.07em; color: inherit; background: none; cursor: pointer; padding: 0.15rem 0.55rem;
        border-radius: 1000px; box-shadow: inset 0 0 0 1px var(--accent); opacity: 0.85;
    }
    .update-badge:hover, .update-badge.busy { background-color: var(--accent); color: white; opacity: 1; }
    .pill .badge + .update-badge { margin-left: 0.6rem; }
    input.anyver {
        border: none; font: inherit; font-size: 0.88rem; color: inherit; background-color: var(--main-bg-color);
        border-radius: 1000px; padding: 0.45rem 0.9rem; width: 100%;
        font-family: JuliaMono, ui-monospace, Menlo, Consolas, monospace;
    }
    input.anyver:focus { outline: none; box-shadow: inset 0 0 0 2px var(--accent); }
</style>
</head>
<body>
    <div class="dragbar"></div>
    <div class="bubble card">
        <header>
            ${logo_svg}
            <h1>Space<span class="land-accent">Station</span></h1>
            <p class="subtitle">Click the Julia that should power this launch.</p>
        </header>
        <div id="content"><h2>Looking for Julia…</h2></div>
        <div id="error"></div>
        <div class="footer">
            <label class="remember"><input type="checkbox" id="remember" /> Always use what I pick — don't ask at launch</label>
            <a class="cancel" id="cancel" href="/deck" style="display: none">Cancel</a>
        </div>
        <div class="note" id="restart-note" style="display: none">Switching versions restarts the SpaceStation server — running notebooks stop.</div>
    </div>
    <script>
        const content = document.getElementById("content")
        let launching = false

        // The clicked control IS the action: post the launch immediately, show what is happening
        // on the control itself, and hand off to the splash. No selection state, no second button.
        const go = async (action, el, busy_text) => {
            if (launching || action == null) return
            launching = true
            document.body.classList.add("launching")
            if (el != null) {
                el.classList.add("busy")
                const label = el.querySelector("span") ?? el
                label.textContent = busy_text
            }
            try {
                const res = await fetch("./api/julia/launch", {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ ...action, remember: document.getElementById("remember").checked }),
                })
                if (!res.ok) throw new Error("launch failed: " + res.status)
                location.replace("/")
            } catch (e) {
                document.getElementById("error").textContent = String(e)
                launching = false
                document.body.classList.remove("launching")
                el?.classList.remove("busy")
            }
        }

        const row = (label, mono, badge, action, busy_text) => {
            const el = document.createElement("button")
            el.className = "pill"
            el.innerHTML = \`<span>\${label}</span>\` + (mono ? \`<span class="mono">\${mono}</span>\` : "") + (badge ? \`<span class="badge">\${badge}</span>\` : "")
            el.onclick = () => go(action, el, busy_text)
            return el
        }

        const render = (info) => {
            content.innerHTML = ""
            const rows = (title, hint) => {
                const h = document.createElement("h2")
                h.textContent = title
                if (hint) {
                    const s = document.createElement("span")
                    s.className = "hint"
                    s.textContent = hint
                    h.appendChild(s)
                }
                content.appendChild(h)
                const d = document.createElement("div")
                d.className = "rows"
                content.appendChild(d)
                return d
            }
            let preferred = null
            if (info.juliaup) {
                const catalog = info.catalog ?? { aliases: [], minors: [], versions: [], updates: {} }
                const installed = rows("Installed Julias", "click to launch")
                for (const ch of info.juliaup.channels) {
                    const is_default = ch.name === info.juliaup.default
                    const latest = catalog.updates[ch.name]
                    const el = row("Julia " + ch.name, ch.version, is_default ? "default" : "", { channel: ch.name }, "launching…")
                    if (latest) {
                        // updating is its own one-click action: the row launches what you have,
                        // the chip updates first and then launches — each does what it says
                        const up = document.createElement("button")
                        up.className = "update-badge"
                        up.textContent = "update to " + latest
                        up.title = "Run juliaup update " + ch.name + " (fetches " + latest + "), then launch on it"
                        up.onclick = (e) => {
                            e.stopPropagation()
                            go({ channel: ch.name, update: true }, up, "updating…")
                        }
                        el.appendChild(up)
                    }
                    installed.appendChild(el)
                    if (info.settings.channel === ch.name) preferred = el
                    if (preferred == null && is_default) preferred = el
                }
                const have = (name) => info.juliaup.channels.some((ch) => ch.name === name)
                const offers = [...catalog.aliases, ...catalog.minors.slice(0, 6)].filter((c) => !have(c.name))
                const more = rows("Get another version", "click to install and launch")
                for (const c of offers) more.appendChild(row("Julia " + c.name, c.version, "install", { add_channel: c.name }, "installing…"))
                if (catalog.versions.length > 0) {
                    const any = document.createElement("input")
                    any.className = "anyver"
                    any.placeholder = "…or type any exact version (e.g. " + catalog.versions[0] + ") and press Enter"
                    any.setAttribute("list", "all-julias")
                    const dl = document.createElement("datalist")
                    dl.id = "all-julias"
                    for (const v of catalog.versions) {
                        const o = document.createElement("option")
                        o.value = v
                        dl.appendChild(o)
                    }
                    any.addEventListener("keydown", (e) => {
                        const v = any.value.trim()
                        if (e.key === "Enter" && v !== "") go(have(v) ? { channel: v } : { add_channel: v }, null, "")
                    })
                    // a datalist PICK launches right away; typed keystrokes wait for Enter (a
                    // typed value can be a prefix of a longer version, e.g. 1.13.0 of 1.13.0-rc3)
                    any.addEventListener("input", (e) => {
                        const v = any.value.trim()
                        if (e.inputType !== "insertText" && e.inputType !== "deleteContentBackward" && catalog.versions.includes(v)) {
                            go(have(v) ? { channel: v } : { add_channel: v }, null, "")
                        }
                    })
                    more.appendChild(any)
                    more.appendChild(dl)
                }
            } else if (info.plain_julia) {
                const sys = rows("Found on this system", "click to launch")
                const el = row("System Julia", info.plain_julia, "", { channel: null }, "launching…")
                sys.appendChild(el)
                preferred = el
                const more = rows("Recommended", "click to install and launch")
                more.appendChild(row("Set up juliaup", "version manager — switch Julias any time", "install", { bootstrap: true, add_channel: "release" }, "installing…"))
            } else {
                const none = rows("No Julia found", "one click — a few minutes once")
                const el = row("Install Julia", "via juliaup — the official installer", "install", { bootstrap: true, add_channel: "release" }, "installing…")
                none.appendChild(el)
                preferred = el
            }
            // Enter = the remembered (or default) version, from anywhere on the page that isn't
            // itself Enter-actionable (a focused pill launches natively; the input handles its own).
            preferred?.focus()
            addEventListener("keydown", (e) => {
                const t = e.target
                if (e.key === "Enter" && preferred != null && !(t instanceof HTMLButtonElement) && !(t instanceof HTMLInputElement && t.type === "text")) {
                    preferred.click()
                }
            })
        }

        const boot = async () => {
            try {
                const info = await (await fetch("./api/julia")).json()
                render(info)
                // arriving from "Julia Version…" while a server runs: offer a way back, warn about restart
                const status = await (await fetch("./status")).json()
                if (status.phase === "ready") {
                    document.getElementById("cancel").style.display = ""
                    document.getElementById("restart-note").style.display = ""
                }
            } catch (e) {
                document.getElementById("error").textContent = String(e)
            }
        }
        boot()
    </script>
</body>
</html>`
