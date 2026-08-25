// macOS window plumbing the Deno Desktop API doesn't expose, reached through libobjc FFI.
//
// extend_under_titlebar(): set NSWindowStyleMaskFullSizeContentView so web content extends under
// the title bar (the deck's Warp-style header). AppKit is main-thread-only and our JS runs
// elsewhere (a direct setStyleMask: SIGTRAPs), so the mutation rides a pure-ObjC trampoline:
// build an NSDictionary of property values (safe off-main) and
// performSelectorOnMainThread:@selector(setValuesForKeysWithDictionary:) — KVC unboxes the
// NSNumbers into the scalar setters on the main thread. Verified: styleMask reads back 0x800f and
// the WKWebView (the contentView) fills the whole window frame.
//
// is_fullscreen(): read NSWindowStyleMaskFullScreen. Needed because size heuristics fail on
// notched MacBooks — fullscreen there is screen height MINUS the notch band, indistinguishable
// from a zoomed window. Property reads are safe off the main thread.

const enc = new TextEncoder()
const cstr = (s: string) => enc.encode(s + "\0")

const RECT = { struct: ["f64", "f64", "f64", "f64"] } as const

let cached: any | null = null
const objc = (): any | null => {
    if (cached != null) return cached
    if (Deno.build.os !== "darwin") return null
    try {
        cached = Deno.dlopen("/usr/lib/libobjc.A.dylib", {
            objc_getClass: { parameters: ["buffer"], result: "pointer" },
            sel_registerName: { parameters: ["buffer"], result: "pointer" },
            msg_ptr: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: "pointer" },
            msg_ptr_buf: { name: "objc_msgSend", parameters: ["pointer", "pointer", "buffer"], result: "pointer" },
            msg_ptr_u64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "u64"], result: "pointer" },
            msg_ptr_i64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "i64"], result: "pointer" },
            msg_u64: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: "u64" },
            msg_rect: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: RECT },
            msg_void_pp: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer", "pointer"], result: "void" },
            msg_void_ppi8: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer", "pointer", "i8"], result: "void" },
        } as const).symbols
    } catch {
        return null
    }
    return cached
}

const frame_of = (S: any, w: any): [number, number, number, number] => {
    const sel = (n: string) => S.sel_registerName(cstr(n))
    const buf = S.msg_rect(w, sel("frame")) as Uint8Array
    const r = new Float64Array(buf.buffer, 0, 4)
    return [r[0], r[1], r[2], r[3]] // x, y (bottom-left origin), width, height
}

/** Run `body(S, w)` for every titled NSWindow; returns false when AppKit is unreachable. */
const each_titled_window = (body: (S: any, w: any, mask: bigint) => void): boolean => {
    const S = objc()
    if (S == null) return false
    const cls = (n: string) => S.objc_getClass(cstr(n))
    const sel = (n: string) => S.sel_registerName(cstr(n))
    const app = S.msg_ptr(cls("NSApplication"), sel("sharedApplication"))
    const windows = S.msg_ptr(app, sel("windows"))
    const count = S.msg_u64(windows, sel("count"))
    for (let i = 0n; i < count; i++) {
        const w = S.msg_ptr_u64arg(windows, sel("objectAtIndex:"), i)
        const mask = S.msg_u64(w, sel("styleMask"))
        if ((mask & 1n) === 0n) continue // not titled
        body(S, w, mask)
    }
    return true
}

export const extend_under_titlebar = (): boolean => {
    try {
        let applied = false
        const ok = each_titled_window((S, w, mask) => {
            const cls = (n: string) => S.objc_getClass(cstr(n))
            const sel = (n: string) => S.sel_registerName(cstr(n))
            const nsstr = (s: string) => S.msg_ptr_buf(cls("NSString"), sel("stringWithUTF8String:"), cstr(s))
            const dict = S.msg_ptr(cls("NSMutableDictionary"), sel("dictionary"))
            const put = (num: unknown, key: string) => S.msg_void_pp(dict, sel("setObject:forKey:"), num, nsstr(key))
            put(S.msg_ptr_u64arg(cls("NSNumber"), sel("numberWithUnsignedLongLong:"), mask | 0x8000n), "styleMask")
            put(S.msg_ptr_i64arg(cls("NSNumber"), sel("numberWithLongLong:"), 1n), "titlebarAppearsTransparent")
            put(S.msg_ptr_i64arg(cls("NSNumber"), sel("numberWithLongLong:"), 1n), "titleVisibility") // hidden
            S.msg_void_ppi8(w, sel("performSelectorOnMainThread:withObject:waitUntilDone:"), sel("setValuesForKeysWithDictionary:"), dict, 1)
            applied = true
        })
        return ok && applied
    } catch (e) {
        console.warn("could not extend content under the title bar:", e)
        return false
    }
}

/** Fullscreen state, plus how far the NATIVE fullscreen overlay (menu bar + title-bar band that
 *  slides down on hover at the screen top) currently covers our window, in px from our top.
 *  The overlay is a separate borderless, full-width system window stacked over ours; its frame
 *  tells us both whether it's out and how deep — so the deck can reveal its tab strip WITH the
 *  native chrome, sitting right below it, instead of the two acting as disconnected reveals. */
export const fullscreen_state = (): { fullscreen: boolean; overlay_px: number } => {
    try {
        const S = objc()
        if (S == null) return { fullscreen: false, overlay_px: 0 }
        const cls = (n: string) => S.objc_getClass(cstr(n))
        const sel = (n: string) => S.sel_registerName(cstr(n))
        const app = S.msg_ptr(cls("NSApplication"), sel("sharedApplication"))
        const windows = S.msg_ptr(app, sel("windows"))
        const count = S.msg_u64(windows, sel("count"))
        let main: any = null
        let fullscreen = false
        for (let i = 0n; i < count; i++) {
            const w = S.msg_ptr_u64arg(windows, sel("objectAtIndex:"), i)
            const mask = S.msg_u64(w, sel("styleMask"))
            if ((mask & 1n) === 0n) continue
            main = w
            fullscreen = (mask & 0x4000n) !== 0n // NSWindowStyleMaskFullScreen
            break
        }
        if (main == null || !fullscreen) return { fullscreen, overlay_px: 0 }
        const [, my, mw, mh] = frame_of(S, main)
        const win_top = my + mh
        let overlay_px = 0
        for (let i = 0n; i < count; i++) {
            const w = S.msg_ptr_u64arg(windows, sel("objectAtIndex:"), i)
            if (w === main) continue
            const mask = S.msg_u64(w, sel("styleMask"))
            if ((mask & 1n) !== 0n) continue // overlay is borderless
            if ((S.msg_u64(w, sel("isVisible")) & 1n) === 0n) continue
            const [, y, w_w] = frame_of(S, w)
            if (w_w < mw - 1) continue // overlay spans the full width
            const covered = win_top - y // how far its bottom edge reaches into our window
            if (covered > 0 && covered < 300) overlay_px = Math.max(overlay_px, Math.round(covered))
        }
        return { fullscreen: true, overlay_px }
    } catch {
        return { fullscreen: false, overlay_px: 0 }
    }
}
