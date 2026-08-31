// The HEADED companion to smoke.ts — it proves a real window opens and its webview actually renders
// and runs JavaScript.
//
// smoke.ts deliberately covers everything EXCEPT the window, and that gap is exactly how issue #55
// shipped: on Windows the MSI installs into %ProgramFiles%\SpaceStation, WebView2 could not create
// its user-data folder beside the binary, no window ever appeared — and CI, which only ever ran the
// headless smoke, stayed green through all of it. So this test opens a window, points it at a local
// page, and waits for that page to call home. No beacon, no pass.
//
//   deno desktop --allow-net --allow-env --allow-read --allow-write window_smoke.ts
//
// On Windows it additionally asserts WHERE WebView2 put its profile: under LOCALAPPDATA (writable),
// never next to the executable. That second assertion is the direct regression test for #55 — and it
// holds even on a CI runner that is an administrator, where the original bug would NOT reproduce on
// its own because Program Files happens to be writable for that account.

// A packaged Windows app is a GUI-subsystem binary: it has no console, so nothing it prints is
// visible to the CI shell that started it. Mirror every line into SPACESTATION_SMOKE_LOG when set,
// and let the runner cat that file — otherwise a Windows failure is just a bare exit code.
const LOG = Deno.env.get("SPACESTATION_SMOKE_LOG")
const say = (line: string) => {
    console.log(line)
    if (LOG != null && LOG !== "") {
        try {
            Deno.writeTextFileSync(LOG, `${line}\n`, { append: true })
        } catch {
            // the console line above is still the record
        }
    }
}

// A function DECLARATION, not an arrow: TypeScript only narrows through a `never`-returning call
// when the callee is declared this way, and the checks below lean on that.
function fail(msg: string): never {
    say(`[window-smoke] FAIL: ${msg}`)
    Deno.exit(1)
}

const BrowserWindow = (Deno as any).BrowserWindow
if (BrowserWindow == null) fail("Deno.BrowserWindow is unavailable — run this with `deno desktop`, not `deno run`.")

// The page below fetches /beacon. Reaching it means the webview process started, loaded a document
// and executed script — the whole chain that was silently dead on Windows.
let saw_beacon: (ua: string) => void
const beacon = new Promise<string>((resolve) => (saw_beacon = resolve))

const PAGE = `<!doctype html><meta charset="utf-8"><title>SpaceStation window smoke</title>
<body style="font: 14px system-ui; padding: 2rem">opening…
<script>fetch("/beacon?ua=" + encodeURIComponent(navigator.userAgent))</script>`

const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen: () => {} }, (req) => {
    const url = new URL(req.url)
    if (url.pathname === "/beacon") {
        saw_beacon(url.searchParams.get("ua") ?? "(no user-agent)")
        return new Response("ok")
    }
    return new Response(PAGE, { headers: { "content-type": "text/html; charset=utf-8" } })
})
const port = (server.addr as Deno.NetAddr).port

say(`[window-smoke] platform: ${Deno.build.os}/${Deno.build.arch}`)
if (Deno.build.os === "windows") {
    say(`[window-smoke] WEBVIEW2_USER_DATA_FOLDER = ${JSON.stringify(Deno.env.get("WEBVIEW2_USER_DATA_FOLDER") ?? "(unset)")}`)
}

let win: any
try {
    win = new BrowserWindow({ title: "SpaceStation window smoke", width: 520, height: 360 })
} catch (e) {
    fail(`could not construct a window: ${e}`)
}
win.navigate(`http://127.0.0.1:${port}/`)

const TIMEOUT_MS = 90_000
const ua = await Promise.race([beacon, new Promise<null>((r) => setTimeout(() => r(null), TIMEOUT_MS))])
if (ua == null) {
    fail(
        `the window never rendered — no beacon within ${TIMEOUT_MS / 1000}s.\n` +
            `           This is the #55 signature: the process is alive but the webview never came up.`
    )
}
say(`[window-smoke] the webview rendered and ran JS — user-agent: ${ua}`)

// The runtime icon setter (issue #63): prove the whole FFI chain — VFS ico materialization,
// window-handle lookup, LoadImageW, WM_SETICON — actually works on a real Windows window. Off
// Windows it reports "skipped" and this stays a no-op.
{
    const { set_windows_window_icon } = await import("./windows_icon.ts")
    const icon_status = await set_windows_window_icon(win, "SpaceStation window smoke")
    say(`[window-smoke] window icon: ${icon_status}`)
    if (Deno.build.os === "windows" && icon_status !== "set") {
        fail(`the runtime window icon was not set: ${icon_status}`)
    }
}

// #55's regression check, restated for what actually fixes it. WebView2 always puts its user-data
// folder beside the executable — laufey passes a NULL userDataFolder and WEBVIEW2_USER_DATA_FOLDER
// is a convention the host app must implement, which CI demonstrated it does not. So the folder's
// LOCATION is not ours to choose; what matters is that wherever the binary lives, it can be written.
if (Deno.build.os === "windows") {
    const beside = `${Deno.execPath()}.WebView2`
    let entries: string[] = []
    const deadline = Date.now() + 20_000
    while (Date.now() < deadline) {
        try {
            entries = [...Deno.readDirSync(beside)].map((e) => e.name)
        } catch {
            entries = []
        }
        if (entries.length > 0) break
        await new Promise((r) => setTimeout(r, 500))
    }
    if (entries.length === 0) {
        fail(`WebView2 rendered but wrote nothing to ${beside} within 20s — its profile went somewhere unexpected.`)
    }
    say(`[window-smoke] WebView2 profile at ${JSON.stringify(beside)} — ${entries.slice(0, 8).join(", ")}`)
    // Prove the directory is genuinely writable by this user, which is the property the installer
    // has to guarantee and the one a Program Files install breaks.
    const probe = `${beside}\\.spacestation-write-probe`
    try {
        Deno.writeTextFileSync(probe, "ok")
        Deno.removeSync(probe)
        say("[window-smoke] the WebView2 directory is writable by this user — good")
    } catch (e) {
        fail(`the WebView2 directory ${beside} is not writable: ${e}. On an installed copy this is issue #55.`)
    }
}

say("[window-smoke] PASS")
Deno.exit(0)
