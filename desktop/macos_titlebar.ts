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
            msg_ptr_f64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "f64"], result: "pointer" },
            msg_f64: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: "f64" },
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

/** Is the app's window in native fullscreen? (NSWindowStyleMaskFullScreen, 1 << 14.) The deck
 *  asks so it can drop the gap it reserves for the traffic lights, which macOS hides in
 *  fullscreen. False off-macOS — no other platform insets the strip in the first place.
 *
 *  NOTE: this reads the WINDOW'S OWN style bit, which is exactly what it claims to be. The
 *  fullscreen tracking removed earlier tried to detect the auto-hiding titlebar OVERLAY by
 *  geometry, which is what proved unreliable; nothing here depends on the overlay. */
export const is_fullscreen = (): boolean => {
    try {
        let full = false
        each_titled_window((_S, _w, mask) => {
            if ((mask & 0x4000n) !== 0n) full = true
        })
        return full
    } catch {
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

// ---- Native zoom (issue #66) ----
// The WKWebView is the window's contentView. Its `pageZoom` is WebKit's own page zoom — the
// engine reflows the whole page, exactly what ⌘= does in Safari — and `allowsMagnification` turns
// on the native trackpad pinch (a compositor-side magnification WebKit handles itself, so it is
// smooth on any notebook). Both are plain KVC-settable properties, so they ride the same
// main-thread trampoline as the title bar tweaks. Whole-window by nature: the deck strip, the hub
// and the notebook zoom together, like a VS Code or Slack window does.

/** The window's web view, or null when AppKit is unreachable or the view is not a WKWebView. */
const web_view = (): any | null => {
    const S = objc()
    if (S == null) return null
    const cls = (n: string) => S.objc_getClass(cstr(n))
    const sel = (n: string) => S.sel_registerName(cstr(n))
    let found: any = null
    each_titled_window((S2, w) => {
        if (found != null) return
        const view = S2.msg_ptr(w, sel("contentView"))
        if (view === null) return
        found = view
    })
    if (found === null) return null
    // `isKindOfClass:` takes a class argument; check by name instead, which needs no extra symbol
    const name_ptr = S.msg_ptr(S.msg_ptr(found, sel("class")), sel("description"))
    const utf8 = name_ptr === null ? null : S.msg_ptr(name_ptr, sel("UTF8String"))
    const name = utf8 === null ? "" : new Deno.UnsafePointerView(utf8).getCString()
    return name.includes("WKWebView") ? found : null
}

/** Set WebKit's page zoom (1 = 100%). Also drops any trackpad magnification, so ⌘0 and the
 *  zoom steps always land on a plain, reflowed page. Returns false when unavailable. */
export const set_page_zoom = (factor: number): boolean => {
    try {
        const S = objc()
        const view = web_view()
        if (S == null || view == null || !Number.isFinite(factor) || factor <= 0) return false
        const cls = (n: string) => S.objc_getClass(cstr(n))
        const sel = (n: string) => S.sel_registerName(cstr(n))
        const nsstr = (str: string) => S.msg_ptr_buf(cls("NSString"), sel("stringWithUTF8String:"), cstr(str))
        const dict = S.msg_ptr(cls("NSMutableDictionary"), sel("dictionary"))
        const put = (num: unknown, key: string) => S.msg_void_pp(dict, sel("setObject:forKey:"), num, nsstr(key))
        put(S.msg_ptr_f64arg(cls("NSNumber"), sel("numberWithDouble:"), factor), "pageZoom")
        put(S.msg_ptr_f64arg(cls("NSNumber"), sel("numberWithDouble:"), 1), "magnification")
        S.msg_void_ppi8(view, sel("performSelectorOnMainThread:withObject:waitUntilDone:"), sel("setValuesForKeysWithDictionary:"), dict, 1)
        return true
    } catch (e) {
        console.warn("could not set the page zoom:", e)
        return false
    }
}

/** WebKit's current page zoom, or null when unavailable. */
export const get_page_zoom = (): number | null => {
    try {
        const S = objc()
        const view = web_view()
        if (S == null || view == null) return null
        const sel = (n: string) => S.sel_registerName(cstr(n))
        return S.msg_f64(view, sel("pageZoom"))
    } catch {
        return null
    }
}

/** Let the trackpad pinch magnify the page natively (WebKit handles the gesture itself). */
export const enable_magnification = (): boolean => {
    try {
        const S = objc()
        const view = web_view()
        if (S == null || view == null) return false
        const cls = (n: string) => S.objc_getClass(cstr(n))
        const sel = (n: string) => S.sel_registerName(cstr(n))
        const nsstr = (str: string) => S.msg_ptr_buf(cls("NSString"), sel("stringWithUTF8String:"), cstr(str))
        const dict = S.msg_ptr(cls("NSMutableDictionary"), sel("dictionary"))
        S.msg_void_pp(dict, sel("setObject:forKey:"), S.msg_ptr_i64arg(cls("NSNumber"), sel("numberWithLongLong:"), 1n), nsstr("allowsMagnification"))
        S.msg_void_ppi8(view, sel("performSelectorOnMainThread:withObject:waitUntilDone:"), sel("setValuesForKeysWithDictionary:"), dict, 1)
        return true
    } catch (e) {
        console.warn("could not enable trackpad magnification:", e)
        return false
    }
}
