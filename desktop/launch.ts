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

        const pill = (label, mono, badge, sel_value) => {
            const el = document.createElement("button")
            el.className = "pill"
            el.innerHTML = \`<span>\${label}</span>\` + (mono ? \`<span class="mono">\${mono}</span>\` : "") + (badge ? \`<span class="badge">\${badge}</span>\` : "")
            el.onclick = () => {
                selection = sel_value
                for (const p of content.querySelectorAll(".pill")) p.classList.remove("selected")
                el.classList.add("selected")
                launch_btn.disabled = false
            }
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
                const installed = rows("Installed Julias")
                for (const ch of info.juliaup.channels) {
                    const is_default = ch.name === info.juliaup.default
                    const el = pill(\`Julia \${ch.name}\`, ch.version, is_default ? "default" : "", { channel: ch.name })
                    installed.appendChild(el)
                    if (info.settings.channel === ch.name) preselect = el
                    if (preselect == null && is_default) preselect = el
                }
                const missing = info.curated.filter((c) => !info.juliaup.channels.some((ch) => ch.name === c))
                if (missing.length > 0) {
                    const more = rows("Get another version")
                    for (const c of missing) more.appendChild(pill(\`Julia \${c}\`, "", "install", { add_channel: c }))
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
