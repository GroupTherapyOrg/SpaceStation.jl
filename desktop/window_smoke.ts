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

import { webview2_user_data_dir } from "./webview2.ts"

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

// #55's regression check: the profile must live somewhere the user can actually write.
if (Deno.build.os === "windows") {
    const expected = webview2_user_data_dir()
    const actual = Deno.env.get("WEBVIEW2_USER_DATA_FOLDER") ?? ""
    if (expected == null) fail("could not compute a WebView2 user-data directory (no LOCALAPPDATA/USERPROFILE?)")
    if (actual === "") fail("WEBVIEW2_USER_DATA_FOLDER is unset — webview2.ts did not run before the window was created")
    // The relaunch is the fix; setting the variable in-process is the fallback that does NOT work,
    // because the environment is already created by the time any module body runs. Assert we are the
    // relaunched child, or a build that silently lost --allow-run looks like a pass.
    if (Deno.env.get("SPACESTATION_WEBVIEW2_RELAUNCHED") !== "1") {
        fail(
            "not the relaunched child — webview2.ts fell back to setting the variable in-process, " +
                "which leaves the WebView2 environment at its default <exe>.WebView2 path. " +
                "Most likely the binary was built without --allow-run."
        )
    }
    if (actual.toLowerCase() !== expected.toLowerCase()) fail(`WEBVIEW2_USER_DATA_FOLDER is ${actual}, expected ${expected}`)

    // THE assertion. Nothing may be written beside the executable: on a real install that is
    // %ProgramFiles%\SpaceStation, read-only for a standard user, and its appearance is the #55
    // signature exactly. This holds even here, where the runner could write there if it tried.
    const exe = Deno.execPath()
    try {
        Deno.statSync(`${exe}.WebView2`)
        fail(`WebView2 fell back to ${exe}.WebView2 — beside the binary. On an installed copy that path is not writable; this is exactly issue #55.`)
    } catch {
        say(`[window-smoke] nothing written beside the executable — good`)
    }

    // And the profile should land in our folder. WebView2 writes it lazily and we beacon the moment
    // the page loads, so poll rather than demanding it be there already — and look for ANY entry,
    // not specifically EBWebView: that subfolder belongs to the DEFAULT <exe>.WebView2\EBWebView
    // layout, and an explicitly named user-data folder is not obliged to reproduce it.
    const deadline = Date.now() + 20_000
    let entries: string[] = []
    while (Date.now() < deadline) {
        try {
            entries = [...Deno.readDirSync(actual)].map((e) => e.name)
        } catch {
            entries = []
        }
        if (entries.length > 0) break
        await new Promise((r) => setTimeout(r, 500))
    }
    if (entries.length === 0) fail(`WebView2 reported success but wrote nothing into ${actual} within 20s`)
    say(`[window-smoke] WebView2 profile materialized in ${actual} — ${entries.slice(0, 8).join(", ")}`)
}

say("[window-smoke] PASS")
Deno.exit(0)
