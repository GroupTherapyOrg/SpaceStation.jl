// Headless end-to-end check of the desktop shell's server plumbing — everything except the
// window: find Julia, boot the server, wait for /ping, read the connection-file secret, fetch the
// hub page, confirm /api/v1/config reports desktop mode, shut down cleanly.
//
//   deno run --allow-run --allow-net --allow-read --allow-write --allow-env smoke.ts

import { SpaceStationServer } from "./boot.ts"

const server = new SpaceStationServer()

// Regression test for the "Not yet authenticated" Launcher (issue #66's thread): a connection file
// for the port we are about to use, under another hostname (a Mac's changes with the network), left
// behind by a crashed or older run, sorting FIRST in the directory and holding a dead secret. The
// shell used to take it and hand the Launcher the wrong secret. Plant one and insist on getting in.
const registry_dir = `${Deno.env.get("XDG_STATE_HOME") ?? `${Deno.env.get("HOME") ?? Deno.env.get("USERPROFILE")}/.local/state`}/pluto/servers`
// A dozen of them: the directory is read in filesystem order (hash order on APFS), so with one
// stale file the old lookup got lucky often enough to hide the bug; with twelve it almost never does.
const planned_port = server.pick_port()
const stale_files = Array.from({ length: 12 }, (_, i) => `${registry_dir}/stale-host-${i}.example-${planned_port}.json`)
Deno.mkdirSync(registry_dir, { recursive: true })
for (const f of stale_files) {
    Deno.writeTextFileSync(f, `{"pid": 1, "host": "127.0.0.1", "port": ${planned_port}, "node": "stale-host", "secret": "stalestale", "workspace": null, "started_at": 0}\n`)
}
console.log(`[smoke] planted ${stale_files.length} stale connection files for port ${planned_port} in ${registry_dir}`)

let last_phase = ""
server.onchange = () => {
    const { phase, detail } = server.state
    if (phase === last_phase) return
    last_phase = phase
    console.log(`[smoke] ${phase}${detail ? ` — ${detail}` : ""}`)
}

const started = server.start()
const poll = setInterval(() => {
    const line = server.state.log.at(-1)
    if (line) console.log(`[julia] ${line}`)
}, 2000)
await started
clearInterval(poll)

if (server.state.phase !== "ready" || server.state.url == null) {
    console.error(`[smoke] FAILED: ${server.state.detail}`)
    console.error(server.state.log.slice(-20).join("\n"))
    Deno.exit(1)
}

console.log(`[smoke] server ready at ${server.state.url.replace(/secret=.*/, "secret=***")}`)
const hub = await fetch(server.state.url)
const html = await hub.text()
console.log(`[smoke] hub page: HTTP ${hub.status}, ${html.length} bytes, land page: ${html.includes("land.js") || html.includes("SpaceStation")}`)
// the config route is auth-guarded and fetch() carries no cookies — present the secret directly
const secret = new URL(server.state.url).searchParams.get("secret") ?? ""
const config = await (await fetch(`http://127.0.0.1:${server.state.port}/api/v1/config?secret=${secret}`)).json()
console.log(`[smoke] /api/v1/config → desktop: ${config.desktop}, tunneled: ${config.tunneled}`)

const used_stale = secret === "stalestale"
console.log(`[smoke] stale connection file ignored: ${!used_stale}`)

await server.stop()
// the server removes the connection file it wrote on a graceful shutdown
let own_removed = true
for (const entry of Deno.readDirSync(registry_dir)) {
    if (entry.name.endsWith(`-${server.state.port}.json`) && !entry.name.startsWith("stale-host-")) own_removed = false
}
console.log(`[smoke] server removed its own connection file on shutdown: ${own_removed}`)
for (const f of stale_files) {
    try {
        Deno.removeSync(f)
    } catch {
        // already gone
    }
}
const ok = hub.ok && config.desktop === true && !used_stale && own_removed
console.log(ok ? "[smoke] PASS" : "[smoke] FAIL")
Deno.exit(ok ? 0 : 1)
