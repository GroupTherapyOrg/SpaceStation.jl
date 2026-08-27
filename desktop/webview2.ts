// Windows only: give WebView2 a user-data folder it is allowed to write to, before the runtime
// creates its first window. main.ts imports this FIRST, for its side effect alone.
//
// WebView2 defaults that folder to `<exe path>.WebView2`, i.e. NEXT TO THE BINARY. Our MSI installs
// into %ProgramFiles%\SpaceStation (deno desktop hard-codes ProgramFiles64Folder with no per-user
// option), and a standard account cannot write there. Creating the WebView2 environment fails, the
// window is never revealed, and nothing treats that as fatal — issue #55, where clicking the app
// repeatedly left five headless SpaceStation.exe processes and, on the first launch after a reboot,
// one dialog reading "Microsoft Edge can't read and write to its data directory:
// C:\Program Files\SpaceStation\SpaceStation.exe.WebView2\EBWebView". Microsoft documents this
// exact case: an unpackaged app in a protected install directory must name its own folder.
//
// WEBVIEW2_USER_DATA_FOLDER is the documented override, read by the statically linked WebView2
// loader inside the app binary. But setting it from here with Deno.env.set is TOO LATE, and that is
// the whole reason this file re-executes instead:
//
//   * The Windows app process IS the laufey WebView2 host — `deno desktop` renames the backend to
//     <AppName>.exe and drops <AppName>.dll (the Deno runtime) beside it.
//   * laufey calls CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, ...) — a NULL
//     userDataFolder, hence the default path.
//   * The runtime creates its initial (hidden) window BEFORE it runs any user JavaScript. So by the
//     time this module's body executes, the environment has already been created — and failed.
//
// An environment variable is only read out of a process's environment block, so the only way to get
// it in front of that first window is for the process to already have it at startup. Hence: set it,
// relaunch ourselves once, and let the child — which starts with the variable in place — be the real
// app. The child skips this branch because the variable is now set, so there is no relaunch loop.
//
// The parent stays alive and waits, rather than exiting immediately: it costs one lightweight
// supervisor process, and in exchange the child's exit code and output propagate normally, which is
// what lets window_smoke.ts and CI see a real pass or failure instead of the parent's cheerful 0.
//
// Nothing here runs off Windows: every other platform keeps its own default.

const KEY = "WEBVIEW2_USER_DATA_FOLDER"

/** Where WebView2 may keep its (large, cache-like, machine-local) profile. LOCALAPPDATA — never
 *  roaming APPDATA, which corporate roaming profiles would try to sync. */
export const webview2_user_data_dir = (): string | null => {
    if (Deno.build.os !== "windows") return null
    const local = Deno.env.get("LOCALAPPDATA")
    if (local != null && local.trim() !== "") return `${local}\\SpaceStation\\WebView2`
    // Falling back to USERPROFILE means RECONSTRUCTING the local-appdata path, not writing to the
    // profile root — %USERPROFILE%\SpaceStation would scatter a cache directory into the user's home
    // folder next to Documents and Desktop. HOME is deliberately not consulted: on Windows it is set
    // only by POSIX-emulation shells and points somewhere unrelated to the real profile.
    const profile = Deno.env.get("USERPROFILE")
    if (profile != null && profile.trim() !== "") return `${profile}\\AppData\\Local\\SpaceStation\\WebView2`
    return null
}

/** True when this process already has a usable folder — i.e. we are the relaunched child, or the
 *  user/admin set one themselves (an explicit setting always wins). */
export const webview2_already_pinned = (): boolean => (Deno.env.get(KEY) ?? "").trim() !== ""

if (Deno.build.os === "windows" && !webview2_already_pinned()) {
    const dir = webview2_user_data_dir()
    if (dir != null) {
        try {
            // Create it ourselves: a path WebView2 cannot create is the entire bug, so fail here —
            // where the reason can be printed — rather than inside a native dialog with no window.
            Deno.mkdirSync(dir, { recursive: true })
            // Deno.Command merges over the inherited environment, so the child gets everything this
            // process has plus the override, present from its very first instruction.
            const child = new Deno.Command(Deno.execPath(), {
                env: { [KEY]: dir },
                stdin: "inherit",
                stdout: "inherit",
                stderr: "inherit",
            }).spawn()
            const status = await child.status
            Deno.exit(status.code)
        } catch (e) {
            // Could not relaunch. Set it anyway and carry on unlaunched-from: the initial window is
            // already lost, but any window created later still gets a writable folder, and the app
            // running degraded beats the app not running at all.
            console.error(`could not relaunch with a writable WebView2 data directory at ${dir}:`, e)
            try {
                Deno.env.set(KEY, dir)
            } catch {
                // nothing further we can do here
            }
        }
    }
}
