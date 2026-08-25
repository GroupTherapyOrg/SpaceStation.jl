// Headless end-to-end check of the desktop shell's server plumbing — everything except the
// window: find Julia, boot the server, wait for /ping, read the connection-file secret, fetch the
// hub page, confirm /api/v1/config reports desktop mode, shut down cleanly.
//
//   deno run --allow-run --allow-net --allow-read --allow-write --allow-env smoke.ts

import { SpaceStationServer } from "./boot.ts"

const server = new SpaceStationServer()
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

await server.stop()
const ok = hub.ok && config.desktop === true
console.log(ok ? "[smoke] PASS" : "[smoke] FAIL")
Deno.exit(ok ? 0 : 1)
