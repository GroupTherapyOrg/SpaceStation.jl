// A walk through the shell as a user takes it, in a real browser. argv: hubUrl secret workspace shotsDir
// Every step is tried, whatever happened to the one before; the report says which held. A step that
// is `must` fails the run; the others are observations (what font was drawn, how wide a scrollbar is).
import puppeteer from "puppeteer"
import fs from "fs"
import path from "path"

const [, , hub, secret, workspace, shots] = process.argv
const wait = (ms) => new Promise((r) => setTimeout(r, ms))
const report = { platform: process.platform, steps: [], seen: {} }
let failed = false
const step = async (name, must, fn) => {
    try {
        const detail = await fn()
        report.steps.push({ name, ok: true, detail })
        console.log("ok   ", name, detail === undefined ? "" : JSON.stringify(detail))
    } catch (e) {
        report.steps.push({ name, ok: false, must, detail: String(e?.message ?? e).slice(0, 400) })
        console.log(must ? "FAIL " : "note ", name, String(e?.message ?? e).slice(0, 400))
        if (must) failed = true
    }
}
const expect = (cond, what) => {
    if (!cond) throw new Error(what)
}
const until = async (fn, { timeout = 30000, every = 250, what = "condition" } = {}) => {
    const end = Date.now() + timeout
    for (;;) {
        const v = await fn().catch(() => null)
        if (v) return v
        if (Date.now() > end) throw new Error(`timed out waiting for ${what}`)
        await wait(every)
    }
}

// Some launches of the bundled Chrome open a connection and never send on it: launch again until one loads the page.
let browser, page
for (let i = 0; ; i++) {
    browser = await puppeteer.launch({ headless: "new", args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"] })
    page = await browser.newPage()
    try {
        await page.goto(`${hub}?secret=${secret}`, { waitUntil: "domcontentloaded", timeout: 15000 })
        break
    } catch (e) {
        await browser.close()
        if (i >= 5) throw e
    }
}
const errors = []
page.on("pageerror", (e) => errors.push(String(e).slice(0, 200)))
const bad = []
page.on("response", (r) => r.status() >= 400 && bad.push(`${r.status()} ${r.url().replace(/secret=\w+/, "secret=…").slice(0, 140)}`))
await page.setViewport({ width: 1440, height: 900 })
await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }])
const shot = (name) => page.screenshot({ path: path.join(shots, `walk-${process.platform}-${name}.png`) })
const cdp = await page.createCDPSession()
await cdp.send("DOM.enable")
await cdp.send("CSS.enable")
// which fonts were really drawn for an element (the stack in the stylesheet says what was asked for)
const drawn_fonts = async (selector, on = cdp) => {
    // (the fonts are reported for an element's own text: mark the first one under `selector` that has some)
    const marked = await page.evaluate((selector) => {
        document.querySelector("[data-walk-font]")?.removeAttribute("data-walk-font")
        for (const top of document.querySelectorAll(selector))
            for (const el of [top, ...top.querySelectorAll("*")])
                if ([...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim() !== "")) return el.setAttribute("data-walk-font", ""), true
        return false
    }, selector)
    if (!marked) return null
    const { root } = await on.send("DOM.getDocument", { depth: 0 })
    const { nodeId } = await on.send("DOM.querySelector", { nodeId: root.nodeId, selector: "[data-walk-font]" })
    if (!nodeId) return null
    const { fonts } = await on.send("CSS.getPlatformFontsForNode", { nodeId })
    return fonts.map((f) => `${f.familyName} (${f.glyphCount})`)
}
// scrollable boxes whose scrollbar takes room (a system without overlay scrollbars), and anything wider than the page
const scroll_report = () =>
    page.evaluate(() => {
        const out = []
        for (const el of document.querySelectorAll("*")) {
            const s = getComputedStyle(el)
            const v = el.offsetWidth - el.clientWidth - parseFloat(s.borderLeftWidth) - parseFloat(s.borderRightWidth)
            const h = el.offsetHeight - el.clientHeight - parseFloat(s.borderTopWidth) - parseFloat(s.borderBottomWidth)
            if (v > 1 || h > 1) out.push(`${el.tagName.toLowerCase()}${el.id ? "#" + el.id : ""}${typeof el.className === "string" && el.className ? "." + el.className.trim().split(/\s+/).slice(0, 2).join(".") : ""} v=${Math.round(v)} h=${Math.round(h)}`)
        }
        return { bars: out.slice(0, 25), page_wider_than_window: document.documentElement.scrollWidth > window.innerWidth }
    })

// the clipboard, as the page sees it
const whole = await browser.target().createCDPSession()
await whole.send("Browser.grantPermissions", { origin: new URL(hub).origin, permissions: ["clipboardReadWrite", "clipboardSanitizedWrite"] })
await page.bringToFront()
const clip_write = (text) => page.evaluate((t) => navigator.clipboard.writeText(t), text)
const clip_read = () => page.evaluate(() => navigator.clipboard.readText())
const mod = process.platform === "darwin" ? "Meta" : "Control"
const chord = async (keys) => {
    const held = keys.slice(0, -1)
    for (const k of held) await page.keyboard.down(k)
    await page.keyboard.press(keys[keys.length - 1])
    for (const k of held.reverse()) await page.keyboard.up(k)
}
const entry_box = (name) =>
    page.evaluate((name) => {
        const b = [...document.querySelectorAll("#land button.entry")].find((b) => b.innerText.trim() === name)
        if (b == null) return null
        b.scrollIntoView({ block: "nearest" })
        const r = b.getBoundingClientRect()
        return { x: r.x + Math.min(60, r.width / 2), y: r.y + r.height / 2, path: b.dataset.path }
    }, name)
const entries_shown = () => page.evaluate(() => [...document.querySelectorAll("#land button.entry")].map((b) => b.innerText.trim()))
const menu = () => page.evaluate(() => [...document.querySelectorAll(".land-menu.context button")].map((b) => b.innerText.replace(/\s+/g, " ").trim()))
const pick = async (label) => {
    const found = await page.evaluate((label) => {
        const b = [...document.querySelectorAll(".land-menu.context button")].find((b) => b.innerText.replace(/\s+/g, " ").trim().startsWith(label))
        b?.click()
        return b != null
    }, label)
    expect(found, `no "${label}" in the menu: ${JSON.stringify(await menu())}`)
    await wait(400)
}
const right_click = async (name) => {
    const at = await entry_box(name)
    expect(at != null, `no "${name}" in the tree: ${JSON.stringify(await entries_shown())}`)
    await page.mouse.click(at.x, at.y, { button: "right" })
    await wait(400)
    return at
}
// a dialog that asks for a name: type it, Enter
const answer = async (text) => {
    await page.waitForSelector("dialog.land-dialog input", { timeout: 5000 })
    await wait(200)
    await page.keyboard.type(text)
    const complaint = await page.evaluate(() => document.querySelector("dialog.land-dialog .field-note.error")?.textContent ?? null)
    await page.keyboard.press("Enter")
    await wait(1200)
    const still = await page.evaluate(() => document.querySelector("dialog.land-dialog") != null)
    if (still) await page.keyboard.press("Escape")
    return { complaint, refused: still }
}
const toasts = () => page.evaluate(() => [...document.querySelectorAll(".land-toast")].map((t) => t.innerText.replace(/\s+/g, " ").trim()))

await wait(3000)
await step("the launcher loads and the address loses its secret", true, async () => {
    const s = await page.evaluate(() => ({ address: location.pathname + location.search, text: document.body.innerText.replace(/\s+/g, " ").slice(0, 300) }))
    expect(/OPEN A FOLDER/i.test(s.text), `no folder browser: ${s.text}`)
    expect(!/secret=/.test(s.address), `secret still in the address: ${s.address}`)
    return s.address
})
await step("launcher: fonts drawn", false, async () => (report.seen.launcher_fonts = { title: await drawn_fonts("h1"), body: await drawn_fonts("input[name=path]") }))
await step("launcher: scrollbars", false, async () => (report.seen.launcher_scroll = await scroll_report()))
await shot("1-launcher")

await step("folder browser: the first listing arrives", true, async () => {
    // (the first one starts the process that reads folders for the hub: as long as a Julia start)
    const t0 = Date.now()
    await page.waitForSelector("input[name=path]", { timeout: 180000 })
    report.seen.first_listing_ms = Date.now() - t0 + 3000
    report.seen.home_crumbs = await page.evaluate(() => document.querySelector("nav.breadcrumbs")?.innerText.replace(/\s+/g, " "))
    return { ms: report.seen.first_listing_ms, crumbs: report.seen.home_crumbs }
})
await shot("1b-launcher-listed")
await step("folder browser: a typed path, as the system writes it", true, async () => {
    await page.click("input[name=path]")
    // in quotes, as a file manager's "Copy as path" gives it; on Windows in small letters too: the same folder
    await page.keyboard.type(`"${process.platform === "win32" ? workspace.toLowerCase() : workspace}"`)
    await page.keyboard.press("Enter")
    const name = path.basename(workspace)
    const label = await until(() => page.evaluate((name) => [...document.querySelectorAll("button")].map((b) => b.textContent.replace(/\s+/g, " ").trim()).find((t) => t.startsWith("Open") && t.includes(name)), name), { what: `an Open button for ${name}` })
    const listed = await page.evaluate(() => [...document.querySelectorAll("input[name=path]")].map((i) => i.closest("form")?.nextElementSibling?.innerText.replace(/\s+/g, " ").slice(0, 200)))
    report.seen.browser_crumbs = await page.evaluate(() => document.querySelector("nav.breadcrumbs")?.innerText.replace(/\s+/g, " "))
    report.seen.drives = await page.evaluate(() => [...document.querySelectorAll(".drives .crumb")].map((b) => b.textContent.trim()))
    const sep = process.platform === "win32" ? "\\" : "/"
    expect(report.seen.browser_crumbs.endsWith(`${sep} ${name}`), `the path's row reads ${JSON.stringify(report.seen.browser_crumbs)}`)
    if (process.platform === "win32") {
        expect(/^[A-Z]: \\ /.test(report.seen.browser_crumbs) && !report.seen.browser_crumbs.includes("/"), `the path's row reads ${JSON.stringify(report.seen.browser_crumbs)}`)
        expect(report.seen.drives.length === 0 || report.seen.drives.every((d) => /^[A-Z]:$/.test(d)), `drives shown as ${JSON.stringify(report.seen.drives)}`)
    }
    return { label, listed, crumbs: report.seen.browser_crumbs, drives: report.seen.drives }
})
await shot("2-folder-browser")

let ws_url = null
await step("a folder opens as a workspace", true, async () => {
    const name = path.basename(workspace)
    await page.evaluate((name) => [...document.querySelectorAll("button")].find((b) => b.textContent.replace(/\s+/g, " ").trim().startsWith("Open") && b.textContent.includes(name)).click(), name)
    ws_url = await until(() => page.evaluate((name) => [...document.querySelectorAll("a[href*='/w/']")].find((a) => a.innerText.includes(name))?.href, name), { timeout: 240000, what: "the workspace's tile" })
    report.seen.tile = await page.evaluate((name) => [...document.querySelectorAll("a[href*='/w/']")].find((a) => a.innerText.includes(name))?.innerText.replace(/\s+/g, " "), name)
    return { url: new URL(ws_url).pathname, tile: report.seen.tile }
})
await shot("3-launcher-with-tile")
if (ws_url == null) {
    fs.writeFileSync(path.join(shots, `walk-${process.platform}-report.json`), JSON.stringify(report, null, 2))
    await browser.close()
    process.exit(1)
}

// The launcher opens a ready workspace in a tab of its own. The walk goes on in this one: close that
// tab (a tab in the background is not drawn, and nothing in it can be clicked or read).
await step("the launcher opens the workspace in a new tab", false, async () => {
    await wait(1500)
    const others = (await browser.pages()).filter((p) => p !== page)
    const urls = others.map((p) => new URL(p.url()).pathname)
    for (const p of others) await p.close()
    await page.bringToFront()
    expect(urls.some((u) => u === new URL(ws_url).pathname), `tabs opened: ${JSON.stringify(urls)}`)
    return urls
})
await page.goto(ws_url, { waitUntil: "domcontentloaded" })
await step("the workspace's file tree, folders first and by letter", true, async () => {
    await page.waitForSelector("#land button.entry", { timeout: 60000 })
    await wait(800)
    const names = await page.evaluate(() => [...document.querySelectorAll("#land ul.tree > li > .entry-row button.entry")].map((b) => b.dataset.path))
    report.seen.tree_paths = names
    const base = names.map((p) => p.split(/[\\/]/).pop())
    expect(JSON.stringify(base) === JSON.stringify(["cluster", "Papers", "results 2026", "fatou.jl", "hello.jl", "notes.txt", "Project.toml", "README.md"]), `order was ${JSON.stringify(base)}`)
    const shown = await page.evaluate(() => [...document.querySelectorAll("#land ul.tree > li > .entry-row button.entry")].map((b) => b.innerText.trim()))
    expect(JSON.stringify(shown) === JSON.stringify(base), `names shown ${JSON.stringify(shown)}`)
    return base
})
await step("sidebar: how the workspace's place is written", false, async () => (report.seen.side_head = await page.evaluate(() => document.querySelector(".side-head")?.innerText.replace(/\s+/g, " "))))
await step("a folder opens in the tree", true, async () => {
    await page.evaluate(() => [...document.querySelectorAll("#land button.entry")].find((b) => b.innerText.trim() === "Papers").click())
    await until(() => page.evaluate(() => [...document.querySelectorAll("#land button.entry")].some((b) => b.innerText.trim() === "drafts")), { what: "Papers/drafts" })
})
await step("a text file opens with its text", true, async () => {
    await page.evaluate(() => [...document.querySelectorAll("#land button.entry")].find((b) => b.innerText.trim() === "notes.txt").click())
    const text = await until(() => page.evaluate(() => document.querySelector("#frames .cm-content, .file-view .cm-content, .cm-content")?.innerText), { what: "the editor" })
    expect(/first line/.test(text) && /second line/.test(text), `editor shows ${JSON.stringify(text.slice(0, 80))}`)
    report.seen.file_tab = await page.evaluate(() => [...document.querySelectorAll(".tab")].map((t) => t.innerText.replace(/\s+/g, " ").trim()))
    return report.seen.file_tab
})
const focus_editor = () => page.evaluate(() => [...document.querySelectorAll(".cm-content")].find((e) => e.offsetParent != null)?.focus())
await step("editor: typing and saving keeps the file's line endings", true, async () => {
    await focus_editor()
    await chord([mod, "End"])
    await page.keyboard.type("third line")
    await chord([mod, "s"])
    await wait(2000)
    const saved = fs.readFileSync(path.join(workspace, "notes.txt"), "utf8")
    expect(/third line/.test(saved), `not saved: ${JSON.stringify(saved)}`)
    expect(saved.startsWith("first line\r\nsecond line\r\n"), `line endings changed: ${JSON.stringify(saved)}`)
    return JSON.stringify(saved)
})
// (on macOS the copy and paste keys belong to the system, and a driven browser does not get them)
await step("editor: select all and copy reach the clipboard", process.platform !== "darwin", async () => {
    await clip_write("nothing yet")
    await focus_editor()
    await chord([mod, "a"])
    await chord([mod, "c"])
    await wait(400)
    const got = await clip_read()
    expect(/first line/.test(got) && /third line/.test(got), `clipboard has ${JSON.stringify(got)}`)
    return JSON.stringify(got)
})
await step("editor: paste puts the clipboard in the file", process.platform !== "darwin", async () => {
    await clip_write("pasted-into-editor")
    await focus_editor()
    await chord([mod, "End"])
    await chord([mod, "v"])
    await wait(600)
    const text = await page.evaluate(() => [...document.querySelectorAll(".cm-content")].find((e) => e.offsetParent != null)?.innerText)
    expect(/pasted-into-editor/.test(text), `editor shows ${JSON.stringify(text)}`)
    await chord([mod, "z"]) // and undo takes it out again
    await wait(400)
    const undone = await page.evaluate(() => [...document.querySelectorAll(".cm-content")].find((e) => e.offsetParent != null)?.innerText)
    expect(!/pasted-into-editor/.test(undone), "undo did not take the paste out")
    await chord([mod, "s"])
    await wait(1200)
})

await step("tree menu: what a file offers", true, async () => {
    await right_click("notes.txt")
    const items = await menu()
    report.seen.file_menu = items
    expect(items.some((i) => i.startsWith("Copy path")) && items.some((i) => i.startsWith("Rename")) && items.some((i) => i.startsWith("Delete")), `menu was ${JSON.stringify(items)}`)
    return items
})
await step("tree menu: Copy path gives the path as this system writes it", true, async () => {
    await clip_write("nothing yet")
    await pick("Copy path")
    const got = await clip_read()
    const want = path.join(fs.realpathSync(workspace), "notes.txt")
    report.seen.copied_path = got
    expect(got.toLowerCase() === want.toLowerCase() || got === path.join(workspace, "notes.txt"), `copied ${JSON.stringify(got)}, the file is ${JSON.stringify(want)}`)
    return got
})
await step("tree menu: Copy relative path", true, async () => {
    await right_click("drafts")
    await clip_write("nothing yet")
    await pick("Copy relative path")
    const got = await clip_read()
    report.seen.copied_relative_path = got
    expect(got === path.join("Papers", "drafts"), `copied ${JSON.stringify(got)}, wanted ${JSON.stringify(path.join("Papers", "drafts"))}`)
    return got
})
await step("tree: a new file in a folder, with a space in its name", true, async () => {
    await right_click("cluster")
    await pick("New file")
    const a = await answer("Made Here.txt")
    expect(!a.refused, `refused: ${a.complaint}`)
    await until(async () => fs.existsSync(path.join(workspace, "cluster", "Made Here.txt")), { timeout: 25000, what: "the file on disk" })
    await until(async () => (await entries_shown()).includes("Made Here.txt"), { timeout: 25000, what: "the file in the tree" })
    return { tabs: await page.evaluate(() => [...document.querySelectorAll(".tab")].map((t) => t.innerText.replace(/\s+/g, " ").trim())) }
})
await step("tree: a new folder", true, async () => {
    await right_click("cluster")
    await pick("New folder")
    const a = await answer("sub dir")
    expect(!a.refused, `refused: ${a.complaint}`)
    await until(async () => fs.existsSync(path.join(workspace, "cluster", "sub dir")), { timeout: 25000, what: "the folder on disk" })
    await until(async () => (await entries_shown()).includes("sub dir"), { timeout: 25000, what: "the folder in the tree" })
})
await step("tree: F2 renames", true, async () => {
    await page.evaluate(() => [...document.querySelectorAll("#land button.entry")].find((b) => b.innerText.trim() === "fatou.jl").focus())
    await page.keyboard.press("F2")
    const a = await answer("renamed") // the name is selected up to its extension
    expect(!a.refused, `refused: ${a.complaint}`)
    await until(async () => fs.existsSync(path.join(workspace, "renamed.jl")) && !fs.existsSync(path.join(workspace, "fatou.jl")), { timeout: 25000, what: "renamed.jl on disk" })
    await until(async () => (await entries_shown()).includes("renamed.jl"), { timeout: 25000, what: "renamed.jl in the tree" })
})
await step("tree: a file that is open in a tab can be renamed and its tab follows", true, async () => {
    await right_click("Made Here.txt")
    await pick("Rename")
    const a = await answer("Moved")
    expect(!a.refused, `refused: ${a.complaint}`)
    await until(async () => fs.existsSync(path.join(workspace, "cluster", "Moved.txt")), { timeout: 25000, what: "Moved.txt on disk" })
    const tabs = await until(async () => { const t = await page.evaluate(() => [...document.querySelectorAll(".tab")].map((t) => t.innerText.replace(/\s+/g, " ").trim())); return t.some((x) => x.includes("Moved.txt")) ? t : null }, { timeout: 25000, what: "the tab's new name" })
    return tabs
})
await step("tree: a name this system does not allow is refused in words", true, async () => {
    const tries = process.platform === "win32" ? ["con.txt", "notes 10:30.md", "a/b.txt"] : ["a/b.txt"]
    const said = []
    for (const name of tries) {
        await right_click("cluster")
        await pick("New file")
        const a = await answer(name)
        await wait(1000)
        const t = await toasts()
        said.push({ name, ...a, toasts: t })
        expect(a.refused || t.some((x) => /Windows|device|not a path|could not/i.test(x)), `"${name}" was taken without a word`)
        await page.evaluate(() => document.querySelectorAll(".land-toast button").forEach((b) => b.click()))
    }
    const on_disk = fs.readdirSync(path.join(workspace, "cluster"))
    expect(JSON.stringify(on_disk.sort()) === JSON.stringify(["Moved.txt", "sub dir"]), `the folder now holds ${JSON.stringify(on_disk)}`)
    report.seen.bad_names = said
    return said
})
await step("tree: delete asks, then removes", true, async () => {
    await right_click("Moved.txt")
    await pick("Delete")
    await page.waitForSelector("dialog.land-dialog .buttons", { timeout: 5000 })
    report.seen.delete_dialog = await page.evaluate(() => document.querySelector("dialog.land-dialog").innerText.replace(/\s+/g, " "))
    await page.evaluate(() => [...document.querySelectorAll("dialog.land-dialog .buttons button")].pop().click())
    await until(async () => !fs.existsSync(path.join(workspace, "cluster", "Moved.txt")), { timeout: 25000, what: "the file gone from disk" })
    await until(async () => !(await entries_shown()).includes("Moved.txt"), { timeout: 25000, what: "the file gone from the tree" })
    return report.seen.delete_dialog
})
await step("tab menu: Copy path", true, async () => {
    const at = await page.evaluate(() => { const t = [...document.querySelectorAll(".tab")].find((t) => t.innerText.includes("notes.txt")); const r = t?.getBoundingClientRect(); return r ? { x: r.x + 20, y: r.y + r.height / 2 } : null })
    expect(at != null, "no notes.txt tab")
    await page.mouse.click(at.x, at.y, { button: "right" })
    await wait(400)
    report.seen.tab_menu = await menu()
    await clip_write("nothing yet")
    await pick("Copy path")
    const got = await clip_read()
    expect(/notes\.txt$/.test(got) && got === report.seen.copied_path, `copied ${JSON.stringify(got)}`)
    return { menu: report.seen.tab_menu, got }
})
await page.evaluate(() => [...document.querySelectorAll(".tab")].find((t) => t.innerText.includes("notes.txt"))?.click())
await wait(500)
await shot("4-workspace-file")
await step("workspace: fonts drawn", false, async () => (report.seen.workspace_fonts = { tree: await drawn_fonts("#land button.entry"), tab: await drawn_fonts(".tab"), editor: await drawn_fonts(".cm-content .cm-line") }))

await step("a notebook opens and runs", true, async () => {
    await page.evaluate(() => [...document.querySelectorAll("#land button.entry")].find((b) => b.innerText.trim() === "hello.jl").click())
    const frame = () => page.frames().find((f) => f !== page.mainFrame() && /\/edit/.test(f.url()))
    await until(async () => (await frame()?.evaluate(() => document.querySelectorAll("pluto-cell").length)) === 2, { timeout: 120000, what: "the notebook's two cells" })
    const outputs = () => frame().evaluate(() => [...document.querySelectorAll("pluto-cell pluto-output")].map((o) => o.textContent.trim()))
    await wait(1500)
    if ((await outputs()).some((o) => /Safe preview|not executed/i.test(o))) await frame().evaluate(() => [...document.querySelectorAll("button, a")].find((b) => /Run notebook code/i.test(b.textContent))?.click())
    const out = await until(async () => { const o = await outputs(); return o.some((t) => /42$/.test(t)) ? o : null }, { timeout: 600000, every: 1000, what: "answer = 42" })
    report.seen.notebook_tab = await page.evaluate(() => [...document.querySelectorAll(".tab")].map((t) => t.innerText.replace(/\s+/g, " ").trim()))
    return { out, tabs: report.seen.notebook_tab }
})
await wait(1500)
await shot("5-notebook")

const rows = () => page.evaluate(() => [...document.querySelectorAll("#terminal-panel .terminal-body.active .xterm-rows > div, #terminal-panel .xterm-rows > div")].map((d) => d.textContent).filter((t) => t.trim()))
const focus_terminal = () => page.evaluate(() => (document.querySelector("#terminal-panel .terminal-body.active .xterm-helper-textarea") ?? document.querySelector("#terminal-panel .xterm-helper-textarea"))?.focus())
const saw = (text, n = 1, timeout = 30000) => until(async () => { const r = await rows(); return r.filter((t) => t.includes(text)).length >= n ? r : null }, { timeout, what: `"${text}" ${n} time(s) in the terminal` })
const win = process.platform === "win32"
await step("a terminal opens and runs a command", true, async () => {
    const t0 = Date.now()
    await page.evaluate(() => document.querySelector("button.terminal-toggle").click())
    await until(async () => (await rows()).length > 0, { timeout: 90000, what: "a prompt" })
    report.seen.terminal_prompt_ms = Date.now() - t0
    await wait(2500)
    report.seen.terminal_start = await rows()
    await focus_terminal()
    await page.keyboard.type("echo walk-through-ok")
    await page.keyboard.press("Enter")
    return { prompt_ms: report.seen.terminal_prompt_ms, rows: (await saw("walk-through-ok", 2)).slice(-6) }
})
await step("terminal: where it starts, and what it is given", true, async () => {
    await focus_terminal()
    await page.keyboard.type(win ? "echo \"here=$((Get-Location).Path) port=$env:SPACESTATION_PORT\"" : "echo \"here=$PWD port=$SPACESTATION_PORT\"")
    await page.keyboard.press("Enter")
    const r = await saw("here=", 2)
    const line = r.filter((t) => t.startsWith("here=")).pop() ?? ""
    report.seen.terminal_env = line
    expect(line.includes("My Project") && /port=\d+/.test(line), `got ${JSON.stringify(line)}`)
    return line
})
await step("terminal: the command its banner names is there to run", true, async () => {
    await focus_terminal()
    await page.keyboard.type(win ? "pluto-collab --help; echo \"rc=$LASTEXITCODE done-collab\"" : "pluto-collab --help; echo \"rc=$? done-collab\"")
    await page.keyboard.press("Enter")
    const r = await until(async () => { const r = await rows(); return r.some((t) => /rc=\d+ done-collab/.test(t)) ? r : null }, { timeout: 60000, what: "pluto-collab to return" })
    report.seen.terminal_collab = r.slice(-10)
    expect(r.some((t) => /rc=0 done-collab/.test(t)), `pluto-collab did not run: ${JSON.stringify(r.slice(-10))}`)
    return r.slice(-3)
})
await step("terminal: paste by this system's key", !["darwin"].includes(process.platform), async () => {
    await clip_write("echo pasted-by-key-ok")
    await focus_terminal()
    await chord(process.platform === "darwin" ? ["Meta", "v"] : win ? ["Control", "v"] : ["Control", "Shift", "V"])
    await wait(800)
    await page.keyboard.press("Enter")
    return (await saw("pasted-by-key-ok", 2, 25000)).slice(-4)
})
await step("terminal: the menu's Paste", true, async () => {
    await clip_write("echo pasted-by-menu-ok")
    const at = await page.evaluate(() => { const r = document.querySelector("#terminal-panel .xterm-screen").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 } })
    await page.mouse.click(at.x, at.y, { button: "right" })
    await wait(400)
    report.seen.terminal_menu = await menu()
    await pick("Paste")
    await wait(800)
    await focus_terminal()
    await page.keyboard.press("Enter")
    return { menu: report.seen.terminal_menu, rows: (await saw("pasted-by-menu-ok", 2, 25000)).slice(-3) }
})
await step("terminal: select all, then the copy key, puts the text on the clipboard and interrupts nothing", true, async () => {
    await clip_write("nothing yet")
    const at = await page.evaluate(() => { const r = document.querySelector("#terminal-panel .xterm-screen").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 } })
    await page.mouse.click(at.x, at.y, { button: "right" })
    await wait(400)
    await pick("Select all")
    await focus_terminal()
    await chord(process.platform === "darwin" ? ["Meta", "c"] : ["Control", "c"])
    await wait(600)
    const got = await clip_read()
    expect(/walk-through-ok/.test(got), `clipboard has ${JSON.stringify(got.slice(0, 200))}`)
    const r = await rows()
    expect(!r.slice(-2).some((t) => /\^C/.test(t)), `the copy reached the shell as an interrupt: ${JSON.stringify(r.slice(-2))}`)
})
await step("terminal: Ctrl+C with nothing selected stops what is running", true, async () => {
    await focus_terminal()
    await page.keyboard.type(win ? "ping -n 60 127.0.0.1" : "sleep 60")
    await page.keyboard.press("Enter")
    await wait(2500)
    await chord(["Control", "c"])
    await wait(1500)
    await page.keyboard.type("echo after-interrupt-ok")
    await page.keyboard.press("Enter")
    return (await saw("after-interrupt-ok", 2, 25000)).slice(-4)
})
// A program that takes the mouse (Claude Code, vim) selects by itself and copies with OSC 52.
// (Not on Windows: older ConPTY does not pass the sequence on.)
await step("terminal: what a program copies itself (OSC 52) reaches the clipboard", !win, async () => {
    await clip_write("nothing yet")
    await focus_terminal()
    await page.keyboard.type(`printf '\\033]52;c;%s\\007' "$(printf program-copy-ok | base64)"`)
    await page.keyboard.press("Enter")
    await until(async () => (await clip_read()) === "program-copy-ok", { timeout: 15000, what: "the program's text on the clipboard" })
    // a program that asks for the clipboard is not answered, and changes nothing
    await page.keyboard.type(`printf '\\033]52;c;?\\007'; echo asked-ok`)
    await page.keyboard.press("Enter")
    await saw("asked-ok", 2, 15000)
    expect((await clip_read()) === "program-copy-ok", "a clipboard query changed the clipboard")
    if (process.platform === "linux") {
        // the copy key with nothing selected in the terminal: what the program copied, again
        await clip_write("something else")
        await focus_terminal()
        await chord(["Control", "Shift", "C"])
        await wait(600)
        const got = await clip_read()
        expect(got === "program-copy-ok", `the copy key gave ${JSON.stringify(got.slice(0, 80))}`)
    }
})
// A program that takes the mouse (Claude Code, vim, tmux) scrolls and is clicked by the reports the
// terminal sends it. On a Windows 10 server neither arrived: the console host of that Windows keeps
// the program's request for the mouse to itself and drops the reports. The server starts terminals
// on the console host it ships for that reason; this is the whole way, browser to program, on all
// three systems. test/mouse_probe.jl is the program.
await step("terminal: the wheel and a click reach a program that takes the mouse", true, async () => {
    const julia = process.env.WALKTHROUGH_JULIA ?? "julia"
    const probe = path.resolve("..", "mouse_probe.jl")
    await focus_terminal()
    await page.keyboard.type(`${win ? "& " : ""}"${julia}" --startup-file=no "${probe}"`)
    await page.keyboard.press("Enter")
    await saw("MOUSE_PROBE_READY", 1, 120000)
    const at = await page.evaluate(() => {
        const r = (document.querySelector("#terminal-panel .terminal-body.active .xterm-screen") ?? document.querySelector("#terminal-panel .xterm-screen")).getBoundingClientRect()
        return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
    })
    await page.mouse.move(at.x, at.y)
    await page.mouse.wheel({ deltaY: -300 })
    await saw("wheel-up-arrived", 1, 20000)
    await page.mouse.click(at.x, at.y)
    await saw("press-arrived", 1, 20000)
    return (await saw("MOUSE_PROBE_DONE", 1, 20000)).slice(-5)
})
await step("terminal: a second one; closing it while a program runs asks first, then closes", true, async () => {
    await page.evaluate(() => document.querySelector("button.new-terminal-tab").click())
    await until(() => page.evaluate(() => document.querySelectorAll(".terminal-tab").length === 2), { timeout: 20000, what: "two terminal tabs" })
    await wait(3500)
    await focus_terminal()
    await page.keyboard.type(win ? "ping -n 120 127.0.0.1" : "sleep 120")
    await page.keyboard.press("Enter")
    await wait(3000)
    await page.evaluate(() => [...document.querySelectorAll(".terminal-tab")].pop().querySelector(".close").click())
    await page.waitForSelector("dialog.land-dialog", { timeout: 8000 })
    report.seen.close_running = await page.evaluate(() => document.querySelector("dialog.land-dialog").innerText.replace(/\s+/g, " "))
    expect(new RegExp(win ? "ping" : "sleep", "i").test(report.seen.close_running), `it asked: ${JSON.stringify(report.seen.close_running)}`)
    const t0 = Date.now()
    await page.evaluate(() => [...document.querySelectorAll("dialog.land-dialog .buttons button")].pop().click())
    await until(() => page.evaluate(() => document.querySelectorAll(".terminal-tab").length === 1), { timeout: 15000, what: "one terminal tab again" })
    // and the server still answers: closing a terminal that is printing must not hold it up
    const ping = await page.evaluate(() => fetch("./api/v1/terminals").then((r) => r.status))
    expect(ping === 200, `the server answered ${ping} after the close`)
    return { asked: report.seen.close_running, closed_ms: Date.now() - t0 }
})
await step("keys: Ctrl+` hides and shows the terminal", true, async () => {
    const shown = () => page.evaluate(() => { const p = document.querySelector("#terminal-panel"); return p != null && p.offsetParent != null && p.getBoundingClientRect().height > 40 })
    expect(await shown(), "the terminal is not showing to begin with")
    await page.evaluate(() => document.querySelector("#land button.entry").focus())
    await chord(["Control", "Backquote"])
    await wait(700)
    const hidden = !(await shown())
    await chord(["Control", "Backquote"])
    await wait(900)
    expect(hidden && (await shown()), `hidden after one press: ${hidden}; showing after two: ${await shown()}`)
})
await step("keys: the next and the previous tab", process.platform !== "darwin", async () => {
    const active = () => page.evaluate(() => document.querySelector(".tab.active:not(.terminal-tab)")?.innerText.replace(/\s+/g, " ").trim())
    await page.evaluate(() => document.querySelector("#land button.entry").focus())
    const a = await active()
    await chord(process.platform === "darwin" ? ["Meta", "Shift", "BracketRight"] : ["Alt", "BracketRight"])
    await wait(500)
    const b = await active()
    await chord(process.platform === "darwin" ? ["Meta", "Shift", "BracketLeft"] : ["Alt", "BracketLeft"])
    await wait(500)
    const c = await active()
    expect(a != null && b != null && a !== b && c === a, `tabs in front: ${JSON.stringify([a, b, c])}`)
    return [a, b, c]
})
await step("keys: the hints shown are this system's", true, async () => {
    const hints = await page.evaluate(() => [...document.querySelectorAll("[title], [aria-keyshortcuts], kbd")].map((e) => `${e.getAttribute("title") ?? ""} ${e.tagName === "KBD" ? e.textContent : ""}`).filter((t) => /[⌘⌥⇧⌃]|Ctrl|Cmd/.test(t)))
    report.seen.key_hints = [...new Set(hints)].slice(0, 30)
    if (process.platform !== "darwin") expect(!hints.some((h) => /[⌘⌥]|Cmd/.test(h)), `Mac keys named here: ${JSON.stringify(hints.filter((h) => /[⌘⌥]|Cmd/.test(h)))}`)
    return report.seen.key_hints
})
await step("terminal: fonts drawn", false, async () => (report.seen.terminal_fonts = await drawn_fonts("#terminal-panel .xterm-rows")))
await shot("6-terminal")
await step("workspace: scrollbars", false, async () => (report.seen.workspace_scroll = await scroll_report()))

await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "dark" }])
await wait(1200)
await shot("7-dark")
// narrower, and at the display scaling most Windows laptops ship with
await page.setViewport({ width: 1100, height: 700, deviceScaleFactor: 1.25 })
await wait(1200)
await shot("8-dark-125-percent")
await step("workspace: nothing wider than the window at 1100 px", false, async () => {
    const s = await scroll_report()
    expect(!s.page_wider_than_window, "the page scrolls sideways")
})

report.page_errors = errors
report.bad_responses = [...new Set(bad)]
console.log("page errors:", JSON.stringify(errors))
console.log("4xx/5xx:", JSON.stringify(report.bad_responses))
fs.writeFileSync(path.join(shots, `walk-${process.platform}-report.json`), JSON.stringify(report, null, 2))
await browser.close()
process.exit(failed ? 1 : 0)
