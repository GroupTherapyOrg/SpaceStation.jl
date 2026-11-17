// @ts-nocheck — this file was written without JSDoc type annotations (~65 tsc errors, mostly
// untyped useRef/useState generics). TODO: annotate and re-enable checking; the shared editor
// code (components/, common/) stays fully checked.
// SpaceStation — the workspace hub: a file browser + tabbed notebooks, all running on a
// stock Pluto server. Every tab is the UNMODIFIED Pluto editor in an iframe (its own
// websocket, its own state); the hub itself only talks to existing server endpoints:
//   GET  ./api/v1/workspace          workspace root + git branch (404 → no workspace open yet)
//   GET  ./api/v1/workspace/listing  one folder's entries — the sidebar tree loads folder by folder
//   POST ./api/v1/workspace/open   open a folder as the workspace (VS Code "Open Folder")
//   GET  ./api/v1/browse           directory listing for the folder picker
//   GET  ./api/v1/notebooks        running notebooks
//   POST ./open?path=…             open a notebook (Safe preview), returns its id
//   POST ./new                     new notebook, returns its id
//   POST ./move?id=…&newpath=…     rename/move (used to place new notebooks in the workspace)
//   POST ./shutdown?id=…           stop a notebook session
import { html, render, useState, useEffect, useCallback, useRef } from "./imports/Preact.js"
import { pluto_file_extensions, has_pluto_file_extension } from "./common/PlutoFileExtensions.js"
import { cycle_color_scheme, get_color_scheme, prefers_dark } from "./common/ColorScheme.js"
import { mount_icons, file_icon } from "./common/Icons.js"

// What the page remembers. localStorage can be missing (blocked in a private window, by a policy)
// or full; both used to leave a blank or half-drawn page. So: every read and write is guarded, a
// copy in memory stands in when the real one fails, and a key is written only when its value
// changes (dragging a pane used to write seven keys several hundred times).
const store = (() => {
    const memory = new Map()
    return {
        get: (key) => {
            try {
                const v = localStorage.getItem(key)
                if (v != null) memory.set(key, v)
                return v ?? memory.get(key) ?? null
            } catch {
                return memory.get(key) ?? null
            }
        },
        set: (key, value) => {
            value = String(value)
            if (memory.get(key) === value) return
            memory.set(key, value)
            try {
                localStorage.setItem(key, value)
            } catch {}
        },
        remove: (key) => {
            memory.delete(key)
            try {
                localStorage.removeItem(key)
            } catch {}
        },
    }
})()

/** What a failed request said, for a person: the server's own words when it sent any. */
const failure_text = async (r) => {
    let said = ""
    try {
        said = (await r.text()).trim()
    } catch {}
    try {
        const parsed = JSON.parse(said)
        said = String(parsed.detail ?? parsed.error ?? parsed.message ?? said)
    } catch {}
    return said !== "" && said.length < 400 && !said.startsWith("<") ? said : `the server answered ${r.status}`
}

const get_text = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(await failure_text(r))
    return await r.text()
}
const get_json = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(await failure_text(r))
    return await r.json()
}

// Both separators: on Windows every path the server hands back is `\`-separated (`C:\ws\a.jl`),
// and splitting that on "/" alone returns the whole path as the "name". Same shape as the
// basename in components/FilePicker.js, which is not exported.
const basename = (p) => (p.split("/").pop() ?? "").split("\\").pop() ?? ""

// Dialogs the browser can't suppress. window.confirm / window.prompt can be permanently silenced
// (Chrome's "prevent this page from creating additional dialogs", frames without allow-modals, and
// some webviews have no prompt() at all) — they then return at once and every button
// that asks first appears dead, with no error. A native <dialog>.showModal() is always shown.
const open_dialog = (build) =>
    new Promise((resolve) => {
        const dialog = document.createElement("dialog")
        dialog.className = "land-dialog"
        const before = document.activeElement
        const done = (result) => {
            dialog.close()
            dialog.remove()
            if (before instanceof HTMLElement && before.isConnected) before.focus()
            resolve(result)
        }
        build(dialog, done)
        document.body.append(dialog)
        dialog.oncancel = (e) => {
            e.preventDefault()
            done(null)
        }
        // a press that STARTS on the backdrop dismisses; a text selection dragged out of the box does not
        dialog.onpointerdown = (e) => e.target === dialog && done(null)
        dialog.showModal()
    })

const dialog_button = (label, classname) => {
    const b = document.createElement("button")
    b.type = "button"
    b.textContent = label
    b.className = `text-button ${classname ?? ""}`
    return b
}

/** Ask before doing something. Returns Promise<boolean>; Esc / backdrop = false. */
const ask_confirm = (message, { action = "Confirm", danger = false, title = null } = {}) =>
    open_dialog((dialog, done) => {
        const [first, ...rest] = message.split("\n\n")
        const heading = document.createElement("h3")
        heading.textContent = title ?? first
        const body = document.createElement("p")
        body.textContent = title == null ? rest.join("\n\n") : message
        const row = document.createElement("div")
        row.className = "buttons"
        const cancel = dialog_button("Cancel", "quiet")
        const ok = dialog_button(action, danger ? "danger" : "primary")
        row.append(cancel, ok)
        dialog.append(heading, ...(body.textContent === "" ? [] : [body]), row)
        cancel.onclick = () => done(null)
        ok.onclick = () => done(true)
        // safe default: Enter cancels, the action needs a deliberate click or Tab
        queueMicrotask(() => (danger ? cancel : ok).focus())
    }).then((r) => r === true)

/** Ask for a line of text (a file name). `check(value)` returns a complaint, or null when the value
 *  will do. Returns Promise<string?>; Esc / backdrop / Cancel = null. */
const ask_text = ({ title, note = "", value = "", action = "Create", select_to = null, check = () => null }) =>
    open_dialog((dialog, done) => {
        const heading = document.createElement("h3")
        heading.textContent = title
        const form = document.createElement("form")
        form.method = "dialog"
        const input = document.createElement("input")
        input.type = "text"
        input.value = value
        input.spellcheck = false
        input.autocomplete = "off"
        const hint = document.createElement("p")
        hint.className = "field-note"
        const row = document.createElement("div")
        row.className = "buttons"
        const cancel = dialog_button("Cancel", "quiet")
        const ok = dialog_button(action, "primary")
        ok.type = "submit"
        row.append(cancel, ok)
        form.append(input, hint, row)
        dialog.append(heading, form)
        const validate = () => {
            const v = input.value.trim()
            const complaint = v === "" ? null : check(v)
            hint.textContent = complaint ?? note
            hint.classList.toggle("error", complaint != null)
            ok.disabled = v === "" || complaint != null
            return !ok.disabled
        }
        input.oninput = validate
        cancel.onclick = () => done(null)
        form.onsubmit = (e) => {
            e.preventDefault()
            if (validate()) done(input.value.trim())
        }
        validate()
        queueMicrotask(() => {
            input.focus()
            // the name without its extension, ready to be typed over
            input.setSelectionRange(0, select_to ?? input.value.length)
        })
    })

/** Put text on the clipboard. The async API needs a secure context and, in WebKit, a user gesture
 *  it still recognises; the hidden-textarea copy is the fallback for a workspace reached over plain
 *  http on another host. */
const copy_text = async (text) => {
    try {
        await navigator.clipboard.writeText(text)
        return true
    } catch {}
    try {
        const ta = document.createElement("textarea")
        ta.value = text
        ta.style.cssText = "position: fixed; opacity: 0; pointer-events: none"
        document.body.append(ta)
        const previous = document.activeElement
        ta.select()
        const ok = document.execCommand("copy")
        ta.remove()
        previous?.focus?.()
        return ok
    } catch {
        return false
    }
}

const is_mac = navigator.platform.toUpperCase().includes("MAC")

/** A menu at the pointer (or under a button). `items`: {label, icon?, keys?, danger?, disabled?, run}
 *  or "-" for a rule. Closes on a choice, Escape, a press outside, a scroll or a resize. */
const open_menu = (x, y, items) => {
    document.querySelector(".land-menu.context")?.remove()
    const menu = document.createElement("div")
    menu.className = "land-menu context"
    menu.setAttribute("role", "menu")
    const before = document.activeElement
    const close = () => {
        menu.remove()
        if (before instanceof HTMLElement && before.isConnected) before.focus()
        document.removeEventListener("pointerdown", on_outside, true)
        document.removeEventListener("keydown", on_key, true)
        window.removeEventListener("blur", close)
        window.removeEventListener("resize", close)
    }
    const on_outside = (e) => menu.contains(e.target) || close()
    const on_key = (e) => {
        const buttons = [...menu.querySelectorAll("button:not(:disabled)")]
        const at = buttons.indexOf(document.activeElement)
        if (e.key === "Escape") close()
        else if (e.key === "ArrowDown") buttons[(at + 1) % buttons.length]?.focus()
        else if (e.key === "ArrowUp") buttons[(at - 1 + buttons.length) % buttons.length]?.focus()
        else return
        e.preventDefault()
        e.stopPropagation()
    }
    for (const item of items) {
        if (item === "-") {
            menu.append(document.createElement("hr"))
            continue
        }
        const b = document.createElement("button")
        b.className = `land-menu-item ${item.danger ? "danger" : ""}`
        b.setAttribute("role", "menuitem")
        b.disabled = item.disabled === true
        const icon = icon_element(item.icon)
        const label = document.createElement("span")
        label.textContent = item.label
        b.append(icon, label)
        if (item.keys) {
            const keys = document.createElement("span")
            keys.className = "keys"
            keys.textContent = item.keys
            b.append(keys)
        }
        b.onclick = () => {
            close()
            item.run()
        }
        menu.append(b)
    }
    document.body.append(menu)
    // keep it on screen: flip to the other side of the pointer when it would run off an edge
    const { width, height } = menu.getBoundingClientRect()
    menu.style.left = `${Math.max(4, x + width > window.innerWidth - 4 ? x - width : x)}px`
    menu.style.top = `${Math.max(4, y + height > window.innerHeight - 4 ? y - height : y)}px`
    document.addEventListener("pointerdown", on_outside, true)
    document.addEventListener("keydown", on_key, true)
    window.addEventListener("blur", close)
    window.addEventListener("resize", close)
    return close
}

// App-wide light/dark/auto. Same-origin pages (the launcher, every workspace under the hub, the
// notebook frames) follow at once through storage events; a workspace link also carries the
// choice as a ?scheme= seed (ColorScheme.js handles both ends). The terminal's own scheme toggle
// is separate on purpose.
const AppSchemeToggle = ({ classname }) => {
    const [scheme, set_scheme] = useState(get_color_scheme())
    return html`<button
        class="text-button app-scheme-toggle ${classname ?? ""}"
        title=${scheme === "system" ? "Appearance follows the system. Switch to light" : scheme === "light" ? "Appearance: light. Switch to dark" : "Appearance: dark. Switch to follow the system"}
        onClick=${() => {
            set_scheme(cycle_color_scheme())
        }}
    >
        <${Ico} name=${scheme === "system" ? "i-auto" : scheme === "light" ? "i-sun" : "i-moon"} />${scheme === "system" ? "Auto" : scheme === "light" ? "Light" : "Dark"}
    </button>`
}

// `new URL(..., import.meta.url)` works unbundled in the browser AND gets rewritten by
// the bundler — a string src would 404 in frontend-dist where filenames are hashed.
const logo_url = new URL("img/spacestation.svg", import.meta.url).href

const RECENT_KEY = "spacestation recent workspaces"
const get_recent_workspaces = () => {
    try {
        const r = JSON.parse(store.get(RECENT_KEY) ?? "[]")
        return Array.isArray(r) ? r : []
    } catch {
        return []
    }
}
const remember_workspace = (path) => {
    store.set(RECENT_KEY, JSON.stringify([path, ...get_recent_workspaces().filter((p) => p !== path)].slice(0, 8)))
}

// Terminals live in the terminal panel as their own tabs. Their shells persist on the server
// (keyed by tid), so we remember each terminal's tid + label and reattach on reload.
// The tabs that were open in a workspace, and which one was in front: a reload comes back to the
// same page, not to an empty editor.
const TABS_KEY = "spacestation tabs by workspace"
const restore_tabs = (workspace_root) => {
    try {
        const saved = JSON.parse(store.get(TABS_KEY) ?? "{}")?.[workspace_root]
        if (saved == null || !Array.isArray(saved.tabs)) return null
        const tabs = saved.tabs.filter((t) => t && typeof t.id === "string" && typeof t.path === "string").map((t) => ({ id: t.id, path: t.path, kind: t.kind === "file" ? "file" : "notebook" }))
        // `known`: every notebook that was running when this was saved, tabbed or not. One that is
        // running now and is not in there was started since (by an agent, from a terminal), and is
        // shown; one whose tab was closed on purpose stays closed.
        const known = Array.isArray(saved.known) ? saved.known.filter((id) => typeof id === "string") : []
        return { tabs, active: typeof saved.active === "string" ? saved.active : null, known }
    } catch {
        return null
    }
}
const save_tabs = (workspace_root, tabs, active, known) => {
    try {
        const parsed = JSON.parse(store.get(TABS_KEY) ?? "{}")
        const all = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
        all[workspace_root] = { tabs: tabs.map((t) => ({ id: t.id, path: t.path, kind: t.kind ?? "notebook" })), active, known }
        store.set(TABS_KEY, JSON.stringify(all))
    } catch {}
}

const forget_workspace = (path) => {
    store.set(RECENT_KEY, JSON.stringify(get_recent_workspaces().filter((p) => p !== path)))
}

const TERMINALS_KEY = "spacestation terminals by workspace"
const LEGACY_TERMINALS_KEY = "spacestation terminals"
const restore_terminals = (workspace_root) => {
    if (typeof workspace_root !== "string" || workspace_root.length === 0) return []
    try {
        const all = JSON.parse(store.get(TERMINALS_KEY) ?? "{}")
        let saved = all && typeof all === "object" && !Array.isArray(all) ? all[workspace_root] : null
        // One-time migration: old builds stored one global list. Adopt it for the workspace that
        // first loads after upgrade, then remove it so other workspaces don't inherit those tabs.
        if (!Array.isArray(saved)) {
            const legacy = JSON.parse(store.get(LEGACY_TERMINALS_KEY) ?? "[]")
            if (Array.isArray(legacy) && legacy.length > 0) {
                saved = legacy
                store.remove(LEGACY_TERMINALS_KEY)
            }
        }
        if (!Array.isArray(saved)) return []
        // `cwd` and `notebook_env` too: reattaching from the workspace root to a shell that was opened
        // in a subfolder made the server take it for a stale one and end it, job and all
        return saved
            .filter((t) => t && typeof t.tid === "string")
            .map((t) => ({ tid: t.tid, label: t.label ?? "Terminal", ...(typeof t.cwd === "string" ? { cwd: t.cwd } : {}), ...(typeof t.notebook_env === "string" ? { notebook_env: t.notebook_env } : {}) }))
    } catch {
        return []
    }
}
const save_terminals = (workspace_root, terminals) => {
    if (typeof workspace_root !== "string" || workspace_root.length === 0) return
    let all = {}
    try {
        const parsed = JSON.parse(store.get(TERMINALS_KEY) ?? "{}")
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) all = parsed
    } catch {}
    all[workspace_root] = terminals.map((t) => ({ tid: t.tid, label: t.label, ...(t.cwd ? { cwd: t.cwd } : {}), ...(t.notebook_env ? { notebook_env: t.notebook_env } : {}) }))
    store.set(TERMINALS_KEY, JSON.stringify(all))
}

// How long to wait for an SSH connection before giving up (seconds). A busy ProxyJump login node can
// need well over the old 8s default just to relay the compute node's banner — so this is user-tunable
// from homebase. Mirrors the server's clamp (see SSH_CONNECT_TIMEOUT in CollabRemote.jl).
const SSH_TIMEOUT_KEY = "spacestation ssh connect timeout"
const SSH_TIMEOUT_DEFAULT = 25
const clamp_ssh_timeout = (v) => Math.max(3, Math.min(180, Math.round(Number(v) || SSH_TIMEOUT_DEFAULT)))
const get_ssh_timeout = () => {
    const v = Number(store.get(SSH_TIMEOUT_KEY))
    return Number.isFinite(v) && v >= 3 ? clamp_ssh_timeout(v) : SSH_TIMEOUT_DEFAULT
}

/** A long path, shortened at folder boundaries: its last two folders, never a fragment of a name. */
const short_path = (path) => {
    const sep = path.includes("\\") && !path.includes("/") ? "\\" : "/"
    const parts = path.split(sep).filter((x) => x !== "")
    return parts.length <= 3 ? path : `…${sep}${parts.slice(-2).join(sep)}`
}
/** What leads up to a folder's own name, shortened at folder boundaries: "…/scratchpad/" for
 *  /a/b/scratchpad/demo-ws. The name itself is shown after it, and stands out. */
const path_lead = (path) => {
    const sep = path.includes("\\") && !path.includes("/") ? "\\" : "/"
    const parts = path.split(sep).filter((x) => x !== "")
    if (parts.length <= 1) return path.startsWith(sep) ? sep : ""
    const lead = parts.length <= 3 ? (path.startsWith(sep) ? sep : "") + parts.slice(0, -1).join(sep) : `…${sep}${parts[parts.length - 2]}`
    return lead + sep
}
const greeting = () => {
    const h = new Date().getHours()
    return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
}

/** An icon from the sprite. `name` is "i-terminal", or what `file_icon` returns. */
const Ico = ({ name }) => {
    const icon = typeof name === "string" ? name : name.icon
    const kind = typeof name === "string" ? (name.startsWith("i-folder") ? "k-folder" : "") : name.kind
    return html`<svg class="ico ${kind}" aria-hidden="true"><use href=${"#" + icon} /></svg>`
}
/** The same, for the menus and dialogs that are built without a template. */
const icon_element = (name) => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    svg.setAttribute("class", "ico")
    svg.setAttribute("aria-hidden", "true")
    if (name != null) {
        const use = document.createElementNS("http://www.w3.org/2000/svg", "use")
        use.setAttribute("href", "#" + name)
        svg.append(use)
    }
    return svg
}

/** One row of the sidebar tree.
 *
 * Which folders are open, and what is in them, are NOT held here — they live in the hub
 * (`expanded` / `listings`) and arrive as props. That is what makes the tree lazy: the hub fetches
 * a folder's contents the first time it is expanded, and its 10s poll re-reads only the folders
 * that are currently open. A folder that has never been opened costs the server nothing.
 *
 * `tree` carries what every row needs and none of them changes: the handlers, the path shown in the
 * active tab, and the paths of the notebooks that are running.
 */
const FileEntry = ({ entry, listings, expanded, tree, depth }) => {
    const row_style = `--depth: ${depth}`
    if (entry.type === "dir") {
        const open = expanded.has(entry.path)
        const children = listings[entry.path]
        return html`<li class="dir ${open ? "open" : ""}">
            <div class="entry-row" onContextMenu=${(e) => tree.on_menu(e, entry)}>
                <button class="entry" style=${row_style} title=${entry.path} aria-expanded=${open} onClick=${(e) => e.detail > 1 || tree.on_toggle(entry.path)}>
                    <svg class="ico chevron" aria-hidden="true"><use href="#i-chevron" /></svg><${Ico} name=${open ? "i-folder-open" : "i-folder"} /><span class="entry-name">${entry.name}</span>
                </button>
                <button class="row-action" title="New notebook or file in ${entry.name}" aria-label="New notebook or file in ${entry.name}" onClick=${(e) => tree.on_create_menu(e.currentTarget, entry.path)}>
                    <svg class="ico" aria-hidden="true"><use href="#i-add" /></svg>
                </button>
            </div>
            ${open
                ? html`<ul>
                      ${children == null
                          ? html`<li class="pending">
                                <div class="entry-row"><span class="entry plain" style=${`--depth: ${depth + 1}`}><span class="no-chevron"></span>Reading…</span></div>
                            </li>`
                          : children.length === 0
                            ? html`<li class="truncated">
                                  <div class="entry-row"><span class="entry plain" style=${`--depth: ${depth + 1}`}><span class="no-chevron"></span>Empty</span></div>
                              </li>`
                            : children.map((c) => html`<${FileEntry} key=${c.path} entry=${c} listings=${listings} expanded=${expanded} tree=${tree} depth=${depth + 1} />`)}
                  </ul>`
                : null}
        </li>`
    }
    // a single folder is still capped, so a directory holding 100k files can't produce a 100k-row
    // response; the server closes such a listing with this marker rather than silently shortening it
    if (entry.type === "truncated") {
        return html`<li class="truncated">
            <div class="entry-row">
                <span class="entry plain" style=${row_style} title="This folder has more entries than SpaceStation lists in one go. Use the terminal to see the rest."
                    ><span class="no-chevron"></span>More files not listed</span
                >
            </div>
        </li>`
    }
    if (entry.type === "unreadable") {
        return html`<li class="truncated">
            <div class="entry-row">
                <span class="entry plain" style=${row_style} title=${entry.detail ?? ""}><span class="no-chevron"></span>Could not be read</span>
            </div>
        </li>`
    }
    const is_notebook = entry.type === "notebook"
    const kind = is_notebook ? null : file_icon(entry.name)
    return html`<li class="${is_notebook ? "notebook" : "file"} ${kind?.kind === "k-quiet" ? "quiet" : ""} ${tree.current_path === entry.path ? "current" : ""}">
        <div class="entry-row" onContextMenu=${(e) => tree.on_menu(e, entry)}>
            <button
                class="entry"
                style=${row_style}
                title=${entry.path}
                aria-current=${tree.current_path === entry.path ? "page" : undefined}
                onClick=${() => (is_notebook ? tree.on_open_notebook(entry.path) : tree.on_open_file(entry.path))}
            >
                <span class="no-chevron"></span><${Ico} name=${is_notebook ? "i-notebook" : kind} /><span class="entry-name">${entry.name}</span>
                ${is_notebook && tree.running_paths.has(entry.path) ? html`<span class="dot ok running-mark" title="Running"></span>` : null}
            </button>
        </div>
    </li>`
}

/** Homebase: the VS Code "Open Folder" experience (browse the filesystem, pick a folder) plus a live
 *  list of every running workspace — local children AND SSH remotes — to reattach to or shut down.
 *  Picking a folder spawns a child server in a new tab (see connect_local); this view never leaves.
 *  `on_cancel` (optional) shows a back button when opened on top of an existing workspace. */
const WorkspaceOpener = ({ on_cancel, tunneled }) => {
    // A workspace's URL is the hub's own page for it (`/w/<id>/`, relative to the hub — see
    // src/webserver/Proxy.jl), so resolve it against this page before handing it to a tab. It
    // carries the homebase fragment: the workspace's way back here.
    const abs_url = (url) => new URL(url, window.location.href).href
    const open_href = (url) => abs_url(url)
    const [listing, set_listing] = useState(
        /** @type {{path: String, parent: String, entries: Array<{name: String, path: String}>, crumbs: Array<{name: String, path: String}>}?} */ (null)
    )
    const [error, set_error] = useState(/** @type {String?} */ (null))
    const [ssh_hosts, set_ssh_hosts] = useState(/** @type {Array<String>} */ ([]))
    const [ssh_timeout, set_ssh_timeout] = useState(get_ssh_timeout)
    const [remote_states, set_remote_states] = useState(/** @type {Record<String, {state: String, detail: String, url: String?}>} */ ({}))
    // Picking a LOCAL folder spawns a child SpaceStation server (its own process + tab), exactly like an
    // SSH remote — so this opener is "homebase": it never leaves to become a workspace, it launches them.
    const [local_states, set_local_states] = useState(/** @type {Record<String, {state: String, detail: String, url: String?}>} */ ({}))
    const [running, set_running] = useState(
        /** @type {Array<{kind: String, key: String, name: String, sub: String, state: String, url: String?, path?: String, host?: String}>} */ ([])
    )
    // a connect can be cancelled mid-flight: the poll loops below bail when their key lands in these sets
    const cancelled_hosts = useRef(/** @type {Set<String>} */ (new Set()))
    const cancelled_paths = useRef(/** @type {Set<String>} */ (new Set()))

    // The lists on this page come from things that change underneath a running app: ~/.ssh/config
    // (a cluster launcher adding hosts), folders appearing on disk, servers starting elsewhere. They
    // used to be read once at load, so a new host or folder meant relaunching the app. Now every
    // source is re-read when the window regains focus or becomes visible again — the moment after
    // you did something in another app — on a slow interval while the page is shown, and on demand
    // from the refresh buttons in the section headers. (Running workspaces have their own 3s poll.)
    const load_ssh_hosts = useCallback(() => get_json("./api/v1/ssh_hosts").then(set_ssh_hosts).catch(() => {}), [])
    useEffect(() => {
        load_ssh_hosts()
    }, [load_ssh_hosts])

    // The SSH connect timeout is a homebase setting. The server resets it to its default on restart, so
    // push our stored value on load and whenever it changes (and persist it locally for next time).
    useEffect(() => {
        store.set(SSH_TIMEOUT_KEY, String(ssh_timeout))
        fetch(`./api/v1/remote/config?connect_timeout=${encodeURIComponent(ssh_timeout)}`, { method: "POST" }).catch(() => {})
    }, [ssh_timeout])

    const connect_remote = useCallback(async (host) => {
        // everything happens server-side, idempotently: reuse a live tunnel/server, bootstrap only on first contact
        cancelled_hosts.current.delete(host) // a fresh attempt clears any earlier cancel
        try {
            let status = await get_json(`./api/v1/remote/open?host=${encodeURIComponent(host)}`, { method: "POST" })
            set_remote_states((s) => ({ ...s, [host]: status }))
            while (status.state !== "ready" && status.state !== "error") {
                await new Promise((r) => setTimeout(r, 1500))
                if (cancelled_hosts.current.has(host)) return // cancelled: stop polling (cancel_remote cleared the UI)
                status = await get_json(`./api/v1/remote/status?host=${encodeURIComponent(host)}`)
                set_remote_states((s) => ({ ...s, [host]: status }))
            }
            if (status.state === "ready" && status.url != null) {
                window.open(open_href(status.url), `spacestation-${status.url}`) // may be blocked: the pill stays a clickable link either way
            }
        } catch (e) {
            if (cancelled_hosts.current.has(host)) return
            set_remote_states((s) => ({ ...s, [host]: { state: "error", detail: String(e), url: null } }))
        }
    }, [])

    // Cancel / dismiss / disconnect a remote: stop polling, tell the server to bail + drop it, clear the UI.
    const cancel_remote = useCallback(async (host) => {
        cancelled_hosts.current.add(host)
        try {
            await fetch(`./api/v1/remote/cancel?host=${encodeURIComponent(host)}`, { method: "POST" })
        } catch (e) {}
        set_remote_states((s) => {
            const c = { ...s }
            delete c[host]
            return c
        })
        set_running((rs) => rs.filter((w) => !(w.kind === "remote" && w.host === host)))
    }, [])

    // Local twin of connect_remote: spawn (or reattach to) the child server for this folder, then open it
    // in a new tab. The homebase tab stays put, so you can launch as many workspaces as you like.
    const connect_local = useCallback(async (path) => {
        cancelled_paths.current.delete(path) // a fresh attempt clears any earlier cancel
        try {
            let status = await get_json(`./api/v1/local/open?path=${encodeURIComponent(path)}`, { method: "POST" })
            set_local_states((s) => ({ ...s, [path]: status }))
            while (status.state !== "ready" && status.state !== "error") {
                await new Promise((r) => setTimeout(r, 1000))
                if (cancelled_paths.current.has(path)) return // cancelled: stop polling
                status = await get_json(`./api/v1/local/status?path=${encodeURIComponent(path)}`)
                set_local_states((s) => ({ ...s, [path]: status }))
            }
            if (status.state === "ready" && status.url != null) {
                remember_workspace(path)
                window.open(open_href(status.url), `spacestation-${status.url}`) // may be blocked: the ready card stays a clickable link either way
            }
        } catch (e) {
            if (cancelled_paths.current.has(path)) return
            set_local_states((s) => ({ ...s, [path]: { state: "error", detail: String(e), url: null } }))
        }
    }, [])

    // Cancel an in-flight (or errored) local spawn — no confirm, nothing's running yet. (Shutting down a
    // READY workspace, which has live notebooks, goes through shutdown_local with its confirm instead.)
    const cancel_local = useCallback(async (path) => {
        cancelled_paths.current.add(path)
        try {
            await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(path)}`, { method: "POST" })
        } catch (e) {}
        set_local_states((s) => {
            const c = { ...s }
            delete c[path]
            return c
        })
        set_running((rs) => rs.filter((w) => !(w.kind === "local" && w.path === path)))
    }, [])

    const shutdown_local = useCallback(async (path) => {
        if (
            !(await ask_confirm(
                `Shut down the workspace server for ${basename(path)}?\n\nIts running notebooks will stop. Files stay on disk and outputs are cached in their .pluto-cache.toml sidecars, so reopening restores everything.`,
                { action: "Shut down" }
            ))
        )
            return
        try {
            await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(path)}`, { method: "POST" })
        } catch (e) {}
        set_local_states((s) => {
            const c = { ...s }
            delete c[path]
            return c
        })
        set_running((rs) => rs.filter((w) => !(w.kind === "local" && w.path === path)))
    }, [])

    // Open a folder as a workspace: spawn (or reattach to) its child server and open the hub's page
    // for it (connect_local). The same over an SSH tunnel: the page is the hub's, under its one
    // forwarded port, and the hub relays to the child on the node — nothing else is forwarded.
    const open_workspace = useCallback(async (path) => connect_local(path), [connect_local])

    // The ✕ on a Running Workspace card: cancel a connecting one, dismiss an errored one, disconnect a
    // ready remote, or shut down a ready local workspace (that one confirms — it has live notebooks).
    const dismiss_running = useCallback(
        (w) => {
            if (w.kind === "remote") return cancel_remote(w.host)
            if (w.state === "ready") return shutdown_local(w.path)
            return cancel_local(w.path)
        },
        [cancel_remote, shutdown_local, cancel_local]
    )

    // Homebase poll: every running workspace — local children AND SSH remotes — in one place, so you can
    // see them all and reattach in a click. (Best-effort; the lists just don't render if a fetch fails.)
    useEffect(() => {
        let alive = true
        const load = async () => {
            const [locals, remotes] = await Promise.all([
                get_json("./api/v1/local/list").catch(() => []),
                get_json("./api/v1/remote/list").catch(() => []),
            ])
            if (!alive) return
            set_running([
                ...locals.map((w) => ({ kind: "local", key: `local:${w.path}`, name: basename(w.path) || w.path, sub: w.path, state: w.state, url: w.url, path: w.path })),
                ...remotes.map((r) => ({ kind: "remote", key: `remote:${r.host}`, name: r.host, sub: "SSH remote", state: r.state, url: r.url, host: r.host })),
            ])
        }
        load()
        // not while the tab is in the background: nobody is looking, and it adds up
        const iv = setInterval(() => document.visibilityState === "visible" && load(), 3000)
        return () => {
            alive = false
            clearInterval(iv)
        }
    }, [])

    const browsed_path = useRef(/** @type {String?} */ (null))
    const browse = useCallback(async (path, { quiet = false } = {}) => {
        const previous = browsed_path.current
        browsed_path.current = path
        try {
            set_listing(await get_json(path == null ? "./api/v1/browse" : `./api/v1/browse?path=${encodeURIComponent(path)}`))
            if (!quiet) set_error(null)
            return true
        } catch (e) {
            // stay where we were: the periodic refresh re-reads `browsed_path`, and a mistyped path
            // must not become the folder it asks for from now on
            browsed_path.current = previous
            if (!quiet) set_error(path == null ? "The folders on this machine could not be read." : `${path} is not a folder that can be opened.`)
        }
    }, [])

    useEffect(() => {
        browse(null)
    }, [])

    const [refreshing, set_refreshing] = useState(false)
    const refresh_sources = useCallback(async () => {
        set_refreshing(true)
        try {
            await Promise.all([load_ssh_hosts(), browse(browsed_path.current, { quiet: true })])
        } finally {
            // keep the spin visible long enough to register as feedback
            setTimeout(() => set_refreshing(false), 400)
        }
    }, [load_ssh_hosts, browse])
    useEffect(() => {
        const on_focus = () => {
            if (document.visibilityState === "visible") void refresh_sources()
        }
        window.addEventListener("focus", on_focus)
        document.addEventListener("visibilitychange", on_focus)
        const iv = setInterval(() => {
            if (document.visibilityState === "visible") void refresh_sources()
        }, 10_000)
        return () => {
            window.removeEventListener("focus", on_focus)
            document.removeEventListener("visibilitychange", on_focus)
            clearInterval(iv)
        }
    }, [refresh_sources])
    const refresh_button = html`<button
        class="icon-button refresh ${refreshing ? "spinning" : ""}"
        title="Read the folders on disk and the hosts in ~/.ssh/config again"
        aria-label="Refresh"
        onClick=${() => void refresh_sources()}
    >
        <svg class="ico" aria-hidden="true"><use href="#i-refresh" /></svg>
    </button>`

    // How long each connect has been going. A step that takes minutes (the first install on a
    // cluster) with nothing moving on screen reads as a hang; a running clock says it is alive.
    const busy_since = useRef(/** @type {Record<String, number>} */ ({}))
    const [, set_tick] = useState(0)
    const is_busy = (st) => st != null && st.state !== "ready" && st.state !== "error"
    const elapsed = (key, st) => {
        if (!is_busy(st)) {
            delete busy_since.current[key]
            return ""
        }
        busy_since.current[key] ??= Date.now()
        const seconds = Math.floor((Date.now() - busy_since.current[key]) / 1000)
        return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
    }
    const state_label = (st) => st.state.charAt(0).toUpperCase() + st.state.slice(1)

    // One answer per place: what this page was told while connecting (it has the detail), else what
    // the server lists (it survives a reload of this page).
    const local_rows = [
        ...running.filter((w) => w.kind === "local").map((w) => ({ path: w.path, st: local_states[w.path] ?? { state: w.state, detail: "", url: w.url } })),
        ...Object.entries(local_states)
            .filter(([path]) => !running.some((w) => w.kind === "local" && w.path === path))
            .map(([path, st]) => ({ path, st })),
    ].map((r) => ({ ...r, st: r.st.state === "ready" && r.st.url == null ? { ...r.st, url: running.find((w) => w.path === r.path)?.url ?? null } : r.st }))
    const remote_state = (h) => {
        const listed = running.find((w) => w.kind === "remote" && w.host === h)
        return remote_states[h] ?? (listed == null ? null : { state: listed.state, detail: "", url: listed.url })
    }
    const connected_hosts = ssh_hosts.map((host) => ({ host, st: remote_state(host) })).filter(({ st }) => st?.state === "ready" && st.url != null)
    const anything_busy = local_rows.some((r) => is_busy(r.st)) || ssh_hosts.some((h) => is_busy(remote_state(h)))
    useEffect(() => {
        if (!anything_busy) return
        const iv = setInterval(() => set_tick((n) => n + 1), 1000)
        return () => clearInterval(iv)
    }, [anything_busy])

    const recent = get_recent_workspaces().filter((p) => !local_rows.some((r) => r.path === p))

    // Built by the server: splitting a path on "/" here turned a Windows one into a single bogus
    // crumb, and joining one back together means knowing about drives and backslashes.
    const crumbs = listing?.crumbs ?? []

    // A link to something that is ready, opened in a new tab (which keeps its opener: the way home).
    const open_link = (url, title, body, classname = "ws-open") => html`<a class=${classname} href=${open_href(url)} target=${`spacestation-${url}`} title=${`Open ${title}`}>${body}</a>`

    return html`<div class="workspace-opener">
        <div class="opener-page">
            <header class="opener-head">
                <img class="land-logo opener-logo" src=${logo_url} alt="" />
                <div class="opener-title">
                    <p class="section-label">${greeting()}</p>
                    <h1 class="wordmark">Space<span class="land-accent">Station</span></h1>
                </div>
                <div class="opener-head-actions">
                    <${AppSchemeToggle} />
                    ${on_cancel == null
                        ? null
                        : html`<button class="text-button opener-cancel" title="Back to your workspace" onClick=${on_cancel}>
                              <svg class="ico" aria-hidden="true"><use href="#i-close" /></svg>Back
                          </button>`}
                </div>
            </header>

            ${!tunneled && (local_rows.length > 0 || connected_hosts.length > 0)
                ? html`<section class="opener-section">
                      <h2 class="section-label">Open workspaces</h2>
                      <div class="island tray">
                          ${local_rows.map(({ path, st }) => {
                              const name = basename(path) || path
                              const time = elapsed(`local:${path}`, st)
                              const body = html`<span class="ws-card-icon"><svg class="ico" aria-hidden="true"><use href="#i-folder" /></svg></span>
                                  <span class="ws-name">${name}</span>
                                  <span class="ws-path" title=${path}>${short_path(path)}</span>
                                  ${st.state === "ready"
                                      ? null
                                      : st.state === "error"
                                        ? html`<span class="ws-state"><span class="dot bad"></span>Did not start</span>`
                                        : html`<span class="ws-state"><span class="spinner"></span>${state_label(st)} · ${time}</span>`}`
                              return html`<div class="ws-card ${st.state === "error" ? "error" : ""} ${is_busy(st) ? "busy" : ""}" key=${path}>
                                  ${st.state === "ready" && st.url != null ? open_link(st.url, name, body, "ws-card-open") : html`<div class="ws-card-open inert">${body}</div>`}
                                  ${st.state !== "ready" && st.detail ? html`<p class="ws-card-detail">${st.detail}</p>` : null}
                                  ${st.state === "ready"
                                      ? html`<div class="ws-card-foot">
                                            <span class="ws-state"><span class="dot ok"></span>Running</span>
                                            <button class="text-button stop" title="Stop this workspace's server and its notebooks. Files stay as they are." onClick=${() => shutdown_local(path)}>
                                                Shut down
                                            </button>
                                        </div>`
                                      : st.state === "error"
                                        ? html`<div class="ws-card-actions">
                                                  <button class="text-button" onClick=${() => open_workspace(path)}>Try again</button>
                                              </div>
                                              <button class="icon-button ws-card-corner" title="Dismiss" aria-label="Dismiss" onClick=${() => cancel_local(path)}><svg class="ico" aria-hidden="true"><use href="#i-close" /></svg></button>`
                                        : html`<div class="ws-card-actions"><button class="text-button" onClick=${() => cancel_local(path)}>Cancel</button></div>`}
                              </div>`
                          })}
                          ${connected_hosts.map(({ host, st }) => {
                              const body = html`<span class="ws-card-icon"><svg class="ico" aria-hidden="true"><use href="#i-server" /></svg></span>
                                  <span class="ws-name">${host}</span>
                                  <span class="ws-path">over SSH</span>`
                              return html`<div class="ws-card" key=${`remote:${host}`}>
                                  ${open_link(st.url, host, body, "ws-card-open")}
                                  <div class="ws-card-foot">
                                      <span class="ws-state"><span class="dot ok"></span>Connected</span>
                                      <button class="text-button stop" title=${`Close the tunnel to ${host}. Its server and whatever runs on it keep going.`} onClick=${() => cancel_remote(host)}>
                                          Disconnect
                                      </button>
                                  </div>
                              </div>`
                          })}
                      </div>
                  </section>`
                : null}

            ${recent.length > 0
                ? html`<section class="opener-section">
                      <h2 class="section-label">Recent</h2>
                      <div class="island tray">
                          ${recent.map(
                              (p) => html`<div class="ws-card" key=${p}>
                                  <button class="ws-card-open" title=${`Open ${p}`} onClick=${() => open_workspace(p)}>
                                      <span class="ws-card-icon quiet"><svg class="ico" aria-hidden="true"><use href="#i-folder" /></svg></span>
                                      <span class="ws-name">${basename(p) || p}</span>
                                      <span class="ws-path" title=${p}>${short_path(p)}</span>
                                  </button>
                                  <button
                                      class="icon-button ws-card-corner on-hover"
                                      title="Remove from this list"
                                      aria-label=${`Remove ${basename(p) || p} from recent`}
                                      onClick=${() => {
                                          forget_workspace(p)
                                          set_tick((n) => n + 1)
                                      }}
                                  >
                                      <svg class="ico" aria-hidden="true"><use href="#i-close" /></svg>
                                  </button>
                              </div>`
                          )}
                      </div>
                  </section>`
                : null}

            <section class="opener-section">
                <h2 class="section-label">Open a folder <span class="spacer"></span>${refresh_button}</h2>
                <div class="island browse-panel">
                    ${listing == null
                        ? html`<p class="ws-empty">${error == null ? "Reading…" : "This folder could not be read."}</p>`
                        : html`
                              <div class="browse-bar">
                                  <nav class="breadcrumbs" aria-label="Folder path">
                                      ${crumbs.map(
                                          (c, i) => html`<button class="crumb ${i === crumbs.length - 1 ? "current" : ""}" onClick=${() => browse(c.path)} title=${c.path}>
                                                  ${c.name}</button
                                              >${i > 0 && i < crumbs.length - 1 ? html`<span class="crumb-sep">/</span>` : null}`
                                      )}
                                  </nav>
                              </div>
                              <form
                                  class="paste-path"
                                  onSubmit=${(e) => {
                                      e.preventDefault()
                                      const v = e.target.elements.path.value.trim()
                                      if (v !== "") browse(v).then((found) => found && (e.target.elements.path.value = ""))
                                  }}
                              >
                                  <input name="path" type="text" aria-label="Go to a folder" placeholder="Go to a folder: type or paste a path, then Enter" autocomplete="off" spellcheck=${false} />
                              </form>
                              <div class="dir-grid">
                                  ${listing.entries.map(
                                      (d) => html`<button class="dir-pill" title=${d.path} onClick=${() => browse(d.path)}>
                                          <svg class="ico" aria-hidden="true"><use href="#i-folder" /></svg><span class="dir-name">${d.name}</span>
                                      </button>`
                                  )}
                                  ${listing.entries.length === 0 ? html`<p class="ws-empty">No folders in here.</p>` : null}
                              </div>
                              <div class="opener-actions">
                                  <button class="text-button primary open-this-folder" onClick=${() => open_workspace(listing.path)}>
                                      Open <strong>${basename(listing.path) || listing.path}</strong>
                                  </button>
                                  <span class="hint">as a workspace</span>
                              </div>
                          `}
                </div>
                ${error == null
                    ? null
                    : html`<p class="opener-error" role="alert"><svg class="ico" aria-hidden="true"><use href="#i-alert" /></svg><span>${error}</span></p>`}
            </section>

            ${!tunneled && ssh_hosts.length > 0
                ? html`<section class="opener-section">
                      <h2 class="section-label">
                          Remote hosts
                          <span class="spacer"></span>
                          <label class="ssh-timeout" title="How long to wait for an SSH connection, including the banner of a slow login node in between, before giving up.">
                              Give up after
                              <input type="number" min="3" max="180" step="1" value=${ssh_timeout} onChange=${(e) => set_ssh_timeout(clamp_ssh_timeout(e.target.value))} />
                              s
                          </label>
                          ${refresh_button}
                      </h2>
                      <p class="section-note">
                          From <code>~/.ssh/config</code>. The files, notebooks and terminal all run on that machine, over an SSH tunnel. The first connection installs
                          SpaceStation there; after that it reconnects at once.
                      </p>
                      <ul class="island ws-list">
                          ${ssh_hosts.map((h) => {
                              const st = remote_state(h)
                              const time = elapsed(`remote:${h}`, st)
                              const body = html`<svg class="ico" aria-hidden="true"><use href="#i-server" /></svg><span class="ws-name">${h}</span>`
                              return html`<li class="ws-row ${st?.state === "error" ? "error" : ""}" key=${h}>
                                  ${st?.state === "ready" && st.url != null
                                      ? open_link(st.url, h, body)
                                      : is_busy(st)
                                        ? html`<div class="ws-open inert">${body}</div>`
                                        : html`<button class="ws-open" title=${`Open a workspace on ${h}`} onClick=${() => connect_remote(h)}>${body}</button>`}
                                  ${st == null
                                      ? html`<span class="row-hint">Connect</span>`
                                      : st.state === "ready"
                                        ? html`<span class="ws-state"><span class="dot ok"></span>Connected</span>
                                              <button class="text-button" title=${`Close the tunnel to ${h}. Its server and whatever runs on it keep going.`} onClick=${() => cancel_remote(h)}>
                                                  Disconnect
                                              </button>`
                                        : st.state === "error"
                                          ? html`<span class="ws-state"><span class="dot bad"></span>Could not connect</span>
                                                <button class="text-button" onClick=${() => connect_remote(h)}>Try again</button>
                                                <button class="icon-button" title="Dismiss" aria-label="Dismiss" onClick=${() => cancel_remote(h)}><svg class="ico" aria-hidden="true"><use href="#i-close" /></svg></button>`
                                          : html`<span class="ws-state"><span class="spinner"></span>${state_label(st)} · ${time}</span>
                                                <button class="text-button" onClick=${() => cancel_remote(h)}>Cancel</button>`}
                                  ${st != null && st.state !== "ready" && (st.detail || st.state === "installing")
                                      ? html`<p class="ws-detail" role=${st.state === "error" ? "alert" : "status"}>
                                            ${st.detail}
                                            ${st.state === "installing"
                                                ? html`<span class="note">The first setup compiles a lot of Julia and takes a few minutes. Leave this page open: it connects by itself.</span>`
                                                : null}
                                        </p>`
                                      : null}
                              </li>`
                          })}
                      </ul>
                  </section>`
                : null}
        </div>
    </div>`
}


/** A terminal view: xterm.js bridged to a real shell over the /terminal websocket, keyed by `tid`.
 *  Wire protocol: we send "0:<keys>" and "1:<rows>,<cols>" text frames; the server sends raw PTY
 *  bytes as binary frames. The shell starts in the workspace folder and PERSISTS on the server by
 *  `tid` — so reattaching (a tab switch, a reload) replays scrollback. Used by both the docked
 *  terminal and each terminal tab; the only difference is which `tid` they own. */
/** The terminal's own colour scheme, deliberately independent of the page theme: a light UI with a
 *  dark terminal is a common preference, so this is a per-user choice rather than something derived
 *  from `prefers-color-scheme`.
 *
 *  Dark sets only background/foreground and leaves xterm's default ANSI palette alone — that is what
 *  SpaceStation has always shipped, and it is already tuned for a dark ground. Light has to name all
 *  sixteen: xterm's bright defaults (yellow #fce94f, cyan #34e2e2, white #eeeeec) are close to
 *  invisible on a pale background. The values below are GitHub's light ANSI set, which is built for
 *  exactly this contrast. */
const terminal_theme_for = (scheme) => {
    const styles = getComputedStyle(document.documentElement)
    const v = (name, fallback) => styles.getPropertyValue(name).trim() || fallback
    return scheme === "light"
        ? {
              background: "#00000000",
              foreground: v("--terminal-light-fg", "#24292f"),
              cursor: "#24292f",
              cursorAccent: "#fbfbfb",
              selectionBackground: "#b4d5fe",
              black: "#24292f",
              red: "#cf222e",
              green: "#116329",
              yellow: "#4d2d00",
              blue: "#0969da",
              magenta: "#8250df",
              cyan: "#1b7c83",
              white: "#6e7781",
              brightBlack: "#57606a",
              brightRed: "#a40e26",
              brightGreen: "#1a7f37",
              brightYellow: "#633c01",
              brightBlue: "#218bff",
              brightMagenta: "#a475f9",
              brightCyan: "#3192aa",
              brightWhite: "#8c959f",
          }
        : {
              background: "#00000000",
              foreground: v("--terminal-fg", "#dddddd"),
          }
}

const TerminalView = ({ tid, cwd, visible, scheme, notebook_env, on_exit }) => {
    const node_ref = useRef(null)
    // "lost": the connection dropped and is being re-made; "failed": it could not be.
    const [link, set_link] = useState(/** @type {"ok" | "lost" | "failed"} */ ("ok"))
    const reconnect_ref = useRef(/** @type {(() => void)?} */ (null))
    const on_exit_ref = useRef(on_exit)
    on_exit_ref.current = on_exit
    const started = useRef(false)
    const fit_ref = useRef(null)
    const refit_timer = useRef(null)
    // Where the view was when the tab went hidden, as lines above the bottom (0 = pinned to the
    // bottom, the common case; null = nothing to restore). Set on hide, consumed by the next refit.
    const restore_scroll_ref = useRef(/** @type {number?} */ (null))
    // Held so the unmount cleanup can tear them all down. Without this, unmounting (closing the
    // tab, switching dock — which remounts under a different parent — or closing the panel) would
    // leak the WebSocket, the xterm instance, and the ResizeObserver: the socket's onmessage
    // closure pins the terminal so nothing is ever GC'd, and a stale socket keeps receiving. The
    // server shell itself is intentionally NOT killed here (that only happens on an explicit tab
    // close, via close_terminal) so reload / dock-switch still reattach.
    const socket_ref = useRef(/** @type {WebSocket?} */ (null))
    const term_ref = useRef(/** @type {any} */ (null))
    const ro_ref = useRef(/** @type {ResizeObserver?} */ (null))
    const paste_cleanup_ref = useRef(/** @type {(() => void)?} */ (null))
    const retry_timer_ref = useRef(/** @type {(() => void)?} */ (null))

    // Recolour in place. The scheme goes through a ref so it stays OUT of the mount effect's deps:
    // that effect owns the websocket and the xterm instance, and re-running it would kill the live
    // shell just to change its colours. The ref also covers the gap where the scheme changes while
    // the dynamic `import()`s are still in flight — construction reads it, not the captured prop.
    const scheme_ref = useRef(scheme)
    useEffect(() => {
        scheme_ref.current = scheme
        if (term_ref.current == null) return
        try {
            term_ref.current.options.theme = terminal_theme_for(scheme)
        } catch {}
    }, [scheme])

    // Fit ONLY when the host is genuinely on-screen at a real size, and debounced so a panel that
    // is animating open settles before we measure. Fitting a hidden tab (display:none → 0px) makes
    // xterm clamp to its minimum 2 columns and ship that to the PTY — which is exactly what leaves a
    // backgrounded terminal reattaching wrapped to a sliver. The guard makes a hide a no-op.
    const refit = useCallback(() => {
        cancelAnimationFrame(refit_timer.current)
        refit_timer.current = requestAnimationFrame(() => {
            const node = node_ref.current
            const fit = fit_ref.current
            if (node == null || fit == null) return
            if (node.offsetParent === null || node.clientWidth < 24 || node.clientHeight < 24) return
            try {
                fit.fit()
            } catch {}
            // fit() is a NO-OP when the geometry is unchanged (FitAddon only acts when the proposed
            // rows/cols differ) — which is exactly the case when returning to a terminal tab, since
            // every tab lives in the same panel. But while this terminal was display:none, xterm's
            // viewport kept syncing against a 0-height element: the scroll-area height was computed
            // from offsetHeight 0, scrollTop writes were clamped to 0, and the browser dropped the
            // element's scroll position outright. A REAL resize repairs all of that (xterm's
            // _afterResize re-syncs the viewport — which is why dragging the panel width "fixed" a
            // broken tab); an unchanged-size reveal repaired nothing. So repair here: put the view
            // back where it was when the tab was hidden, then force the scroll geometry to re-sync.
            // (viewport.syncScrollArea was internal API and is GONE in xterm 6.0 — the viewport was
            // rewritten around VS Code's scrollable element, which tracks scroll state internally
            // instead of trusting the browser element's scrollTop. That internal tracking is exactly
            // what the display:none scroll loss needed, so the repair below may simply be a no-op on
            // 6.0; the optional chain keeps it harmless either way, and scrollToBottom/scrollLines
            // are public API.)
            const term = term_ref.current
            if (term == null) return
            try {
                const lines_from_bottom = restore_scroll_ref.current
                restore_scroll_ref.current = null
                if (lines_from_bottom != null) {
                    const buf = term.buffer.active
                    if (lines_from_bottom <= 0) term.scrollToBottom()
                    else term.scrollLines(Math.max(0, buf.baseY - lines_from_bottom) - buf.viewportY)
                }
                term._core?.viewport?.syncScrollArea?.(true)
                term.refresh(0, term.rows - 1)
            } catch {}
        })
    }, [])

    useEffect(() => {
        if (!visible) {
            // Going hidden (display:none): the browser zeroes the element's scroll position and
            // xterm can't maintain its viewport while unmeasurable. Remember where the user was so
            // the reveal repair in refit() can put them back.
            const term = term_ref.current
            if (term != null) {
                try {
                    restore_scroll_ref.current = term.buffer.active.baseY - term.buffer.active.viewportY
                } catch {}
            }
            return
        }
        // returning to this tab (or first reveal of an already-started one): re-measure once painted,
        // and take the keyboard — showing a terminal is asking to type in it
        if (started.current) {
            refit()
            term_ref.current?.focus()
            return
        }
        if (node_ref.current == null) return
        started.current = true
        ;(async () => {
            const [{ Terminal }, { FitAddon }, config] = await Promise.all([
                // 6.0.0, not 5.5.0: 5.5 predates two upstream fixes — "Fixed CapsLock triggering input
                // twice in MacOS" (#5282) and "Fix duplicate input for some IMEs" (#5024). In WebKit,
                // xterm 5.5's input layer garbles caps/fast typing into TUIs like Claude Code; Chrome
                // never showed it.
                import("https://esm.sh/@xterm/xterm@6.0.0?target=es2020"),
                import("https://esm.sh/@xterm/addon-fit@0.11.0?target=es2020"),
                get_json("./api/v1/config").catch(() => null),
            ])
            const term = new Terminal({
                fontSize: 13,
                fontFamily: "JuliaMono, SFMono-Regular, Menlo, Consolas, monospace",
                cursorBlink: true,
                allowTransparency: true, // the island behind is the background (see terminal_theme_for)
                scrollback: 5000,
                // The SERVER's pty backend decides this, not the browser's OS: on a Windows server the
                // pty is ConPTY, and xterm needs its ConPTY heuristics (reliable wrapped-line detection
                // around ConPTY's full-viewport repaints) or redraw-in-place TUIs — Claude Code, vim,
                // anything Ink-style — leave stale duplicated frames stacked above the live one.
                ...(config?.windows ? { windowsPty: { backend: "conpty" } } : {}),
                theme: terminal_theme_for(scheme_ref.current),
            })
            const fit = new FitAddon()
            term.loadAddon(fit)
            fit_ref.current = fit
            term_ref.current = term
            // If we were unmounted while the dynamic imports were in flight, don't attach to a
            // detached node or open a socket that would never be cleaned up.
            if (node_ref.current == null) {
                try {
                    term.dispose()
                } catch {}
                term_ref.current = null
                return
            }
            term.open(node_ref.current)
            term.focus()

            // Assigned when the websocket opens (below); the paste handler needs it, so it lives out here.
            let socket = null

            // Copy and paste, by each platform's own convention:
            //   macOS            ⌘C / ⌘V
            //   Windows          Ctrl+C with text selected (Ctrl+C alone stays the interrupt), Ctrl+V,
            //                    and Ctrl+Shift+C / Ctrl+Shift+V
            //   Linux and others Ctrl+Shift+C / Ctrl+Shift+V, and Ctrl+C with text selected
            // Paste is never read here. Returning false hands the key back to the browser, whose own
            // `paste` event xterm already handles (bracketed paste included): one path, and no
            // clipboard permission prompt. Without that, Ctrl+V reached the shell as ^V and
            // Ctrl+Shift+V did nothing at all.
            const is_windows = navigator.platform.toUpperCase().includes("WIN")
            term.attachCustomKeyEventHandler((e) => {
                if (e.type !== "keydown") return true
                const key = e.key.toLowerCase()
                const mod = is_mac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey
                if (!mod || e.altKey) return true
                // ⌘← ⌘→ ⌘⌫ on macOS: start of line, end of line, delete to the start
                const line_edit = is_mac && !e.shiftKey ? { arrowleft: "\x01", arrowright: "\x05", backspace: "\x15" }[key] : undefined
                if (line_edit != null) {
                    if (socket?.readyState === WebSocket.OPEN) socket.send("0:" + line_edit)
                    e.preventDefault()
                    return false
                }
                if (key === "c" && (is_mac || e.shiftKey || term.hasSelection())) {
                    if (term.hasSelection()) {
                        copy_text(term.getSelection())
                        // off macOS the same key is the interrupt: once copied, let the next press be one
                        if (!is_mac) term.clearSelection()
                    }
                    e.preventDefault() // Ctrl+Shift+C opens the inspector in Chromium
                    return false
                }
                if (key === "v" && (is_mac || is_windows || e.shiftKey)) return false
                if (is_mac && key === "a") {
                    term.selectAll()
                    e.preventDefault()
                    return false
                }
                if (is_mac && key === "k") {
                    term.clear()
                    e.preventDefault()
                    return false
                }
                return true
            })

            // Right-click: what every terminal offers. (On macOS xterm has already selected the word
            // under the pointer by now, so Copy is ready.) Shift+right-click keeps the browser's own menu.
            const on_context_menu = (/** @type {MouseEvent} */ e) => {
                if (e.shiftKey) return
                e.preventDefault()
                const can_read = typeof navigator.clipboard?.readText === "function"
                open_menu(e.clientX, e.clientY, [
                    { label: "Copy", icon: "i-copy", keys: is_mac ? "⌘C" : "Ctrl+Shift+C", disabled: !term.hasSelection(), run: () => (copy_text(term.getSelection()), term.focus()) },
                    {
                        label: "Paste",
                        icon: "i-paste",
                        keys: is_mac ? "⌘V" : is_windows ? "Ctrl+V" : "Ctrl+Shift+V",
                        disabled: !can_read,
                        run: () =>
                            navigator.clipboard
                                .readText()
                                .then((text) => text && term.paste(text))
                                .catch(() => {})
                                .finally(() => term.focus()),
                    },
                    "-",
                    { label: "Select all", keys: is_mac ? "⌘A" : "", run: () => (term.selectAll(), term.focus()) },
                    { label: "Clear", keys: is_mac ? "⌘K" : "", run: () => (term.clear(), term.focus()) },
                ])
            }
            node_ref.current.addEventListener("contextmenu", on_context_menu)

            // Images cannot go through xterm's text-only paste. Intercept ONLY a native paste carrying
            // an image; ordinary text is left untouched for xterm to process exactly once. Using the
            // ClipboardEvent payload also works without navigator.clipboard permissions and preserves
            // the browser's native user-gesture semantics.
            const handle_image_paste = async (/** @type {ClipboardEvent} */ e) => {
                const image_item = Array.from(e.clipboardData?.items ?? []).find((item) => item.type?.startsWith("image/"))
                const image_file = image_item?.getAsFile() ?? Array.from(e.clipboardData?.files ?? []).find((file) => file.type?.startsWith("image/"))
                if (image_file == null) return
                e.preventDefault()
                e.stopPropagation()
                try {
                    const bytes = new Uint8Array(await image_file.arrayBuffer())
                    let bin = ""
                    for (let i = 0; i < bytes.length; i += 0x8000) {
                        bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
                    }
                    const ext = image_file.type.split("/")[1] || "png"
                    if (socket?.readyState === WebSocket.OPEN) socket.send(`2:${ext}:${btoa(bin)}`)
                } catch {}
            }
            // Capture before xterm's textarea handler: image clipboards can also expose a text
            // representation, which xterm must not paste in addition to the uploaded image path.
            term.element?.addEventListener("paste", handle_image_paste, { capture: true })
            paste_cleanup_ref.current = () => term.element?.removeEventListener("paste", handle_image_paste, { capture: true })

            // Measure after the webfont is ready, so the cell size (hence the column count) is correct.
            try {
                await document.fonts?.ready
            } catch {}
            // One immediate fit (same visibility guards as refit, but not debounced): the connect URL
            // below carries the terminal's true geometry so a NEW shell is BORN at the right size.
            // Spawning at the 24×80 default and resizing on attach makes ConPTY repaint the viewport,
            // which duplicates the banner/first frame on a Windows server.
            if (node_ref.current != null && node_ref.current.offsetParent !== null && node_ref.current.clientWidth >= 24 && node_ref.current.clientHeight >= 24) {
                try {
                    fit.fit()
                } catch {}
            }
            refit()

            const proto = window.location.protocol === "https:" ? "wss" : "ws"
            // Measure the panel and tell the pty (the server ignores a no-change resize). Called once
            // the attach replay has fully rendered — resizing earlier would make the pty repaint into
            // a grid the replay bytes weren't recorded for.
            const sync_size_to_panel = () => {
                const node = node_ref.current
                if (node != null && node.offsetParent !== null && node.clientWidth >= 24 && node.clientHeight >= 24) {
                    try {
                        fit.fit()
                    } catch {}
                }
                if (socket?.readyState === WebSocket.OPEN) socket.send(`1:${term.rows},${term.cols}`)
            }
            let attempts = 0
            let retry_timer = null
            const connect = () => {
                if (node_ref.current == null) return // unmounted while waiting to retry
                // Open the shell in the workspace the client is showing (local or ssh-remote), not wherever
                // the server happened to launch. The server falls back to its workspace_folder if omitted.
                const cwd_param = cwd ? `&cwd=${encodeURIComponent(cwd)}` : ""
                const size_param = `&rows=${term.rows}&cols=${term.cols}`
                // A notebook-environment terminal (issue #29): the server types `julia --project=<env>`
                // into the shell it spawns for this tid — only on spawn, so reattaching never repeats it.
                const env_param = notebook_env ? `&notebook_env=${encodeURIComponent(notebook_env)}` : ""
                // Relative to this page: under a hub's /w/<id>/ the terminal is the hub's, at that prefix.
                const terminal_url = new URL(`./terminal?tid=${tid}${cwd_param}${size_param}${env_param}`, window.location.href)
                terminal_url.protocol = `${proto}:`
                const sock = new WebSocket(terminal_url.href)
                socket = sock
                socket_ref.current = sock
                sock.binaryType = "arraybuffer"
                let exited = false
                let failed = false // no shell could be started: what the server said stays on screen
                let first_frame = true
                sock.onmessage = (e) => {
                    if (typeof e.data !== "string") {
                        term.write(new Uint8Array(e.data))
                        return
                    }
                    // Text frames are the attach protocol (all shell output is binary). First frame: the
                    // pty's current geometry — adopt it BEFORE the replay renders, since the replayed bytes
                    // (absolute cursor positioning included) only make sense in that exact grid. Second
                    // frame: replay complete — now re-fit to the panel; the resulting pty resize makes the
                    // live app repaint itself cleanly at the real size.
                    let meta = null
                    try {
                        meta = JSON.parse(e.data)
                    } catch {}
                    if (meta == null) return
                    if (meta.exited || meta.failed) {
                        exited = meta.exited === true
                        failed = meta.failed === true
                        if (exited) {
                            socket_ref.current = null // its close is expected: nothing to re-attach to
                            on_exit_ref.current?.(tid)
                        }
                        return
                    }
                    if (first_frame) {
                        first_frame = false
                        // a re-made connection replays the scrollback: start from a clean screen, or
                        // everything already shown would be there twice
                        if (attempts > 0) term.reset()
                        attempts = 0
                        set_link("ok")
                    }
                    if (Number.isFinite(meta.rows) && Number.isFinite(meta.cols) && (term.rows !== meta.rows || term.cols !== meta.cols)) {
                        try {
                            term.resize(meta.cols, meta.rows)
                        } catch {}
                    }
                    if (meta.replayed) sync_size_to_panel()
                }
                sock.onopen = () => refit()
                sock.onclose = () => {
                    if (socket_ref.current !== sock) return // replaced, or torn down on purpose
                    // The shell ended (`exit`, Ctrl-D): its tab goes with it, as in any terminal.
                    if (exited) return on_exit_ref.current?.(tid)
                    if (failed) return
                    // Otherwise the connection dropped and the shell is still there: re-attach to it.
                    attempts += 1
                    if (attempts > 8) return set_link("failed")
                    set_link("lost")
                    retry_timer = setTimeout(connect, Math.min(500 * 2 ** (attempts - 1), 8000))
                }
            }
            reconnect_ref.current = () => {
                clearTimeout(retry_timer)
                attempts = 1
                set_link("lost")
                connect()
            }
            retry_timer_ref.current = () => clearTimeout(retry_timer)
            connect()
            term.onData((d) => socket?.readyState === WebSocket.OPEN && socket.send("0:" + d))
            let told = { rows: term.rows, cols: term.cols }
            let width_timer = null
            const tell_size = () => {
                told = { rows: term.rows, cols: term.cols }
                if (socket?.readyState === WebSocket.OPEN) socket.send(`1:${term.rows},${term.cols}`)
            }
            term.onResize(({ rows, cols }) => {
                clearTimeout(width_timer)
                if (cols === told.cols) tell_size()
                else width_timer = setTimeout(tell_size, 90)
            })
            const ro = new ResizeObserver(() => refit())
            ro.observe(node_ref.current)
            ro_ref.current = ro
        })()
    }, [visible, refit])

    // Tear everything down on unmount — closing the tab, switching dock (which remounts under a
    // different parent), or closing the panel. Runs exactly once (empty deps), so a plain tab
    // switch (visible→false) does NOT dispose anything; only a real unmount does. Detaching the
    // socket leaves the server shell running for reattach; an explicit tab close reaps it
    // separately (close_terminal → POST /api/v1/terminal/close).
    useEffect(() => {
        return () => {
            cancelAnimationFrame(refit_timer.current)
            retry_timer_ref.current?.()
            paste_cleanup_ref.current?.()
            paste_cleanup_ref.current = null
            try {
                ro_ref.current?.disconnect()
            } catch {}
            ro_ref.current = null
            const sock = socket_ref.current
            if (sock != null) {
                // Silence the handlers first: onclose would otherwise write "[disconnected]" into a
                // terminal we're about to dispose, and onmessage could fire mid-teardown.
                sock.onclose = null
                sock.onmessage = null
                sock.onopen = null
                sock.onerror = null
                try {
                    sock.close()
                } catch {}
            }
            socket_ref.current = null
            try {
                term_ref.current?.dispose()
            } catch {}
            term_ref.current = null
            fit_ref.current = null
        }
    }, [])

    return html`<div class="terminal-host" ref=${node_ref}></div>
        ${link === "ok"
            ? null
            : html`<div class="terminal-note" role="status">
                  ${link === "lost"
                      ? html`<span class="spinner"></span><span>Connection lost. The shell is still running; reconnecting…</span>`
                      : html`<span>Could not reconnect. The shell may still be running.</span
                            ><button class="text-button" onClick=${() => reconnect_ref.current?.()}>Try again</button>`}
              </div>`}`
}


// dirty state per open file, shared so close_tab can warn
const file_dirty = new Map()

/** A text-file editor pane built on Pluto's own bundled CodeMirror (imports/CodemirrorPlutoSetup.js),
 *  with syntax colors wired to Pluto's --cm-color-* theme variables. Save with the button or Ctrl/Cmd+S. */
const FileEditorPane = ({ path, label, visible, on_dirty }) => {
    const node_ref = useRef(null)
    const view_ref = useRef(null)
    const started = useRef(false)
    const [dirty, set_dirty] = useState(false)
    const [status, set_status] = useState("Loading…")
    const [failed, set_failed] = useState(false)

    const save = useCallback(async () => {
        const view = view_ref.current
        if (view == null) return
        try {
            await get_json(`./api/v1/file/save?path=${encodeURIComponent(path)}`, { method: "POST", body: view.state.doc.toString() })
            file_dirty.set(path, false)
            set_dirty(false)
            on_dirty?.(path, false)
            set_failed(false)
            set_status("Saved")
            setTimeout(() => set_status(""), 1500)
        } catch (e) {
            set_failed(true)
            set_status(`Not saved: ${e?.message ?? e}`)
        }
    }, [path])

    useEffect(() => {
        if (!visible || started.current || node_ref.current == null) return
        started.current = true
        ;(async () => {
            try {
                const cm = await import("./imports/CodemirrorPlutoSetup.js")
                const content = await get_text(`./api/v1/file?path=${encodeURIComponent(path)}`)
                const v = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim()
                const pluto_colors = cm.HighlightStyle.define(
                    [
                        { tag: cm.tags.keyword, color: "var(--cm-color-keyword)" },
                        { tag: cm.tags.comment, color: "var(--cm-color-comment)", fontStyle: "italic" },
                        { tag: cm.tags.string, color: "var(--cm-color-string)" },
                        { tag: cm.tags.number, color: "var(--cm-color-literal)" },
                        { tag: cm.tags.literal, color: "var(--cm-color-literal)" },
                        { tag: cm.tags.macroName, color: "var(--cm-color-macro)" },
                        { tag: cm.tags.variableName, color: "var(--cm-color-variable)" },
                        { tag: cm.tags.heading, color: "var(--cm-color-md)", fontWeight: "700" },
                        { tag: cm.tags.link, color: "var(--cm-color-link)" },
                    ],
                    { all: { color: "var(--cm-color-editor-text)" } }
                )
                const ext = path.split(".").pop()?.toLowerCase()
                const language =
                    ext === "jl"
                        ? [cm.julia()]
                        : ext === "md"
                          ? [cm.markdown()]
                          : ext === "toml"
                            ? (() => {
                                  try {
                                      return [cm.StreamLanguage.define(cm.toml)]
                                  } catch {
                                      return []
                                  }
                              })()
                            : ext === "css"
                              ? [cm.css()]
                              : ext === "js" || ext === "mjs"
                                ? [cm.javascript()]
                                : ext === "html"
                                  ? [cm.html()]
                                  : ext === "py"
                                    ? [cm.python()]
                                    : []
                const view = new cm.EditorView({
                    state: cm.EditorState.create({
                        doc: content,
                        extensions: [
                            cm.lineNumbers(),
                            cm.history(),
                            cm.drawSelection(),
                            cm.indentOnInput(),
                            cm.bracketMatching(),
                            cm.highlightActiveLine(),
                            cm.syntaxHighlighting(pluto_colors),
                            ...language,
                            cm.keymap.of([
                                { key: "Mod-s", run: () => (save(), true) },
                                ...cm.defaultKeymap,
                                ...cm.historyKeymap,
                            ]),
                            cm.EditorView.updateListener.of((update) => {
                                if (update.docChanged && !file_dirty.get(path)) {
                                    file_dirty.set(path, true)
                                    set_dirty(true)
                                    on_dirty?.(path, true)
                                }
                            }),
                            cm.EditorView.theme({}, { dark: prefers_dark() }),
                        ],
                    }),
                    parent: node_ref.current,
                })
                // Unmounted while the dynamic import / file read was in flight: don't attach a view
                // to a detached node (it would leak with no way to destroy it).
                if (node_ref.current == null) {
                    try {
                        view.destroy()
                    } catch {}
                    return
                }
                view_ref.current = view
                set_status("")
            } catch (e) {
                set_failed(true)
                set_status(`Could not be opened: ${e?.message ?? e}`)
            }
        })()
    }, [visible])

    // Destroy the CodeMirror EditorView on unmount (closing the file tab) — otherwise the view, its
    // DOM, keymaps, and the update listener leak for every file opened and closed.
    useEffect(() => {
        return () => {
            try {
                view_ref.current?.destroy()
            } catch {}
            view_ref.current = null
        }
    }, [])

    return html`<div class="file-pane">
        <div class="file-toolbar">
            <span class="file-path" title=${path}>${label ?? path}</span>
            <span class="file-status ${failed ? "error" : ""}" role="status">${status !== "" ? status : dirty ? "Unsaved changes" : ""}</span>
            <button class="text-button file-save ${dirty ? "primary" : ""}" disabled=${!dirty} onClick=${save} title=${`Save (${is_mac ? "⌘S" : "Ctrl+S"})`}>Save</button>
        </div>
        <div class="file-editor" ref=${node_ref}></div>
    </div>`
}

const SIDEBAR_WIDTH = 260
const TERMINAL_HEIGHT = 280
const TERMINAL_WIDTH = 460

/** Drag a pane's edge. `measure(event)` turns a pointer position into the new size; it is applied
 *  at most once a frame, however fast the pointer reports. The handle captures the pointer, so the
 *  drag carries on over the notebook frames and the terminal, and ends wherever the button is let go. */
const drag_resize = (e, axis, measure, apply) => {
    if (e.button !== 0) return
    e.preventDefault()
    const handle = e.currentTarget
    try {
        handle.setPointerCapture(e.pointerId)
    } catch {}
    const body_class = axis === "x" ? "resizing" : "resizing-v"
    document.body.classList.add(body_class)
    handle.classList.add("dragging")
    let frame = 0
    let latest = null
    const flush = () => {
        frame = 0
        if (latest != null) apply(measure(latest))
    }
    const move = (ev) => {
        latest = ev
        if (frame === 0) frame = requestAnimationFrame(flush)
    }
    const up = () => {
        cancelAnimationFrame(frame)
        flush()
        document.body.classList.remove(body_class)
        handle.classList.remove("dragging")
        handle.removeEventListener("pointermove", move)
        handle.removeEventListener("pointerup", up)
        handle.removeEventListener("pointercancel", up)
    }
    handle.addEventListener("pointermove", move)
    handle.addEventListener("pointerup", up)
    handle.addEventListener("pointercancel", up)
}
const clamp = (v, lo, hi) => Math.max(lo, Math.min(Math.max(lo, hi), v))

const Land = () => {
    const [workspace, set_workspace] = useState(/** @type {{root: String, entries: Array, git?: {branch: String, detached: Boolean}?}?} */ (null))
    // The sidebar tree, one folder at a time: `listings` maps a folder path to its entries (only
    // folders that have been opened are in here), `expanded` is which ones are currently unfolded.
    // The poll below refreshes exactly the expanded set, so an unopened folder is never read.
    const [listings, set_listings] = useState(/** @type {Record<String, Array>} */ ({}))
    const [expanded, set_expanded] = useState(/** @type {Set<String>} */ (new Set()))
    // `refresh` runs from an interval set up once, so it can't close over `expanded` — it reads the
    // live set through this mirror instead.
    const expanded_ref = useRef(expanded)
    useEffect(() => {
        expanded_ref.current = expanded
    }, [expanded])
    const [no_workspace, set_no_workspace] = useState(false)
    const [running, set_running] = useState(/** @type {Array<{notebook_id: String, path: String}>} */ ([]))
    const [tabs, set_tabs] = useState(/** @type {Array<{id: String, path: String, kind?: String}>} */ ([]))
    const [active, set_active] = useState(/** @type {String?} */ (null))
    const [error, set_error] = useState(/** @type {String?} */ (null))
    // what the background poll could not do; it clears itself when the poll works again
    const [poll_error, set_poll_error] = useState(/** @type {String?} */ (null))
    const [sidebar_width, set_sidebar_width] = useState(() => Number(store.get("spacestation sidebar width")) || SIDEBAR_WIDTH)
    const [sidebar_hidden, set_sidebar_hidden] = useState(() => store.get("spacestation sidebar hidden") === "true")
    const [terminal_open, set_terminal_open] = useState(() => store.get("spacestation terminal open") === "true")
    const [terminal_height, set_terminal_height] = useState(() => Number(store.get("spacestation terminal height")) || TERMINAL_HEIGHT)
    const [terminal_width, set_terminal_width] = useState(() => Number(store.get("spacestation terminal width")) || TERMINAL_WIDTH)
    const [terminal_dock, set_terminal_dock] = useState(() => {
        const saved = store.get("spacestation terminal dock")
        return saved === "right" || saved === "tab" ? saved : "bottom"
    })
    // The terminal's colours are its own preference, not the page theme's: plenty of people want a
    // light UI with a dark terminal. Defaults to dark, which is what the terminal has always been.
    const [terminal_scheme, set_terminal_scheme] = useState(() => (store.get("spacestation terminal scheme") === "light" ? "light" : "dark"))
    const terminal_ever_opened = useRef(false)
    if (terminal_open) terminal_ever_opened.current = true
    const [show_opener, set_show_opener] = useState(false)
    const [path_copied, set_path_copied] = useState(false)
    // which file tabs have unsaved changes (the panes report it; the strip marks them)
    const [dirty_tabs, set_dirty_tabs] = useState(/** @type {Set<String>} */ (new Set()))
    const set_tab_dirty = useCallback((path, dirty) => {
        set_dirty_tabs((prev) => {
            if (prev.has(path) === dirty) return prev
            const next = new Set(prev)
            dirty ? next.add(path) : next.delete(path)
            return next
        })
    }, [])

    // ---- Tab switching from the keyboard (issue #29) ----
    // The conventions every browser, VS Code and iTerm share: ⌘⇧[ / ⌘⇧] and ⌘⌥← / ⌘⌥→ on macOS,
    // Ctrl+PageUp / Ctrl+PageDown and Ctrl+Tab / Ctrl+Shift+Tab everywhere, ⌘/Ctrl+1…8 for the
    // Nth tab and ⌘/Ctrl+9 for the last. They cycle the strip as shown: notebooks and files in
    // order, then the terminal when it is docked as a tab. The handler runs in the CAPTURE phase on
    // the hub window and, because the notebook frames are same-origin documents that never bubble
    // keys up here, on each frame's window as it loads (`attach_tab_keys`) — so the chord works with
    // a cell, a file, the sidebar or the terminal focused. None of it collides with Pluto's own
    // bindings (cell folding is ⌘⌥[ on macOS and Ctrl+Shift+[ elsewhere) or with xterm.
    const toggle_terminal_ref = useRef(/** @type {(() => void)?} */ (null))
    const tab_keys_ref = useRef({ tabs: /** @type {Array<{id: String}>} */ ([]), active: /** @type {String?} */ (null), terminal_tab: false })
    const handle_tab_keys = useCallback((/** @type {KeyboardEvent} */ e) => {
        if (e.defaultPrevented || e.isComposing) return
        // Ctrl+` shows and hides the terminal, as in VS Code — on macOS too, where it is also Ctrl.
        if (e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && e.code === "Backquote") {
            e.preventDefault()
            e.stopPropagation()
            toggle_terminal_ref.current?.()
            return
        }
        const mac = is_mac
        const mod = mac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey
        let move = 0
        let jump = -1
        if (e.ctrlKey && !e.metaKey && !e.altKey && e.key === "Tab") move = e.shiftKey ? -1 : 1
        else if (e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && (e.key === "PageUp" || e.key === "PageDown")) move = e.key === "PageUp" ? -1 : 1
        else if (mac && e.metaKey && e.shiftKey && !e.altKey && !e.ctrlKey && (e.code === "BracketLeft" || e.code === "BracketRight")) move = e.code === "BracketLeft" ? -1 : 1
        else if (mac && e.metaKey && e.altKey && !e.shiftKey && !e.ctrlKey && (e.key === "ArrowLeft" || e.key === "ArrowRight")) move = e.key === "ArrowLeft" ? -1 : 1
        else if (mod && !e.shiftKey && !e.altKey && /^Digit[1-9]$/.test(e.code)) jump = Number(e.code.slice(5))
        if (move === 0 && jump < 0) return
        const { tabs, active, terminal_tab } = tab_keys_ref.current
        const order = [...tabs.map((t) => t.id), ...(terminal_tab ? ["__terminal__"] : [])]
        if (order.length === 0) return
        e.preventDefault()
        e.stopPropagation()
        let next
        if (jump > 0) next = order[jump === 9 ? order.length - 1 : Math.min(jump, order.length) - 1]
        else {
            const i = order.indexOf(active ?? "")
            next = order[(i + move + order.length) % order.length]
        }
        if (next != null) set_active(next)
    }, [])
    useEffect(() => {
        window.addEventListener("keydown", handle_tab_keys, true)
        return () => window.removeEventListener("keydown", handle_tab_keys, true)
    }, [handle_tab_keys])
    /** Hook a same-origin frame's window (a notebook tab) into the tab-switching keys. */
    const attach_tab_keys = useCallback(
        (/** @type {Window?} */ frame_window) => {
            try {
                frame_window?.addEventListener("keydown", handle_tab_keys, true)
            } catch {
                // cross-origin (should not happen: ./edit is ours) — the chord just won't work from that frame
            }
        },
        [handle_tab_keys]
    )

    // ---- "Open the notebook's package environment in a terminal" (issue #29) ----
    // Answers "I can never remember the invocation": the server composes the exact command for
    // this Julia and this shell, and types it into a fresh terminal tab, so the line is there to
    // read, edit and learn. Availability is looked up when the menu opens, for the active notebook.
    tab_keys_ref.current = { tabs, active, terminal_tab: terminal_open && terminal_dock === "tab" }

    const active_notebook_tab = active != null && active !== "__terminal__" && tabs.find((t) => t.id === active && t.kind !== "file")

    useEffect(() => {
        if (active == null && tabs.length > 0) set_active(tabs[tabs.length - 1].id)
        else if (active === "__terminal__" && !(terminal_open && terminal_dock === "tab")) set_active(tabs.length > 0 ? tabs[tabs.length - 1].id : null)
    }, [active, tabs, terminal_open, terminal_dock])

    const auto_tabbed = useRef(false)
    // set once the saved tabs of this workspace are on screen: only then is what is on screen worth saving
    const tabs_restored_for = useRef(/** @type {String?} */ (null))
    useEffect(() => {
        const root = workspace?.root
        if (root != null && tabs_restored_for.current === root) save_tabs(root, tabs, active, running.map((nb) => nb.notebook_id))
    }, [tabs, active, running, workspace?.root])
    // This server may be reached over an SSH tunnel (when it's a remote workspace). If so, its child
    // workspace ports aren't forwarded to the browser, so workspaces open IN-PLACE rather than in new tabs.
    const [tunneled, set_tunneled] = useState(false)
    // This page is a workspace on a hub, under /w/<id>/ (src/webserver/Proxy.jl): the notebooks live
    // in a child server the hub relays to; the hub itself never freezes with them. Known
    // synchronously from the URL, so nothing waits on the config fetch to behave right.
    const [hub, set_hub] = useState(/^\/w\/[^/]+\//.test(window.location.pathname))
    // Nothing is answering on our own origin. For an SSH workspace this is the ordinary consequence
    // of the laptop having been shut — see the recovery loop further down.
    const [offline, set_offline] = useState(false)
    // Which extensions make a new file a notebook. The server owns the list (`pluto_file_extensions`),
    // so the create prompts below agree with the `type` the sidebar already gets decided server-side.
    // The bundled list is the fallback, so a failed or older-server config request still recognises
    // every extension this frontend knows about.
    const [notebook_extensions, set_notebook_extensions] = useState(/** @type {Array<String>} */ (pluto_file_extensions))
    useEffect(() => {
        get_json("./api/v1/config")
            .then((c) => {
                set_tunneled(!!(c && c.tunneled))
                set_hub(!!(c && c.hub && c.wid != null))
                if (Array.isArray(c?.notebook_extensions) && c.notebook_extensions.length > 0) set_notebook_extensions(c.notebook_extensions)
            })
            .catch(() => {})
    }, [])

    /** Would a file with this name be opened as a notebook? Mirrors `_is_pluto_notebook_file`'s
     *  extension half — the header half only applies to files that already exist. */
    const has_notebook_extension = useCallback((name) => has_pluto_file_extension(name, notebook_extensions), [notebook_extensions])

    // Tab title tells the homebase apart from workspaces in the browser's tab strip: the launcher reads
    // "SpaceStation (launcher)"; a workspace reads "SpaceStation — <folder>".
    useEffect(() => {
        document.title = no_workspace ? "SpaceStation (launcher)" : workspace?.root ? `SpaceStation — ${basename(workspace.root)}` : "SpaceStation"
    }, [no_workspace, workspace])

    // The logo: the launcher, shown over this workspace, with a way back. (It used to ask the
    // browser to raise the tab that opened this one, which browsers do not allow: the button did
    // nothing.) The workspace keeps running underneath.
    const go_home = useCallback(() => {
        if (!hub && tunneled) {
            fetch("./api/v1/workspace/close", { method: "POST" }).finally(() => window.location.reload())
            return
        }
        set_show_opener(true)
    }, [tunneled, hub])

    // Terminals are tabs INSIDE the terminal panel (like VS Code). Each is a persistent shell
    // keyed by tid; the list + active terminal are restored on reload. `terminal_seq` numbers them.
    const [terminals, set_terminals] = useState(/** @type {Array<{tid: String, label: String, notebook_env?: String}>} */ ([]))
    const [active_terminal, set_active_terminal] = useState(/** @type {String?} */ (null))
    const terminals_workspace = useRef(/** @type {String?} */ (null))
    const [terminals_loaded_for, set_terminals_loaded_for] = useState(/** @type {String?} */ (null))
    const terminal_seq = useRef(/** @type {Number} */ (-1))

    // Terminal tabs belong to a workspace, not the browser origin. The old global localStorage
    // list made Terminal 1/2/3 from every folder accumulate together and reconnect in the wrong
    // workspace. Load the independent list whenever the server's active workspace changes.
    useEffect(() => {
        const root = workspace?.root ?? null
        if (root == null || terminals_workspace.current === root) return
        const restored = restore_terminals(root)
        terminals_workspace.current = root
        set_terminals(restored)
        set_active_terminal(restored.length ? restored[restored.length - 1].tid : null)
        const nums = restored.map((t) => parseInt(String(t.label ?? "").replace(/[^0-9]/g, ""), 10)).filter((x) => !isNaN(x))
        terminal_seq.current = nums.length ? Math.max(...nums) : 0
        // The state updates above land on the next render. Until then, `terminals` still belongs to
        // the previous render/workspace and must neither be persisted nor treated as an empty list
        // that needs a brand-new terminal.
        set_terminals_loaded_for(root)
    }, [workspace?.root])

    useEffect(() => {
        store.set("spacestation sidebar width", String(sidebar_width))
        store.set("spacestation sidebar hidden", String(sidebar_hidden))
        store.set("spacestation terminal open", String(terminal_open))
        store.set("spacestation terminal height", String(terminal_height))
        store.set("spacestation terminal scheme", terminal_scheme)
        store.set("spacestation terminal width", String(terminal_width))
        store.set("spacestation terminal dock", terminal_dock)
    }, [sidebar_width, sidebar_hidden, terminal_open, terminal_height, terminal_width, terminal_dock, terminal_scheme])

    useEffect(() => {
        const root = workspace?.root ?? null
        if (root != null && terminals_workspace.current === root && terminals_loaded_for === root) save_terminals(root, terminals)
    }, [terminals, terminals_loaded_for, workspace?.root])

    // Warn before a browser close/reload discards unsaved FILE edits. File buffers are client-only
    // until Save hits ./api/v1/file/save; notebooks persist server-side, and terminals reattach on
    // reload, so this covers the one thing that's actually lost. Only prompts when something is dirty.
    useEffect(() => {
        const on_beforeunload = (e) => {
            let any_dirty = false
            for (const v of file_dirty.values())
                if (v) {
                    any_dirty = true
                    break
                }
            if (any_dirty) {
                e.preventDefault()
                e.returnValue = "" // some browsers require this to show the native prompt
            }
        }
        window.addEventListener("beforeunload", on_beforeunload)
        return () => window.removeEventListener("beforeunload", on_beforeunload)
    }, [])

    const split_ref = useRef(/** @type {HTMLElement?} */ (null))
    const start_terminal_resize = useCallback(
        (e) => {
            const split = split_ref.current
            if (split == null) return
            const box = split.getBoundingClientRect()
            if (terminal_dock === "bottom") drag_resize(e, "y", (ev) => clamp(box.bottom - ev.clientY, 100, box.height - 140), set_terminal_height)
            else drag_resize(e, "x", (ev) => clamp(box.right - ev.clientX, 240, box.width - 320), set_terminal_width)
        },
        [terminal_dock]
    )
    const reset_terminal_size = useCallback(() => (terminal_dock === "bottom" ? set_terminal_height(TERMINAL_HEIGHT) : set_terminal_width(TERMINAL_WIDTH)), [terminal_dock])

    const add_tab = useCallback((id, path, kind = "notebook") => {
        set_tabs((tabs) => (tabs.some((t) => t.id === id) ? tabs : [...tabs, { id, path, kind }]))
        set_active(id)
    }, [])

    const open_file = useCallback(
        (path) => {
            add_tab(`file:${path}`, path, "file")
        },
        [add_tab]
    )

    /** Open a new terminal tab. `notebook_env` (a notebook id) makes it a notebook-environment
     *  terminal: the shell starts by activating that notebook's package environment (issue #29). */
    const new_terminal = useCallback(
        (/** @type {{label?: String, notebook_env?: String, cwd?: String}} */ opts = {}) => {
            if (workspace?.root == null || terminals_workspace.current !== workspace.root) return
            terminal_seq.current += 1
            const tid = "term-" + Math.random().toString(36).slice(2, 12)
            const entry = { tid, label: opts.label ?? `Terminal ${terminal_seq.current}` }
            if (opts.notebook_env) entry.notebook_env = opts.notebook_env
            if (opts.cwd) entry.cwd = opts.cwd
            if (terminal_dock === "tab") set_active("__terminal__")
            set_terminals((ts) => [...ts, entry])
            set_active_terminal(tid)
            set_terminal_open(true)
        },
        [workspace?.root, terminal_dock]
    )

    const close_terminal = useCallback((tid) => {
        // Reap the server-side shell (this is a real close, not a detach) — best-effort; the tab is
        // going away regardless. Persistent shells only survive detaches (hide / dock / reload).
        fetch(`./api/v1/terminal/close?tid=${encodeURIComponent(tid)}`, { method: "POST" }).catch(() => {})
        set_terminals((ts) => {
            const at = ts.findIndex((t) => t.tid === tid)
            const remaining = ts.filter((t) => t.tid !== tid)
            set_active_terminal((a) => (a === tid ? (remaining[Math.min(at, remaining.length - 1)]?.tid ?? null) : a))
            // closing the last one closes the panel: it used to start another in its place
            if (remaining.length === 0) {
                set_terminal_open(false)
                set_active((a) => (a === "__terminal__" ? null : a))
            }
            return remaining
        })
    }, [])

    // Opening the terminal panel with no terminals yet spins up the first one, but only AFTER the
    // saved list for this workspace has reached React state. On a hard refresh `terminal_open` is
    // restored synchronously while the terminal list is loaded in an effect; without this gate the
    // pre-load empty state creates a duplicate beside the restored terminal.
    useEffect(() => {
        if (
            terminal_open &&
            workspace?.root != null &&
            terminals_workspace.current === workspace.root &&
            terminals_loaded_for === workspace.root &&
            terminals.length === 0
        )
            new_terminal()
    }, [terminal_open, terminals.length, terminals_loaded_for, workspace?.root])


    // Read one folder and drop it into `listings`. A folder that can't be read (deleted under us,
    // permissions) gets a marker row rather than an endless "reading…" — but only if it's still
    // expanded by the time the answer lands, so a stale reply can't resurrect a folded folder.
    const load_listing = useCallback(async (path) => {
        try {
            const { entries } = await get_json(`./api/v1/workspace/listing?path=${encodeURIComponent(path)}`)
            set_listings((prev) => ({ ...prev, [path]: entries }))
        } catch (e) {
            if (!expanded_ref.current.has(path)) return
            set_listings((prev) => ({ ...prev, [path]: [{ name: "…", path: `${path}/…`, type: "unreadable", detail: String(e) }] }))
        }
    }, [])

    const toggle_dir = useCallback(
        (path) => {
            const opening = !expanded_ref.current.has(path)
            set_expanded((prev) => {
                const next = new Set(prev)
                opening ? next.add(path) : next.delete(path)
                expanded_ref.current = next // the fetch below and a same-tick poll both read this
                return next
            })
            // A folder opened before is redrawn from cache immediately and re-read in the background,
            // so expanding something you've already seen never flashes a placeholder.
            if (opening) load_listing(path)
        },
        [load_listing]
    )

    // The relay's answers for this workspace's child: a 504 `workspace_busy` (no answer in time) or a
    // 503 `workspace_down`. The page stays usable — the hub answered — and says which it is.
    // the filesystem that holds the workspace's files is not answering (the hub says 504 filesystem_busy):
    // the last listing stays on screen, and everything that is not a file listing keeps working
    const [files_status, set_files_status] = useState(/** @type {{since: number, detail: String}?} */ (null))
    const [workspace_status, set_workspace_status] = useState(/** @type {{kind: "busy" | "down", since: number, detail: String}?} */ (null))
    const refreshing = useRef(false)
    const unreachable = useRef(0) // polls in a row that nothing answered
    const refresh = useCallback(async () => {
        // One poll in flight at a time, with a deadline: against a stalled child every poll would
        // otherwise pile up on the one origin, and the browser's per-origin connection limit would
        // then block the sidebar and the terminal handshake behind them.
        if (refreshing.current) return
        refreshing.current = true
        const ctrl = new AbortController()
        const deadline = setTimeout(() => ctrl.abort(), 15_000)
        const signal = ctrl.signal
        let root_now = null
        try {
            const ws_response = await fetch("./api/v1/workspace", { signal })
            unreachable.current = 0
            if (ws_response.status === 404) {
                set_files_status(null)
                set_no_workspace(true)
                set_workspace(null)
                set_poll_error(null)
                return // the launcher has no notebooks to list (a hub's root list would poll every workspace's child)
            } else if (ws_response.status === 504) {
                const info = await ws_response.json().catch(() => ({}))
                set_files_status((prev) => ({ since: prev?.since ?? Date.now(), detail: String(info.detail ?? "") }))
                // no return and no throw: what is on screen stays, and the notebooks are asked about below
            } else if (ws_response.ok) {
                set_files_status(null)
                set_no_workspace(false)
                const ws_now = await ws_response.json()
                root_now = typeof ws_now?.root === "string" ? ws_now.root : null
                set_workspace(ws_now)
                // Re-read the open folders — and only those. This is the whole point of the lazy
                // tree: poll cost tracks what is on screen, not the size of the workspace.
                const open_dirs = [...expanded_ref.current]
                const results = await Promise.all(
                    open_dirs.map((p) =>
                        get_json(`./api/v1/workspace/listing?path=${encodeURIComponent(p)}`)
                            .then((r) => [p, r.entries])
                            .catch(() => [p, null]) // transient failure: keep showing what we had
                    )
                )
                set_listings((prev) => {
                    const next = { ...prev }
                    for (const [p, entries] of results) if (entries != null) next[p] = entries
                    return next
                })
            } else {
                // Any other status (e.g. 500) — don't silently leave stale workspace state on screen.
                throw new Error(`workspace request failed: ${ws_response.status}`)
            }
            const nb_response = await fetch("./api/v1/notebooks", { signal })
            if (nb_response.status === 503 || nb_response.status === 504) {
                const info = await nb_response.json().catch(() => ({}))
                set_workspace_status((prev) => ({ kind: info.workspace_down ? "down" : "busy", since: prev?.since ?? Date.now(), detail: String(info.detail ?? "") }))
                set_poll_error(null)
                return
            }
            if (!nb_response.ok) throw new Error(`notebooks request failed: ${nb_response.status}`)
            const running_now = await nb_response.json()
            set_workspace_status(null)
            set_running(running_now)
            // On first load: the tabs that were open here last time — files, and the notebooks among
            // them that are still running — with the same one in front. A workspace seen for the first
            // time shows its running notebooks as tabs (e.g. one passed via Pluto.run(notebook=…)).
            if (!auto_tabbed.current) {
                auto_tabbed.current = true
                const saved = root_now == null ? null : restore_tabs(root_now)
                if (saved == null) running_now.forEach((nb) => add_tab(nb.notebook_id, nb.path))
                else {
                    const still_running = new Set(running_now.map((nb) => nb.notebook_id))
                    const known = new Set(saved.known)
                    const restored = [
                        ...saved.tabs.filter((t) => t.kind === "file" || still_running.has(t.id)),
                        ...running_now.filter((nb) => !known.has(nb.notebook_id) && !saved.tabs.some((t) => t.id === nb.notebook_id)).map((nb) => ({ id: nb.notebook_id, path: nb.path, kind: "notebook" })),
                    ]
                    set_tabs(restored)
                    set_active((a) => a ?? (restored.some((t) => t.id === saved.active) || (saved.active === "__terminal__" && tab_keys_ref.current.terminal_tab) ? saved.active : (restored[restored.length - 1]?.id ?? null)))
                }
                tabs_restored_for.current = root_now
            }
            set_poll_error(null)
        } catch (e) {
            // A rejected fetch (TypeError) means nothing answered — the server is gone, or for a
            // remote workspace the SSH tunnel is down, which is just what a closed laptop lid looks
            // like. That is not an error the user has to act on: the hub's watchdog is already
            // rebuilding the tunnel, on the same local port, so this tab's URL stays valid. Wait for
            // it instead. A response that arrives and is bad (a thrown status) is still a real error.
            if (e?.name === "AbortError") set_workspace_status((prev) => ({ kind: "busy", since: prev?.since ?? Date.now(), detail: "no answer within 15 seconds" }))
            else if (e instanceof TypeError) {
                unreachable.current += 1
                if (unreachable.current >= 2) set_offline(true)
            } else set_poll_error(String(e?.message ?? e))
        } finally {
            clearTimeout(deadline)
            refreshing.current = false
        }
    }, [add_tab])

    // Replace a dead child: the hub stops whatever is left of it and spawns a fresh one for this folder.
    const restart_workspace = useCallback(async () => {
        const root = workspace?.root
        if (root == null) return
        set_workspace_status((prev) => ({ kind: "busy", since: prev?.since ?? Date.now(), detail: "restarting the workspace server…" }))
        try {
            let status = await get_json(`./api/v1/local/restart?path=${encodeURIComponent(root)}`, { method: "POST" })
            while (status.state !== "ready" && status.state !== "error") {
                await new Promise((r) => setTimeout(r, 1000))
                status = await get_json(`./api/v1/local/status?path=${encodeURIComponent(root)}`)
            }
            if (status.state === "ready") window.location.reload()
            else set_error(String(status.detail ?? "the workspace server did not start"))
        } catch (e) {
            set_error(String(e))
        }
    }, [workspace])

    useEffect(() => {
        refresh()
        const interval = setInterval(refresh, 10_000)
        return () => clearInterval(interval)
    }, [])

    // Reopening the laptop should not cost a 10s wait for the next poll, and coming back from
    // sleep does not always fire `online`. Probe on any signal that the machine is awake again.
    useEffect(() => {
        const probe = () => {
            if (document.visibilityState === "visible") refresh()
        }
        window.addEventListener("online", probe)
        document.addEventListener("visibilitychange", probe)
        window.addEventListener("focus", probe)
        return () => {
            window.removeEventListener("online", probe)
            document.removeEventListener("visibilitychange", probe)
            window.removeEventListener("focus", probe)
        }
    }, [refresh])

    // While unreachable, poll our OWN origin until something answers, then reload. Reloading (rather
    // than just clearing the banner) is deliberate: the notebook iframes each hold their own dead
    // websocket, and a reload is the one action that revives all of them at once.
    useEffect(() => {
        if (!offline) return
        let cancelled = false
        let timer = null
        let delay = 1000
        const tick = async () => {
            if (cancelled) return
            try {
                const r = await fetch("./ping", { cache: "no-store" })
                if (r.ok) {
                    // Back. A reload revives every notebook frame's dead socket at once, but it also
                    // throws away a file that has not been saved: then just carry on in place.
                    const unsaved = [...file_dirty.values()].some(Boolean)
                    unreachable.current = 0
                    set_offline(false)
                    if (!unsaved) window.location.reload()
                    else refresh()
                    return
                }
            } catch {}
            delay = Math.min(delay * 1.5, 5000)
            if (!cancelled) timer = setTimeout(tick, delay)
        }
        timer = setTimeout(tick, 700)
        return () => {
            cancelled = true
            if (timer != null) clearTimeout(timer)
        }
    }, [offline])

    const start_sidebar_resize = useCallback((e) => {
        const left = e.currentTarget.parentElement.getBoundingClientRect().left
        drag_resize(e, "x", (ev) => clamp(ev.clientX - left, 180, Math.min(560, window.innerWidth - 360)), set_sidebar_width)
    }, [])

    const open_notebook = useCallback(
        async (path) => {
            try {
                const id = await get_text(`./open?path=${encodeURIComponent(path)}`, { method: "POST" })
                add_tab(id, path)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [add_tab, refresh]
    )

    /** Names already in a folder, as far as this page has seen it listed (the server checks again). */
    const names_in = useCallback((dir) => new Set((dir === workspace?.root ? workspace?.entries : listings[dir])?.map((e) => e.name) ?? []), [workspace, listings])

    const close_tab = useCallback(async (id) => {
        if (id.startsWith("file:")) {
            const path = id.slice(5)
            if (file_dirty.get(path) && !(await ask_confirm(`Close ${basename(path)} without saving?\n\nIts unsaved changes will be lost.`, { action: "Close without saving", danger: true }))) return
            file_dirty.delete(path)
            set_tab_dirty(path, false)
        }
        // closing a notebook tab does NOT shut down the notebook (JupyterHub semantics) — it keeps running, listed under "Running"
        set_tabs((tabs) => {
            const at = tabs.findIndex((t) => t.id === id)
            const remaining = tabs.filter((t) => t.id !== id)
            // the tab that slides into its place, as in a browser; the last one when it was the last
            set_active((a) => (a === id ? (remaining[Math.min(at, remaining.length - 1)]?.id ?? null) : a))
            return remaining
        })
    }, [set_tab_dirty])

    // What is in front has the keyboard, and its tab is in view. Without this a click on a file left
    // the keys on the tree, and a chord that switched tabs from inside a notebook left them inside
    // the notebook that had just been hidden.
    useEffect(() => {
        if (active == null) return
        const frame = requestAnimationFrame(() => {
            document.querySelector("#tabs .tab.active")?.scrollIntoView({ block: "nearest", inline: "nearest" })
            if (document.querySelector("dialog[open], .land-menu.context") != null) return
            const front = document.querySelector("#frames > .active")
            if (front instanceof HTMLIFrameElement) front.contentWindow?.focus()
            else front?.querySelector(".cm-content, .xterm-helper-textarea")?.focus()
        })
        return () => cancelAnimationFrame(frame)
    }, [active])

    // A notebook frame asks to be closed: its session is gone (the editor's "Close tab"), or it
    // navigated to this hub and would otherwise render a whole Land inside the tab (see the bottom
    // of this file). Only our own origin, and only the frame that sent it.
    useEffect(() => {
        const on_message = (/** @type {MessageEvent} */ e) => {
            if (e.origin !== location.origin || e.data?.type !== "spacestation:close-notebook-tab") return
            const frame = [...document.querySelectorAll("#frames iframe")].find((f) => /** @type {HTMLIFrameElement} */ (f).contentWindow === e.source)
            const id = frame == null ? undefined : /** @type {HTMLIFrameElement} */ (frame).dataset.tabId
            if (id != null) close_tab(id)
        }
        window.addEventListener("message", on_message)
        return () => window.removeEventListener("message", on_message)
    }, [close_tab])

    /** Make a notebook or a file in `dir`, asking for its name. `kind` only decides what the dialog
     *  proposes: a name with a notebook extension makes a notebook either way. */
    const create_in = useCallback(
        async (dir, kind = "notebook") => {
            let taken = names_in(dir)
            if (workspace != null && dir !== workspace.root && listings[dir] == null) {
                try {
                    const { entries } = await get_json(`./api/v1/workspace/listing?path=${encodeURIComponent(dir)}`)
                    taken = new Set(entries.map((e) => e.name))
                } catch {}
            }
            const proposed = kind === "notebook" ? "notebook.jl" : ""
            const typed = await ask_text({
                title: kind === "notebook" ? `New notebook in ${basename(dir) || dir}` : `New file in ${basename(dir) || dir}`,
                note: kind === "notebook" ? "" : "A name ending in .jl opens as a notebook.",
                value: proposed,
                select_to: proposed.includes(".") ? proposed.lastIndexOf(".") : null,
                check: (v) => {
                    if (/[\\/]/.test(v)) return "A name, not a path: pick the folder in the sidebar."
                    const name = kind === "notebook" && !has_notebook_extension(v) ? `${v}.jl` : v
                    return taken.has(name) ? `${name} already exists here.` : null
                },
            })
            if (typed == null) return
            const name = kind === "notebook" && !has_notebook_extension(typed) ? `${typed}.jl` : typed
            // the folder's own separator: a Windows server lists `C:\ws\sub`
            const sep = dir.includes("\\") && !dir.includes("/") ? "\\" : "/"
            const path = `${dir}${dir.endsWith(sep) ? "" : sep}${name}`
            try {
                if (has_notebook_extension(name)) {
                    const id = await get_text("./new", { method: "POST" })
                    try {
                        await get_text(`./move?id=${encodeURIComponent(id)}&newpath=${encodeURIComponent(path)}`, { method: "POST" })
                    } catch (e) {
                        // it could not be put where it was asked for: do not leave it running somewhere else
                        fetch(`./shutdown?id=${encodeURIComponent(id)}`, { method: "POST" }).catch(() => {})
                        throw e
                    }
                    add_tab(id, path)
                } else {
                    await get_json(`./api/v1/file/new?path=${encodeURIComponent(path)}`, { method: "POST" })
                    open_file(path)
                }
                // show the new file: its folder may be collapsed (the + button works without
                // expanding), and refresh() only re-reads folders that are open
                if (workspace != null && dir !== workspace.root && !expanded_ref.current.has(dir)) toggle_dir(dir)
                else load_listing(dir)
                refresh()
            } catch (e) {
                set_error(`${name} could not be created: ${e?.message ?? e}`)
            }
        },
        [add_tab, open_file, refresh, toggle_dir, load_listing, workspace, has_notebook_extension, names_in, listings]
    )
    const create_menu = useCallback(
        (anchor, dir) => {
            const box = anchor.getBoundingClientRect()
            open_menu(box.left, box.bottom + 2, [
                { label: "New notebook…", icon: "i-notebook", run: () => create_in(dir, "notebook") },
                { label: "New file…", icon: "i-file", run: () => create_in(dir, "file") },
            ])
        },
        [create_in]
    )

    const delete_entry = useCallback(
        async (entry) => {
            const what = entry.type === "notebook" ? "notebook (it will be shut down if running; its output cache is deleted too)" : "file"
            if (!(await ask_confirm(`Delete ${entry.name}?\n\nThis permanently deletes the ${what}. There is no trash.`, { action: "Delete", danger: true }))) return
            try {
                await get_json(`./api/v1/file/delete?path=${encodeURIComponent(entry.path)}`, { method: "POST" })
                // close any tab showing it
                set_tabs((tabs) => tabs.filter((t) => t.path !== entry.path))
                file_dirty.delete(entry.path)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [refresh]
    )

    const shutdown_notebook = useCallback(
        async (id) => {
            const nb = running.find((n) => n.notebook_id === id)
            if (!(await ask_confirm(`Shut down ${nb ? basename(nb.path) : "this notebook"}?\n\nIts process stops. The file stays on disk and its outputs stay cached, so opening it again shows them.`, { action: "Shut down", danger: true }))) return
            try {
                await get_text(`./shutdown?id=${encodeURIComponent(id)}`, { method: "POST" })
                close_tab(id)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [close_tab, refresh, running]
    )

    // The terminal area can live in three places (its "dock"): bottom, right, or embedded as an
    // editor tab. `__terminal__` is the synthetic editor-tab id used in "tab" mode.
    const tab_mode = terminal_open && terminal_dock === "tab"

    const toggle_terminal = useCallback(() => {
        const next = !terminal_open
        set_terminal_open(next)
        if (next && terminal_dock === "tab") set_active("__terminal__")
        if (!next) set_active((a) => (a === "__terminal__" ? null : a))
    }, [terminal_open, terminal_dock])
    toggle_terminal_ref.current = toggle_terminal

    /** Put the terminal at the bottom, at the right, or among the editor's tabs. */
    const set_dock = useCallback(
        (next) => {
            if (next === terminal_dock) return
            if (next === "tab") {
                set_terminal_open(true)
                set_active("__terminal__")
            }
            set_terminal_dock(next)
        },
        [terminal_dock]
    )
    // The places are a choice, not a cycle: pick one from a menu under the button.
    const dock_menu = useCallback(
        (anchor) => {
            const box = anchor.getBoundingClientRect()
            const place = (dock, label, icon) => ({ label: dock === terminal_dock ? `${label}  ✓` : label, icon, run: () => set_dock(dock) })
            open_menu(box.right - 190, box.bottom + 4, [place("bottom", "Dock at the bottom", "i-dock-bottom"), place("right", "Dock at the right", "i-dock-right"), place("tab", "Show as a tab", "i-dock-tab")])
        },
        [terminal_dock, set_dock]
    )

    // the terminals UI (a tab strip of terminals + their bodies); rendered either in the docked
    // panel or inside the editor "Terminal" tab. `shown` gates which shell is live/painted.
    const shown_terminals = terminals_workspace.current === workspace?.root ? terminals : []
    const hide_terminal = () => {
        set_terminal_open(false)
        set_active((a) => (a === "__terminal__" ? null : a))
    }
    // a shell that ends takes its tab with it; the last one takes the panel
    const on_terminal_exit = useCallback(
        (tid) => {
            close_terminal(tid)
            if (terminals.length <= 1) hide_terminal()
        },
        [close_terminal, terminals.length]
    )
    const render_terminals = (shown) => html`
        <div class="terminal-tabs">
            <div class="terminal-tab-scroller" role="tablist">
                ${shown_terminals.map(
                    (t) => html`<div
                        class="tab terminal-tab ${t.tid === active_terminal ? "active" : ""}"
                        key=${t.tid}
                        onAuxClick=${(e) => e.button === 1 && close_terminal(t.tid)}
                    >
                        <button class="title" role="tab" aria-selected=${t.tid === active_terminal} title=${t.label} onClick=${() => set_active_terminal(t.tid)}>
                            <svg class="ico" aria-hidden="true"><use href="#i-terminal" /></svg><span class="tab-name">${t.label}</span>
                        </button>
                        <button class="close" title="Close this terminal and end its shell" aria-label=${`Close ${t.label}`} onClick=${() => close_terminal(t.tid)}>
                            <svg class="ico" aria-hidden="true"><use href="#i-close" /></svg>
                        </button>
                    </div>`
                )}
                <button class="icon-button new-terminal-tab" title="New terminal" aria-label="New terminal" onClick=${() => new_terminal()}>
                    <svg class="ico" aria-hidden="true"><use href="#i-add" /></svg>
                </button>
            </div>
            <div class="panel-actions">
                <button
                    class="icon-button terminal-scheme-toggle"
                    title=${terminal_scheme === "light" ? "Terminal colours: light. Switch to dark" : "Terminal colours: dark. Switch to light"}
                    aria-label="Switch the terminal between light and dark"
                    onClick=${() => set_terminal_scheme((s) => (s === "light" ? "dark" : "light"))}
                >
                    <${Ico} name=${terminal_scheme === "light" ? "i-sun" : "i-moon"} />
                </button>
                <button class="icon-button dock-toggle" title="Where the terminal sits" aria-label="Where the terminal sits" aria-haspopup="menu" onClick=${(e) => dock_menu(e.currentTarget)}>
                    <${Ico} name=${terminal_dock === "bottom" ? "i-dock-bottom" : terminal_dock === "right" ? "i-dock-right" : "i-dock-tab"} />
                </button>
                <button class="icon-button" title="Hide the terminal (Ctrl+\`). Its shells keep running." aria-label="Hide the terminal" onClick=${hide_terminal}>
                    <svg class="ico" aria-hidden="true"><use href="#i-close" /></svg>
                </button>
            </div>
        </div>
        <div class="terminal-bodies">
            ${shown_terminals.map(
                (t) => html`<div key=${t.tid} class="terminal-body ${t.tid === active_terminal ? "active" : ""}">
                    <${TerminalView}
                        tid=${t.tid}
                        cwd=${t.cwd ?? workspace?.root}
                        visible=${shown && t.tid === active_terminal}
                        scheme=${terminal_scheme}
                        notebook_env=${t.notebook_env}
                        on_exit=${on_terminal_exit}
                    />
                </div>`
            )}
        </div>
    `

    // Shut the whole server down from the UI — the terminal-independent way out (the launching
    // terminal may be gone or ssh'd away). The server answers, then stops itself a beat later.
    const shutdown_server = useCallback(async () => {
        if (
            !(await ask_confirm(
                hub
                    ? `Shut down the server for this workspace?\n\nIts running notebooks stop; this terminal, the launcher and other workspaces keep running.`
                    : "Shut down the SpaceStation server?\n\nRunning notebooks and the integrated terminal will stop. SSH remote servers keep running and can be reattached later.",
                { action: "Shut down", danger: true }
            ))
        )
            return
        // Fire the shutdown, but don't trust the request's own result: a SUCCESSFUL shutdown usually
        // makes it throw (the server dies mid-response, so the connection resets). Instead verify the
        // server is really gone by polling /ping — and only then declare it down. If it keeps
        // answering past the grace period, say so rather than lying that it shut down.
        fetch("./api/v1/shutdown", { method: "POST" }).catch(() => {})
        // Under a hub only this workspace's child stops; the hub (and its /ping) stay up by design, so
        // the proof is the relay reporting the workspace down — then the page offers a restart.
        const still_up = async () => {
            try {
                if (hub) {
                    // 503 down, 504 busy, 502 mid-teardown (a reset connection): all mean "not up"
                    const r = await fetch("./api/v1/notebooks", { cache: "no-store" })
                    return !(r.status === 502 || r.status === 503 || r.status === 504)
                }
                await fetch("./ping", { method: "GET", cache: "no-store" })
                return true
            } catch {
                return false
            }
        }
        // a child's teardown escalates to SIGKILL after ~6 s (shutdown_local_session!), so give a hub longer
        const deadline = Date.now() + (hub ? 15000 : 8000)
        while (Date.now() < deadline) {
            await new Promise((r) => setTimeout(r, 400))
            if (!(await still_up())) {
                if (hub) {
                    set_workspace_status({ kind: "down", since: Date.now(), detail: "shut down from this page" })
                    return
                }
                document.body.innerHTML =
                    '<div style="font: 15px/1.6 system-ui, sans-serif; padding: 3rem; text-align: center; color: #888">SpaceStation has shut down. You can close this tab.</div>'
                return
            }
        }
        set_error("Shutdown was requested, but the server is still responding — it may not have shut down.")
    }, [hub])

    // The ⋯ menu in the sidebar's header. Whether the active notebook has an environment to open is
    // asked when the menu is: a notebook gets one the first time it runs.
    const open_header_menu = useCallback(
        async (anchor) => {
            const box = anchor.getBoundingClientRect()
            const tab = active_notebook_tab || null
            const env =
                tab == null
                    ? null
                    : await Promise.race([
                          get_json(`./api/v1/notebook/env?id=${encodeURIComponent(tab.id)}`).catch(() => null),
                          new Promise((r) => setTimeout(() => r(null), 600)),
                      ])
            const scheme = get_color_scheme()
            open_menu(box.left, box.bottom + 2, [
                {
                    label: tab == null ? "Open notebook environment in terminal" : `Open the environment of ${basename(tab.path)} in a terminal`,
                    icon: "i-terminal",
                    // no Pluto-managed environment: it has not run yet, or it activates its own with Pkg.activate
                    disabled: env?.managed !== true,
                    run: () => tab && new_terminal({ label: `env: ${basename(tab.path)}`, notebook_env: tab.id }),
                },
                "-",
                {
                    label: `Appearance: ${scheme === "system" ? "match the system" : scheme}`,
                    icon: scheme === "system" ? "i-auto" : scheme === "light" ? "i-sun" : "i-moon",
                    run: () => void cycle_color_scheme(),
                },
                { label: "Launcher", icon: "i-home", run: go_home },
                "-",
                { label: hub ? "Shut down this workspace…" : "Shut down SpaceStation…", icon: "i-power", danger: true, run: shutdown_server },
            ])
        },
        [active_notebook_tab, new_terminal, go_home, shutdown_server, hub]
    )

    const relative_path = (path) => {
        const root = workspace?.root ?? ""
        return root !== "" && path.startsWith(root) ? path.slice(root.length).replace(/^[\\/]+/, "") : path
    }
    const entry_menu = useCallback(
        (e, entry) => {
            e.preventDefault()
            const nb = entry.type === "notebook" ? running.find((n) => n.path === entry.path) : null
            const copy_items = [
                { label: "Copy path", icon: "i-copy", run: () => copy_text(entry.path) },
                { label: "Copy relative path", run: () => copy_text(relative_path(entry.path)) },
            ]
            open_menu(
                e.clientX,
                e.clientY,
                entry.type === "dir"
                    ? [
                          { label: "New notebook…", icon: "i-notebook", run: () => create_in(entry.path, "notebook") },
                          { label: "New file…", icon: "i-file", run: () => create_in(entry.path, "file") },
                          { label: "Open in terminal", icon: "i-terminal", run: () => new_terminal({ label: entry.name, cwd: entry.path }) },
                          "-",
                          ...copy_items,
                      ]
                    : [
                          { label: "Open", icon: "i-arrow", run: () => (entry.type === "notebook" ? open_notebook(entry.path) : open_file(entry.path)) },
                          ...(nb == null ? [] : [{ label: "Shut down", icon: "i-stop", run: () => shutdown_notebook(nb.notebook_id) }]),
                          "-",
                          ...copy_items,
                          "-",
                          { label: "Delete…", icon: "i-trash", danger: true, run: () => delete_entry(entry) },
                      ]
            )
        },
        [running, workspace?.root, create_in, new_terminal, open_notebook, open_file, shutdown_notebook, delete_entry]
    )

    // The opener is "homebase": it shows on first launch (no workspace) and on demand (the "open another
    // workspace" button). Picking a folder spawns a child server in a new tab — it never takes over this
    // tab — so the launcher persists as the place you see and manage every running workspace.
    if (no_workspace || show_opener) {
        return html`<${WorkspaceOpener} on_cancel=${no_workspace ? null : () => set_show_opener(false)} tunneled=${tunneled} />`
    }

    const active_tab = tabs.find((t) => t.id === active)
    const tree = {
        on_toggle: toggle_dir,
        on_open_notebook: open_notebook,
        on_open_file: open_file,
        on_create_menu: create_menu,
        on_delete: delete_entry,
        on_menu: entry_menu,
        current_path: active_tab?.path ?? null,
        running_paths: new Set(running.map((nb) => nb.path)),
    }
    const seconds_since = (t) => Math.max(1, Math.round((Date.now() - t) / 1000))

    return html`
        <div id="land">
            ${offline
                ? html`<div class="reconnect-overlay" role="status" aria-live="polite">
                      <div class="reconnect-card">
                          <span class="spinner"></span>
                          <div>
                              <b>Reconnecting…</b>
                              <p>Notebooks and terminals keep running on the server. This page reloads itself as soon as it can reach them again.</p>
                          </div>
                      </div>
                  </div>`
                : null}
            ${sidebar_hidden
                ? null
                : html`<aside class="island" aria-label="Workspace" style=${`width: ${sidebar_width}px`}>
                      <header class="side-head">
                          <button class="land-logo-button" title="Launcher: open and manage workspaces" aria-label="Launcher" onClick=${go_home}>
                              <img class="land-logo" src=${logo_url} alt="" />
                          </button>
                          <span class="wordmark">Space<span class="land-accent">Station</span></span>
                          <span class="head-buttons">
                              <button class="icon-button menu-button" title="More" aria-label="More" aria-haspopup="menu" onClick=${(e) => open_header_menu(e.currentTarget)}>
                                  <svg class="ico" aria-hidden="true"><use href="#i-more" /></svg>
                              </button>
                              <button class="icon-button collapse-button" title="Hide the sidebar" aria-label="Hide the sidebar" onClick=${() => set_sidebar_hidden(true)}>
                                  <svg class="ico" aria-hidden="true"><use href="#i-sidebar" /></svg>
                              </button>
                          </span>
                          ${workspace?.root
                              ? html`<div class="side-where">
                                    <button
                                        class="where-line where-path"
                                        title=${`${workspace.root}\nClick to copy the path`}
                                        aria-label=${`Workspace folder ${workspace.root}. Copy the path`}
                                        onClick=${() => {
                                            copy_text(workspace.root)
                                            set_path_copied(true)
                                            setTimeout(() => set_path_copied(false), 1200)
                                        }}
                                    >
                                        ${path_copied
                                            ? html`<span class="where-name">Path copied</span>`
                                            : html`<span class="where-prefix">${path_lead(workspace.root)}</span><span class="where-name">${basename(workspace.root) || workspace.root}</span>`}
                                    </button>
                                    ${workspace.git == null
                                        ? null
                                        : html`<span class="where-line where-branch" title=${workspace.git.detached ? `Detached HEAD at ${workspace.git.branch}` : `On branch ${workspace.git.branch}`}>
                                              <svg class="ico" aria-hidden="true"><use href="#i-branch" /></svg><span class="where-text">${workspace.git.branch}</span>${workspace.git.detached
                                                  ? html`<span class="git-detached">detached</span>`
                                                  : null}
                                          </span>`}
                                </div>`
                              : null}
                      </header>
                      <section class="files">
                          <h2 class="section-label">
                              Files
                              ${workspace == null
                                  ? null
                                  : html`<span class="section-actions">
                                        <button class="icon-button" title="New notebook or file" aria-label="New notebook or file" onClick=${(e) => create_menu(e.currentTarget, workspace.root)}>
                                            <svg class="ico" aria-hidden="true"><use href="#i-add" /></svg>
                                        </button>
                                        <button class="icon-button" title="Read the files again" aria-label="Refresh the files" onClick=${() => refresh()}>
                                            <svg class="ico" aria-hidden="true"><use href="#i-refresh" /></svg>
                                        </button>
                                    </span>`}
                          </h2>
                          <ul class="tree" onContextMenu=${(e) => workspace != null && e.target === e.currentTarget && entry_menu(e, { type: "dir", path: workspace.root, name: basename(workspace.root) })}>
                              ${workspace == null
                                  ? null
                                  : workspace.entries.length === 0
                                    ? html`<li><p class="tree-empty">This folder is empty.</p></li>`
                                    : workspace.entries.map((e) => html`<${FileEntry} key=${e.path} entry=${e} listings=${listings} expanded=${expanded} tree=${tree} depth=${0} />`)}
                          </ul>
                      </section>
                      ${running.length === 0
                          ? null
                          : html`<section class="running">
                                <h2 class="section-label">Running <span class="count">${running.length}</span></h2>
                                <ul>
                                    ${running.map(
                                        (nb) => html`<li key=${nb.notebook_id}>
                                            <div class="entry-row">
                                                <button class="entry" title=${nb.path} onClick=${() => add_tab(nb.notebook_id, nb.path)}>
                                                    <span class="no-chevron"></span><span class="dot ok"></span><span class="entry-name">${basename(nb.path)}</span>
                                                </button>
                                                <button
                                                    class="row-action danger shutdown"
                                                    title="Shut down this notebook"
                                                    aria-label=${`Shut down ${basename(nb.path)}`}
                                                    onClick=${() => shutdown_notebook(nb.notebook_id)}
                                                >
                                                    <svg class="ico" aria-hidden="true"><use href="#i-stop" /></svg>
                                                </button>
                                            </div>
                                        </li>`
                                    )}
                                </ul>
                            </section>`}
                  </aside>`}
            ${sidebar_hidden
                ? null
                : html`<div
                      id="sidebar-resizer"
                      class="resizer col"
                      role="separator"
                      aria-orientation="vertical"
                      title="Drag to resize. Double-click to reset."
                      onPointerDown=${start_sidebar_resize}
                      onDblClick=${() => set_sidebar_width(SIDEBAR_WIDTH)}
                  ></div>`}
            <main>
                <div class="main-split dock-${terminal_dock}" ref=${split_ref}>
                    <div class="editor-card island">
                        <nav id="tabs">
                            ${sidebar_hidden
                                ? html`<div class="strip-lead">
                                      <button id="sidebar-reopen" class="icon-button" title="Show the sidebar" aria-label="Show the sidebar" onClick=${() => set_sidebar_hidden(false)}>
                                          <svg class="ico" aria-hidden="true"><use href="#i-sidebar" /></svg>
                                      </button>
                                  </div>`
                                : null}
                            <div
                                class="tab-scroller"
                                role="tablist"
                                onWheel=${(e) => {
                                    // a wheel that only goes up and down still moves along the strip
                                    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) e.currentTarget.scrollLeft += e.deltaY
                                }}
                            >
                                ${tabs.map(
                                    (t) => html`<div
                                        class="tab ${t.kind === "file" ? "file" : "notebook"} ${t.id === active ? "active" : ""} ${t.kind === "file" && dirty_tabs.has(t.path) ? "dirty" : ""}"
                                        key=${t.id}
                                        onMouseDown=${(e) => e.button === 1 && e.preventDefault()}
                                        onAuxClick=${(e) => e.button === 1 && close_tab(t.id)}
                                    >
                                        <button class="title" role="tab" aria-selected=${t.id === active} title=${t.path} onClick=${() => set_active(t.id)}>
                                            <${Ico} name=${t.kind === "file" ? file_icon(basename(t.path)) : "i-notebook"} /><span class="tab-name">${basename(t.path)}</span>
                                        </button>
                                        <button
                                            class="close"
                                            title=${t.kind === "file" ? "Close" : "Close the tab. The notebook keeps running."}
                                            aria-label=${`Close ${basename(t.path)}`}
                                            onClick=${() => close_tab(t.id)}
                                        >
                                            <svg class="ico" aria-hidden="true"><use href="#i-close" /></svg>
                                        </button>
                                    </div>`
                                )}
                                ${tab_mode
                                    ? html`<div class="tab terminal-tab ${active === "__terminal__" ? "active" : ""}" key="__terminal__">
                                          <button class="title" role="tab" aria-selected=${active === "__terminal__"} title="Terminal" onClick=${() => set_active("__terminal__")}>
                                              <svg class="ico" aria-hidden="true"><use href="#i-terminal" /></svg><span class="tab-name">Terminal</span>
                                          </button>
                                          <button class="close" title="Hide the terminal. Its shells keep running." aria-label="Hide the terminal" onClick=${hide_terminal}>
                                              <svg class="ico" aria-hidden="true"><use href="#i-close" /></svg>
                                          </button>
                                      </div>`
                                    : null}
                            </div>
                            ${tab_mode
                                ? null
                                : html`<div class="tab-actions">
                                <button
                                    class="terminal-toggle ${terminal_open ? "active" : ""}"
                                    title="Show or hide the terminal (Ctrl+\`)"
                                    aria-pressed=${terminal_open}
                                    onClick=${toggle_terminal}
                                >
                                    <svg class="ico" aria-hidden="true"><use href="#i-terminal" /></svg>Terminal
                                </button>
                            </div>`}
                        </nav>
                        ${files_status != null && !offline
                            ? html`<div class="workspace-status busy" role="status" aria-live="polite" title=${files_status.detail}>
                                  <span class="spinner"></span>
                                  <span class="text"
                                      >The disk these files are on is not answering (${seconds_since(files_status.since)}s). The file list will catch up; notebooks and the
                                      terminal keep working.</span
                                  >
                              </div>`
                            : null}
                        ${workspace_status != null && !offline
                            ? html`<div class="workspace-status ${workspace_status.kind}" role="status" aria-live="polite">
                                  ${workspace_status.kind === "down"
                                      ? html`<svg class="ico" aria-hidden="true"><use href="#i-alert" /></svg>
                                            <span class="text">The server for this workspace stopped, and its notebooks with it. The files and the terminal are fine.</span>
                                            <button class="text-button primary" onClick=${restart_workspace}>Start it again</button>`
                                      : html`<span class="spinner"></span>
                                            <span class="text"
                                                >The server for this workspace is busy (${seconds_since(workspace_status.since)}s). Notebooks will catch up; the files and the
                                                terminal keep working.</span
                                            >`}
                              </div>`
                            : null}
                        <div id="frames">
                            ${tabs.map((t) =>
                                t.kind === "file"
                                    ? html`<div key=${t.id} class="pane ${t.id === active ? "active" : ""}">
                                          <${FileEditorPane} path=${t.path} label=${relative_path(t.path)} visible=${t.id === active} on_dirty=${set_tab_dirty} />
                                      </div>`
                                    : // every notebook tab is the stock Pluto editor; iframes stay mounted so switching tabs never loses state
                                      html`<iframe
                                          key=${t.id}
                                          data-tab-id=${t.id}
                                          title=${basename(t.path)}
                                          src=${`./edit?id=${t.id}`}
                                          class=${t.id === active ? "active" : ""}
                                          onLoad=${(/** @type {Event} */ e) => attach_tab_keys(/** @type {HTMLIFrameElement} */ (e.target).contentWindow)}
                                      ></iframe>`
                            )}
                            ${tab_mode
                                ? html`<div class="pane terminal-area-pane terminal-surface scheme-${terminal_scheme} ${active === "__terminal__" ? "active" : ""}">
                                      ${render_terminals(tab_mode && active === "__terminal__")}
                                  </div>`
                                : null}
                            ${active_tab == null && active !== "__terminal__"
                                ? html`<div class="empty-state">
                                      <img src=${logo_url} alt="" />
                                      <p class="lede">Nothing open yet</p>
                                      <p>Open a notebook or a file from the sidebar, or start a new one.</p>
                                      ${workspace == null
                                          ? null
                                          : html`<div class="empty-actions">
                                                <button class="text-button primary" onClick=${() => create_in(workspace.root, "notebook")}>New notebook</button>
                                                ${terminal_open ? null : html`<button class="text-button" onClick=${toggle_terminal}>Open the terminal</button>`}
                                            </div>`}
                                      <p class="hint">Coding agents can work here too: they edit a notebook's file, and run what changed with <code>pluto-collab</code>.</p>
                                  </div>`
                                : null}
                        </div>
                    </div>
                    ${terminal_ever_opened.current
                        ? html`
                              <div
                                  id="terminal-resizer"
                                  class="resizer ${terminal_dock === "bottom" ? "row" : "col"}"
                                  role="separator"
                                  aria-orientation=${terminal_dock === "bottom" ? "horizontal" : "vertical"}
                                  title="Drag to resize. Double-click to reset."
                                  style=${terminal_open && terminal_dock !== "tab" ? "" : "display: none"}
                                  onPointerDown=${start_terminal_resize}
                                  onDblClick=${reset_terminal_size}
                              ></div>
                              <div
                                  id="terminal-panel"
                                  class="island terminal-surface scheme-${terminal_scheme}"
                                  style=${terminal_open && terminal_dock !== "tab"
                                      ? terminal_dock === "bottom"
                                          ? `height: ${terminal_height}px`
                                          : `width: ${terminal_width}px`
                                      : "display: none"}
                              >
                                  ${terminal_dock !== "tab" ? render_terminals(terminal_open && terminal_dock !== "tab") : null}
                              </div>
                          `
                        : null}
                </div>
            </main>
            ${(error ?? poll_error) == null
                ? null
                : html`<div class="land-toasts">
                      <div class="land-toast" role="alert">
                          <svg class="ico" aria-hidden="true"><use href="#i-alert" /></svg>
                          <p>${error ?? poll_error}</p>
                          <button class="icon-button" title="Dismiss" aria-label="Dismiss" onClick=${() => (set_error(null), set_poll_error(null))}><svg class="ico" aria-hidden="true"><use href="#i-close" /></svg></button>
                      </div>
                  </div>`}
        </div>
    `
}

// Loaded inside one of a Land's own notebook frames — any relative "./" followed from an editor lands
// here — this page would render the whole workspace nested in that tab, with its own polling, sockets
// and terminals. A same-origin parent that is itself a Land means exactly that: ask the parent to
// close the tab instead of rendering.
const framed_by_land = (() => {
    try {
        return window.frameElement != null && window.parent.document.getElementById("land-app") != null
    } catch (e) {
        return false
    }
})()
if (framed_by_land) window.parent.postMessage({ type: "spacestation:close-notebook-tab" }, location.origin)
else {
    mount_icons()
    render(html`<${Land} />`, document.querySelector("#land-app"))
}
