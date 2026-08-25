// Shared look for the shell's own pages (splash, launch), lifted VERBATIM from the SpaceStation
// frontend so they read as the same product: dark-theme tokens from frontend/themes/dark.css,
// card/pill/heading styles from frontend/land.css, and the planets mark inlined (the shell origin
// can't reach the Julia server's /img assets).

export const logo_svg = /* html */ `<svg xmlns="http://www.w3.org/2000/svg" viewBox="12 5 82 82" width="74" height="74">
  <defs>
    <radialGradient id="st-g" cx="0.36" cy="0.30" r="0.82"><stop offset="0" stop-color="#8fe07d"/><stop offset="0.52" stop-color="#389826"/><stop offset="1" stop-color="#1a5312"/></radialGradient>
    <radialGradient id="st-p" cx="0.36" cy="0.30" r="0.82"><stop offset="0" stop-color="#d3a6e8"/><stop offset="0.52" stop-color="#9558B2"/><stop offset="1" stop-color="#4f2668"/></radialGradient>
    <radialGradient id="st-r" cx="0.36" cy="0.30" r="0.82"><stop offset="0" stop-color="#f79287"/><stop offset="0.52" stop-color="#CB3C33"/><stop offset="1" stop-color="#761a14"/></radialGradient>
    <radialGradient id="st-s" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="#a9c4ff"/><stop offset="1" stop-color="#3f6dff"/></radialGradient>
  </defs>
  <circle cx="36" cy="64" r="20" fill="url(#st-p)" stroke="#4f2668" stroke-width="1.5"/>
  <circle cx="64" cy="64" r="20" fill="url(#st-r)" stroke="#761a14" stroke-width="1.5"/>
  <circle cx="50" cy="42" r="20" fill="url(#st-g)" stroke="#1a5312" stroke-width="1.5"/>
  <path d="M82 17.1 L83.7 24.1 L91 26 L83.7 27.9 L82 34.9 L80.3 27.9 L73 26 L80.3 24.1 Z" fill="url(#st-s)"/>
  <path d="M69 10.8 L69.8 13.9 L73 14.7 L69.8 15.5 L69 18.6 L68.2 15.5 L65 14.7 L68.2 13.9 Z" fill="#8fb4ff"/>
</svg>`

export const base_css = /* css */ `
    :root {
        color-scheme: dark;
        --main-bg-color: hsl(0deg 0% 12%);
        --code-background: hsl(222deg 16% 19%);
        --rule-color: rgba(255, 255, 255, 0.15);
        --pluto-output-color: hsl(0deg 0% 77%);
        --accent: #5e7be1;
    }
    * { box-sizing: border-box; }
    body {
        margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center;
        background-color: var(--main-bg-color); color: var(--pluto-output-color);
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, "Open Sans", "Helvetica Neue", sans-serif;
    }
    /* The window content extends under the (transparent, title-less) native title bar. The deck
       has its tab strip as the grab area, but these shell pages had NOTHING draggable — the
       window could not be moved at all, including to another display. This invisible strip is
       that grab area. */
    .dragbar { position: fixed; top: 0; left: 0; right: 0; height: 28px; -webkit-app-region: drag; }
    .bubble {
        background-color: var(--code-background); border-radius: 0.8rem;
        box-shadow: 0 0 0 1px var(--rule-color), -2px 5px 14px 0px #00000022;
    }
    .card { width: 44rem; max-width: 95vw; max-height: 92vh; overflow-y: auto; padding: 2rem; }
    h1 { margin: 0.6rem 0 0 0; font-size: 2rem; }
    h1 .land-accent { opacity: 0.55; }
    .subtitle { opacity: 0.65; margin: 0.35rem 0 0 0; }
    h2 { font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.09em; opacity: 0.5; margin: 1.4rem 0 0.5rem 0.15rem; font-weight: 600; }
    .pill {
        text-align: left; border: none; color: inherit; font: inherit; font-size: 0.88rem;
        background-color: var(--main-bg-color); border-radius: 1000px; padding: 0.45rem 0.9rem;
        cursor: pointer; display: flex; align-items: center; gap: 0.55rem; width: 100%;
    }
    .pill:hover { box-shadow: inset 0 0 0 1px var(--rule-color); }
    .pill.selected { box-shadow: inset 0 0 0 2px var(--accent); }
    .pill .mono { font-family: JuliaMono, ui-monospace, Menlo, Consolas, monospace; font-size: 0.8rem; opacity: 0.6; }
    .pill .badge { margin-left: auto; font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.07em; opacity: 0.5; }
    .primary {
        font: inherit; font-size: 0.95rem; padding: 0.6rem 1.3rem; border-radius: 1000px; border: none; color: inherit;
        background-color: var(--main-bg-color);
        box-shadow: -2px 4px 9px 0px #00000012, inset 0 0 0 2px var(--accent);
        cursor: pointer; transition: box-shadow 0.08s linear, transform 0.08s linear;
    }
    .primary:hover { box-shadow: -2px 5px 14px 0px #00000026, inset 0 0 0 2px var(--accent); transform: translateY(-1px); }
    .primary:disabled { opacity: 0.4; cursor: default; transform: none; }
`
