// Windows only: give the running window the SpaceStation icon (issue #63).
//
// `deno desktop` 2.9 embeds no icon resource into the .exe it packages — verified back in the #55
// work: the binary is byte-identical with and without the icon configuration — so the taskbar,
// Alt-Tab and the window caption all fall back to Windows' generic executable icon. Until the
// packager learns to do it at build time, do it at runtime: load the .ico and hand it to the
// window via WM_SETICON, the same call every Win32 app makes. The taskbar follows immediately.
// (The Start Menu shortcut and Add/Remove Programs entry can't be fixed from here — those live in
// the installer, which stamp_msi.vbs now handles with an Icon table entry.)
//
// Nothing here runs off Windows; every failure is caught and reported as a status string rather
// than thrown — a missing icon must never take down the app.

import { data_dir } from "./julia.ts"

const WM_SETICON = 0x0080
const ICON_SMALL = 0n
const ICON_BIG = 1n
const IMAGE_ICON = 1
const LR_LOADFROMFILE = 0x0010
const LR_DEFAULTSIZE = 0x0040

/** UTF-16LE with a NUL terminator — charCodeAt yields UTF-16 code units directly, surrogate
 *  pairs included, so non-ASCII profile paths survive. */
const wide = (s: string): Uint8Array => {
    const out = new Uint8Array((s.length + 1) * 2)
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i)
        out[i * 2] = c & 0xff
        out[i * 2 + 1] = c >> 8
    }
    return out
}

/** LoadImageW needs a real file. The .ico ships inside the compiled binary's VFS (--include
 *  icons), or sits in the checkout during dev — materialize it once into the app-data dir, the
 *  same pattern vendored_bin_dir uses for juliaup. */
const materialize_ico = (): string => {
    const path = `${data_dir()}\\spacestation.ico`
    try {
        Deno.statSync(path)
        return path
    } catch {
        // not there yet
    }
    const bytes = Deno.readFileSync(new URL("./icons/spacestation.ico", import.meta.url))
    Deno.mkdirSync(data_dir(), { recursive: true })
    Deno.writeFileSync(path, bytes)
    return path
}

/** Set the window's big+small icons. Returns a status string for logging/assertion: "set" on
 *  success, "skipped: not windows" off-platform, otherwise what went wrong. */
export const set_windows_window_icon = async (win: unknown, window_title: string): Promise<string> => {
    if (Deno.build.os !== "windows") return "skipped: not windows"
    try {
        const ico_path = materialize_ico()
        const user32 = Deno.dlopen("user32.dll", {
            FindWindowW: { parameters: ["buffer", "buffer"], result: "pointer" },
            LoadImageW: { parameters: ["pointer", "buffer", "u32", "i32", "i32", "u32"], result: "pointer" },
            SendMessageW: { parameters: ["pointer", "u32", "u64", "pointer"], result: "isize" },
        })
        try {
            // The window handle: laufey's getNativeWindow when it answers usefully, otherwise find
            // the window by its (known, we set it) title. Retry briefly — the native window may
            // trail the constructor by a beat.
            let hwnd: Deno.PointerValue = null
            for (let attempt = 0; attempt < 4 && hwnd == null; attempt++) {
                if (attempt > 0) await new Promise((r) => setTimeout(r, 1500))
                try {
                    const raw = (win as any)?.getNativeWindow?.()
                    if (typeof raw === "bigint" || typeof raw === "number") hwnd = Deno.UnsafePointer.create(BigInt(raw))
                } catch {
                    // fall through to FindWindowW
                }
                hwnd ??= user32.symbols.FindWindowW(null, wide(window_title))
            }
            if (hwnd == null) return `failed: no window handle for title ${JSON.stringify(window_title)}`

            const big = user32.symbols.LoadImageW(null, wide(ico_path), IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE)
            if (big == null) return `failed: LoadImageW could not load ${ico_path}`
            // Small: let Windows scale from the same file at its preferred small size.
            const small = user32.symbols.LoadImageW(null, wide(ico_path), IMAGE_ICON, 16, 16, LR_LOADFROMFILE)
            user32.symbols.SendMessageW(hwnd, WM_SETICON, ICON_BIG, big)
            user32.symbols.SendMessageW(hwnd, WM_SETICON, ICON_SMALL, small ?? big)
            return "set"
        } finally {
            // The HICONs must outlive this call (the window keeps using them), but the library
            // handle itself is done. NOT closing user32 would also be fine; being tidy is free.
            user32.close()
        }
    } catch (e) {
        return `failed: ${e}`
    }
}
