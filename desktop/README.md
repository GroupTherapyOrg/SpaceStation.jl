# SpaceStation Desktop (experimental)

A native desktop app for SpaceStation, built with [Deno Desktop](https://docs.deno.com/runtime/desktop/)
(`deno desktop`, Deno ≥ 2.9): a thin shell that boots the Julia server and shows it in a native
window. All of the product stays in Julia + the web frontend — this folder is only process
management, a boot splash, and packaging.

## How it works

1. The shell serves a splash page via `Deno.serve` — the desktop runtime points the startup
   window at it automatically. The splash polls `/status` and streams the Julia boot log.
2. It finds `julia` (juliaup first — `SPACESTATION_JULIA` overrides), picks a free port, and runs
   `SpaceStation.run(port=…, launch_browser=false)` with `SPACESTATION_DESKTOP=1`.
3. Readiness is `/ping`; the access secret is read from SpaceStation's connection file
   (`~/.local/state/pluto/servers/<node>-<port>.json` — written exactly for tools like this).
4. The window navigates to `http://127.0.0.1:<port>/?secret=…`. Closing it SIGTERMs the server,
   which reaps terminals, SSH tunnels, and child workspace servers on its way down.

The window shows the **deck**: a Warp-style tab strip in the title-bar area (the shell serves it
at `/deck`) with the Launcher pinned first and each workspace as a tab, every tab a live iframe.
Workspaces run exactly like in the browser — each is its own child server, listed live under
Running Workspaces — and the hub pages detect desktop mode STRUCTURALLY (they are framed by the
deck: `window.self !== window.top`), so it survives auth redirects and children that never saw an
env var. Opening a workspace posts a message to the deck, which opens (or focuses — one tab per
server) its tab; Home focuses the Launcher tab; closing a tab leaves the workspace running, ready
to reopen from the Launcher. `SPACESTATION_DESKTOP=1` / `?desktop=1` remain as secondary hints.

The window has a native menu: Edit roles (so clipboard shortcuts reach the webview), **⌘R Reload**
(deck tabs survive it via sessionStorage), and **⌘⇧L Back to Launcher**.

Which Julia project runs, in priority order:

1. `SPACESTATION_PROJECT` env var — an explicit project directory.
2. The repo this folder sits in, when running from a source checkout (`deno task dev`).
3. A **managed environment** (compiled app): `~/Library/Application Support/SpaceStation/julia-env`
   (macOS) / `%APPDATA%\SpaceStation\julia-env` (Windows) / `~/.local/share/spacestation/julia-env`
   (Linux), bootstrapped from the General registry on first run. First run installs and
   precompiles — minutes, once; the splash shows progress.

## Commands (from this folder)

```bash
deno task dev            # run the app from this checkout, with HMR
deno task smoke          # headless end-to-end check, no window (CI-able)
deno task build          # → dist/SpaceStation.app   (this Mac)
deno task build:dmg      # → dist/SpaceStation.dmg   (compressed, drag-to-install)
deno task build:mac-intel
deno task build:win      # → dist/SpaceStation-win-x64/   (cross-compiled)
deno task build:linux    # → dist/SpaceStation-linux-x64.AppImage
```

Cross-compilation works from one machine for every target except `.dmg` (needs macOS `hdiutil`).
Julia itself is **not** bundled — the app finds or asks for it (juliaup bootstrap is future work).

## Known limitations (v1)

- **No app icon yet** — ships with the default Deno icon (`--icon` / `desktop.app.icons` TODO).
- **Unsigned** — macOS builds get an ad-hoc signature; real signing needs `macos.codesignIdentity`
  in `deno.json` + notarization. Windows needs `signtool` post-build.
- **SSH workspace "open" degrades**: the ready-pill's `window.open` is inert in a webview, but the
  pill is a plain link — clicking it navigates the window to the tunneled workspace. The Home
  button returns via the in-place path.
- **Webview quirks untested**: terminal clipboard (`navigator.clipboard`, image paste) and file
  downloads may behave differently in WKWebView/WebView2/WebKitGTK than in Chrome. If rendering
  quirks bite, switch `desktop.backend` to `"cef"` in `deno.json` — bundled Chromium, bigger
  binary, identical rendering everywhere.
- **Julia is not auto-installed** — a friendly error points at julialang.org/downloads.

## Release integration (future)

`deno desktop --all-targets` + a GitHub Actions matrix can attach `.dmg` / `.msi` / `.AppImage`
artifacts to the release-please releases. Deliberately not wired up while this folder is
experimental.
