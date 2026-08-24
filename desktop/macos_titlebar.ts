// macOS: extend web content under the title bar (Warp-style header) — the one NSWindow bit Deno
// Desktop doesn't expose (NSWindowStyleMaskFullSizeContentView). We set it ourselves through
// libobjc FFI. AppKit is main-thread-only and our JS runs elsewhere (a direct setStyleMask:
// SIGTRAPs), so the mutation rides a pure-ObjC trampoline: build an NSDictionary of property
// values (safe off-main) and performSelectorOnMainThread:@selector(setValuesForKeysWithDictionary:)
// — KVC unboxes the NSNumbers into the scalar setters on the main thread. Verified empirically:
// styleMask reads back 0x800f and the WKWebView (the contentView) fills the whole window frame.

export const extend_under_titlebar = (): boolean => {
    if (Deno.build.os !== "darwin") return false
    try {
        const enc = new TextEncoder()
        const cstr = (s: string) => enc.encode(s + "\0")
        const objc = Deno.dlopen("/usr/lib/libobjc.A.dylib", {
            objc_getClass: { parameters: ["buffer"], result: "pointer" },
            sel_registerName: { parameters: ["buffer"], result: "pointer" },
            msg_ptr: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: "pointer" },
            msg_ptr_buf: { name: "objc_msgSend", parameters: ["pointer", "pointer", "buffer"], result: "pointer" },
            msg_ptr_u64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "u64"], result: "pointer" },
            msg_ptr_i64arg: { name: "objc_msgSend", parameters: ["pointer", "pointer", "i64"], result: "pointer" },
            msg_u64: { name: "objc_msgSend", parameters: ["pointer", "pointer"], result: "u64" },
            msg_void_pp: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer", "pointer"], result: "void" },
            msg_void_ppi8: { name: "objc_msgSend", parameters: ["pointer", "pointer", "pointer", "pointer", "i8"], result: "void" },
        } as const)
        const S = objc.symbols
        const cls = (n: string) => S.objc_getClass(cstr(n))
        const sel = (n: string) => S.sel_registerName(cstr(n))
        const nsstr = (s: string) => S.msg_ptr_buf(cls("NSString"), sel("stringWithUTF8String:"), cstr(s))

        const app = S.msg_ptr(cls("NSApplication"), sel("sharedApplication"))
        const windows = S.msg_ptr(app, sel("windows"))
        const count = S.msg_u64(windows, sel("count"))
        let applied = false
        for (let i = 0n; i < count; i++) {
            const w = S.msg_ptr_u64arg(windows, sel("objectAtIndex:"), i)
            const mask = S.msg_u64(w, sel("styleMask"))
            if ((mask & 1n) === 0n) continue // only titled windows
            const dict = S.msg_ptr(cls("NSMutableDictionary"), sel("dictionary"))
            const put = (num: unknown, key: string) => S.msg_void_pp(dict, sel("setObject:forKey:"), num as any, nsstr(key))
            put(S.msg_ptr_u64arg(cls("NSNumber"), sel("numberWithUnsignedLongLong:"), mask | 0x8000n), "styleMask")
            put(S.msg_ptr_i64arg(cls("NSNumber"), sel("numberWithLongLong:"), 1n), "titlebarAppearsTransparent")
            put(S.msg_ptr_i64arg(cls("NSNumber"), sel("numberWithLongLong:"), 1n), "titleVisibility") // hidden
            S.msg_void_ppi8(w, sel("performSelectorOnMainThread:withObject:waitUntilDone:"), sel("setValuesForKeysWithDictionary:"), dict, 1)
            applied = true
        }
        return applied
    } catch (e) {
        console.warn("could not extend content under the title bar:", e)
        return false
    }
}
