// macOS window plumbing the Deno Desktop API doesn't expose, reached through libobjc FFI.
//
// extend_under_titlebar(): set NSWindowStyleMaskFullSizeContentView so web content extends under
// the title bar (the deck's Warp-style header). AppKit is main-thread-only and our JS runs
// elsewhere (a direct setStyleMask: SIGTRAPs), so the mutation rides a pure-ObjC trampoline:
// build an NSDictionary of property values (safe off-main) and
// performSelectorOnMainThread:@selector(setValuesForKeysWithDictionary:) — KVC unboxes the
// NSNumbers into the scalar setters on the main thread. Verified: styleMask reads back 0x800f and
// the WKWebView (the contentView) fills the whole window frame.

const enc = new TextEncoder()
const cstr = (s: string) => enc.encode(s + "\0")

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
            msg_ptr_parg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer"], result: "pointer" },
            msg_ptr_u64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "u64"], result: "pointer" },
            msg_ptr_i64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "i64"], result: "pointer" },
            msg_u64: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: "u64" },
            msg_void_pp: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer", "pointer"], result: "void" },
            msg_void_ppi8: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer", "pointer", "i8"], result: "void" },
        } as const).symbols
    } catch {
        return null
    }
    return cached
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

/** Pin the whole app to light/dark (or back to following the OS). WKWebView resolves
 *  prefers-color-scheme from the hosting window's effective appearance, so this flips the web
 *  content's theme the same way a real OS dark-mode switch does — a path WebKit repaints
 *  correctly, native scrollbars included. (Rewriting color-scheme purely from CSS inside the
 *  webview left WKWebView with stale scrollbar/compositor state; see the v0.4.2 theme-toggle
 *  regressions.) Set on NSApplication so every current and future window follows. KVC maps
 *  NSNull back to nil, which restores "follow the system". */
export const set_app_appearance = (scheme: "light" | "dark" | "system"): boolean => {
    try {
        const S = objc()
        if (S == null) return false
        const cls = (n: string) => S.objc_getClass(cstr(n))
        const sel = (n: string) => S.sel_registerName(cstr(n))
        const nsstr = (s: string) => S.msg_ptr_buf(cls("NSString"), sel("stringWithUTF8String:"), cstr(s))
        const app = S.msg_ptr(cls("NSApplication"), sel("sharedApplication"))
        const value =
            scheme === "system"
                ? S.msg_ptr(cls("NSNull"), sel("null"))
                : S.msg_ptr_parg(cls("NSAppearance"), sel("appearanceNamed:"), nsstr(scheme === "dark" ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua"))
        // A nil here (AppKit missing, unknown appearance name) must NOT reach setObject:forKey: —
        // that throws an ObjC exception straight through the FFI, killing the process.
        if (app === null || value === null) return false
        const dict = S.msg_ptr(cls("NSMutableDictionary"), sel("dictionary"))
        S.msg_void_pp(dict, sel("setObject:forKey:"), value, nsstr("appearance"))
        S.msg_void_ppi8(app, sel("performSelectorOnMainThread:withObject:waitUntilDone:"), sel("setValuesForKeysWithDictionary:"), dict, 1)
        return true
    } catch (e) {
        console.warn("could not set the app appearance:", e)
        return false
    }
}

/** Start a native window drag. WKWebView swallows every mouse event, so CSS app-region does
 *  nothing in this shell (it is a Chromium feature) and the window had NO way to be moved.
 *  The standard WKWebView-shell workaround: on mousedown in a page's drag area, the page calls
 *  the shell, and the shell hands the in-flight mouse event to performWindowDragWithEvent: —
 *  AppKit then runs the whole native drag session (tracking, spaces, displays) by itself.
 *  currentEvent is read off-main (the JS thread), so the event is retained immediately and
 *  deliberately never released — one leaked NSEvent per drag START is noise, and it removes
 *  any chance of handing AppKit a freed pointer. */
export const begin_window_drag = (): boolean => {
    try {
        const S = objc()
        if (S == null) return false
        const cls = (n: string) => S.objc_getClass(cstr(n))
        const sel = (n: string) => S.sel_registerName(cstr(n))
        const app = S.msg_ptr(cls("NSApplication"), sel("sharedApplication"))
        if (app === null) return false
        const ev = S.msg_ptr(app, sel("currentEvent"))
        if (ev === null) return false
        S.msg_ptr(ev, sel("retain"))
        let started = false
        each_titled_window((S2, w) => {
            S2.msg_void_ppi8(w, sel("performSelectorOnMainThread:withObject:waitUntilDone:"), sel("performWindowDragWithEvent:"), ev, 0)
            started = true
        })
        return started
    } catch (e) {
        console.warn("could not start a window drag:", e)
        return false
    }
}

/** The main display's size in points (CoreGraphics reports the scaled mode's logical size), or
 *  null off-macOS / on failure. Used to clamp the initial window so it cannot open larger than
 *  the screen — the fixed default overflowed smaller displays, cutting off the bottom of every
 *  shell page. Plain C calls, no structs, no AppKit dependency. */
export const main_screen_size = (): { width: number; height: number } | null => {
    if (Deno.build.os !== "darwin") return null
    try {
        const cg = Deno.dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", {
            CGMainDisplayID: { parameters: [], result: "u32" },
            CGDisplayPixelsWide: { parameters: ["u32"], result: "usize" },
            CGDisplayPixelsHigh: { parameters: ["u32"], result: "usize" },
        } as const).symbols
        const id = cg.CGMainDisplayID()
        return { width: Number(cg.CGDisplayPixelsWide(id)), height: Number(cg.CGDisplayPixelsHigh(id)) }
    } catch {
        return null
    }
}

// NOTE: fullscreen-overlay tracking (auto-hiding the deck strip in sync with the native
// fullscreen chrome) was implemented here and deliberately removed: between notch geometry, the
// overlay stealing the mouse, and unrelated helper windows fooling the detection, it broke more
// ways than it worked. The deck keeps its strip always visible instead. See git history.
