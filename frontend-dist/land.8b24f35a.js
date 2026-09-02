import"./frontend.4d03b972.js";var e=globalThis,t={},n={},a=e.parcelRequire94c2;null==a&&((a=function(e){if(e in t)return t[e].exports;if(e in n){var a=n[e];delete n[e];var l={id:e,exports:{}};return t[e]=l,a.call(l.exports,l,l.exports),l.exports}var o=Error("Cannot find module '"+e+"'");throw o.code="MODULE_NOT_FOUND",o}).register=function(e,t){n[e]=t},e.parcelRequire94c2=a);var l=a.register;l("5IQaQ",function(e,t){navigator.platform.toUpperCase().includes("MAC")&&window.top!==window&&fetch("./api/v1/config").then(e=>e.json()).then(e=>{e?.desktop===!0&&window.addEventListener("keydown",e=>{if(!e.metaKey||e.ctrlKey||e.altKey)return;let t="Equal"===e.code||"+"===e.key||"="===e.key?"in":"Minus"===e.code||"-"===e.key?"out":"Digit0"===e.code||"0"===e.key?"reset":null;if(null!=t){e.preventDefault(),e.stopPropagation();try{window.top?.postMessage({type:"spacestation:zoom",action:t},"*")}catch{}}},{capture:!0})}).catch(()=>{})}),l("hmt3d",function(e,t){e.exports=Promise.all([import("a4Bpq"),import("iJpDL")]).then(()=>a("bnHn0"))}),l("aDKOm",function(e,t){e.exports=import("hmOBl").then(()=>a("bJtX0"))}),l("iCed3",function(e,t){e.exports=import("aZARi").then(()=>a("hiQgq"))});var o=a("cNaMA"),r=a("6ha54"),i=a("aLlws");a("5IQaQ");let s=async(e,t)=>{let n=await fetch(e,t);if(!n.ok)throw Error(`${e} \u{2192} ${n.status}`);return await n.text()},c=async(e,t)=>{let n=await fetch(e,t);if(!n.ok)throw Error(`${e} \u{2192} ${n.status}`);return await n.json()},u=e=>(e.split("/").pop()??"").split("\\").pop()??"",d=(e,{action:t="Confirm",danger:n=!1}={})=>new Promise(a=>{let l=document.createElement("dialog");l.className="land-confirm";let o=document.createElement("p");o.textContent=e;let r=document.createElement("div");r.className="buttons";let i=document.createElement("button");i.textContent="Cancel";let s=document.createElement("button");s.textContent=t,s.className=`go ${n?"danger":""}`,r.append(i,s),l.append(o,r),document.body.append(l);let c=e=>{l.close(),l.remove(),a(e)};i.onclick=()=>c(!1),s.onclick=()=>c(!0),l.oncancel=e=>{e.preventDefault(),c(!1)},l.onclick=e=>e.target===l&&c(!1),l.showModal(),i.focus()}),p="spacestation-homebase",h=(()=>{try{return window.self!==window.top}catch(e){return!0}})(),m=h||new URLSearchParams(window.location.search).has("desktop"),b=({classname:e})=>{let[t,n]=(0,o.useState)((0,i.get_color_scheme)());return(0,o.html)`<button
        class="app-scheme-toggle ${e??""}"
        title=${"system"===t?"Appearance: follow the system — switch to light":"light"===t?"Appearance: light — switch to dark":"Appearance: dark — follow the system"}
        aria-label="Toggle light/dark appearance"
        onClick=${()=>{let e=(0,i.cycle_color_scheme)();n(e),f({type:"spacestation:color-scheme",scheme:e})}}
    >
        ${"system"===t?"◐":"light"===t?"☀":"☾"}
    </button>`},f=e=>{try{window.parent.postMessage(e,"*")}catch(e){}},g=new URL(import.meta.resolve("gx1Fc")).href,v="spacestation recent workspaces",w=()=>{try{let e=JSON.parse(localStorage.getItem(v)??"[]");return Array.isArray(e)?e:[]}catch{return[]}},$=e=>{localStorage.setItem(v,JSON.stringify([e,...w().filter(t=>t!==e)].slice(0,8)))},y="spacestation terminals by workspace",k="spacestation terminals",S="spacestation ssh connect timeout",C=e=>Math.max(3,Math.min(180,Math.round(Number(e)||25))),_=()=>{let e=Number(localStorage.getItem(S));return Number.isFinite(e)&&e>=3?C(e):25},E=({entry:e,listings:t,expanded:n,on_toggle:a,on_open_notebook:l,on_open_file:r,on_create_in:i,on_delete:s,depth:c})=>{if("dir"===e.type){let u=n.has(e.path),d=t[e.path];return(0,o.html)`<li class="dir ${u?"open":""}">
            <div class="entry-row">
                <button class="entry" onClick=${()=>a(e.path)}><span class="icon chevron"></span>${e.name}</button>
                <button class="row-action" title="New notebook or file in ${e.name}/" onClick=${()=>i(e.path)}>+</button>
            </div>
            ${u?(0,o.html)`<ul>
                      ${null==d?(0,o.html)`<li class="pending">
                                <div class="entry-row"><span class="entry plain">reading…</span></div>
                            </li>`:d.map(e=>(0,o.html)`<${E}
                                        key=${e.path}
                                        entry=${e}
                                        listings=${t}
                                        expanded=${n}
                                        on_toggle=${a}
                                        on_open_notebook=${l}
                                        on_open_file=${r}
                                        on_create_in=${i}
                                        on_delete=${s}
                                        depth=${c+1}
                                    />`)}
                  </ul>`:null}
        </li>`}if("truncated"===e.type)return(0,o.html)`<li class="truncated">
            <div class="entry-row">
                <span
                    class="entry plain"
                    title="This folder has more entries than SpaceStation lists in one go. Use the terminal to see the rest."
                    >… not listed</span
                >
            </div>
        </li>`;if("unreadable"===e.type)return(0,o.html)`<li class="truncated">
            <div class="entry-row"><span class="entry plain" title=${e.detail??""}>… could not be read</span></div>
        </li>`;let u="notebook"===e.type;return(0,o.html)`<li class=${u?"notebook":"file"}>
        <div class="entry-row">
            <button
                class="entry ${u?"":"quiet"}"
                title=${e.path}
                onClick=${()=>u?l(e.path):r(e.path)}
            >
                <span class="icon ${u?"pluto-dot":""}"></span>${e.name}
            </button>
            <button class="row-action danger" title="Delete ${e.name}" onClick=${()=>s(e)}>✕</button>
        </div>
    </li>`},R=({on_cancel:e,tunneled:t,desktop:n})=>{let a=(0,o.useRef)(n);a.current=n;let l=e=>a.current?`${e}${e.includes("?")?"&":"?"}desktop=1`:e,r=e=>{let t,n;return null==(n=l("system"===(t=(0,i.get_color_scheme)())?e:`${e}${e.includes("?")?"&":"?"}scheme=${t}`))?n:`${n}#homebase=${encodeURIComponent(window.location.origin+window.location.pathname+window.location.search)}`},s=n?"_self":"_blank",p=(e,t)=>f({type:"spacestation:open-workspace",url:l(e),title:t}),[h,m]=(0,o.useState)(null),[v,y]=(0,o.useState)(null),[k,E]=(0,o.useState)([]),[R,I]=(0,o.useState)(_),[T,O]=(0,o.useState)({}),[L,P]=(0,o.useState)({}),[x,U]=(0,o.useState)([]),N=(0,o.useRef)(new Set),A=(0,o.useRef)(new Set),D=(0,o.useCallback)(()=>c("./api/v1/ssh_hosts").then(E).catch(()=>{}),[]);(0,o.useEffect)(()=>{D()},[D]),(0,o.useEffect)(()=>{localStorage.setItem(S,String(R)),fetch(`./api/v1/remote/config?connect_timeout=${encodeURIComponent(R)}`,{method:"POST"}).catch(()=>{})},[R]);let K=(0,o.useCallback)(async e=>{N.current.delete(e);try{let t=await c(`./api/v1/remote/open?host=${encodeURIComponent(e)}`,{method:"POST"});for(O(n=>({...n,[e]:t}));"ready"!==t.state&&"error"!==t.state;){if(await new Promise(e=>setTimeout(e,1500)),N.current.has(e))return;t=await c(`./api/v1/remote/status?host=${encodeURIComponent(e)}`),O(n=>({...n,[e]:t}))}"ready"===t.state&&null!=t.url&&(a.current?p(t.url,e):window.open(r(t.url),"_blank"))}catch(t){if(N.current.has(e))return;O(n=>({...n,[e]:{state:"error",detail:String(t),url:null}}))}},[]),M=(0,o.useCallback)(async e=>{N.current.add(e);try{await fetch(`./api/v1/remote/cancel?host=${encodeURIComponent(e)}`,{method:"POST"})}catch(e){}O(t=>{let n={...t};return delete n[e],n}),U(t=>t.filter(t=>"remote"!==t.kind||t.host!==e))},[]),j=(0,o.useCallback)(async e=>{A.current.delete(e);try{let t=await c(`./api/v1/local/open?path=${encodeURIComponent(e)}`,{method:"POST"});for(P(n=>({...n,[e]:t}));"ready"!==t.state&&"error"!==t.state;){if(await new Promise(e=>setTimeout(e,1e3)),A.current.has(e))return;t=await c(`./api/v1/local/status?path=${encodeURIComponent(e)}`),P(n=>({...n,[e]:t}))}"ready"===t.state&&null!=t.url&&($(e),a.current?p(t.url,u(e)||e):window.open(r(t.url),"_blank"))}catch(t){if(A.current.has(e))return;P(n=>({...n,[e]:{state:"error",detail:String(t),url:null}}))}},[]),H=(0,o.useCallback)(async e=>{A.current.add(e);try{await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(e)}`,{method:"POST"})}catch(e){}P(t=>{let n={...t};return delete n[e],n}),U(t=>t.filter(t=>"local"!==t.kind||t.path!==e))},[]),W=(0,o.useCallback)(async e=>{if(await d(`Shut down the workspace server for ${u(e)}?

Its running notebooks will stop. Files stay on disk and outputs are cached in their .pluto-cache.toml sidecars, so reopening restores everything.`,{action:"Shut down"})){try{await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(e)}`,{method:"POST"})}catch(e){}P(t=>{let n={...t};return delete n[e],n}),U(t=>t.filter(t=>"local"!==t.kind||t.path!==e))}},[]),z=(0,o.useCallback)(async e=>{if(!t)return j(e);try{await c(`./api/v1/workspace/open?path=${encodeURIComponent(e)}`,{method:"POST"}),$(e),window.location.reload()}catch(e){y(String(e))}},[t,j]),B=(0,o.useCallback)(e=>"remote"===e.kind?M(e.host):"ready"===e.state?W(e.path):H(e.path),[M,W,H]);(0,o.useEffect)(()=>{let e=!0,t=async()=>{let[t,n]=await Promise.all([c("./api/v1/local/list").catch(()=>[]),c("./api/v1/remote/list").catch(()=>[])]);e&&U([...t.map(e=>({kind:"local",key:`local:${e.path}`,name:u(e.path)||e.path,sub:e.path,state:e.state,url:e.url,path:e.path})),...n.map(e=>({kind:"remote",key:`remote:${e.host}`,name:e.host,sub:"SSH remote",state:e.state,url:e.url,host:e.host}))])};t();let n=setInterval(t,3e3);return()=>{e=!1,clearInterval(n)}},[]);let F=(0,o.useRef)(null),J=(0,o.useCallback)(async e=>{F.current=e;try{m(await c(null==e?"./api/v1/browse":`./api/v1/browse?path=${encodeURIComponent(e)}`)),y(null)}catch(e){y(String(e))}},[]);(0,o.useEffect)(()=>{J(null)},[]);let[q,Y]=(0,o.useState)(!1),Q=(0,o.useCallback)(async()=>{Y(!0);try{await Promise.all([D(),J(F.current)])}finally{setTimeout(()=>Y(!1),400)}},[D,J]);(0,o.useEffect)(()=>{let e=()=>{"visible"===document.visibilityState&&Q()};window.addEventListener("focus",e),document.addEventListener("visibilitychange",e);let t=setInterval(()=>{"visible"===document.visibilityState&&Q()},1e4);return()=>{window.removeEventListener("focus",e),document.removeEventListener("visibilitychange",e),clearInterval(t)}},[Q]);let V=(0,o.html)`<button
        class="row-action h2-action refresh ${q?"spinning":""}"
        title="Refresh: re-read the folders on disk and the hosts in ~/.ssh/config"
        aria-label="Refresh"
        onClick=${()=>void Q()}
    >
        <span class="refresh-icon"></span>
    </button>`,X=w(),G=h?.crumbs??[];return(0,o.html)`<div class="workspace-opener">
        <div class="bubble opener-card">
            <header>
                <img class="land-logo opener-logo" src=${g} alt="SpaceStation" />
                <h1>Space<span class="land-accent">Station</span></h1>
                <p class="subtitle">Open a folder as your workspace — notebooks inside it open as tabs.</p>
                <${b} classname=${null==e?"opener-corner":"opener-corner beside-cancel"} />
                ${null==e?null:(0,o.html)`<button class="opener-cancel" title="Close — back to your workspace" onClick=${e}><span class="opener-cancel-icon"></span></button>`}
            </header>

            ${!t&&x.length>0?(0,o.html)`<section>
                      <h2>Running Workspaces</h2>
                      <div class="recent-grid">
                          ${x.map(e=>(0,o.html)`<div class="recent-card running-card ${"ready"===e.state?"":"running-busy"}" key=${e.key}>
                                  ${null!=e.url?(0,o.html)`<a
                                            class="running-open"
                                            href=${r(e.url)}
                                            target=${s}
                                            rel="opener"
                                            title=${`Open ${e.name}`}
                                            onClick=${n?t=>{t.preventDefault(),p(e.url,e.name)}:void 0}
                                        >
                                            <span class="recent-icon">${"remote"===e.kind?"🛰":"🗂"}</span>
                                            <span class="recent-name">${e.name}</span>
                                            <span class="recent-path">${e.sub}</span>
                                        </a>`:(0,o.html)`<div class="running-open is-busy">
                                            <span class="recent-icon">${"remote"===e.kind?"🛰":"🗂"}</span>
                                            <span class="recent-name">${e.name}</span>
                                            <span class="recent-path">${e.state}…</span>
                                        </div>`}
                                  <button
                                      class="running-shutdown"
                                      title=${"error"===e.state?"Dismiss":"ready"!==e.state?"Cancel":"remote"===e.kind?"Disconnect":"Shut down this workspace"}
                                      onClick=${()=>B(e)}
                                  >
                                      ✕
                                  </button>
                              </div>`)}
                      </div>
                  </section>`:null}

            ${X.length>0?(0,o.html)`<section>
                      <h2>Recent</h2>
                      <div class="recent-grid">
                          ${X.map(e=>(0,o.html)`<button class="recent-card" title=${e} onClick=${()=>z(e)}>
                                  <span class="recent-icon">🗂</span>
                                  <span class="recent-name">${u(e)}</span>
                                  <span class="recent-path">${e}</span>
                              </button>`)}
                      </div>
                  </section>`:null}

            <section>
                <h2>Browse ${V}</h2>
                ${null==h?(0,o.html)`<p class="subtitle">loading…</p>`:(0,o.html)`
                          <nav class="breadcrumbs">
                              ${G.map((e,t)=>(0,o.html)`<button
                                          class="crumb ${t===G.length-1?"current":""}"
                                          onClick=${()=>J(e.path)}
                                          title=${e.path}
                                      >
                                          ${e.name}</button
                                      >${t>0&&t<G.length-1?(0,o.html)`<span class="crumb-sep">/</span>`:null}`)}
                          </nav>
                          <div class="dir-grid">
                              ${h.entries.map(e=>(0,o.html)`<button class="dir-pill" title=${e.path} onClick=${()=>J(e.path)}>
                                      <span class="dir-icon">📁</span>${e.name}
                                  </button>`)}
                              ${0===h.entries.length?(0,o.html)`<p class="subtitle">no subfolders</p>`:null}
                          </div>
                          <div class="opener-actions">
                              <button class="open-this-folder" onClick=${()=>z(h.path)}>
                                  Open <strong>${u(h.path)||"/"}</strong> as workspace
                              </button>
                              <form
                                  class="paste-path"
                                  onSubmit=${e=>{e.preventDefault();let t=e.target.elements.path.value.trim();""!==t&&J(t)}}
                              >
                                  <input name="path" type="text" placeholder="…or paste a folder path and press Enter" autocomplete="off" />
                              </form>
                          </div>
                      `}
            </section>
            ${!t&&k.length>0?(0,o.html)`<section>
                      <h2>SSH Remotes ${V}</h2>
                      <p class="subtitle small">
                          Click a host: the whole Land (files, kernels, terminal) runs on that machine over an SSH tunnel. First contact installs the
                          server there; after that it reconnects instantly.
                      </p>
                      <label
                          class="ssh-timeout"
                          title="How long to wait for an SSH connection — including the banner from a slow ProxyJump login node — before giving up."
                      >
                          Connection timeout
                          <input
                              type="number"
                              min="3"
                              max="180"
                              step="1"
                              value=${R}
                              onChange=${e=>I(C(e.target.value))}
                          />
                          <span class="unit">s</span>
                          <span class="ssh-timeout-hint">Raise this if a host fails with “timed out reaching … slow SSH hop”.</span>
                      </label>
                      <div class="dir-grid">
                          ${k.map(e=>{let t=T[e],a=null!=t&&"ready"!==t.state&&"error"!==t.state;return t?.state==="ready"&&null!=t.url?(0,o.html)`<a
                                        class="dir-pill remote-ready"
                                        href=${r(t.url)}
                                        target=${s}
                                        rel="opener"
                                        title=${t.detail}
                                        onClick=${n?n=>{n.preventDefault(),p(t.url,e)}:void 0}
                                    >
                                        <span class="dir-icon">🛰</span>${e} →
                                    </a>`:(0,o.html)`<button
                                        class="dir-pill ${a?"remote-busy":""} ${t?.state==="error"?"remote-error":""}"
                                        title=${t?.detail??`Open a workspace on ${e}`}
                                        onClick=${()=>K(e)}
                                    >
                                        <span class="dir-icon">🛰</span>${a?`${e}: ${t.state}\u{2026}`:t?.state==="error"?`${e}: failed (retry)`:e}
                                    </button>`})}
                      </div>
                      ${Object.entries(T).filter(([e,t])=>"ready"!==t.state&&"error"!==t.state).map(([e,t])=>(0,o.html)`<div class="remote-progress" key=${e}>
                                  <span class="remote-spinner"></span>
                                  <div class="remote-progress-text">
                                      <strong>Connecting to ${e} — ${t.state}</strong>
                                      <span>${t.detail}</span>
                                      ${"installing"===t.state?(0,o.html)`<span class="remote-progress-note">First-time setup compiles a lot of Julia — this is the slow step. Leave this page open; it will connect by itself.</span>`:null}
                                  </div>
                                  <button class="remote-cancel" title="Cancel this connection" onClick=${()=>M(e)}>Cancel</button>
                              </div>`)}
                      ${Object.values(T).some(e=>"error"===e.state)?(0,o.html)`<p class="opener-error">${Object.entries(T).filter(([e,t])=>"error"===t.state).map(([e,t])=>`${e}: ${t.detail}`).join(" · ")}</p>`:null}
                  </section>`:null}
            ${Object.entries(L).filter(([e,t])=>"ready"!==t.state&&"error"!==t.state).map(([e,t])=>(0,o.html)`<div class="remote-progress" key=${e}>
                        <span class="remote-spinner"></span>
                        <div class="remote-progress-text">
                            <strong>Starting ${u(e)} — ${t.state}</strong>
                            <span>${t.detail}</span>
                        </div>
                        <button class="remote-cancel" title="Cancel this launch" onClick=${()=>H(e)}>Cancel</button>
                    </div>`)}
            ${Object.values(L).some(e=>"error"===e.state)?(0,o.html)`<p class="opener-error">
                      ${Object.entries(L).filter(([e,t])=>"error"===t.state).map(([e,t])=>`${u(e)}: ${t.detail}`).join(" · ")}
                  </p>`:null}
            ${null==v?null:(0,o.html)`<p class="opener-error">${v}</p>`}
        </div>
    </div>`},I=e=>{let t=getComputedStyle(document.documentElement),n=(e,n)=>t.getPropertyValue(e).trim()||n;return"light"===e?{background:n("--terminal-light-bg","#fbfbfb"),foreground:n("--terminal-light-fg","#24292f"),cursor:"#24292f",cursorAccent:"#fbfbfb",selectionBackground:"#b4d5fe",black:"#24292f",red:"#cf222e",green:"#116329",yellow:"#4d2d00",blue:"#0969da",magenta:"#8250df",cyan:"#1b7c83",white:"#6e7781",brightBlack:"#57606a",brightRed:"#a40e26",brightGreen:"#1a7f37",brightYellow:"#633c01",brightBlue:"#218bff",brightMagenta:"#a475f9",brightCyan:"#3192aa",brightWhite:"#8c959f"}:{background:n("--terminal-bg","#1f1f1f"),foreground:n("--terminal-fg","#dddddd")}},T=({tid:e,cwd:t,visible:n,scheme:l,notebook_env:r})=>{let i=(0,o.useRef)(null),s=(0,o.useRef)(!1),u=(0,o.useRef)(null),d=(0,o.useRef)(null),p=(0,o.useRef)(null),h=(0,o.useRef)(null),m=(0,o.useRef)(null),b=(0,o.useRef)(null),f=(0,o.useRef)(null),g=(0,o.useRef)(l);(0,o.useEffect)(()=>{if(g.current=l,null!=m.current)try{m.current.options.theme=I(l)}catch{}},[l]);let v=(0,o.useCallback)(()=>{clearTimeout(d.current),d.current=setTimeout(()=>{let e=i.current,t=u.current;if(null==e||null==t||null===e.offsetParent||e.clientWidth<24||e.clientHeight<24)return;try{t.fit()}catch{}let n=m.current;if(null!=n)try{let e=p.current;if(p.current=null,null!=e){let t=n.buffer.active;e<=0?n.scrollToBottom():n.scrollLines(Math.max(0,t.baseY-e)-t.viewportY)}n._core?.viewport?.syncScrollArea?.(!0),n.refresh(0,n.rows-1)}catch{}},120)},[]);return(0,o.useEffect)(()=>{if(!n){let e=m.current;if(null!=e)try{p.current=e.buffer.active.baseY-e.buffer.active.viewportY}catch{}return}s.current?v():null!=i.current&&(s.current=!0,(async()=>{let[{Terminal:n},{FitAddon:l},o]=await Promise.all([a("hmt3d"),a("aDKOm"),c("./api/v1/config").catch(()=>null)]),s=new n({fontSize:13,fontFamily:"JuliaMono, SFMono-Regular, Menlo, Consolas, monospace",cursorBlink:!0,scrollback:5e3,...o?.windows?{windowsPty:{backend:"conpty"}}:{},theme:I(g.current)}),d=new l;if(s.loadAddon(d),u.current=d,m.current=s,null==i.current){try{s.dispose()}catch{}m.current=null;return}s.open(i.current);let p=null;s.attachCustomKeyEventHandler(e=>"keydown"!==e.type||!((e.metaKey||e.ctrlKey)&&("c"===e.key||"C"===e.key)&&s.hasSelection())||(navigator.clipboard?.writeText(s.getSelection()).catch(()=>{}),!1));let w=async e=>{let t=Array.from(e.clipboardData?.items??[]).find(e=>e.type?.startsWith("image/")),n=t?.getAsFile()??Array.from(e.clipboardData?.files??[]).find(e=>e.type?.startsWith("image/"));if(null!=n){e.preventDefault(),e.stopPropagation();try{let e=new Uint8Array(await n.arrayBuffer()),t="";for(let n=0;n<e.length;n+=32768)t+=String.fromCharCode.apply(null,e.subarray(n,n+32768));let a=n.type.split("/")[1]||"png";p?.readyState===WebSocket.OPEN&&p.send(`2:${a}:${btoa(t)}`)}catch{}}};s.element?.addEventListener("paste",w,{capture:!0}),f.current=()=>s.element?.removeEventListener("paste",w,{capture:!0});try{await document.fonts?.ready}catch{}if(null!=i.current&&null!==i.current.offsetParent&&i.current.clientWidth>=24&&i.current.clientHeight>=24)try{d.fit()}catch{}v();let $="https:"===window.location.protocol?"wss":"ws",y=t?`&cwd=${encodeURIComponent(t)}`:"",k=`&rows=${s.rows}&cols=${s.cols}`,S=r?`&notebook_env=${encodeURIComponent(r)}`:"";h.current=p=new WebSocket(`${$}://${window.location.host}/terminal?tid=${e}${y}${k}${S}`),p.binaryType="arraybuffer",p.onmessage=e=>{if("string"!=typeof e.data)return void s.write(new Uint8Array(e.data));let t=null;try{t=JSON.parse(e.data)}catch{}if(null!=t){if(Number.isFinite(t.rows)&&Number.isFinite(t.cols)&&(s.rows!==t.rows||s.cols!==t.cols))try{s.resize(t.cols,t.rows)}catch{}t.replayed&&(()=>{let e=i.current;if(null!=e&&null!==e.offsetParent&&e.clientWidth>=24&&e.clientHeight>=24)try{d.fit()}catch{}p?.readyState===WebSocket.OPEN&&p.send(`1:${s.rows},${s.cols}`)})()}},p.onopen=()=>v(),p.onclose=()=>s.write("\r\n\x1b[2m[disconnected — the shell is still running; reload to reattach]\x1b[0m\r\n"),s.onData(e=>p.readyState===WebSocket.OPEN&&p.send("0:"+e)),s.onResize(({rows:e,cols:t})=>p.readyState===WebSocket.OPEN&&p.send(`1:${e},${t}`));let C=new ResizeObserver(()=>v());C.observe(i.current),b.current=C})())},[n,v]),(0,o.useEffect)(()=>()=>{clearTimeout(d.current),f.current?.(),f.current=null;try{b.current?.disconnect()}catch{}b.current=null;let e=h.current;if(null!=e){e.onclose=null,e.onmessage=null,e.onopen=null,e.onerror=null;try{e.close()}catch{}}h.current=null;try{m.current?.dispose()}catch{}m.current=null,u.current=null},[]),(0,o.html)`<div class="terminal-host" ref=${i}></div>`},O=new Map,L=({path:e,visible:t})=>{let n=(0,o.useRef)(null),l=(0,o.useRef)(null),r=(0,o.useRef)(!1),[u,d]=(0,o.useState)(!1),[p,h]=(0,o.useState)("loading…"),m=(0,o.useCallback)(async()=>{let t=l.current;if(null!=t)try{await c(`./api/v1/file/save?path=${encodeURIComponent(e)}`,{method:"POST",body:t.state.doc.toString()}),O.set(e,!1),d(!1),h("saved"),setTimeout(()=>h(""),1500)}catch(e){h(String(e))}},[e]);return(0,o.useEffect)(()=>{t&&!r.current&&null!=n.current&&(r.current=!0,(async()=>{try{let t=await a("iCed3"),o=await s(`./api/v1/file?path=${encodeURIComponent(e)}`),r=t.HighlightStyle.define([{tag:t.tags.keyword,color:"var(--cm-color-keyword)"},{tag:t.tags.comment,color:"var(--cm-color-comment)",fontStyle:"italic"},{tag:t.tags.string,color:"var(--cm-color-string)"},{tag:t.tags.number,color:"var(--cm-color-literal)"},{tag:t.tags.literal,color:"var(--cm-color-literal)"},{tag:t.tags.macroName,color:"var(--cm-color-macro)"},{tag:t.tags.variableName,color:"var(--cm-color-variable)"},{tag:t.tags.heading,color:"var(--cm-color-md)",fontWeight:"700"},{tag:t.tags.link,color:"var(--cm-color-link)"}],{all:{color:"var(--cm-color-editor-text)"}}),c=e.split(".").pop()?.toLowerCase(),u="jl"===c?[t.julia()]:"md"===c?[t.markdown()]:"toml"===c?(()=>{try{return[t.StreamLanguage.define(t.toml)]}catch{return[]}})():"css"===c?[t.css()]:"js"===c||"mjs"===c?[t.javascript()]:"html"===c?[t.html()]:"py"===c?[t.python()]:[],p=new t.EditorView({state:t.EditorState.create({doc:o,extensions:[t.lineNumbers(),t.history(),t.drawSelection(),t.indentOnInput(),t.bracketMatching(),t.highlightActiveLine(),t.syntaxHighlighting(r),...u,t.keymap.of([{key:"Mod-s",run:()=>(m(),!0)},...t.defaultKeymap,...t.historyKeymap]),t.EditorView.updateListener.of(t=>{t.docChanged&&(O.set(e,!0),d(!0))}),t.EditorView.theme({},{dark:(0,i.prefers_dark)()})]}),parent:n.current});if(null==n.current){try{p.destroy()}catch{}return}l.current=p,h("")}catch(e){h(String(e))}})())},[t]),(0,o.useEffect)(()=>()=>{try{l.current?.destroy()}catch{}l.current=null},[]),(0,o.html)`<div class="file-pane">
        <div class="file-toolbar">
            <span class="file-path" title=${e}>${e}</span>
            <span class="file-status">${u?"●":""} ${p}</span>
            <button class="file-save ${u?"dirty":""}" onClick=${m} title="Save (Ctrl/Cmd+S)">Save</button>
        </div>
        <div class="file-editor" ref=${n}></div>
    </div>`};(0,o.render)((0,o.html)`<${()=>{let[e,t]=(0,o.useState)(null),[n,a]=(0,o.useState)({}),[l,i]=(0,o.useState)(new Set),b=(0,o.useRef)(l);(0,o.useEffect)(()=>{b.current=l},[l]);let[v,w]=(0,o.useState)(!1),[$,S]=(0,o.useState)([]),[C,_]=(0,o.useState)([]),[I,P]=(0,o.useState)(null),[x,U]=(0,o.useState)(null),[N,A]=(0,o.useState)(()=>Number(localStorage.getItem("spacestation sidebar width"))||290),[D,K]=(0,o.useState)(()=>"true"===localStorage.getItem("spacestation sidebar hidden")),[M,j]=(0,o.useState)(()=>"true"===localStorage.getItem("spacestation terminal open")),[H,W]=(0,o.useState)(()=>Number(localStorage.getItem("spacestation terminal height"))||280),[z,B]=(0,o.useState)(()=>Number(localStorage.getItem("spacestation terminal width"))||420),[F,J]=(0,o.useState)(()=>"right"===localStorage.getItem("spacestation terminal dock")?"right":"bottom"),[q,Y]=(0,o.useState)(()=>"light"===localStorage.getItem("spacestation terminal scheme")?"light":"dark"),Q=(0,o.useRef)(!1);M&&(Q.current=!0);let[V,X]=(0,o.useState)(!1),[G,Z]=(0,o.useState)(!1),ee=(0,o.useRef)(null),et=(0,o.useRef)({tabs:[],active:null,terminal_tab:!1}),en=(0,o.useCallback)(e=>{let t;if(e.defaultPrevented||e.isComposing)return;let n=navigator.platform.toUpperCase().includes("MAC"),a=n?e.metaKey&&!e.ctrlKey:e.ctrlKey&&!e.metaKey,l=0,o=-1;if(!e.ctrlKey||e.metaKey||e.altKey||"Tab"!==e.key?!e.ctrlKey||e.metaKey||e.altKey||e.shiftKey||"PageUp"!==e.key&&"PageDown"!==e.key?n&&e.metaKey&&e.shiftKey&&!e.altKey&&!e.ctrlKey&&("BracketLeft"===e.code||"BracketRight"===e.code)?l="BracketLeft"===e.code?-1:1:n&&e.metaKey&&e.altKey&&!e.shiftKey&&!e.ctrlKey&&("ArrowLeft"===e.key||"ArrowRight"===e.key)?l="ArrowLeft"===e.key?-1:1:a&&!e.shiftKey&&!e.altKey&&/^Digit[1-9]$/.test(e.code)&&(o=Number(e.code.slice(5))):l="PageUp"===e.key?-1:1:l=e.shiftKey?-1:1,0===l&&o<0)return;let{tabs:r,active:i,terminal_tab:s}=et.current,c=[...r.map(e=>e.id),...s?["__terminal__"]:[]];if(0!==c.length){if(e.preventDefault(),e.stopPropagation(),o>0)t=c[9===o?c.length-1:Math.min(o,c.length)-1];else{let e=c.indexOf(i??"");t=c[(e+l+c.length)%c.length]}null!=t&&P(t)}},[]);(0,o.useEffect)(()=>(window.addEventListener("keydown",en,!0),()=>window.removeEventListener("keydown",en,!0)),[en]);let ea=(0,o.useCallback)(e=>{try{e?.addEventListener("keydown",en,!0)}catch{}},[en]),[el,eo]=(0,o.useState)(null);(0,o.useEffect)(()=>{if(!G)return;let e=e=>{null==ee.current||ee.current.contains(e.target)||Z(!1)},t=e=>{"Escape"===e.key&&Z(!1)};return document.addEventListener("pointerdown",e),document.addEventListener("keydown",t),()=>{document.removeEventListener("pointerdown",e),document.removeEventListener("keydown",t)}},[G]),et.current={tabs:C,active:I,terminal_tab:M&&"tab"===F};let er=null!=I&&"__terminal__"!==I&&C.find(e=>e.id===I&&"file"!==e.kind);(0,o.useEffect)(()=>{if(!G)return;if(!er)return void eo(null);let e=!0;return c(`./api/v1/notebook/env?id=${encodeURIComponent(er.id)}`).then(t=>e&&eo({id:er.id,managed:t?.managed===!0,command:t?.command})).catch(()=>e&&eo({id:er.id,managed:!1})),()=>{e=!1}},[G,er?.id]);let ei=(0,o.useRef)(!1),es=(0,o.useRef)(null);if(null==es.current){let e=window.location.hash.match(/[#&]homebase=([^&]+)/);if(e)try{es.current=decodeURIComponent(e[1])}catch(e){}}let[ec,eu]=(0,o.useState)(!1),[ed,ep]=(0,o.useState)(m),[eh,em]=(0,o.useState)(!1),[eb,ef]=(0,o.useState)(r.pluto_file_extensions);(0,o.useEffect)(()=>{c("./api/v1/config").then(e=>{eu(!!(e&&e.tunneled)),ep(m||!!(e&&e.desktop)),Array.isArray(e?.notebook_extensions)&&e.notebook_extensions.length>0&&ef(e.notebook_extensions)}).catch(()=>{})},[]);let eg=(0,o.useCallback)(e=>(0,r.has_pluto_file_extension)(e,eb),[eb]);(0,o.useEffect)(()=>{v&&(window.name=p)},[v]),(0,o.useEffect)(()=>{document.title=v?"SpaceStation (launcher)":e?.root?`SpaceStation \u{2014} ${u(e.root)}`:"SpaceStation"},[v,e]);let ev=(0,o.useCallback)(()=>{if(ed&&h)return void f({type:"spacestation:focus-launcher"});if(ed&&null!=es.current){window.location.href=es.current;return}if(ec||ed)return void fetch("./api/v1/workspace/close",{method:"POST"}).finally(()=>window.location.reload());try{if(window.opener&&!window.opener.closed)return void window.opener.focus()}catch(e){}if(es.current){let e=null;try{e=window.open("",p)}catch(e){}if(null==e)return void window.open(es.current,p);let t=!1;try{t="about:blank"===e.location.href}catch(e){}if(t)try{e.location.href=es.current}catch(e){}try{e.focus()}catch(e){}return}X(!0)},[ec,ed]),[ew,e$]=(0,o.useState)([]),[ey,ek]=(0,o.useState)(null),eS=(0,o.useRef)(null),[eC,e_]=(0,o.useState)(null),eE=(0,o.useRef)(-1);(0,o.useEffect)(()=>{let t=e?.root??null;if(null==t||eS.current===t)return;let n=(e=>{if("string"!=typeof e||0===e.length)return[];try{let t=JSON.parse(localStorage.getItem(y)??"{}"),n=t&&"object"==typeof t&&!Array.isArray(t)?t[e]:null;if(!Array.isArray(n)){let e=JSON.parse(localStorage.getItem(k)??"[]");Array.isArray(e)&&e.length>0&&(n=e,localStorage.removeItem(k))}if(!Array.isArray(n))return[];return n.filter(e=>e&&"string"==typeof e.tid).map(e=>({tid:e.tid,label:e.label??"Terminal"}))}catch{return[]}})(t);eS.current=t,e$(n),ek(n.length?n[n.length-1].tid:null);let a=n.map(e=>parseInt(String(e.label??"").replace(/[^0-9]/g,""),10)).filter(e=>!isNaN(e));eE.current=a.length?Math.max(...a):0,e_(t)},[e?.root]),(0,o.useEffect)(()=>{localStorage.setItem("spacestation sidebar width",String(N)),localStorage.setItem("spacestation sidebar hidden",String(D)),localStorage.setItem("spacestation terminal open",String(M)),localStorage.setItem("spacestation terminal height",String(H)),localStorage.setItem("spacestation terminal scheme",q),localStorage.setItem("spacestation terminal width",String(z)),localStorage.setItem("spacestation terminal dock",F)},[N,D,M,H,z,F,q]),(0,o.useEffect)(()=>{let t=e?.root??null;null!=t&&eS.current===t&&eC===t&&((e,t)=>{if("string"!=typeof e||0===e.length)return;let n={};try{let e=JSON.parse(localStorage.getItem(y)??"{}");e&&"object"==typeof e&&!Array.isArray(e)&&(n=e)}catch{}n[e]=t.map(e=>({tid:e.tid,label:e.label})),localStorage.setItem(y,JSON.stringify(n))})(t,ew)},[ew,eC,e?.root]),(0,o.useEffect)(()=>{let e=e=>{let t=!1;for(let e of O.values())if(e){t=!0;break}t&&(e.preventDefault(),e.returnValue="")};return window.addEventListener("beforeunload",e),()=>window.removeEventListener("beforeunload",e)},[]);let eR=(0,o.useCallback)(e=>{e.preventDefault();let t="bottom"===F;document.body.classList.add(t?"resizing-v":"resizing");let n=e=>t?W(Math.max(120,Math.min(window.innerHeight-220,window.innerHeight-e.clientY-12))):B(Math.max(240,Math.min(window.innerWidth-420,window.innerWidth-e.clientX-12))),a=()=>{document.body.classList.remove("resizing-v"),document.body.classList.remove("resizing"),window.removeEventListener("pointermove",n),window.removeEventListener("pointerup",a)};window.addEventListener("pointermove",n),window.addEventListener("pointerup",a)},[F]),eI=(0,o.useCallback)((e,t,n="notebook")=>{_(a=>a.some(t=>t.id===e)?a:[...a,{id:e,path:t,kind:n}]),P(e)},[]),eT=(0,o.useCallback)(e=>{eI(`file:${e}`,e,"file")},[eI]),eO=(0,o.useCallback)((t={})=>{if(e?.root==null||eS.current!==e.root)return;eE.current+=1;let n="term-"+Math.random().toString(36).slice(2,12),a={tid:n,label:t.label??`Terminal ${eE.current}`};t.notebook_env&&(a.notebook_env=t.notebook_env),e$(e=>[...e,a]),ek(n),j(!0)},[e?.root]),eL=(0,o.useCallback)(e=>{fetch(`./api/v1/terminal/close?tid=${encodeURIComponent(e)}`,{method:"POST"}).catch(()=>{}),e$(t=>{let n=t.filter(t=>t.tid!==e);return ek(t=>t===e?n.length?n[n.length-1].tid:null:t),n})},[]);(0,o.useEffect)(()=>{M&&e?.root!=null&&eS.current===e.root&&eC===e.root&&0===ew.length&&eO()},[M,ew.length,eC,e?.root]);let eP=(0,o.useCallback)(async e=>{try{let{entries:t}=await c(`./api/v1/workspace/listing?path=${encodeURIComponent(e)}`);a(n=>({...n,[e]:t}))}catch(t){if(!b.current.has(e))return;a(n=>({...n,[e]:[{name:"…",path:`${e}/\u{2026}`,type:"unreadable",detail:String(t)}]}))}},[]),ex=(0,o.useCallback)(e=>{let t=!b.current.has(e);i(n=>{let a=new Set(n);return t?a.add(e):a.delete(e),b.current=a,a}),t&&eP(e)},[eP]),eU=(0,o.useCallback)(async()=>{try{let e=await fetch("./api/v1/workspace");if(404===e.status)w(!0),t(null);else if(e.ok){w(!1),t(await e.json());let n=[...b.current],l=await Promise.all(n.map(e=>c(`./api/v1/workspace/listing?path=${encodeURIComponent(e)}`).then(t=>[e,t.entries]).catch(()=>[e,null])));a(e=>{let t={...e};for(let[e,n]of l)null!=n&&(t[e]=n);return t})}else throw Error(`workspace request failed: ${e.status}`);let n=await c("./api/v1/notebooks");S(n),ei.current||(ei.current=!0,n.forEach(e=>eI(e.notebook_id,e.path))),U(null)}catch(e){e instanceof TypeError?em(!0):U(String(e))}},[eI]);(0,o.useEffect)(()=>{eU();let e=setInterval(eU,1e4);return()=>clearInterval(e)},[]),(0,o.useEffect)(()=>{let e=()=>{"visible"===document.visibilityState&&eU()};return window.addEventListener("online",e),document.addEventListener("visibilitychange",e),window.addEventListener("focus",e),()=>{window.removeEventListener("online",e),document.removeEventListener("visibilitychange",e),window.removeEventListener("focus",e)}},[eU]),(0,o.useEffect)(()=>{if(!eh)return;let e=!1,t=null,n=1e3,a=async()=>{if(!e){try{if((await fetch("./ping",{cache:"no-store"})).ok)return void window.location.reload()}catch{}n=Math.min(1.5*n,5e3),e||(t=setTimeout(a,n))}};return t=setTimeout(a,700),()=>{e=!0,null!=t&&clearTimeout(t)}},[eh]);let eN=(0,o.useCallback)(e=>{e.preventDefault(),document.body.classList.add("resizing");let t=e=>A(Math.max(180,Math.min(560,e.clientX-12))),n=()=>{document.body.classList.remove("resizing"),window.removeEventListener("pointermove",t),window.removeEventListener("pointerup",n)};window.addEventListener("pointermove",t),window.addEventListener("pointerup",n)},[]),eA=(0,o.useCallback)(async e=>{try{let t=await s(`./open?path=${encodeURIComponent(e)}`,{method:"POST"});eI(t,e),eU()}catch(e){U(String(e))}},[eI,eU]),eD=(0,o.useCallback)(async()=>{if(null==e)return;let t=prompt("Notebook file name (created in the workspace):","new notebook.jl");if(null!=t)try{let n=await s("./new",{method:"POST"}),a=`${e.root}/${eg(t)?t:t+".jl"}`;await s(`./move?id=${encodeURIComponent(n)}&newpath=${encodeURIComponent(a)}`,{method:"POST"}),eI(n,a),eU()}catch(e){U(String(e))}},[e,eI,eU,eg]),eK=(0,o.useCallback)(async e=>{if(e.startsWith("file:")){let t=e.slice(5);if(O.get(t)&&!await d("This file has unsaved changes. Close anyway?",{action:"Close without saving",danger:!0}))return;O.delete(t)}_(t=>{let n=t.filter(t=>t.id!==e);return P(t=>t===e?n.length>0?n[n.length-1].id:null:t),n})},[]),eM=(0,o.useCallback)(async t=>{let n=prompt(`New file in ${u(t)}/ \u{2014} a name ending in .jl or .plutojl becomes a Pluto notebook:`,"notebook.jl");if(null==n||""===n.trim())return;let a=`${t}/${n.trim()}`;try{if(eg(n.trim())){let e=await s("./new",{method:"POST"});await s(`./move?id=${encodeURIComponent(e)}&newpath=${encodeURIComponent(a)}`,{method:"POST"}),eI(e,a)}else await c(`./api/v1/file/new?path=${encodeURIComponent(a)}`,{method:"POST"}),eT(a);null==e||t===e.root||b.current.has(t)?eP(t):ex(t),eU()}catch(e){U(String(e))}},[eI,eT,eU,ex,eP,e,eg]),ej=(0,o.useCallback)(async e=>{let t="notebook"===e.type?"notebook (it will be shut down if running; its output cache is deleted too)":"file";if(await d(`Delete ${e.name}?

This permanently deletes the ${t}. There is no trash.`,{action:"Delete",danger:!0}))try{await c(`./api/v1/file/delete?path=${encodeURIComponent(e.path)}`,{method:"POST"}),_(t=>t.filter(t=>t.path!==e.path)),O.delete(e.path),eU()}catch(e){U(String(e))}},[eU]),eH=(0,o.useCallback)(async e=>{if(await d("Shut down this notebook session? The file stays on disk; outputs are cached.",{action:"Shut down"}))try{await s(`./shutdown?id=${encodeURIComponent(e)}`,{method:"POST"}),eK(e),eU()}catch(e){U(String(e))}},[eK,eU]),eW=M&&"tab"===F,ez=(0,o.useCallback)(()=>{let e=!M;j(e),e&&"tab"===F&&P("__terminal__"),e||P(e=>"__terminal__"===e?null:e)},[M,F]),eB=(0,o.useCallback)(()=>{let e="bottom"===F?"right":"right"===F?"tab":"bottom";"tab"===e?(j(!0),P("__terminal__")):"tab"===F&&P(e=>"__terminal__"===e?null:e),J(e)},[F]),eF=t=>(0,o.html)`
        <div class="terminal-tabs">
            <div class="terminal-tab-scroller">
                ${(eS.current===e?.root?ew:[]).map(e=>(0,o.html)`<div class="tab terminal-tab ${e.tid===ey?"active":""}" key=${e.tid}>
                        <button class="title" title=${e.label} onClick=${()=>ek(e.tid)}>
                            <span class="tab-term-icon">⌨</span>${e.label}
                        </button>
                        <button class="close" title="Close terminal" onClick=${()=>eL(e.tid)}>×</button>
                    </div>`)}
                <button class="new-terminal-tab" title="New terminal" onClick=${()=>eO()}>
                    <span class="nt-icon">⌨</span><span class="nt-plus">＋</span>
                </button>
            </div>
            <button
                class="terminal-scheme-toggle"
                title=${"light"===q?"Terminal colours: light — switch to dark":"Terminal colours: dark — switch to light"}
                aria-label="Toggle terminal colours"
                onClick=${()=>Y(e=>"light"===e?"dark":"light")}
            >
                ${"light"===q?"☀":"☾"}
            </button>
        </div>
        <div class="terminal-bodies">
            ${(eS.current===e?.root?ew:[]).map(n=>(0,o.html)`<div key=${n.tid} class="terminal-body ${n.tid===ey?"active":""}">
                    <${T} tid=${n.tid} cwd=${e?.root} visible=${t&&n.tid===ey} scheme=${q} notebook_env=${n.notebook_env} />
                </div>`)}
        </div>
    `,eJ=(0,o.useCallback)(async()=>{if(!await d("Shut down the SpaceStation server?\n\nRunning notebooks and the integrated terminal will stop. SSH remote servers keep running and can be reattached later.",{action:"Shut down"}))return;fetch("./api/v1/shutdown",{method:"POST"}).catch(()=>{});let e=async()=>{try{return await fetch("./ping",{method:"GET",cache:"no-store"}),!0}catch{return!1}},t=Date.now()+8e3;for(;Date.now()<t;)if(await new Promise(e=>setTimeout(e,400)),!await e()){document.body.innerHTML='<div style="font: 15px/1.6 system-ui, sans-serif; padding: 3rem; text-align: center; color: #888">SpaceStation has shut down. You can close this tab.</div>';return}U("Shutdown was requested, but the server is still responding — it may not have shut down.")},[]);return v||V?(0,o.html)`<${R} on_cancel=${v?null:()=>X(!1)} tunneled=${ec} desktop=${ed} />`:(0,o.html)`
        <div id="land">
            ${eh?(0,o.html)`<div class="reconnect-overlay" role="status" aria-live="polite">
                      <div class="reconnect-card">
                          <span class="reconnect-spinner"></span>
                          <div>
                              <b>Reconnecting…</b>
                              <p>
                                  Waiting for this workspace to come back. Notebooks and terminals on the server keep running — this page reloads
                                  itself as soon as it can reach them again.
                              </p>
                          </div>
                      </div>
                  </div>`:null}
            ${D?(0,o.html)`<button id="sidebar-reopen" title="Show sidebar" onClick=${()=>K(!1)}>☰</button>`:(0,o.html)`<aside style=${`width: ${N}px`}>
                <header class="bubble">
                    <div class="header-row">
                        <button class="land-logo-button" title="Back to homebase (open &amp; manage workspaces)" onClick=${ev}>
                            <img class="land-logo" src=${g} alt="SpaceStation" />
                        </button>
                        <div class="header-text">
                            <h1 title=${e?.root??""}>Space<span class="land-accent">Station</span></h1>
                            ${e?.root?(0,o.html)`<p class="workspace-root" title=${e.root}>${u(e.root)||e.root}</p>`:null}
                        </div>
                        <div class="header-buttons">
                            <div class="header-menu" ref=${ee}>
                                <button class="header-button menu-button ${G?"active":""}" title="More actions" aria-haspopup="menu" aria-expanded=${G} onClick=${()=>Z(e=>!e)}><span class="menu-dots"></span></button>
                                ${G?(0,o.html)`<div class="header-menu-popover" role="menu">
                                          <button
                                              class="header-menu-item"
                                              role="menuitem"
                                              disabled=${!(er&&el?.id===er.id&&el.managed)}
                                              title=${!er?"Open a notebook tab first":el?.id!==er.id?"Checking the notebook's environment…":el.managed?`Open a terminal in this notebook's package environment. It runs:
${el.command}`:"This notebook has no Pluto-managed environment yet: it has not run, or it activates its own with Pkg.activate"}
                                              onClick=${()=>{Z(!1),er&&eO({label:`env: ${u(er.path)}`,notebook_env:er.id})}}
                                          >
                                              <span class="menu-icon terminal"></span>Open env in terminal
                                          </button>
                                          <button class="header-menu-item danger" role="menuitem" onClick=${()=>{Z(!1),eJ()}}><span class="menu-icon power"></span>Shut down server</button>
                                      </div>`:null}
                            </div>
                            <button class="header-button collapse-button" title="Hide sidebar" onClick=${()=>K(!0)}><span class="collapse-icon"></span></button>
                        </div>
                    </div>
                </header>
                <section class="files bubble">
                    <h2>
                        Workspace
                        ${e?.git==null?null:(0,o.html)`<span
                                  class="git-branch"
                                  title=${e.git.detached?`Detached HEAD at ${e.git.branch}`:`On branch ${e.git.branch}`}
                              >
                                  <span class="git-branch-icon"></span><span class="git-branch-name">${e.git.branch}</span>
                              </span>`}
                        ${null==e?null:(0,o.html)`<button class="row-action h2-action" title="New notebook or file in the workspace root" onClick=${()=>eM(e.root)}>+</button>`}
                    </h2>
                    <ul class="tree">
                        ${null==e?null:e.entries.map(e=>(0,o.html)`<${E}
                                          key=${e.path}
                                          entry=${e}
                                          listings=${n}
                                          expanded=${l}
                                          on_toggle=${ex}
                                          on_open_notebook=${eA}
                                          on_open_file=${eT}
                                          on_create_in=${eM}
                                          on_delete=${ej}
                                          depth=${0}
                                      />`)}
                    </ul>
                </section>
                <section class="running bubble">
                    <h2>Running</h2>
                    <ul>
                        ${$.map(e=>(0,o.html)`<li>
                                <button class="entry" title=${e.path} onClick=${()=>eI(e.notebook_id,e.path)}>
                                    <span class="icon running-dot"></span>${u(e.path)}
                                </button>
                                <button class="shutdown" title="Shut down this notebook" onClick=${()=>eH(e.notebook_id)}>✕</button>
                            </li>`)}
                    </ul>
                </section>
                <footer>
                    <button class="new-notebook" onClick=${eD}>+ New notebook</button>
                </footer>
            </aside>`}
            ${D?null:(0,o.html)`<div id="sidebar-resizer" onPointerDown=${eN}></div>`}
            <main>
                <div class="main-split ${F}">
                    <div class="editor-card">
                        <nav id="tabs">
                            <div class="tab-scroller">
                                ${C.map(e=>(0,o.html)`<div class="tab ${e.id===I?"active":""}" key=${e.id}>
                                        <button class="title" title=${e.path} onClick=${()=>P(e.id)}>${u(e.path)}</button>
                                        <button class="close" title="Close tab (notebook keeps running)" onClick=${()=>eK(e.id)}>×</button>
                                    </div>`)}
                                ${eW?(0,o.html)`<div class="tab terminal-tab ${"__terminal__"===I?"active":""}" key="__terminal__">
                                          <button class="title" title="Terminal" onClick=${()=>P("__terminal__")}>
                                              <span class="tab-term-icon">⌨</span>Terminal
                                          </button>
                                          <button class="close" title="Hide terminal" onClick=${()=>{j(!1),P(e=>"__terminal__"===e?null:e)}}>×</button>
                                      </div>`:null}
                            </div>
                            <button class="terminal-toggle ${M?"active":""}" title="Toggle the integrated terminal (runs in the workspace folder)" onClick=${ez}>⌨ Terminal</button>
                            ${M?(0,o.html)`<button
                                      class="terminal-toggle dock-toggle"
                                      title=${"bottom"===F?"Move terminal to the right":"right"===F?"Embed terminal as an editor tab":"Dock terminal to the bottom"}
                                      onClick=${eB}
                                  >
                                      ${"bottom"===F?"◨":"right"===F?"▭":"⬓"}
                                  </button>`:null}
                        </nav>
                        <div id="frames">
                            ${C.map(e=>"file"===e.kind?(0,o.html)`<div key=${e.id} class="pane ${e.id===I?"active":""}">
                                          <${L} path=${e.path} visible=${e.id===I} />
                                      </div>`:(0,o.html)`<iframe
                                          key=${e.id}
                                          src=${`./edit?id=${e.id}`}
                                          class=${e.id===I?"active":""}
                                          onLoad=${e=>ea(e.target.contentWindow)}
                                      ></iframe>`)}
                            ${eW?(0,o.html)`<div class="pane terminal-area-pane ${"__terminal__"===I?"active":""}">
                                      ${eF(eW&&"__terminal__"===I)}
                                  </div>`:null}
                            ${0===C.length&&"__terminal__"!==I?(0,o.html)`<div class="empty-state">
                                      <p>Open a notebook from the workspace on the left, or create a new one.</p>
                                      <p class="hint">Agents can work here too: edit any notebook file, or use <code>pluto-collab</code>.</p>
                                  </div>`:null}
                        </div>
                    </div>
                    ${Q.current?(0,o.html)`
                              <div
                                  id="terminal-resizer"
                                  style=${M&&"tab"!==F?"":"display: none"}
                                  onPointerDown=${eR}
                              ></div>
                              <div
                                  id="terminal-panel"
                                  class="bubble"
                                  style=${M&&"tab"!==F?"bottom"===F?`height: ${H}px`:`width: ${z}px`:"display: none"}
                              >
                                  ${"tab"!==F?eF(M&&"tab"!==F):null}
                              </div>
                          `:null}
                </div>
            </main>
            ${null==x?null:(0,o.html)`<div id="land-error">${x}</div>`}
        </div>
    `}} />`,document.querySelector("#land-app"));