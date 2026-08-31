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
import "./common/Zoom.js" // browser-style zoom for the desktop app (no-op in real browsers)

const get_text = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(`${url} → ${r.status}`)
    return await r.text()
}
const get_json = async (url, opts) => {
    const r = await fetch(url, opts)
    if (!r.ok) throw new Error(`${url} → ${r.status}`)
    return await r.json()
}

// Both separators: on Windows every path the server hands back is `\`-separated (`C:\ws\a.jl`),
// and splitting that on "/" alone returns the whole path as the "name". Same shape as the
// basename in components/FilePicker.js, which is not exported.
const basename = (p) => (p.split("/").pop() ?? "").split("\\").pop() ?? ""

// A confirm() the browser can't suppress. window.confirm can be permanently silenced (Chrome's
// "prevent this page from creating additional dialogs", iframes without allow-modals) — it then
// returns false instantly and every destructive button in the hub appears dead, with no error.
// A native <dialog>.showModal() is always shown. Returns Promise<boolean>; Esc / backdrop = false.
const ask_confirm = (message, { action = "Confirm", danger = false } = {}) =>
    new Promise((resolve) => {
        const dialog = document.createElement("dialog")
        dialog.className = "land-confirm"
        const body = document.createElement("p")
        body.textContent = message
        const row = document.createElement("div")
        row.className = "buttons"
        const cancel = document.createElement("button")
        cancel.textContent = "Cancel"
        const ok = document.createElement("button")
        ok.textContent = action
        ok.className = `go ${danger ? "danger" : ""}`
        row.append(cancel, ok)
        dialog.append(body, row)
        document.body.append(dialog)
        const done = (result) => {
            dialog.close()
            dialog.remove()
            resolve(result)
        }
        cancel.onclick = () => done(false)
        ok.onclick = () => done(true)
        dialog.oncancel = (e) => {
            e.preventDefault()
            done(false)
        }
        dialog.onclick = (e) => e.target === dialog && done(false)
        dialog.showModal()
        cancel.focus() // safe default: Enter cancels, the destructive action needs a deliberate click/Tab
    })

// One canonical homebase: the launcher tab names itself this, so a workspace's "home" button can focus it
// (or reopen it if it was closed) via window.open(url, HOMEBASE_WINDOW_NAME) — instead of every workspace
// spawning its own disconnected in-tab launcher.
const HOMEBASE_WINDOW_NAME = "spacestation-homebase"
const homebase_self_url = () => window.location.origin + window.location.pathname + window.location.search
// Tag a workspace URL with this homebase's address (in the #fragment — never sent to the server) so the
// workspace it opens knows where "home" is.
const with_homebase = (url) => (url == null ? url : `${url}#homebase=${encodeURIComponent(homebase_self_url())}`)

// The desktop shell (desktop/) frames every hub page inside its deck — the tab-strip chrome — so
// being framed IS the desktop signal: structural, known synchronously, and it survives auth
// redirects and reattached child servers that never saw the env var. The ?desktop=1 the shell
// appends and the /api/v1/config flag remain as secondary hints.
const in_desktop_frame = (() => {
    try {
        return window.self !== window.top
    } catch (e) {
        return true // a cross-origin parent blocked the check — framed by definition
    }
})()
const desktop_boot_hint = in_desktop_frame || new URLSearchParams(window.location.search).has("desktop")

// App-wide light/dark/auto — LAUNCHER-ONLY control (so the terminal's own scheme toggle stays
// unambiguous), applied to every workspace immediately: same-origin pages follow via storage
// events, and workspaces on other ports get it via the deck broadcast + a ?scheme= seed on
// workspace links (ColorScheme.js handles both ends).
const AppSchemeToggle = ({ classname }) => {
    const [scheme, set_scheme] = useState(get_color_scheme())
    return html`<button
        class="app-scheme-toggle ${classname ?? ""}"
        title=${scheme === "system" ? "Appearance: follow the system — switch to light" : scheme === "light" ? "Appearance: light — switch to dark" : "Appearance: dark — follow the system"}
        aria-label="Toggle light/dark appearance"
        onClick=${() => {
            const next = cycle_color_scheme()
            set_scheme(next)
            // the deck rebroadcasts to every workspace tab (they live on other ports/origins)
            post_to_deck({ type: "spacestation:color-scheme", scheme: next })
        }}
    >
        ${scheme === "system" ? "◐" : scheme === "light" ? "☀" : "☾"}
    </button>`
}
// Ask the deck to do something (open a workspace tab, focus the Launcher tab).
const post_to_deck = (message) => {
    try {
        window.parent.postMessage(message, "*")
    } catch (e) {}
}

// `new URL(..., import.meta.url)` works unbundled in the browser AND gets rewritten by
// the bundler — a string src would 404 in frontend-dist where filenames are hashed.
const logo_url = new URL("img/spacestation.svg", import.meta.url).href

const RECENT_KEY = "spacestation recent workspaces"
const get_recent_workspaces = () => {
    try {
        const r = JSON.parse(localStorage.getItem(RECENT_KEY) ?? "[]")
        return Array.isArray(r) ? r : []
    } catch {
        return []
    }
}
const remember_workspace = (path) => {
    localStorage.setItem(RECENT_KEY, JSON.stringify([path, ...get_recent_workspaces().filter((p) => p !== path)].slice(0, 8)))
}

// Terminals live in the terminal panel as their own tabs. Their shells persist on the server
// (keyed by tid), so we remember each terminal's tid + label and reattach on reload.
const TERMINALS_KEY = "spacestation terminals by workspace"
const LEGACY_TERMINALS_KEY = "spacestation terminals"
const restore_terminals = (workspace_root) => {
    if (typeof workspace_root !== "string" || workspace_root.length === 0) return []
    try {
        const all = JSON.parse(localStorage.getItem(TERMINALS_KEY) ?? "{}")
        let saved = all && typeof all === "object" && !Array.isArray(all) ? all[workspace_root] : null
        // One-time migration: old builds stored one global list. Adopt it for the workspace that
        // first loads after upgrade, then remove it so other workspaces don't inherit those tabs.
        if (!Array.isArray(saved)) {
            const legacy = JSON.parse(localStorage.getItem(LEGACY_TERMINALS_KEY) ?? "[]")
            if (Array.isArray(legacy) && legacy.length > 0) {
                saved = legacy
                localStorage.removeItem(LEGACY_TERMINALS_KEY)
            }
        }
        if (!Array.isArray(saved)) return []
        return saved.filter((t) => t && typeof t.tid === "string").map((t) => ({ tid: t.tid, label: t.label ?? "Terminal" }))
    } catch {
        return []
    }
}
const save_terminals = (workspace_root, terminals) => {
    if (typeof workspace_root !== "string" || workspace_root.length === 0) return
    let all = {}
    try {
        const parsed = JSON.parse(localStorage.getItem(TERMINALS_KEY) ?? "{}")
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) all = parsed
    } catch {}
    all[workspace_root] = terminals.map((t) => ({ tid: t.tid, label: t.label }))
    localStorage.setItem(TERMINALS_KEY, JSON.stringify(all))
}

// How long to wait for an SSH connection before giving up (seconds). A busy ProxyJump login node can
// need well over the old 8s default just to relay the compute node's banner — so this is user-tunable
// from homebase. Mirrors the server's clamp (see SSH_CONNECT_TIMEOUT in CollabRemote.jl).
const SSH_TIMEOUT_KEY = "spacestation ssh connect timeout"
const SSH_TIMEOUT_DEFAULT = 25
const clamp_ssh_timeout = (v) => Math.max(3, Math.min(180, Math.round(Number(v) || SSH_TIMEOUT_DEFAULT)))
const get_ssh_timeout = () => {
    const v = Number(localStorage.getItem(SSH_TIMEOUT_KEY))
    return Number.isFinite(v) && v >= 3 ? clamp_ssh_timeout(v) : SSH_TIMEOUT_DEFAULT
}

/** One row of the sidebar tree.
 *
 * Which folders are open, and what is in them, are NOT held here — they live in the hub
 * (`expanded` / `listings`) and arrive as props. That is what makes the tree lazy: the hub fetches
 * a folder's contents the first time it is expanded, and its 10s poll re-reads only the folders
 * that are currently open. A folder that has never been opened costs the server nothing.
 */
const FileEntry = ({ entry, listings, expanded, on_toggle, on_open_notebook, on_open_file, on_create_in, on_delete, depth }) => {
    if (entry.type === "dir") {
        const open = expanded.has(entry.path)
        const children = listings[entry.path]
        return html`<li class="dir ${open ? "open" : ""}">
            <div class="entry-row">
                <button class="entry" onClick=${() => on_toggle(entry.path)}><span class="icon chevron"></span>${entry.name}</button>
                <button class="row-action" title="New notebook or file in ${entry.name}/" onClick=${() => on_create_in(entry.path)}>+</button>
            </div>
            ${open
                ? html`<ul>
                      ${children == null
                          ? html`<li class="pending">
                                <div class="entry-row"><span class="entry plain">reading…</span></div>
                            </li>`
                          : children.map(
                                (c) =>
                                    html`<${FileEntry}
                                        key=${c.path}
                                        entry=${c}
                                        listings=${listings}
                                        expanded=${expanded}
                                        on_toggle=${on_toggle}
                                        on_open_notebook=${on_open_notebook}
                                        on_open_file=${on_open_file}
                                        on_create_in=${on_create_in}
                                        on_delete=${on_delete}
                                        depth=${depth + 1}
                                    />`
                            )}
                  </ul>`
                : null}
        </li>`
    }
    // a single folder is still capped, so a directory holding 100k files can't produce a 100k-row
    // response; the server closes such a listing with this marker rather than silently shortening it
    if (entry.type === "truncated") {
        return html`<li class="truncated">
            <div class="entry-row">
                <span
                    class="entry plain"
                    title="This folder has more entries than SpaceStation lists in one go. Use the terminal to see the rest."
                    >… not listed</span
                >
            </div>
        </li>`
    }
    if (entry.type === "unreadable") {
        return html`<li class="truncated">
            <div class="entry-row"><span class="entry plain" title=${entry.detail ?? ""}>… could not be read</span></div>
        </li>`
    }
    const is_notebook = entry.type === "notebook"
    return html`<li class=${is_notebook ? "notebook" : "file"}>
        <div class="entry-row">
            <button
                class="entry ${is_notebook ? "" : "quiet"}"
                title=${entry.path}
                onClick=${() => (is_notebook ? on_open_notebook(entry.path) : on_open_file(entry.path))}
            >
                <span class="icon ${is_notebook ? "pluto-dot" : ""}"></span>${entry.name}
            </button>
            <button class="row-action danger" title="Delete ${entry.name}" onClick=${() => on_delete(entry)}>✕</button>
        </div>
    </li>`
}

/** Homebase: the VS Code "Open Folder" experience (browse the filesystem, pick a folder) plus a live
 *  list of every running workspace — local children AND SSH remotes — to reattach to or shut down.
 *  Picking a folder spawns a child server in a new tab (see connect_local); this view never leaves.
 *  `on_cancel` (optional) shows a back button when opened on top of an existing workspace. */
const WorkspaceOpener = ({ on_cancel, tunneled, desktop }) => {
    // Read through a ref inside the long-running connect polls: they can outlive a `desktop` flip
    // (the config fetch landing just after mount), and must honour the value at COMPLETION time.
    const desktop_ref = useRef(desktop)
    desktop_ref.current = desktop
    // Workspace links: a browser homebase opens them in a new tab; the desktop's single webview
    // window navigates in place. Both carry the homebase fragment — the workspace's way back — and
    // desktop destinations also carry ?desktop=1 so the workspace knows its mode synchronously.
    const desktop_url = (url) => (desktop_ref.current ? `${url}${url.includes("?") ? "&" : "?"}desktop=1` : url)
    // Stamp the launcher's appearance choice on workspace links: workspaces are other origins
    // (their own ports), so localStorage can't carry it — the ?scheme= seed does.
    const scheme_url = (url) => {
        const s = get_color_scheme()
        return s === "system" ? url : `${url}${url.includes("?") ? "&" : "?"}scheme=${s}`
    }
    const open_href = (url) => with_homebase(desktop_url(scheme_url(url)))
    const open_target = desktop ? "_self" : "_blank"
    // Desktop: workspaces open as DECK TABS — the deck dedupes by server, so reopening focuses.
    const post_open_tab = (url, title) => post_to_deck({ type: "spacestation:open-workspace", url: desktop_url(url), title })
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

    useEffect(() => {
        get_json("./api/v1/ssh_hosts")
            .then(set_ssh_hosts)
            .catch(() => {})
    }, [])

    // The SSH connect timeout is a homebase setting. The server resets it to its default on restart, so
    // push our stored value on load and whenever it changes (and persist it locally for next time).
    useEffect(() => {
        localStorage.setItem(SSH_TIMEOUT_KEY, String(ssh_timeout))
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
                // Desktop: open this remote workspace as a deck tab.
                if (desktop_ref.current) post_open_tab(status.url, host)
                else window.open(open_href(status.url), "_blank") // may be blocked: the pill stays a clickable link either way
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
                // Desktop: open this workspace as a deck tab.
                if (desktop_ref.current) post_open_tab(status.url, basename(path) || path)
                else window.open(open_href(status.url), "_blank") // may be blocked: the ready card stays a clickable link either way
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

    // Open a folder as a workspace. Local: spawn a child server in its own tab (connect_local) —
    // the desktop shell does this too, just navigating its single window there instead of opening
    // a tab, so the workspace stays a real running child this launcher lists and returns to. Over
    // a tunnel (a remote server): switch THIS server's workspace in-place and reload — the child's
    // port wouldn't be reachable from the browser, so a new tab would just fail to connect.
    const open_workspace = useCallback(
        async (path) => {
            if (!tunneled) return connect_local(path)
            try {
                await get_json(`./api/v1/workspace/open?path=${encodeURIComponent(path)}`, { method: "POST" })
                remember_workspace(path)
                window.location.reload()
            } catch (e) {
                set_error(String(e))
            }
        },
        [tunneled, connect_local]
    )

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
        const iv = setInterval(load, 3000)
        return () => {
            alive = false
            clearInterval(iv)
        }
    }, [])

    const browse = useCallback(async (path) => {
        try {
            set_listing(await get_json(path == null ? "./api/v1/browse" : `./api/v1/browse?path=${encodeURIComponent(path)}`))
            set_error(null)
        } catch (e) {
            set_error(String(e))
        }
    }, [])

    useEffect(() => {
        browse(null)
    }, [])

    const recent = get_recent_workspaces()

    // Built by the server: splitting a path on "/" here turned a Windows one into a single bogus
    // crumb, and joining one back together means knowing about drives and backslashes.
    const crumbs = listing?.crumbs ?? []

    return html`<div class="workspace-opener">
        <div class="bubble opener-card">
            <header>
                <img class="land-logo opener-logo" src=${logo_url} alt="SpaceStation" />
                <h1>Space<span class="land-accent">Station</span></h1>
                <p class="subtitle">Open a folder as your workspace — notebooks inside it open as tabs.</p>
                <${AppSchemeToggle} classname=${on_cancel == null ? "opener-corner" : "opener-corner beside-cancel"} />
                ${on_cancel == null ? null : html`<button class="opener-cancel" title="Close — back to your workspace" onClick=${on_cancel}><span class="opener-cancel-icon"></span></button>`}
            </header>

            ${!tunneled && running.length > 0
                ? html`<section>
                      <h2>Running Workspaces</h2>
                      <div class="recent-grid">
                          ${running.map(
                              (w) => html`<div class="recent-card running-card ${w.state === "ready" ? "" : "running-busy"}" key=${w.key}>
                                  ${w.url != null
                                      ? html`<a
                                            class="running-open"
                                            href=${open_href(w.url)}
                                            target=${open_target}
                                            rel="opener"
                                            title=${`Open ${w.name}`}
                                            onClick=${desktop
                                                ? (e) => {
                                                      e.preventDefault()
                                                      post_open_tab(w.url, w.name)
                                                  }
                                                : undefined}
                                        >
                                            <span class="recent-icon">${w.kind === "remote" ? "🛰" : "🗂"}</span>
                                            <span class="recent-name">${w.name}</span>
                                            <span class="recent-path">${w.sub}</span>
                                        </a>`
                                      : html`<div class="running-open is-busy">
                                            <span class="recent-icon">${w.kind === "remote" ? "🛰" : "🗂"}</span>
                                            <span class="recent-name">${w.name}</span>
                                            <span class="recent-path">${w.state}…</span>
                                        </div>`}
                                  <button
                                      class="running-shutdown"
                                      title=${w.state === "error" ? "Dismiss" : w.state !== "ready" ? "Cancel" : w.kind === "remote" ? "Disconnect" : "Shut down this workspace"}
                                      onClick=${() => dismiss_running(w)}
                                  >
                                      ✕
                                  </button>
                              </div>`
                          )}
                      </div>
                  </section>`
                : null}

            ${recent.length > 0
                ? html`<section>
                      <h2>Recent</h2>
                      <div class="recent-grid">
                          ${recent.map(
                              (p) => html`<button class="recent-card" title=${p} onClick=${() => open_workspace(p)}>
                                  <span class="recent-icon">🗂</span>
                                  <span class="recent-name">${basename(p)}</span>
                                  <span class="recent-path">${p}</span>
                              </button>`
                          )}
                      </div>
                  </section>`
                : null}

            <section>
                <h2>Browse</h2>
                ${listing == null
                    ? html`<p class="subtitle">loading…</p>`
                    : html`
                          <nav class="breadcrumbs">
                              ${crumbs.map(
                                  (c, i) => html`<button
                                          class="crumb ${i === crumbs.length - 1 ? "current" : ""}"
                                          onClick=${() => browse(c.path)}
                                          title=${c.path}
                                      >
                                          ${c.name}</button
                                      >${i > 0 && i < crumbs.length - 1 ? html`<span class="crumb-sep">/</span>` : null}`
                              )}
                          </nav>
                          <div class="dir-grid">
                              ${listing.entries.map(
                                  (d) => html`<button class="dir-pill" title=${d.path} onClick=${() => browse(d.path)}>
                                      <span class="dir-icon">📁</span>${d.name}
                                  </button>`
                              )}
                              ${listing.entries.length === 0 ? html`<p class="subtitle">no subfolders</p>` : null}
                          </div>
                          <div class="opener-actions">
                              <button class="open-this-folder" onClick=${() => open_workspace(listing.path)}>
                                  Open <strong>${basename(listing.path) || "/"}</strong> as workspace
                              </button>
                              <form
                                  class="paste-path"
                                  onSubmit=${(e) => {
                                      e.preventDefault()
                                      const v = e.target.elements.path.value.trim()
                                      if (v !== "") browse(v)
                                  }}
                              >
                                  <input name="path" type="text" placeholder="…or paste a folder path and press Enter" autocomplete="off" />
                              </form>
                          </div>
                      `}
            </section>
            ${!tunneled && ssh_hosts.length > 0
                ? html`<section>
                      <h2>SSH Remotes</h2>
                      <p class="subtitle small">
                          Click a host: the whole Land (files, kernels, terminal) runs on that machine over an SSH tunnel. First contact installs the
                          server there; after that it reconnects instantly.
                      </p>
                      <label
                          class="ssh-timeout"
                          title="How long to wait for an SSH connection — including the banner from a slow ProxyJump login node — before giving up."
                      >
                          Connection timeout
                          <input
                              type="number"
                              min="3"
                              max="180"
                              step="1"
                              value=${ssh_timeout}
                              onChange=${(e) => set_ssh_timeout(clamp_ssh_timeout(e.target.value))}
                          />
                          <span class="unit">s</span>
                          <span class="ssh-timeout-hint">Raise this if a host fails with “timed out reaching … slow SSH hop”.</span>
                      </label>
                      <div class="dir-grid">
                          ${ssh_hosts.map((h) => {
                              const st = remote_states[h]
                              const busy = st != null && st.state !== "ready" && st.state !== "error"
                              return st?.state === "ready" && st.url != null
                                  ? html`<a
                                        class="dir-pill remote-ready"
                                        href=${open_href(st.url)}
                                        target=${open_target}
                                        rel="opener"
                                        title=${st.detail}
                                        onClick=${desktop
                                            ? (e) => {
                                                  e.preventDefault()
                                                  post_open_tab(st.url, h)
                                              }
                                            : undefined}
                                    >
                                        <span class="dir-icon">🛰</span>${h} →
                                    </a>`
                                  : html`<button
                                        class="dir-pill ${busy ? "remote-busy" : ""} ${st?.state === "error" ? "remote-error" : ""}"
                                        title=${st?.detail ?? `Open a workspace on ${h}`}
                                        onClick=${() => connect_remote(h)}
                                    >
                                        <span class="dir-icon">🛰</span>${busy ? `${h}: ${st.state}…` : st?.state === "error" ? `${h}: failed (retry)` : h}
                                    </button>`
                          })}
                      </div>
                      ${Object.entries(remote_states)
                          .filter(([_, st]) => st.state !== "ready" && st.state !== "error")
                          .map(
                              ([h, st]) => html`<div class="remote-progress" key=${h}>
                                  <span class="remote-spinner"></span>
                                  <div class="remote-progress-text">
                                      <strong>Connecting to ${h} — ${st.state}</strong>
                                      <span>${st.detail}</span>
                                      ${st.state === "installing"
                                          ? html`<span class="remote-progress-note">First-time setup compiles a lot of Julia — this is the slow step. Leave this page open; it will connect by itself.</span>`
                                          : null}
                                  </div>
                                  <button class="remote-cancel" title="Cancel this connection" onClick=${() => cancel_remote(h)}>Cancel</button>
                              </div>`
                          )}
                      ${Object.values(remote_states).some((st) => st.state === "error")
                          ? html`<p class="opener-error">${Object.entries(remote_states).filter(([_, st]) => st.state === "error").map(([h, st]) => `${h}: ${st.detail}`).join(" · ")}</p>`
                          : null}
                  </section>`
                : null}
            ${Object.entries(local_states)
                .filter(([_, st]) => st.state !== "ready" && st.state !== "error")
                .map(
                    ([path, st]) => html`<div class="remote-progress" key=${path}>
                        <span class="remote-spinner"></span>
                        <div class="remote-progress-text">
                            <strong>Starting ${basename(path)} — ${st.state}</strong>
                            <span>${st.detail}</span>
                        </div>
                        <button class="remote-cancel" title="Cancel this launch" onClick=${() => cancel_local(path)}>Cancel</button>
                    </div>`
                )}
            ${Object.values(local_states).some((st) => st.state === "error")
                ? html`<p class="opener-error">
                      ${Object.entries(local_states)
                          .filter(([_, st]) => st.state === "error")
                          .map(([path, st]) => `${basename(path)}: ${st.detail}`)
                          .join(" · ")}
                  </p>`
                : null}
            ${error == null ? null : html`<p class="opener-error">${error}</p>`}
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
              background: v("--terminal-light-bg", "#fbfbfb"),
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
              background: v("--terminal-bg", "#1f1f1f"),
              foreground: v("--terminal-fg", "#dddddd"),
          }
}

const TerminalView = ({ tid, cwd, visible, scheme }) => {
    const node_ref = useRef(null)
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
        clearTimeout(refit_timer.current)
        refit_timer.current = setTimeout(() => {
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
        }, 120)
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
        // returning to this tab (or first reveal of an already-started one): re-measure once painted
        if (started.current) {
            refit()
            return
        }
        if (node_ref.current == null) return
        started.current = true
        ;(async () => {
            const [{ Terminal }, { FitAddon }, config] = await Promise.all([
                // 6.0.0, not 5.5.0: 5.5 predates two upstream fixes that hit the desktop app directly —
                // "Fixed CapsLock triggering input twice in MacOS" (#5282) and "Fix duplicate input for
                // some IMEs" (#5024). The desktop shell is WKWebView (WebKit), where xterm 5.5's input
                // layer garbles caps/fast typing into TUIs like Claude Code; Chrome never showed it.
                import("https://esm.sh/@xterm/xterm@6.0.0?target=es2020"),
                import("https://esm.sh/@xterm/addon-fit@0.11.0?target=es2020"),
                get_json("./api/v1/config").catch(() => null),
            ])
            const term = new Terminal({
                fontSize: 13,
                fontFamily: "JuliaMono, SFMono-Regular, Menlo, Consolas, monospace",
                cursorBlink: true,
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

            // Assigned when the websocket opens (below); the paste handler needs it, so it lives out here.
            let socket = null

            // Copy: Cmd/Ctrl+C copies when there is a selection; otherwise it falls through to the shell
            // as SIGINT. Text paste is deliberately NOT handled here: xterm already consumes the browser's
            // native `paste` event. Calling the privileged Clipboard API from Cmd+V as well caused
            // browser permission prompts and could deliver text twice through the two competing paths.
            term.attachCustomKeyEventHandler((e) => {
                if (e.type !== "keydown") return true
                if ((e.metaKey || e.ctrlKey) && (e.key === "c" || e.key === "C") && term.hasSelection()) {
                    navigator.clipboard?.writeText(term.getSelection()).catch(() => {})
                    return false
                }
                return true
            })

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
            // Open the shell in the workspace the client is showing (local or ssh-remote), not wherever
            // the server happened to launch. The server falls back to its workspace_folder if omitted.
            const cwd_param = cwd ? `&cwd=${encodeURIComponent(cwd)}` : ""
            const size_param = `&rows=${term.rows}&cols=${term.cols}`
            socket = new WebSocket(`${proto}://${window.location.host}/terminal?tid=${tid}${cwd_param}${size_param}`)
            socket_ref.current = socket
            socket.binaryType = "arraybuffer"
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
            socket.onmessage = (e) => {
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
                if (Number.isFinite(meta.rows) && Number.isFinite(meta.cols) && (term.rows !== meta.rows || term.cols !== meta.cols)) {
                    try {
                        term.resize(meta.cols, meta.rows)
                    } catch {}
                }
                if (meta.replayed) sync_size_to_panel()
            }
            socket.onopen = () => refit()
            socket.onclose = () => term.write("\r\n\x1b[2m[disconnected — the shell is still running; reload to reattach]\x1b[0m\r\n")
            term.onData((d) => socket.readyState === WebSocket.OPEN && socket.send("0:" + d))
            term.onResize(({ rows, cols }) => socket.readyState === WebSocket.OPEN && socket.send(`1:${rows},${cols}`))
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
            clearTimeout(refit_timer.current)
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

    return html`<div class="terminal-host" ref=${node_ref}></div>`
}


// dirty state per open file, shared so close_tab can warn
const file_dirty = new Map()

/** A text-file editor pane built on Pluto's own bundled CodeMirror (imports/CodemirrorPlutoSetup.js),
 *  with syntax colors wired to Pluto's --cm-color-* theme variables. Save with the button or Ctrl/Cmd+S. */
const FileEditorPane = ({ path, visible }) => {
    const node_ref = useRef(null)
    const view_ref = useRef(null)
    const started = useRef(false)
    const [dirty, set_dirty] = useState(false)
    const [status, set_status] = useState("loading…")

    const save = useCallback(async () => {
        const view = view_ref.current
        if (view == null) return
        try {
            await get_json(`./api/v1/file/save?path=${encodeURIComponent(path)}`, { method: "POST", body: view.state.doc.toString() })
            file_dirty.set(path, false)
            set_dirty(false)
            set_status("saved")
            setTimeout(() => set_status(""), 1500)
        } catch (e) {
            set_status(String(e))
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
                                if (update.docChanged) {
                                    file_dirty.set(path, true)
                                    set_dirty(true)
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
                set_status(String(e))
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
            <span class="file-path" title=${path}>${path}</span>
            <span class="file-status">${dirty ? "●" : ""} ${status}</span>
            <button class="file-save ${dirty ? "dirty" : ""}" onClick=${save} title="Save (Ctrl/Cmd+S)">Save</button>
        </div>
        <div class="file-editor" ref=${node_ref}></div>
    </div>`
}

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
    const [sidebar_width, set_sidebar_width] = useState(() => Number(localStorage.getItem("spacestation sidebar width")) || 290)
    const [sidebar_hidden, set_sidebar_hidden] = useState(() => localStorage.getItem("spacestation sidebar hidden") === "true")
    const [terminal_open, set_terminal_open] = useState(() => localStorage.getItem("spacestation terminal open") === "true")
    const [terminal_height, set_terminal_height] = useState(() => Number(localStorage.getItem("spacestation terminal height")) || 280)
    const [terminal_width, set_terminal_width] = useState(() => Number(localStorage.getItem("spacestation terminal width")) || 420)
    const [terminal_dock, set_terminal_dock] = useState(() => (localStorage.getItem("spacestation terminal dock") === "right" ? "right" : "bottom"))
    // The terminal's colours are its own preference, not the page theme's: plenty of people want a
    // light UI with a dark terminal. Defaults to dark, which is what the terminal has always been.
    const [terminal_scheme, set_terminal_scheme] = useState(() => (localStorage.getItem("spacestation terminal scheme") === "light" ? "light" : "dark"))
    const terminal_ever_opened = useRef(false)
    if (terminal_open) terminal_ever_opened.current = true
    const [show_opener, set_show_opener] = useState(false)
    const [menu_open, set_menu_open] = useState(false)
    const menu_ref = useRef(null)
    // Close the header overflow menu on an outside click or Escape — standard popover behaviour.
    useEffect(() => {
        if (!menu_open) return
        const on_pointer = (e) => {
            if (menu_ref.current != null && !menu_ref.current.contains(e.target)) set_menu_open(false)
        }
        const on_key = (e) => {
            if (e.key === "Escape") set_menu_open(false)
        }
        document.addEventListener("pointerdown", on_pointer)
        document.addEventListener("keydown", on_key)
        return () => {
            document.removeEventListener("pointerdown", on_pointer)
            document.removeEventListener("keydown", on_key)
        }
    }, [menu_open])
    const auto_tabbed = useRef(false)
    // If this tab was spawned by a homebase, it carries the homebase URL in its #fragment — remember it so
    // the "home" button returns there instead of opening a disconnected in-tab launcher.
    const homebase_url = useRef(/** @type {String?} */ (null))
    if (homebase_url.current == null) {
        const m = window.location.hash.match(/[#&]homebase=([^&]+)/)
        if (m) {
            try {
                homebase_url.current = decodeURIComponent(m[1])
            } catch (e) {}
        }
    }
    // This server may be reached over an SSH tunnel (when it's a remote workspace). If so, its child
    // workspace ports aren't forwarded to the browser, so workspaces open IN-PLACE rather than in new tabs.
    const [tunneled, set_tunneled] = useState(false)
    // The desktop shell (desktop/): one webview window, no browser tabs — workspaces open in-place
    // like tunneled ones, but the SSH sections stay (their tunnels come FROM this local server).
    const [desktop, set_desktop] = useState(desktop_boot_hint)
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
                set_desktop(desktop_boot_hint || !!(c && c.desktop))
                if (Array.isArray(c?.notebook_extensions) && c.notebook_extensions.length > 0) set_notebook_extensions(c.notebook_extensions)
            })
            .catch(() => {})
    }, [])

    /** Would a file with this name be opened as a notebook? Mirrors `_is_pluto_notebook_file`'s
     *  extension half — the header half only applies to files that already exist. */
    const has_notebook_extension = useCallback((name) => has_pluto_file_extension(name, notebook_extensions), [notebook_extensions])

    // The launcher (no workspace of its own) is THE homebase — name the tab so workspaces can target it.
    useEffect(() => {
        if (no_workspace) window.name = HOMEBASE_WINDOW_NAME
    }, [no_workspace])

    // Tab title tells the homebase apart from workspaces in the browser's tab strip: the launcher reads
    // "SpaceStation (launcher)"; a workspace reads "SpaceStation — <folder>".
    useEffect(() => {
        document.title = no_workspace ? "SpaceStation (launcher)" : workspace?.root ? `SpaceStation — ${basename(workspace.root)}` : "SpaceStation"
    }, [no_workspace, workspace])

    // "Home" from inside a workspace. Over a tunnel: clear the workspace and reload this same tab (the
    // remote homebase). Otherwise: focus the homebase tab if open, or reopen it if it was closed — one
    // shared homebase, never a disconnected duplicate. (In-tab opener only when no homebase is known.)
    const go_home = useCallback(() => {
        // Desktop: the deck chrome has a pinned Launcher tab — just focus it. This workspace's
        // tab and child server stay alive.
        if (desktop && in_desktop_frame) {
            post_to_deck({ type: "spacestation:focus-launcher" })
            return
        }
        // Desktop outside the deck (shouldn't happen): fall back to navigating home in place.
        if (desktop && homebase_url.current != null) {
            window.location.href = homebase_url.current
            return
        }
        if (tunneled || desktop) {
            fetch("./api/v1/workspace/close", { method: "POST" }).finally(() => window.location.reload())
            return
        }
        // Focus the homebase tab that opened us. opener.focus() is one of the few cross-origin-permitted
        // calls, so unlike window.open(url, name) it actually focuses across the different ports our
        // workspaces live on — and it doesn't reload the homebase. (Anchor-opened tabs keep their opener
        // thanks to rel="opener" on the workspace links.)
        try {
            if (window.opener && !window.opener.closed) {
                window.opener.focus()
                return
            }
        } catch (e) {}
        // No live opener. If we know the homebase, switch to its tab: reuse it (never a duplicate) and
        // focus the returned handle, so an ALREADY-OPEN homebase actually gets raised to the front — plain
        // window.open(url, name) reuses the tab but only auto-focuses when it has to CREATE one.
        if (homebase_url.current) {
            // window.open("", name) hands back the existing named tab WITHOUT reloading it; if none is open
            // it returns a fresh blank tab, which we then point at the homebase.
            let w = null
            try {
                w = window.open("", HOMEBASE_WINDOW_NAME)
            } catch (e) {}
            if (w == null) {
                // Popup blocked / unsupported: last-resort reopen-by-name.
                window.open(homebase_url.current, HOMEBASE_WINDOW_NAME)
                return
            }
            let is_blank = false
            try {
                is_blank = w.location.href === "about:blank"
            } catch (e) {
                // cross-origin: the homebase runs on another port, so it's already open — just focus it.
            }
            if (is_blank) {
                try {
                    w.location.href = homebase_url.current
                } catch (e) {}
            }
            try {
                w.focus()
            } catch (e) {}
            return
        }
        set_show_opener(true)
    }, [tunneled, desktop])

    // Terminals are tabs INSIDE the terminal panel (like VS Code). Each is a persistent shell
    // keyed by tid; the list + active terminal are restored on reload. `terminal_seq` numbers them.
    const [terminals, set_terminals] = useState(/** @type {Array<{tid: String, label: String}>} */ ([]))
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
        localStorage.setItem("spacestation sidebar width", String(sidebar_width))
        localStorage.setItem("spacestation sidebar hidden", String(sidebar_hidden))
        localStorage.setItem("spacestation terminal open", String(terminal_open))
        localStorage.setItem("spacestation terminal height", String(terminal_height))
        localStorage.setItem("spacestation terminal scheme", terminal_scheme)
        localStorage.setItem("spacestation terminal width", String(terminal_width))
        localStorage.setItem("spacestation terminal dock", terminal_dock)
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

    const start_terminal_resize = useCallback(
        (e) => {
            e.preventDefault()
            const vertical = terminal_dock === "bottom"
            document.body.classList.add(vertical ? "resizing-v" : "resizing")
            const move = (ev) =>
                vertical
                    ? set_terminal_height(Math.max(120, Math.min(window.innerHeight - 220, window.innerHeight - ev.clientY - 12)))
                    : set_terminal_width(Math.max(240, Math.min(window.innerWidth - 420, window.innerWidth - ev.clientX - 12)))
            const up = () => {
                document.body.classList.remove("resizing-v")
                document.body.classList.remove("resizing")
                window.removeEventListener("pointermove", move)
                window.removeEventListener("pointerup", up)
            }
            window.addEventListener("pointermove", move)
            window.addEventListener("pointerup", up)
        },
        [terminal_dock]
    )

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

    const new_terminal = useCallback(() => {
        if (workspace?.root == null || terminals_workspace.current !== workspace.root) return
        terminal_seq.current += 1
        const tid = "term-" + Math.random().toString(36).slice(2, 12)
        set_terminals((ts) => [...ts, { tid, label: `Terminal ${terminal_seq.current}` }])
        set_active_terminal(tid)
        set_terminal_open(true)
    }, [workspace?.root])

    const close_terminal = useCallback((tid) => {
        // Reap the server-side shell (this is a real close, not a detach) — best-effort; the tab is
        // going away regardless. Persistent shells only survive detaches (hide / dock / reload).
        fetch(`./api/v1/terminal/close?tid=${encodeURIComponent(tid)}`, { method: "POST" }).catch(() => {})
        set_terminals((ts) => {
            const remaining = ts.filter((t) => t.tid !== tid)
            set_active_terminal((a) => (a === tid ? (remaining.length ? remaining[remaining.length - 1].tid : null) : a))
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

    const refresh = useCallback(async () => {
        try {
            const ws_response = await fetch("./api/v1/workspace")
            if (ws_response.status === 404) {
                set_no_workspace(true)
                set_workspace(null)
            } else if (ws_response.ok) {
                set_no_workspace(false)
                set_workspace(await ws_response.json())
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
            const running_now = await get_json("./api/v1/notebooks")
            set_running(running_now)
            // on first load, show already-running notebooks as tabs (e.g. one passed via Pluto.run(notebook=…))
            if (!auto_tabbed.current) {
                auto_tabbed.current = true
                running_now.forEach((nb) => add_tab(nb.notebook_id, nb.path))
            }
            set_error(null)
        } catch (e) {
            // A rejected fetch (TypeError) means nothing answered — the server is gone, or for a
            // remote workspace the SSH tunnel is down, which is just what a closed laptop lid looks
            // like. That is not an error the user has to act on: the hub's watchdog is already
            // rebuilding the tunnel, on the same local port, so this tab's URL stays valid. Wait for
            // it instead. A response that arrives and is bad (a thrown status) is still a real error.
            if (e instanceof TypeError) set_offline(true)
            else set_error(String(e))
        }
    }, [add_tab])

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
                    window.location.reload()
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
        e.preventDefault()
        document.body.classList.add("resizing") // disables pointer events on the iframes so the drag isn't swallowed
        const move = (ev) => set_sidebar_width(Math.max(180, Math.min(560, ev.clientX - 12)))
        const up = () => {
            document.body.classList.remove("resizing")
            window.removeEventListener("pointermove", move)
            window.removeEventListener("pointerup", up)
        }
        window.addEventListener("pointermove", move)
        window.addEventListener("pointerup", up)
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

    const new_notebook = useCallback(async () => {
        if (workspace == null) return
        const name = prompt("Notebook file name (created in the workspace):", "new notebook.jl")
        if (name == null) return
        try {
            const id = await get_text("./new", { method: "POST" })
            // "notes.plutojl" is already a notebook name — appending .jl would make "notes.plutojl.jl"
            const newpath = `${workspace.root}/${has_notebook_extension(name) ? name : name + ".jl"}`
            await get_text(`./move?id=${encodeURIComponent(id)}&newpath=${encodeURIComponent(newpath)}`, { method: "POST" })
            add_tab(id, newpath)
            refresh()
        } catch (e) {
            set_error(String(e))
        }
    }, [workspace, add_tab, refresh, has_notebook_extension])

    const close_tab = useCallback(async (id) => {
        if (id.startsWith("file:")) {
            const path = id.slice(5)
            if (file_dirty.get(path) && !(await ask_confirm("This file has unsaved changes. Close anyway?", { action: "Close without saving", danger: true }))) return
            file_dirty.delete(path)
        }
        // closing a notebook tab does NOT shut down the notebook (JupyterHub semantics) — it keeps running, listed under "Running"
        set_tabs((tabs) => {
            const remaining = tabs.filter((t) => t.id !== id)
            set_active((a) => (a === id ? (remaining.length > 0 ? remaining[remaining.length - 1].id : null) : a))
            return remaining
        })
    }, [])

    const create_in = useCallback(
        async (dir) => {
            const name = prompt(`New file in ${basename(dir)}/ — a name ending in .jl or .plutojl becomes a Pluto notebook:`, "notebook.jl")
            if (name == null || name.trim() === "") return
            const path = `${dir}/${name.trim()}`
            try {
                if (has_notebook_extension(name.trim())) {
                    const id = await get_text("./new", { method: "POST" })
                    await get_text(`./move?id=${encodeURIComponent(id)}&newpath=${encodeURIComponent(path)}`, { method: "POST" })
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
                set_error(String(e))
            }
        },
        [add_tab, open_file, refresh, toggle_dir, load_listing, workspace, has_notebook_extension]
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
            if (!(await ask_confirm("Shut down this notebook session? The file stays on disk; outputs are cached.", { action: "Shut down" }))) return
            try {
                await get_text(`./shutdown?id=${encodeURIComponent(id)}`, { method: "POST" })
                close_tab(id)
                refresh()
            } catch (e) {
                set_error(String(e))
            }
        },
        [close_tab, refresh]
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

    const cycle_dock = useCallback(() => {
        const next = terminal_dock === "bottom" ? "right" : terminal_dock === "right" ? "tab" : "bottom"
        if (next === "tab") {
            set_terminal_open(true)
            set_active("__terminal__")
        } else if (terminal_dock === "tab") {
            set_active((a) => (a === "__terminal__" ? null : a))
        }
        set_terminal_dock(next)
    }, [terminal_dock])

    // the terminals UI (a tab strip of terminals + their bodies); rendered either in the docked
    // panel or inside the editor "Terminal" tab. `shown` gates which shell is live/painted.
    const render_terminals = (shown) => html`
        <div class="terminal-tabs">
            <div class="terminal-tab-scroller">
                ${(terminals_workspace.current === workspace?.root ? terminals : []).map(
                    (t) => html`<div class="tab terminal-tab ${t.tid === active_terminal ? "active" : ""}" key=${t.tid}>
                        <button class="title" title=${t.label} onClick=${() => set_active_terminal(t.tid)}>
                            <span class="tab-term-icon">⌨</span>${t.label}
                        </button>
                        <button class="close" title="Close terminal" onClick=${() => close_terminal(t.tid)}>×</button>
                    </div>`
                )}
                <button class="new-terminal-tab" title="New terminal" onClick=${new_terminal}>
                    <span class="nt-icon">⌨</span><span class="nt-plus">＋</span>
                </button>
            </div>
            <button
                class="terminal-scheme-toggle"
                title=${terminal_scheme === "light" ? "Terminal colours: light — switch to dark" : "Terminal colours: dark — switch to light"}
                aria-label="Toggle terminal colours"
                onClick=${() => set_terminal_scheme((s) => (s === "light" ? "dark" : "light"))}
            >
                ${terminal_scheme === "light" ? "☀" : "☾"}
            </button>
        </div>
        <div class="terminal-bodies">
            ${(terminals_workspace.current === workspace?.root ? terminals : []).map(
                (t) => html`<div key=${t.tid} class="terminal-body ${t.tid === active_terminal ? "active" : ""}">
                    <${TerminalView} tid=${t.tid} cwd=${workspace?.root} visible=${shown && t.tid === active_terminal} scheme=${terminal_scheme} />
                </div>`
            )}
        </div>
    `

    // Shut the whole server down from the UI — the terminal-independent way out (the launching
    // terminal may be gone or ssh'd away). The server answers, then stops itself a beat later.
    const shutdown_server = useCallback(async () => {
        if (
            !(await ask_confirm(
                "Shut down the SpaceStation server?\n\nRunning notebooks and the integrated terminal will stop. SSH remote servers keep running and can be reattached later.",
                { action: "Shut down" }
            ))
        )
            return
        // Fire the shutdown, but don't trust the request's own result: a SUCCESSFUL shutdown usually
        // makes it throw (the server dies mid-response, so the connection resets). Instead verify the
        // server is really gone by polling /ping — and only then declare it down. If it keeps
        // answering past the grace period, say so rather than lying that it shut down.
        fetch("./api/v1/shutdown", { method: "POST" }).catch(() => {})
        const still_up = async () => {
            try {
                await fetch("./ping", { method: "GET", cache: "no-store" })
                return true
            } catch {
                return false
            }
        }
        const deadline = Date.now() + 8000
        while (Date.now() < deadline) {
            await new Promise((r) => setTimeout(r, 400))
            if (!(await still_up())) {
                document.body.innerHTML =
                    '<div style="font: 15px/1.6 system-ui, sans-serif; padding: 3rem; text-align: center; color: #888">SpaceStation has shut down. You can close this tab.</div>'
                return
            }
        }
        set_error("Shutdown was requested, but the server is still responding — it may not have shut down.")
    }, [])

    // The opener is "homebase": it shows on first launch (no workspace) and on demand (the "open another
    // workspace" button). Picking a folder spawns a child server in a new tab — it never takes over this
    // tab — so the launcher persists as the place you see and manage every running workspace.
    if (no_workspace || show_opener) {
        return html`<${WorkspaceOpener} on_cancel=${no_workspace ? null : () => set_show_opener(false)} tunneled=${tunneled} desktop=${desktop} />`
    }

    return html`
        <div id="land">
            ${offline
                ? html`<div class="reconnect-overlay" role="status" aria-live="polite">
                      <div class="reconnect-card">
                          <span class="reconnect-spinner"></span>
                          <div>
                              <b>Reconnecting…</b>
                              <p>
                                  Waiting for this workspace to come back. Notebooks and terminals on the server keep running — this page reloads
                                  itself as soon as it can reach them again.
                              </p>
                          </div>
                      </div>
                  </div>`
                : null}
            ${sidebar_hidden
                ? html`<button id="sidebar-reopen" title="Show sidebar" onClick=${() => set_sidebar_hidden(false)}>☰</button>`
                : html`<aside style=${`width: ${sidebar_width}px`}>
                <header class="bubble">
                    <div class="header-row">
                        <button class="land-logo-button" title="Back to homebase (open &amp; manage workspaces)" onClick=${go_home}>
                            <img class="land-logo" src=${logo_url} alt="SpaceStation" />
                        </button>
                        <div class="header-text">
                            <h1 title=${workspace?.root ?? ""}>Space<span class="land-accent">Station</span></h1>
                            ${workspace?.root
                                ? html`<p class="workspace-root" title=${workspace.root}>${basename(workspace.root) || workspace.root}</p>`
                                : null}
                        </div>
                        <div class="header-buttons">
                            <div class="header-menu" ref=${menu_ref}>
                                <button class="header-button menu-button ${menu_open ? "active" : ""}" title="More actions" aria-haspopup="menu" aria-expanded=${menu_open} onClick=${() => set_menu_open((o) => !o)}><span class="menu-dots"></span></button>
                                ${menu_open
                                    ? html`<div class="header-menu-popover" role="menu">
                                          <button class="header-menu-item danger" role="menuitem" onClick=${() => {
                                              set_menu_open(false)
                                              shutdown_server()
                                          }}>⏻ Shut down server</button>
                                      </div>`
                                    : null}
                            </div>
                            <button class="header-button collapse-button" title="Hide sidebar" onClick=${() => set_sidebar_hidden(true)}><span class="collapse-icon"></span></button>
                        </div>
                    </div>
                </header>
                <section class="files bubble">
                    <h2>
                        Workspace
                        ${workspace?.git == null
                            ? null
                            : html`<span
                                  class="git-branch"
                                  title=${workspace.git.detached ? `Detached HEAD at ${workspace.git.branch}` : `On branch ${workspace.git.branch}`}
                              >
                                  <span class="git-branch-icon"></span><span class="git-branch-name">${workspace.git.branch}</span>
                              </span>`}
                        ${workspace == null
                            ? null
                            : html`<button class="row-action h2-action" title="New notebook or file in the workspace root" onClick=${() => create_in(workspace.root)}>+</button>`}
                    </h2>
                    <ul class="tree">
                        ${workspace == null
                            ? null
                            : workspace.entries.map(
                                  (e) =>
                                      html`<${FileEntry}
                                          key=${e.path}
                                          entry=${e}
                                          listings=${listings}
                                          expanded=${expanded}
                                          on_toggle=${toggle_dir}
                                          on_open_notebook=${open_notebook}
                                          on_open_file=${open_file}
                                          on_create_in=${create_in}
                                          on_delete=${delete_entry}
                                          depth=${0}
                                      />`
                              )}
                    </ul>
                </section>
                <section class="running bubble">
                    <h2>Running</h2>
                    <ul>
                        ${running.map(
                            (nb) => html`<li>
                                <button class="entry" title=${nb.path} onClick=${() => add_tab(nb.notebook_id, nb.path)}>
                                    <span class="icon running-dot"></span>${basename(nb.path)}
                                </button>
                                <button class="shutdown" title="Shut down this notebook" onClick=${() => shutdown_notebook(nb.notebook_id)}>✕</button>
                            </li>`
                        )}
                    </ul>
                </section>
                <footer>
                    <button class="new-notebook" onClick=${new_notebook}>+ New notebook</button>
                </footer>
            </aside>`}
            ${sidebar_hidden ? null : html`<div id="sidebar-resizer" onPointerDown=${start_sidebar_resize}></div>`}
            <main>
                <div class="main-split ${terminal_dock}">
                    <div class="editor-card">
                        <nav id="tabs">
                            <div class="tab-scroller">
                                ${tabs.map(
                                    (t) => html`<div class="tab ${t.id === active ? "active" : ""}" key=${t.id}>
                                        <button class="title" title=${t.path} onClick=${() => set_active(t.id)}>${basename(t.path)}</button>
                                        <button class="close" title="Close tab (notebook keeps running)" onClick=${() => close_tab(t.id)}>×</button>
                                    </div>`
                                )}
                                ${tab_mode
                                    ? html`<div class="tab terminal-tab ${active === "__terminal__" ? "active" : ""}" key="__terminal__">
                                          <button class="title" title="Terminal" onClick=${() => set_active("__terminal__")}>
                                              <span class="tab-term-icon">⌨</span>Terminal
                                          </button>
                                          <button class="close" title="Hide terminal" onClick=${() => {
        set_terminal_open(false)
        set_active((a) => (a === "__terminal__" ? null : a))
    }}>×</button>
                                      </div>`
                                    : null}
                            </div>
                            <button class="terminal-toggle ${terminal_open ? "active" : ""}" title="Toggle the integrated terminal (runs in the workspace folder)" onClick=${toggle_terminal}>⌨ Terminal</button>
                            ${terminal_open
                                ? html`<button
                                      class="terminal-toggle dock-toggle"
                                      title=${terminal_dock === "bottom"
                                          ? "Move terminal to the right"
                                          : terminal_dock === "right"
                                            ? "Embed terminal as an editor tab"
                                            : "Dock terminal to the bottom"}
                                      onClick=${cycle_dock}
                                  >
                                      ${terminal_dock === "bottom" ? "◨" : terminal_dock === "right" ? "▭" : "⬓"}
                                  </button>`
                                : null}
                        </nav>
                        <div id="frames">
                            ${tabs.map((t) =>
                                t.kind === "file"
                                    ? html`<div key=${t.id} class="pane ${t.id === active ? "active" : ""}">
                                          <${FileEditorPane} path=${t.path} visible=${t.id === active} />
                                      </div>`
                                    : // every notebook tab is the stock Pluto editor; iframes stay mounted so switching tabs never loses state
                                      html`<iframe key=${t.id} src=${`./edit?id=${t.id}`} class=${t.id === active ? "active" : ""}></iframe>`
                            )}
                            ${tab_mode
                                ? html`<div class="pane terminal-area-pane ${active === "__terminal__" ? "active" : ""}">
                                      ${render_terminals(tab_mode && active === "__terminal__")}
                                  </div>`
                                : null}
                            ${tabs.length === 0 && active !== "__terminal__"
                                ? html`<div class="empty-state">
                                      <p>Open a notebook from the workspace on the left, or create a new one.</p>
                                      <p class="hint">Agents can work here too: edit any notebook file, or use <code>pluto-collab</code>.</p>
                                  </div>`
                                : null}
                        </div>
                    </div>
                    ${terminal_ever_opened.current
                        ? html`
                              <div
                                  id="terminal-resizer"
                                  style=${terminal_open && terminal_dock !== "tab" ? "" : "display: none"}
                                  onPointerDown=${start_terminal_resize}
                              ></div>
                              <div
                                  id="terminal-panel"
                                  class="bubble"
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
            ${error == null ? null : html`<div id="land-error">${error}</div>`}
        </div>
    `
}

render(html`<${Land} />`, document.querySelector("#land-app"))
