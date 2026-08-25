// The Launch Station: pick which Julia powers this launch. Mirrors the SpaceStation launcher's
// design (same card, pills, headings — theme.ts) so it reads as the first screen of the same
// product. Three audiences, one page:
//   • power users — every installed juliaup channel, default preselected, Enter/click to go
//   • one-click installs — curated channels not yet installed (juliaup add, progress on splash)
//   • complete newbies — no Julia at all: a single "Install Julia" button (juliaup bootstrap)
// The "always use this" checkbox is the VS Code-style don't-ask-again: saved by the shell, the
// picker skipped on future launches (SpaceStation menu → "Julia Version…" brings it back).

import { base_css, logo_svg } from "./theme.ts"

export const launch_html = /* html */ `<!doctype html>
<html>
<head>
<meta charset="utf-8" />
<title>SpaceStation</title>
<style>
${base_css}
    .rows { display: flex; flex-direction: column; gap: 0.45rem; }
    .footer { display: flex; align-items: center; gap: 1rem; margin-top: 1.6rem; }
    .remember { display: flex; align-items: center; gap: 0.45rem; font-size: 0.85rem; opacity: 0.8; cursor: pointer; user-select: none; }
    .remember input { accent-color: var(--accent); }
    .note { font-size: 0.78rem; opacity: 0.55; margin-top: 0.9rem; }
    .cancel { margin-left: auto; font-size: 0.85rem; opacity: 0.6; color: inherit; }
    #error { color: #ff8a8a; font-size: 0.85rem; margin-top: 0.8rem; }
    .update-badge {
        margin-left: auto; border: none; font: inherit; font-size: 0.68rem; text-transform: uppercase;
        letter-spacing: 0.07em; color: inherit; background: none; cursor: pointer; padding: 0.15rem 0.55rem;
        border-radius: 1000px; box-shadow: inset 0 0 0 1px var(--accent); opacity: 0.85;
    }
    .update-badge:hover, .update-badge.active { background-color: var(--accent); color: white; opacity: 1; }
    .pill .badge + .update-badge { margin-left: 0.6rem; }
    input.anyver {
        border: none; font: inherit; font-size: 0.88rem; color: inherit; background-color: var(--main-bg-color);
        border-radius: 1000px; padding: 0.45rem 0.9rem; width: 100%;
        font-family: JuliaMono, ui-monospace, Menlo, Consolas, monospace;
    }
    input.anyver:focus { outline: none; box-shadow: inset 0 0 0 2px var(--accent); }
    input.anyver.selected { box-shadow: inset 0 0 0 2px var(--accent); }
</style>
</head>
<body>
    <div class="bubble card">
        <header>
            ${logo_svg}
            <h1>Space<span class="land-accent">Station</span></h1>
            <p class="subtitle">Choose the Julia that powers this launch.</p>
        </header>
        <div id="content"><h2>Looking for Julia…</h2></div>
        <div id="error"></div>
        <div class="footer">
            <label class="remember"><input type="checkbox" id="remember" /> Always use this version — don't ask at launch</label>
            <button class="primary" id="launch" disabled>Launch</button>
            <a class="cancel" id="cancel" href="/deck" style="display: none">Cancel</a>
        </div>
        <div class="note" id="restart-note" style="display: none">Switching versions restarts the SpaceStation server — running notebooks stop.</div>
    </div>
    <script>
        const content = document.getElementById("content")
        const launch_btn = document.getElementById("launch")
        let selection = null // { channel } | { add_channel } | { bootstrap: true }

        // One place decides what is selected, so the row highlight, the update badge's on/off
        // state and the button's own label can never disagree. The label is the real feedback:
        // an update or an install is a different (slower) action than a plain launch, and the
        // button should say so BEFORE it is pressed.
        const select = (value, row, badge_el) => {
            selection = value
            for (const p of content.querySelectorAll(".pill")) p.classList.remove("selected")
            for (const b of content.querySelectorAll(".update-badge")) b.classList.remove("active")
            for (const i of content.querySelectorAll("input.anyver")) i.classList.remove("selected")
            row?.classList.add("selected")
            badge_el?.classList.add("active")
            launch_btn.textContent = value?.update ? "Update & Launch" : value?.add_channel || value?.bootstrap ? "Install & Launch" : "Launch"
            launch_btn.disabled = false
        }

        const pill = (label, mono, badge, sel_value) => {
            const el = document.createElement("button")
            el.className = "pill"
            el.innerHTML = \`<span>\${label}</span>\` + (mono ? \`<span class="mono">\${mono}</span>\` : "") + (badge ? \`<span class="badge">\${badge}</span>\` : "")
            el.onclick = () => select(sel_value, el)
            return el
        }

        const render = (info) => {
            content.innerHTML = ""
            const rows = (title) => {
                const h = document.createElement("h2")
                h.textContent = title
                content.appendChild(h)
                const d = document.createElement("div")
                d.className = "rows"
                content.appendChild(d)
                return d
            }
            let preselect = null
            if (info.juliaup) {
                const catalog = info.catalog ?? { aliases: [], minors: [], versions: [], updates: {} }
                const installed = rows("Installed Julias")
                for (const ch of info.juliaup.channels) {
                    const is_default = ch.name === info.juliaup.default
                    const latest = catalog.updates[ch.name]
                    const el = pill(\`Julia \${ch.name}\`, latest ? \`\${ch.version} → \${latest}\` : ch.version, is_default ? "default" : "", { channel: ch.name })
                    if (latest) {
                        // Updating is its own choice — the row alone launches the version you
                        // already have; the badge runs a juliaup update first. Clicking it picks
                        // the row too, so the two can't disagree.
                        const up = document.createElement("button")
                        up.className = "update-badge"
                        up.textContent = \`update to \${latest}\`
                        up.title = \`Run juliaup update \${ch.name} (fetches \${latest}), then launch on it\`
                        up.onclick = (e) => {
                            e.stopPropagation()
                            select({ channel: ch.name, update: true }, el, up)
                        }
                        el.appendChild(up)
                    }
                    installed.appendChild(el)
                    if (info.settings.channel === ch.name) preselect = el
                    if (preselect == null && is_default) preselect = el
                }
                const have = (name) => info.juliaup.channels.some((ch) => ch.name === name)
                const offers = [...catalog.aliases, ...catalog.minors.slice(0, 6)].filter((c) => !have(c.name))
                const more = rows("Get another version")
                for (const c of offers) more.appendChild(pill(\`Julia \${c.name}\`, c.version, "install", { add_channel: c.name }))
                if (catalog.versions.length > 0) {
                    const any = document.createElement("input")
                    any.className = "anyver"
                    any.placeholder = "…or any exact version — type e.g. \${catalog.versions[0]}".replace("\\\${catalog.versions[0]}", catalog.versions[0])
                    any.setAttribute("list", "all-julias")
                    const dl = document.createElement("datalist")
                    dl.id = "all-julias"
                    for (const v of catalog.versions) {
                        const o = document.createElement("option")
                        o.value = v
                        dl.appendChild(o)
                    }
                    const pick_typed = () => {
                        const v = any.value.trim()
                        if (v === "") return
                        select(have(v) ? { channel: v } : { add_channel: v }, null, null)
                        any.classList.add("selected")
                    }
                    any.addEventListener("input", pick_typed)
                    any.addEventListener("focus", pick_typed)
                    more.appendChild(any)
                    more.appendChild(dl)
                }
            } else if (info.plain_julia) {
                const sys = rows("Found on this system")
                const el = pill("System Julia", info.plain_julia, "", { channel: null })
                sys.appendChild(el)
                preselect = el
                const more = rows("Recommended")
                more.appendChild(pill("Set up juliaup", "version manager — switch Julias any time", "install", { bootstrap: true, add_channel: "release" }))
            } else {
                const none = rows("No Julia found")
                const el = pill("Install Julia", "via juliaup — the official installer, a few minutes once", "install", { bootstrap: true, add_channel: "release" })
                none.appendChild(el)
                preselect = el
            }
            preselect?.click()
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

        launch_btn.onclick = async () => {
            if (selection == null) return
            launch_btn.disabled = true
            try {
                const res = await fetch("./api/julia/launch", {
                    method: "POST",
                    headers: { "content-type": "application/json" },
                    body: JSON.stringify({ ...selection, remember: document.getElementById("remember").checked }),
                })
                if (!res.ok) throw new Error("launch failed: " + res.status)
                location.replace("/")
            } catch (e) {
                document.getElementById("error").textContent = String(e)
                launch_btn.disabled = false
            }
        }
        addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !launch_btn.disabled) launch_btn.click()
        })
    </script>
</body>
</html>`
