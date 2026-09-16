// The deck page is browser JavaScript inside a TypeScript template literal (deck.ts): a backtick in
// a comment, a type annotation, or a single-escaped backslash in a regex all pass `deno check` and
// break only in the webview. This parses every inline <script> with the JS engine.
import { deck_html } from "./deck.ts"

Deno.test("the deck's inline scripts are valid JavaScript", () => {
    const html = deck_html("http://localhost:1234/?secret=x")
    const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1])
    if (scripts.length === 0) throw new Error("no inline script found in the deck page")
    for (const src of scripts) {
        new Function(src) // throws a SyntaxError on anything the browser would reject
    }
})
