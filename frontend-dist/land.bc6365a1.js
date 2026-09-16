import"./frontend.4d03b972.js";var e=globalThis,t={},n={},a=e.parcelRequire94c2;null==a&&((a=function(e){if(e in t)return t[e].exports;if(e in n){var a=n[e];delete n[e];var o={id:e,exports:{}};return t[e]=o,a.call(o.exports,o,o.exports),o.exports}var r=Error("Cannot find module '"+e+"'");throw r.code="MODULE_NOT_FOUND",r}).register=function(e,t){n[e]=t},e.parcelRequire94c2=a);var o=a.register;o("5IQaQ",function(e,t){navigator.platform.toUpperCase().includes("MAC")&&window.top!==window&&fetch("./api/v1/config").then(e=>e.json()).then(e=>{e?.desktop===!0&&window.addEventListener("keydown",e=>{if(!e.metaKey||e.ctrlKey||e.altKey)return;let t="Equal"===e.code||"+"===e.key||"="===e.key?"in":"Minus"===e.code||"-"===e.key?"out":"Digit0"===e.code||"0"===e.key?"reset":null;if(null!=t){e.preventDefault(),e.stopPropagation();try{window.top?.postMessage({type:"spacestation:zoom",action:t},"*")}catch{}}},{capture:!0})}).catch(()=>{})}),o("hmt3d",function(e,t){e.exports=Promise.all([import("a4Bpq"),import("iJpDL")]).then(()=>a("bnHn0"))}),o("aDKOm",function(e,t){e.exports=import("hmOBl").then(()=>a("bJtX0"))}),o("iCed3",function(e,t){e.exports=import("aZARi").then(()=>a("hiQgq"))});var r=a("cNaMA"),l=a("6ha54"),i=a("aLlws");a("5IQaQ");let s=async(e,t)=>{let n=await fetch(e,t);if(!n.ok)throw Error(`${e} \u{2192} ${n.status}`);return await n.text()},c=async(e,t)=>{let n=await fetch(e,t);if(!n.ok)throw Error(`${e} \u{2192} ${n.status}`);return await n.json()},u=e=>(e.split("/").pop()??"").split("\\").pop()??"",d=(e,{action:t="Confirm",danger:n=!1}={})=>new Promise(a=>{let o=document.createElement("dialog");o.className="land-confirm";let r=document.createElement("p");r.textContent=e;let l=document.createElement("div");l.className="buttons";let i=document.createElement("button");i.textContent="Cancel";let s=document.createElement("button");s.textContent=t,s.className=`go ${n?"danger":""}`,l.append(i,s),o.append(r,l),document.body.append(o);let c=e=>{o.close(),o.remove(),a(e)};i.onclick=()=>c(!1),s.onclick=()=>c(!0),o.oncancel=e=>{e.preventDefault(),c(!1)},o.onclick=e=>e.target===o&&c(!1),o.showModal(),i.focus()}),p="spacestation-homebase",h=(()=>{try{return window.self!==window.top}catch(e){return!0}})(),m=h||new URLSearchParams(window.location.search).has("desktop"),b=({classname:e})=>{let[t,n]=(0,r.useState)((0,i.get_color_scheme)());return(0,r.html)`<button
        class="app-scheme-toggle ${e??""}"
        title=${"system"===t?"Appearance: follow the system — switch to light":"light"===t?"Appearance: light — switch to dark":"Appearance: dark — follow the system"}
        aria-label="Toggle light/dark appearance"
        onClick=${()=>{let e=(0,i.cycle_color_scheme)();n(e),f({type:"spacestation:color-scheme",scheme:e})}}
    >
        ${"system"===t?"◐":"light"===t?"☀":"☾"}
    </button>`},f=e=>{try{window.parent.postMessage(e,"*")}catch(e){}},g=new URL(import.meta.resolve("gx1Fc")).href,w="spacestation recent workspaces",v=()=>{try{let e=JSON.parse(localStorage.getItem(w)??"[]");return Array.isArray(e)?e:[]}catch{return[]}},$="spacestation terminals by workspace",y="spacestation terminals",k="spacestation ssh connect timeout",S=e=>Math.max(3,Math.min(180,Math.round(Number(e)||25))),C=()=>{let e=Number(localStorage.getItem(k));return Number.isFinite(e)&&e>=3?S(e):25},_=({entry:e,listings:t,expanded:n,on_toggle:a,on_open_notebook:o,on_open_file:l,on_create_in:i,on_delete:s,depth:c})=>{if("dir"===e.type){let u=n.has(e.path),d=t[e.path];return(0,r.html)`<li class="dir ${u?"open":""}">
            <div class="entry-row">
                <button class="entry" onClick=${()=>a(e.path)}><span class="icon chevron"></span>${e.name}</button>
                <button class="row-action" title="New notebook or file in ${e.name}/" onClick=${()=>i(e.path)}>+</button>
            </div>
            ${u?(0,r.html)`<ul>
                      ${null==d?(0,r.html)`<li class="pending">
                                <div class="entry-row"><span class="entry plain">reading…</span></div>
                            </li>`:d.map(e=>(0,r.html)`<${_}
                                        key=${e.path}
                                        entry=${e}
                                        listings=${t}
                                        expanded=${n}
                                        on_toggle=${a}
                                        on_open_notebook=${o}
                                        on_open_file=${l}
                                        on_create_in=${i}
                                        on_delete=${s}
                                        depth=${c+1}
                                    />`)}
                  </ul>`:null}
        </li>`}if("truncated"===e.type)return(0,r.html)`<li class="truncated">
            <div class="entry-row">
                <span
                    class="entry plain"
                    title="This folder has more entries than SpaceStation lists in one go. Use the terminal to see the rest."
                    >… not listed</span
                >
            </div>
        </li>`;if("unreadable"===e.type)return(0,r.html)`<li class="truncated">
            <div class="entry-row"><span class="entry plain" title=${e.detail??""}>… could not be read</span></div>
        </li>`;let u="notebook"===e.type;return(0,r.html)`<li class=${u?"notebook":"file"}>
        <div class="entry-row">
            <button
                class="entry ${u?"":"quiet"}"
                title=${e.path}
                onClick=${()=>u?o(e.path):l(e.path)}
            >
                <span class="icon ${u?"pluto-dot":""}"></span>${e.name}
            </button>
            <button class="row-action danger" title="Delete ${e.name}" onClick=${()=>s(e)}>✕</button>
        </div>
    </li>`},E=({on_cancel:e,tunneled:t,desktop:n})=>{let a=(0,r.useRef)(n);a.current=n;let o=e=>a.current?`${e}${e.includes("?")?"&":"?"}desktop=1`:e,l=e=>new URL(e,window.location.href).href,s=e=>{var t;let n,a;return null==(a=o((t=l(e),"system"===(n=(0,i.get_color_scheme)())?t:`${t}${t.includes("?")?"&":"?"}scheme=${n}`)))?a:`${a}#homebase=${encodeURIComponent(window.location.origin+window.location.pathname+window.location.search)}`},p=n?"_self":"_blank",h=(e,t)=>f({type:"spacestation:open-workspace",url:o(l(e)),title:t}),[m,$]=(0,r.useState)(null),[y,_]=(0,r.useState)(null),[E,R]=(0,r.useState)([]),[I,T]=(0,r.useState)(C),[L,O]=(0,r.useState)({}),[P,x]=(0,r.useState)({}),[U,A]=(0,r.useState)([]),D=(0,r.useRef)(new Set),N=(0,r.useRef)(new Set),M=(0,r.useCallback)(()=>c("./api/v1/ssh_hosts").then(R).catch(()=>{}),[]);(0,r.useEffect)(()=>{M()},[M]),(0,r.useEffect)(()=>{localStorage.setItem(k,String(I)),fetch(`./api/v1/remote/config?connect_timeout=${encodeURIComponent(I)}`,{method:"POST"}).catch(()=>{})},[I]);let K=(0,r.useCallback)(async e=>{D.current.delete(e);try{let t=await c(`./api/v1/remote/open?host=${encodeURIComponent(e)}`,{method:"POST"});for(O(n=>({...n,[e]:t}));"ready"!==t.state&&"error"!==t.state;){if(await new Promise(e=>setTimeout(e,1500)),D.current.has(e))return;t=await c(`./api/v1/remote/status?host=${encodeURIComponent(e)}`),O(n=>({...n,[e]:t}))}"ready"===t.state&&null!=t.url&&(a.current?h(t.url,e):window.open(s(t.url),"_blank"))}catch(t){if(D.current.has(e))return;O(n=>({...n,[e]:{state:"error",detail:String(t),url:null}}))}},[]),j=(0,r.useCallback)(async e=>{D.current.add(e);try{await fetch(`./api/v1/remote/cancel?host=${encodeURIComponent(e)}`,{method:"POST"})}catch(e){}O(t=>{let n={...t};return delete n[e],n}),A(t=>t.filter(t=>"remote"!==t.kind||t.host!==e))},[]),H=(0,r.useCallback)(async e=>{N.current.delete(e);try{let t=await c(`./api/v1/local/open?path=${encodeURIComponent(e)}`,{method:"POST"});for(x(n=>({...n,[e]:t}));"ready"!==t.state&&"error"!==t.state;){if(await new Promise(e=>setTimeout(e,1e3)),N.current.has(e))return;t=await c(`./api/v1/local/status?path=${encodeURIComponent(e)}`),x(n=>({...n,[e]:t}))}"ready"===t.state&&null!=t.url&&(localStorage.setItem(w,JSON.stringify([e,...v().filter(t=>t!==e)].slice(0,8))),a.current?h(t.url,u(e)||e):window.open(s(t.url),"_blank"))}catch(t){if(N.current.has(e))return;x(n=>({...n,[e]:{state:"error",detail:String(t),url:null}}))}},[]),W=(0,r.useCallback)(async e=>{N.current.add(e);try{await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(e)}`,{method:"POST"})}catch(e){}x(t=>{let n={...t};return delete n[e],n}),A(t=>t.filter(t=>"local"!==t.kind||t.path!==e))},[]),B=(0,r.useCallback)(async e=>{if(await d(`Shut down the workspace server for ${u(e)}?

Its running notebooks will stop. Files stay on disk and outputs are cached in their .pluto-cache.toml sidecars, so reopening restores everything.`,{action:"Shut down"})){try{await fetch(`./api/v1/local/shutdown?path=${encodeURIComponent(e)}`,{method:"POST"})}catch(e){}x(t=>{let n={...t};return delete n[e],n}),A(t=>t.filter(t=>"local"!==t.kind||t.path!==e))}},[]),J=(0,r.useCallback)(async e=>H(e),[H]),z=(0,r.useCallback)(e=>"remote"===e.kind?j(e.host):"ready"===e.state?B(e.path):W(e.path),[j,B,W]);(0,r.useEffect)(()=>{let e=!0,t=async()=>{let[t,n]=await Promise.all([c("./api/v1/local/list").catch(()=>[]),c("./api/v1/remote/list").catch(()=>[])]);e&&A([...t.map(e=>({kind:"local",key:`local:${e.path}`,name:u(e.path)||e.path,sub:e.path,state:e.state,url:e.url,path:e.path})),...n.map(e=>({kind:"remote",key:`remote:${e.host}`,name:e.host,sub:"SSH remote",state:e.state,url:e.url,host:e.host}))])};t();let n=setInterval(t,3e3);return()=>{e=!1,clearInterval(n)}},[]);let F=(0,r.useRef)(null),q=(0,r.useCallback)(async e=>{F.current=e;try{$(await c(null==e?"./api/v1/browse":`./api/v1/browse?path=${encodeURIComponent(e)}`)),_(null)}catch(e){_(String(e))}},[]);(0,r.useEffect)(()=>{q(null)},[]);let[Y,Q]=(0,r.useState)(!1),V=(0,r.useCallback)(async()=>{Q(!0);try{await Promise.all([M(),q(F.current)])}finally{setTimeout(()=>Q(!1),400)}},[M,q]);(0,r.useEffect)(()=>{let e=()=>{"visible"===document.visibilityState&&V()};window.addEventListener("focus",e),document.addEventListener("visibilitychange",e);let t=setInterval(()=>{"visible"===document.visibilityState&&V()},1e4);return()=>{window.removeEventListener("focus",e),document.removeEventListener("visibilitychange",e),clearInterval(t)}},[V]);let X=(0,r.html)`<button
        class="row-action h2-action refresh ${Y?"spinning":""}"
        title="Refresh: re-read the folders on disk and the hosts in ~/.ssh/config"
        aria-label="Refresh"
        onClick=${()=>void V()}
    >
        <span class="refresh-icon"></span>
    </button>`,G=v(),Z=m?.crumbs??[];return(0,r.html)`<div class="workspace-opener">
        <div class="bubble opener-card">
            <header>
                <img class="land-logo opener-logo" src=${g} alt="SpaceStation" />
                <h1>Space<span class="land-accent">Station</span></h1>
                <p class="subtitle">Open a folder as your workspace — notebooks inside it open as tabs.</p>
                ${n?(0,r.html)`<button
                          class="opener-julia-version"
                          title="Pick which Julia the app runs on (restarts the SpaceStation server)"
                          onClick=${()=>f({type:"spacestation:julia-version"})}
                      >
                          Julia version…
                      </button>`:null}
                <${b} classname=${null==e?"opener-corner":"opener-corner beside-cancel"} />
                ${null==e?null:(0,r.html)`<button class="opener-cancel" title="Close — back to your workspace" onClick=${e}><span class="opener-cancel-icon"></span></button>`}
            </header>

            ${!t&&U.length>0?(0,r.html)`<section>
                      <h2>Running Workspaces</h2>
                      <div class="recent-grid">
                          ${U.map(e=>(0,r.html)`<div class="recent-card running-card ${"ready"===e.state?"":"running-busy"}" key=${e.key}>
                                  ${null!=e.url?(0,r.html)`<a
                                            class="running-open"
                                            href=${s(e.url)}
                                            target=${p}
                                            rel="opener"
                                            title=${`Open ${e.name}`}
                                            onClick=${n?t=>{t.preventDefault(),h(e.url,e.name)}:void 0}
                                        >
                                            <span class="recent-icon">${"remote"===e.kind?"🛰":"🗂"}</span>
                                            <span class="recent-name">${e.name}</span>
                                            <span class="recent-path">${e.sub}</span>
                                        </a>`:(0,r.html)`<div class="running-open is-busy">
                                            <span class="recent-icon">${"remote"===e.kind?"🛰":"🗂"}</span>
                                            <span class="recent-name">${e.name}</span>
                                            <span class="recent-path">${e.state}…</span>
                                        </div>`}
                                  <button
                                      class="running-shutdown"
                                      title=${"error"===e.state?"Dismiss":"ready"!==e.state?"Cancel":"remote"===e.kind?"Disconnect":"Shut down this workspace"}
                                      onClick=${()=>z(e)}
                                  >
                                      ✕
                                  </button>
                              </div>`)}
                      </div>
                  </section>`:null}

            ${G.length>0?(0,r.html)`<section>
                      <h2>Recent</h2>
                      <div class="recent-grid">
                          ${G.map(e=>(0,r.html)`<button class="recent-card" title=${e} onClick=${()=>J(e)}>
                                  <span class="recent-icon">🗂</span>
                                  <span class="recent-name">${u(e)}</span>
                                  <span class="recent-path">${e}</span>
                              </button>`)}
                      </div>
                  </section>`:null}

            <section>
                <h2>Browse ${X}</h2>
                ${null==m?(0,r.html)`<p class="subtitle">loading…</p>`:(0,r.html)`
                          <nav class="breadcrumbs">
                              ${Z.map((e,t)=>(0,r.html)`<button
                                          class="crumb ${t===Z.length-1?"current":""}"
                                          onClick=${()=>q(e.path)}
                                          title=${e.path}
                                      >
                                          ${e.name}</button
                                      >${t>0&&t<Z.length-1?(0,r.html)`<span class="crumb-sep">/</span>`:null}`)}
                          </nav>
                          <div class="dir-grid">
                              ${m.entries.map(e=>(0,r.html)`<button class="dir-pill" title=${e.path} onClick=${()=>q(e.path)}>
                                      <span class="dir-icon">📁</span>${e.name}
                                  </button>`)}
                              ${0===m.entries.length?(0,r.html)`<p class="subtitle">no subfolders</p>`:null}
                          </div>
                          <div class="opener-actions">
                              <button class="open-this-folder" onClick=${()=>J(m.path)}>
                                  Open <strong>${u(m.path)||"/"}</strong> as workspace
                              </button>
                              <form
                                  class="paste-path"
                                  onSubmit=${e=>{e.preventDefault();let t=e.target.elements.path.value.trim();""!==t&&q(t)}}
                              >
                                  <input name="path" type="text" placeholder="…or paste a folder path and press Enter" autocomplete="off" />
                              </form>
                          </div>
                      `}
            </section>
            ${!t&&E.length>0?(0,r.html)`<section>
                      <h2>SSH Remotes ${X}</h2>
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
                              value=${I}
                              onChange=${e=>T(S(e.target.value))}
                          />
                          <span class="unit">s</span>
                          <span class="ssh-timeout-hint">Raise this if a host fails with “timed out reaching … slow SSH hop”.</span>
                      </label>
                      <div class="dir-grid">
                          ${E.map(e=>{let t=L[e],a=null!=t&&"ready"!==t.state&&"error"!==t.state;return t?.state==="ready"&&null!=t.url?(0,r.html)`<a
                                        class="dir-pill remote-ready"
                                        href=${s(t.url)}
                                        target=${p}
                                        rel="opener"
                                        title=${t.detail}
                                        onClick=${n?n=>{n.preventDefault(),h(t.url,e)}:void 0}
                                    >
                                        <span class="dir-icon">🛰</span>${e} →
                                    </a>`:(0,r.html)`<button
                                        class="dir-pill ${a?"remote-busy":""} ${t?.state==="error"?"remote-error":""}"
                                        title=${t?.detail??`Open a workspace on ${e}`}
                                        onClick=${()=>K(e)}
                                    >
                                        <span class="dir-icon">🛰</span>${a?`${e}: ${t.state}\u{2026}`:t?.state==="error"?`${e}: failed (retry)`:e}
                                    </button>`})}
                      </div>
                      ${Object.entries(L).filter(([e,t])=>"ready"!==t.state&&"error"!==t.state).map(([e,t])=>(0,r.html)`<div class="remote-progress" key=${e}>
                                  <span class="remote-spinner"></span>
                                  <div class="remote-progress-text">
                                      <strong>Connecting to ${e} — ${t.state}</strong>
                                      <span>${t.detail}</span>
                                      ${"installing"===t.state?(0,r.html)`<span class="remote-progress-note">First-time setup compiles a lot of Julia — this is the slow step. Leave this page open; it will connect by itself.</span>`:null}
                                  </div>
                                  <button class="remote-cancel" title="Cancel this connection" onClick=${()=>j(e)}>Cancel</button>
                              </div>`)}
                      ${Object.values(L).some(e=>"error"===e.state)?(0,r.html)`<p class="opener-error">${Object.entries(L).filter(([e,t])=>"error"===t.state).map(([e,t])=>`${e}: ${t.detail}`).join(" · ")}</p>`:null}
                  </section>`:null}
            ${Object.entries(P).filter(([e,t])=>"ready"!==t.state&&"error"!==t.state).map(([e,t])=>(0,r.html)`<div class="remote-progress" key=${e}>
                        <span class="remote-spinner"></span>
                        <div class="remote-progress-text">
                            <strong>Starting ${u(e)} — ${t.state}</strong>
                            <span>${t.detail}</span>
                        </div>
                        <button class="remote-cancel" title="Cancel this launch" onClick=${()=>W(e)}>Cancel</button>
                    </div>`)}
            ${Object.values(P).some(e=>"error"===e.state)?(0,r.html)`<p class="opener-error">
                      ${Object.entries(P).filter(([e,t])=>"error"===t.state).map(([e,t])=>`${u(e)}: ${t.detail}`).join(" · ")}
                  </p>`:null}
            ${null==y?null:(0,r.html)`<p class="opener-error">${y}</p>`}
        </div>
    </div>`},R=e=>{let t=getComputedStyle(document.documentElement),n=(e,n)=>t.getPropertyValue(e).trim()||n;return"light"===e?{background:n("--terminal-light-bg","#fbfbfb"),foreground:n("--terminal-light-fg","#24292f"),cursor:"#24292f",cursorAccent:"#fbfbfb",selectionBackground:"#b4d5fe",black:"#24292f",red:"#cf222e",green:"#116329",yellow:"#4d2d00",blue:"#0969da",magenta:"#8250df",cyan:"#1b7c83",white:"#6e7781",brightBlack:"#57606a",brightRed:"#a40e26",brightGreen:"#1a7f37",brightYellow:"#633c01",brightBlue:"#218bff",brightMagenta:"#a475f9",brightCyan:"#3192aa",brightWhite:"#8c959f"}:{background:n("--terminal-bg","#1f1f1f"),foreground:n("--terminal-fg","#dddddd")}},I=({tid:e,cwd:t,visible:n,scheme:o,notebook_env:l})=>{let i=(0,r.useRef)(null),s=(0,r.useRef)(!1),u=(0,r.useRef)(null),d=(0,r.useRef)(null),p=(0,r.useRef)(null),h=(0,r.useRef)(null),m=(0,r.useRef)(null),b=(0,r.useRef)(null),f=(0,r.useRef)(null),g=(0,r.useRef)(o);(0,r.useEffect)(()=>{if(g.current=o,null!=m.current)try{m.current.options.theme=R(o)}catch{}},[o]);let w=(0,r.useCallback)(()=>{clearTimeout(d.current),d.current=setTimeout(()=>{let e=i.current,t=u.current;if(null==e||null==t||null===e.offsetParent||e.clientWidth<24||e.clientHeight<24)return;try{t.fit()}catch{}let n=m.current;if(null!=n)try{let e=p.current;if(p.current=null,null!=e){let t=n.buffer.active;e<=0?n.scrollToBottom():n.scrollLines(Math.max(0,t.baseY-e)-t.viewportY)}n._core?.viewport?.syncScrollArea?.(!0),n.refresh(0,n.rows-1)}catch{}},120)},[]);return(0,r.useEffect)(()=>{if(!n){let e=m.current;if(null!=e)try{p.current=e.buffer.active.baseY-e.buffer.active.viewportY}catch{}return}s.current?w():null!=i.current&&(s.current=!0,(async()=>{let[{Terminal:n},{FitAddon:o},r]=await Promise.all([a("hmt3d"),a("aDKOm"),c("./api/v1/config").catch(()=>null)]),s=new n({fontSize:13,fontFamily:"JuliaMono, SFMono-Regular, Menlo, Consolas, monospace",cursorBlink:!0,scrollback:5e3,...r?.windows?{windowsPty:{backend:"conpty"}}:{},theme:R(g.current)}),d=new o;if(s.loadAddon(d),u.current=d,m.current=s,null==i.current){try{s.dispose()}catch{}m.current=null;return}s.open(i.current);let p=null;s.attachCustomKeyEventHandler(e=>"keydown"!==e.type||!((e.metaKey||e.ctrlKey)&&("c"===e.key||"C"===e.key)&&s.hasSelection())||(navigator.clipboard?.writeText(s.getSelection()).catch(()=>{}),!1));let v=async e=>{let t=Array.from(e.clipboardData?.items??[]).find(e=>e.type?.startsWith("image/")),n=t?.getAsFile()??Array.from(e.clipboardData?.files??[]).find(e=>e.type?.startsWith("image/"));if(null!=n){e.preventDefault(),e.stopPropagation();try{let e=new Uint8Array(await n.arrayBuffer()),t="";for(let n=0;n<e.length;n+=32768)t+=String.fromCharCode.apply(null,e.subarray(n,n+32768));let a=n.type.split("/")[1]||"png";p?.readyState===WebSocket.OPEN&&p.send(`2:${a}:${btoa(t)}`)}catch{}}};s.element?.addEventListener("paste",v,{capture:!0}),f.current=()=>s.element?.removeEventListener("paste",v,{capture:!0});try{await document.fonts?.ready}catch{}if(null!=i.current&&null!==i.current.offsetParent&&i.current.clientWidth>=24&&i.current.clientHeight>=24)try{d.fit()}catch{}w();let $="https:"===window.location.protocol?"wss":"ws",y=t?`&cwd=${encodeURIComponent(t)}`:"",k=`&rows=${s.rows}&cols=${s.cols}`,S=l?`&notebook_env=${encodeURIComponent(l)}`:"",C=new URL(`./terminal?tid=${e}${y}${k}${S}`,window.location.href);C.protocol=`${$}:`,h.current=p=new WebSocket(C.href),p.binaryType="arraybuffer",p.onmessage=e=>{if("string"!=typeof e.data)return void s.write(new Uint8Array(e.data));let t=null;try{t=JSON.parse(e.data)}catch{}if(null!=t){if(Number.isFinite(t.rows)&&Number.isFinite(t.cols)&&(s.rows!==t.rows||s.cols!==t.cols))try{s.resize(t.cols,t.rows)}catch{}t.replayed&&(()=>{let e=i.current;if(null!=e&&null!==e.offsetParent&&e.clientWidth>=24&&e.clientHeight>=24)try{d.fit()}catch{}p?.readyState===WebSocket.OPEN&&p.send(`1:${s.rows},${s.cols}`)})()}},p.onopen=()=>w(),p.onclose=()=>s.write("\r\n\x1b[2m[disconnected — the shell is still running; reload to reattach]\x1b[0m\r\n"),s.onData(e=>p.readyState===WebSocket.OPEN&&p.send("0:"+e)),s.onResize(({rows:e,cols:t})=>p.readyState===WebSocket.OPEN&&p.send(`1:${e},${t}`));let _=new ResizeObserver(()=>w());_.observe(i.current),b.current=_})())},[n,w]),(0,r.useEffect)(()=>()=>{clearTimeout(d.current),f.current?.(),f.current=null;try{b.current?.disconnect()}catch{}b.current=null;let e=h.current;if(null!=e){e.onclose=null,e.onmessage=null,e.onopen=null,e.onerror=null;try{e.close()}catch{}}h.current=null;try{m.current?.dispose()}catch{}m.current=null,u.current=null},[]),(0,r.html)`<div class="terminal-host" ref=${i}></div>`},T=new Map,L=({path:e,visible:t})=>{let n=(0,r.useRef)(null),o=(0,r.useRef)(null),l=(0,r.useRef)(!1),[u,d]=(0,r.useState)(!1),[p,h]=(0,r.useState)("loading…"),m=(0,r.useCallback)(async()=>{let t=o.current;if(null!=t)try{await c(`./api/v1/file/save?path=${encodeURIComponent(e)}`,{method:"POST",body:t.state.doc.toString()}),T.set(e,!1),d(!1),h("saved"),setTimeout(()=>h(""),1500)}catch(e){h(String(e))}},[e]);return(0,r.useEffect)(()=>{t&&!l.current&&null!=n.current&&(l.current=!0,(async()=>{try{let t=await a("iCed3"),r=await s(`./api/v1/file?path=${encodeURIComponent(e)}`),l=t.HighlightStyle.define([{tag:t.tags.keyword,color:"var(--cm-color-keyword)"},{tag:t.tags.comment,color:"var(--cm-color-comment)",fontStyle:"italic"},{tag:t.tags.string,color:"var(--cm-color-string)"},{tag:t.tags.number,color:"var(--cm-color-literal)"},{tag:t.tags.literal,color:"var(--cm-color-literal)"},{tag:t.tags.macroName,color:"var(--cm-color-macro)"},{tag:t.tags.variableName,color:"var(--cm-color-variable)"},{tag:t.tags.heading,color:"var(--cm-color-md)",fontWeight:"700"},{tag:t.tags.link,color:"var(--cm-color-link)"}],{all:{color:"var(--cm-color-editor-text)"}}),c=e.split(".").pop()?.toLowerCase(),u="jl"===c?[t.julia()]:"md"===c?[t.markdown()]:"toml"===c?(()=>{try{return[t.StreamLanguage.define(t.toml)]}catch{return[]}})():"css"===c?[t.css()]:"js"===c||"mjs"===c?[t.javascript()]:"html"===c?[t.html()]:"py"===c?[t.python()]:[],p=new t.EditorView({state:t.EditorState.create({doc:r,extensions:[t.lineNumbers(),t.history(),t.drawSelection(),t.indentOnInput(),t.bracketMatching(),t.highlightActiveLine(),t.syntaxHighlighting(l),...u,t.keymap.of([{key:"Mod-s",run:()=>(m(),!0)},...t.defaultKeymap,...t.historyKeymap]),t.EditorView.updateListener.of(t=>{t.docChanged&&(T.set(e,!0),d(!0))}),t.EditorView.theme({},{dark:(0,i.prefers_dark)()})]}),parent:n.current});if(null==n.current){try{p.destroy()}catch{}return}o.current=p,h("")}catch(e){h(String(e))}})())},[t]),(0,r.useEffect)(()=>()=>{try{o.current?.destroy()}catch{}o.current=null},[]),(0,r.html)`<div class="file-pane">
        <div class="file-toolbar">
            <span class="file-path" title=${e}>${e}</span>
            <span class="file-status">${u?"●":""} ${p}</span>
            <button class="file-save ${u?"dirty":""}" onClick=${m} title="Save (Ctrl/Cmd+S)">Save</button>
        </div>
        <div class="file-editor" ref=${n}></div>
    </div>`};(()=>{try{return null!=window.frameElement&&null!=window.parent.document.getElementById("land-app")}catch(e){return!1}})()?window.parent.postMessage({type:"spacestation:close-notebook-tab"},location.origin):(0,r.render)((0,r.html)`<${()=>{let[e,t]=(0,r.useState)(null),[n,a]=(0,r.useState)({}),[o,i]=(0,r.useState)(new Set),b=(0,r.useRef)(o);(0,r.useEffect)(()=>{b.current=o},[o]);let[w,v]=(0,r.useState)(!1),[k,S]=(0,r.useState)([]),[C,R]=(0,r.useState)([]),[O,P]=(0,r.useState)(null),[x,U]=(0,r.useState)(null),[A,D]=(0,r.useState)(()=>Number(localStorage.getItem("spacestation sidebar width"))||290),[N,M]=(0,r.useState)(()=>"true"===localStorage.getItem("spacestation sidebar hidden")),[K,j]=(0,r.useState)(()=>"true"===localStorage.getItem("spacestation terminal open")),[H,W]=(0,r.useState)(()=>Number(localStorage.getItem("spacestation terminal height"))||280),[B,J]=(0,r.useState)(()=>Number(localStorage.getItem("spacestation terminal width"))||420),[z,F]=(0,r.useState)(()=>"right"===localStorage.getItem("spacestation terminal dock")?"right":"bottom"),[q,Y]=(0,r.useState)(()=>"light"===localStorage.getItem("spacestation terminal scheme")?"light":"dark"),Q=(0,r.useRef)(!1);K&&(Q.current=!0);let[V,X]=(0,r.useState)(!1),[G,Z]=(0,r.useState)(!1),ee=(0,r.useRef)(null),et=(0,r.useRef)({tabs:[],active:null,terminal_tab:!1}),en=(0,r.useCallback)(e=>{let t;if(e.defaultPrevented||e.isComposing)return;let n=navigator.platform.toUpperCase().includes("MAC"),a=n?e.metaKey&&!e.ctrlKey:e.ctrlKey&&!e.metaKey,o=0,r=-1;if(!e.ctrlKey||e.metaKey||e.altKey||"Tab"!==e.key?!e.ctrlKey||e.metaKey||e.altKey||e.shiftKey||"PageUp"!==e.key&&"PageDown"!==e.key?n&&e.metaKey&&e.shiftKey&&!e.altKey&&!e.ctrlKey&&("BracketLeft"===e.code||"BracketRight"===e.code)?o="BracketLeft"===e.code?-1:1:n&&e.metaKey&&e.altKey&&!e.shiftKey&&!e.ctrlKey&&("ArrowLeft"===e.key||"ArrowRight"===e.key)?o="ArrowLeft"===e.key?-1:1:a&&!e.shiftKey&&!e.altKey&&/^Digit[1-9]$/.test(e.code)&&(r=Number(e.code.slice(5))):o="PageUp"===e.key?-1:1:o=e.shiftKey?-1:1,0===o&&r<0)return;let{tabs:l,active:i,terminal_tab:s}=et.current,c=[...l.map(e=>e.id),...s?["__terminal__"]:[]];if(0!==c.length){if(e.preventDefault(),e.stopPropagation(),r>0)t=c[9===r?c.length-1:Math.min(r,c.length)-1];else{let e=c.indexOf(i??"");t=c[(e+o+c.length)%c.length]}null!=t&&P(t)}},[]);(0,r.useEffect)(()=>(window.addEventListener("keydown",en,!0),()=>window.removeEventListener("keydown",en,!0)),[en]);let ea=(0,r.useCallback)(e=>{try{e?.addEventListener("keydown",en,!0)}catch{}},[en]),[eo,er]=(0,r.useState)(null);(0,r.useEffect)(()=>{if(!G)return;let e=e=>{null==ee.current||ee.current.contains(e.target)||Z(!1)},t=e=>{"Escape"===e.key&&Z(!1)};return document.addEventListener("pointerdown",e),document.addEventListener("keydown",t),()=>{document.removeEventListener("pointerdown",e),document.removeEventListener("keydown",t)}},[G]),et.current={tabs:C,active:O,terminal_tab:K&&"tab"===z};let el=null!=O&&"__terminal__"!==O&&C.find(e=>e.id===O&&"file"!==e.kind);(0,r.useEffect)(()=>{if(!G)return;if(!el)return void er(null);let e=!0;return c(`./api/v1/notebook/env?id=${encodeURIComponent(el.id)}`).then(t=>e&&er({id:el.id,managed:t?.managed===!0,command:t?.command})).catch(()=>e&&er({id:el.id,managed:!1})),()=>{e=!1}},[G,el?.id]);let ei=(0,r.useRef)(!1),es=(0,r.useRef)(null);if(null==es.current){let e=window.location.hash.match(/[#&]homebase=([^&]+)/);if(e)try{es.current=decodeURIComponent(e[1])}catch(e){}}let[ec,eu]=(0,r.useState)(!1),[ed,ep]=(0,r.useState)(/^\/w\/[^/]+\//.test(window.location.pathname)),[eh,em]=(0,r.useState)(m),[eb,ef]=(0,r.useState)(!1),[eg,ew]=(0,r.useState)(l.pluto_file_extensions);(0,r.useEffect)(()=>{c("./api/v1/config").then(e=>{eu(!!(e&&e.tunneled)),em(m||!!(e&&e.desktop)),ep(!!(e&&e.hub&&null!=e.wid)),Array.isArray(e?.notebook_extensions)&&e.notebook_extensions.length>0&&ew(e.notebook_extensions)}).catch(()=>{})},[]);let ev=(0,r.useCallback)(e=>(0,l.has_pluto_file_extension)(e,eg),[eg]);(0,r.useEffect)(()=>{w&&(window.name=p)},[w]),(0,r.useEffect)(()=>{document.title=w?"SpaceStation (launcher)":e?.root?`SpaceStation \u{2014} ${u(e.root)}`:"SpaceStation"},[w,e]);let e$=(0,r.useCallback)(()=>{if(eh&&h)return void f({type:"spacestation:focus-launcher"});if(eh&&null!=es.current){window.location.href=es.current;return}if(!ed&&(ec||eh))return void fetch("./api/v1/workspace/close",{method:"POST"}).finally(()=>window.location.reload());try{if(window.opener&&!window.opener.closed)return void window.opener.focus()}catch(e){}if(ed&&null==es.current&&(es.current=new URL("../../",window.location.href).href),es.current){let e=null;try{e=window.open("",p)}catch(e){}if(null==e)return void window.open(es.current,p);let t=!1;try{t="about:blank"===e.location.href}catch(e){}if(t)try{e.location.href=es.current}catch(e){}try{e.focus()}catch(e){}return}X(!0)},[ec,eh,ed]),[ey,ek]=(0,r.useState)([]),[eS,eC]=(0,r.useState)(null),e_=(0,r.useRef)(null),[eE,eR]=(0,r.useState)(null),eI=(0,r.useRef)(-1);(0,r.useEffect)(()=>{let t=e?.root??null;if(null==t||e_.current===t)return;let n=(e=>{if("string"!=typeof e||0===e.length)return[];try{let t=JSON.parse(localStorage.getItem($)??"{}"),n=t&&"object"==typeof t&&!Array.isArray(t)?t[e]:null;if(!Array.isArray(n)){let e=JSON.parse(localStorage.getItem(y)??"[]");Array.isArray(e)&&e.length>0&&(n=e,localStorage.removeItem(y))}if(!Array.isArray(n))return[];return n.filter(e=>e&&"string"==typeof e.tid).map(e=>({tid:e.tid,label:e.label??"Terminal"}))}catch{return[]}})(t);e_.current=t,ek(n),eC(n.length?n[n.length-1].tid:null);let a=n.map(e=>parseInt(String(e.label??"").replace(/[^0-9]/g,""),10)).filter(e=>!isNaN(e));eI.current=a.length?Math.max(...a):0,eR(t)},[e?.root]),(0,r.useEffect)(()=>{localStorage.setItem("spacestation sidebar width",String(A)),localStorage.setItem("spacestation sidebar hidden",String(N)),localStorage.setItem("spacestation terminal open",String(K)),localStorage.setItem("spacestation terminal height",String(H)),localStorage.setItem("spacestation terminal scheme",q),localStorage.setItem("spacestation terminal width",String(B)),localStorage.setItem("spacestation terminal dock",z)},[A,N,K,H,B,z,q]),(0,r.useEffect)(()=>{let t=e?.root??null;null!=t&&e_.current===t&&eE===t&&((e,t)=>{if("string"!=typeof e||0===e.length)return;let n={};try{let e=JSON.parse(localStorage.getItem($)??"{}");e&&"object"==typeof e&&!Array.isArray(e)&&(n=e)}catch{}n[e]=t.map(e=>({tid:e.tid,label:e.label})),localStorage.setItem($,JSON.stringify(n))})(t,ey)},[ey,eE,e?.root]),(0,r.useEffect)(()=>{let e=e=>{let t=!1;for(let e of T.values())if(e){t=!0;break}t&&(e.preventDefault(),e.returnValue="")};return window.addEventListener("beforeunload",e),()=>window.removeEventListener("beforeunload",e)},[]);let eT=(0,r.useCallback)(e=>{e.preventDefault();let t="bottom"===z;document.body.classList.add(t?"resizing-v":"resizing");let n=e=>t?W(Math.max(120,Math.min(window.innerHeight-220,window.innerHeight-e.clientY-12))):J(Math.max(240,Math.min(window.innerWidth-420,window.innerWidth-e.clientX-12))),a=()=>{document.body.classList.remove("resizing-v"),document.body.classList.remove("resizing"),window.removeEventListener("pointermove",n),window.removeEventListener("pointerup",a)};window.addEventListener("pointermove",n),window.addEventListener("pointerup",a)},[z]),eL=(0,r.useCallback)((e,t,n="notebook")=>{R(a=>a.some(t=>t.id===e)?a:[...a,{id:e,path:t,kind:n}]),P(e)},[]),eO=(0,r.useCallback)(e=>{eL(`file:${e}`,e,"file")},[eL]),eP=(0,r.useCallback)((t={})=>{if(e?.root==null||e_.current!==e.root)return;eI.current+=1;let n="term-"+Math.random().toString(36).slice(2,12),a={tid:n,label:t.label??`Terminal ${eI.current}`};t.notebook_env&&(a.notebook_env=t.notebook_env),ek(e=>[...e,a]),eC(n),j(!0)},[e?.root]),ex=(0,r.useCallback)(e=>{fetch(`./api/v1/terminal/close?tid=${encodeURIComponent(e)}`,{method:"POST"}).catch(()=>{}),ek(t=>{let n=t.filter(t=>t.tid!==e);return eC(t=>t===e?n.length?n[n.length-1].tid:null:t),n})},[]);(0,r.useEffect)(()=>{K&&e?.root!=null&&e_.current===e.root&&eE===e.root&&0===ey.length&&eP()},[K,ey.length,eE,e?.root]);let eU=(0,r.useCallback)(async e=>{try{let{entries:t}=await c(`./api/v1/workspace/listing?path=${encodeURIComponent(e)}`);a(n=>({...n,[e]:t}))}catch(t){if(!b.current.has(e))return;a(n=>({...n,[e]:[{name:"…",path:`${e}/\u{2026}`,type:"unreadable",detail:String(t)}]}))}},[]),eA=(0,r.useCallback)(e=>{let t=!b.current.has(e);i(n=>{let a=new Set(n);return t?a.add(e):a.delete(e),b.current=a,a}),t&&eU(e)},[eU]),[eD,eN]=(0,r.useState)(null),eM=(0,r.useRef)(!1),eK=(0,r.useCallback)(async()=>{if(eM.current)return;eM.current=!0;let e=new AbortController,n=setTimeout(()=>e.abort(),15e3),o=e.signal;try{let e=await fetch("./api/v1/workspace",{signal:o});if(404===e.status){v(!0),t(null),U(null);return}if(e.ok){v(!1),t(await e.json());let n=[...b.current],o=await Promise.all(n.map(e=>c(`./api/v1/workspace/listing?path=${encodeURIComponent(e)}`).then(t=>[e,t.entries]).catch(()=>[e,null])));a(e=>{let t={...e};for(let[e,n]of o)null!=n&&(t[e]=n);return t})}else throw Error(`workspace request failed: ${e.status}`);let n=await fetch("./api/v1/notebooks",{signal:o});if(503===n.status||504===n.status){let e=await n.json().catch(()=>({}));eN(t=>({kind:e.workspace_down?"down":"busy",since:t?.since??Date.now(),detail:String(e.detail??"")})),U(null);return}if(!n.ok)throw Error(`notebooks request failed: ${n.status}`);let r=await n.json();eN(null),S(r),ei.current||(ei.current=!0,r.forEach(e=>eL(e.notebook_id,e.path))),U(null)}catch(e){e?.name==="AbortError"?eN(e=>({kind:"busy",since:e?.since??Date.now(),detail:"no answer within 15 seconds"})):e instanceof TypeError?ef(!0):U(String(e))}finally{clearTimeout(n),eM.current=!1}},[eL]),ej=(0,r.useCallback)(async()=>{let t=e?.root;if(null!=t){eN(e=>({kind:"busy",since:e?.since??Date.now(),detail:"restarting the workspace server…"}));try{let e=await c(`./api/v1/local/restart?path=${encodeURIComponent(t)}`,{method:"POST"});for(;"ready"!==e.state&&"error"!==e.state;)await new Promise(e=>setTimeout(e,1e3)),e=await c(`./api/v1/local/status?path=${encodeURIComponent(t)}`);"ready"===e.state?window.location.reload():U(String(e.detail??"the workspace server did not start"))}catch(e){U(String(e))}}},[e]);(0,r.useEffect)(()=>{eK();let e=setInterval(eK,1e4);return()=>clearInterval(e)},[]),(0,r.useEffect)(()=>{let e=()=>{"visible"===document.visibilityState&&eK()};return window.addEventListener("online",e),document.addEventListener("visibilitychange",e),window.addEventListener("focus",e),()=>{window.removeEventListener("online",e),document.removeEventListener("visibilitychange",e),window.removeEventListener("focus",e)}},[eK]),(0,r.useEffect)(()=>{if(!eb)return;let e=!1,t=null,n=1e3,a=async()=>{if(!e){try{if((await fetch("./ping",{cache:"no-store"})).ok)return void window.location.reload()}catch{}n=Math.min(1.5*n,5e3),e||(t=setTimeout(a,n))}};return t=setTimeout(a,700),()=>{e=!0,null!=t&&clearTimeout(t)}},[eb]);let eH=(0,r.useCallback)(e=>{e.preventDefault(),document.body.classList.add("resizing");let t=e=>D(Math.max(180,Math.min(560,e.clientX-12))),n=()=>{document.body.classList.remove("resizing"),window.removeEventListener("pointermove",t),window.removeEventListener("pointerup",n)};window.addEventListener("pointermove",t),window.addEventListener("pointerup",n)},[]),eW=(0,r.useCallback)(async e=>{try{let t=await s(`./open?path=${encodeURIComponent(e)}`,{method:"POST"});eL(t,e),eK()}catch(e){U(String(e))}},[eL,eK]),eB=(0,r.useCallback)(async()=>{if(null==e)return;let t=prompt("Notebook file name (created in the workspace):","new notebook.jl");if(null!=t)try{let n=await s("./new",{method:"POST"}),a=`${e.root}/${ev(t)?t:t+".jl"}`;await s(`./move?id=${encodeURIComponent(n)}&newpath=${encodeURIComponent(a)}`,{method:"POST"}),eL(n,a),eK()}catch(e){U(String(e))}},[e,eL,eK,ev]),eJ=(0,r.useCallback)(async e=>{if(e.startsWith("file:")){let t=e.slice(5);if(T.get(t)&&!await d("This file has unsaved changes. Close anyway?",{action:"Close without saving",danger:!0}))return;T.delete(t)}R(t=>{let n=t.filter(t=>t.id!==e);return P(t=>t===e?n.length>0?n[n.length-1].id:null:t),n})},[]);(0,r.useEffect)(()=>{let e=e=>{if(e.origin!==location.origin||e.data?.type!=="spacestation:close-notebook-tab")return;let t=[...document.querySelectorAll("#frames iframe")].find(t=>t.contentWindow===e.source),n=null==t?void 0:t.dataset.tabId;null!=n&&eJ(n)};return window.addEventListener("message",e),()=>window.removeEventListener("message",e)},[eJ]);let ez=(0,r.useCallback)(async t=>{let n=prompt(`New file in ${u(t)}/ \u{2014} a name ending in .jl or .plutojl becomes a Pluto notebook:`,"notebook.jl");if(null==n||""===n.trim())return;let a=`${t}/${n.trim()}`;try{if(ev(n.trim())){let e=await s("./new",{method:"POST"});await s(`./move?id=${encodeURIComponent(e)}&newpath=${encodeURIComponent(a)}`,{method:"POST"}),eL(e,a)}else await c(`./api/v1/file/new?path=${encodeURIComponent(a)}`,{method:"POST"}),eO(a);null==e||t===e.root||b.current.has(t)?eU(t):eA(t),eK()}catch(e){U(String(e))}},[eL,eO,eK,eA,eU,e,ev]),eF=(0,r.useCallback)(async e=>{let t="notebook"===e.type?"notebook (it will be shut down if running; its output cache is deleted too)":"file";if(await d(`Delete ${e.name}?

This permanently deletes the ${t}. There is no trash.`,{action:"Delete",danger:!0}))try{await c(`./api/v1/file/delete?path=${encodeURIComponent(e.path)}`,{method:"POST"}),R(t=>t.filter(t=>t.path!==e.path)),T.delete(e.path),eK()}catch(e){U(String(e))}},[eK]),eq=(0,r.useCallback)(async e=>{if(await d("Shut down this notebook session? The file stays on disk; outputs are cached.",{action:"Shut down"}))try{await s(`./shutdown?id=${encodeURIComponent(e)}`,{method:"POST"}),eJ(e),eK()}catch(e){U(String(e))}},[eJ,eK]),eY=K&&"tab"===z,eQ=(0,r.useCallback)(()=>{let e=!K;j(e),e&&"tab"===z&&P("__terminal__"),e||P(e=>"__terminal__"===e?null:e)},[K,z]),eV=(0,r.useCallback)(()=>{let e="bottom"===z?"right":"right"===z?"tab":"bottom";"tab"===e?(j(!0),P("__terminal__")):"tab"===z&&P(e=>"__terminal__"===e?null:e),F(e)},[z]),eX=t=>(0,r.html)`
        <div class="terminal-tabs">
            <div class="terminal-tab-scroller">
                ${(e_.current===e?.root?ey:[]).map(e=>(0,r.html)`<div class="tab terminal-tab ${e.tid===eS?"active":""}" key=${e.tid}>
                        <button class="title" title=${e.label} onClick=${()=>eC(e.tid)}>
                            <span class="tab-term-icon">⌨</span>${e.label}
                        </button>
                        <button class="close" title="Close terminal" onClick=${()=>ex(e.tid)}>×</button>
                    </div>`)}
                <button class="new-terminal-tab" title="New terminal" onClick=${()=>eP()}>
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
            ${(e_.current===e?.root?ey:[]).map(n=>(0,r.html)`<div key=${n.tid} class="terminal-body ${n.tid===eS?"active":""}">
                    <${I} tid=${n.tid} cwd=${e?.root} visible=${t&&n.tid===eS} scheme=${q} notebook_env=${n.notebook_env} />
                </div>`)}
        </div>
    `,eG=(0,r.useCallback)(async()=>{if(!await d(ed?`Shut down the server for this workspace?

Its running notebooks stop; this terminal, the launcher and other workspaces keep running.`:"Shut down the SpaceStation server?\n\nRunning notebooks and the integrated terminal will stop. SSH remote servers keep running and can be reattached later.",{action:"Shut down"}))return;fetch("./api/v1/shutdown",{method:"POST"}).catch(()=>{});let e=async()=>{try{if(ed){let e=await fetch("./api/v1/notebooks",{cache:"no-store"});return 502!==e.status&&503!==e.status&&504!==e.status}return await fetch("./ping",{method:"GET",cache:"no-store"}),!0}catch{return!1}},t=Date.now()+(ed?15e3:8e3);for(;Date.now()<t;)if(await new Promise(e=>setTimeout(e,400)),!await e()){if(ed)return void eN({kind:"down",since:Date.now(),detail:"shut down from this page"});document.body.innerHTML='<div style="font: 15px/1.6 system-ui, sans-serif; padding: 3rem; text-align: center; color: #888">SpaceStation has shut down. You can close this tab.</div>';return}U("Shutdown was requested, but the server is still responding — it may not have shut down.")},[ed]);return w||V?(0,r.html)`<${E} on_cancel=${w?null:()=>X(!1)} tunneled=${ec} desktop=${eh} />`:(0,r.html)`
        <div id="land">
            ${eb?(0,r.html)`<div class="reconnect-overlay" role="status" aria-live="polite">
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
            ${null!=eD&&!eb?(0,r.html)`<div class="workspace-status ${eD.kind}" role="status" aria-live="polite">
                      ${"down"===eD.kind?(0,r.html)`<span>The server for this workspace stopped answering. Its notebooks are gone with it; the sidebar and terminal are fine.</span>
                                <button onClick=${ej}>Restart workspace server</button>`:(0,r.html)`<span>The server for this workspace is busy (${Math.max(1,Math.round((Date.now()-eD.since)/1e3))}s) — notebooks will catch up; the sidebar and terminal keep working.</span>`}
                  </div>`:null}
            ${N?(0,r.html)`<button id="sidebar-reopen" title="Show sidebar" onClick=${()=>M(!1)}>☰</button>`:(0,r.html)`<aside style=${`width: ${A}px`}>
                <header class="bubble">
                    <div class="header-row">
                        <button class="land-logo-button" title="Back to homebase (open &amp; manage workspaces)" onClick=${e$}>
                            <img class="land-logo" src=${g} alt="SpaceStation" />
                        </button>
                        <div class="header-text">
                            <h1 title=${e?.root??""}>Space<span class="land-accent">Station</span></h1>
                            ${e?.root?(0,r.html)`<p class="workspace-root" title=${e.root}>${u(e.root)||e.root}</p>`:null}
                        </div>
                        <div class="header-buttons">
                            <div class="header-menu" ref=${ee}>
                                <button class="header-button menu-button ${G?"active":""}" title="More actions" aria-haspopup="menu" aria-expanded=${G} onClick=${()=>Z(e=>!e)}><span class="menu-dots"></span></button>
                                ${G?(0,r.html)`<div class="header-menu-popover" role="menu">
                                          <button
                                              class="header-menu-item"
                                              role="menuitem"
                                              disabled=${!(el&&eo?.id===el.id&&eo.managed)}
                                              title=${!el?"Open a notebook tab first":eo?.id!==el.id?"Checking the notebook's environment…":eo.managed?`Open a terminal in this notebook's package environment. It runs:
${eo.command}`:"This notebook has no Pluto-managed environment yet: it has not run, or it activates its own with Pkg.activate"}
                                              onClick=${()=>{Z(!1),el&&eP({label:`env: ${u(el.path)}`,notebook_env:el.id})}}
                                          >
                                              <span class="menu-icon terminal"></span>Open env in terminal
                                          </button>
                                          <button class="header-menu-item danger" role="menuitem" onClick=${()=>{Z(!1),eG()}}><span class="menu-icon power"></span>Shut down server</button>
                                      </div>`:null}
                            </div>
                            <button class="header-button collapse-button" title="Hide sidebar" onClick=${()=>M(!0)}><span class="collapse-icon"></span></button>
                        </div>
                    </div>
                </header>
                <section class="files bubble">
                    <h2>
                        Workspace
                        ${e?.git==null?null:(0,r.html)`<span
                                  class="git-branch"
                                  title=${e.git.detached?`Detached HEAD at ${e.git.branch}`:`On branch ${e.git.branch}`}
                              >
                                  <span class="git-branch-icon"></span><span class="git-branch-name">${e.git.branch}</span>
                              </span>`}
                        ${null==e?null:(0,r.html)`<button class="row-action h2-action" title="New notebook or file in the workspace root" onClick=${()=>ez(e.root)}>+</button>`}
                    </h2>
                    <ul class="tree">
                        ${null==e?null:e.entries.map(e=>(0,r.html)`<${_}
                                          key=${e.path}
                                          entry=${e}
                                          listings=${n}
                                          expanded=${o}
                                          on_toggle=${eA}
                                          on_open_notebook=${eW}
                                          on_open_file=${eO}
                                          on_create_in=${ez}
                                          on_delete=${eF}
                                          depth=${0}
                                      />`)}
                    </ul>
                </section>
                <section class="running bubble">
                    <h2>Running</h2>
                    <ul>
                        ${k.map(e=>(0,r.html)`<li>
                                <button class="entry" title=${e.path} onClick=${()=>eL(e.notebook_id,e.path)}>
                                    <span class="icon running-dot"></span>${u(e.path)}
                                </button>
                                <button class="shutdown" title="Shut down this notebook" onClick=${()=>eq(e.notebook_id)}>✕</button>
                            </li>`)}
                    </ul>
                </section>
                <footer>
                    <button class="new-notebook" onClick=${eB}>+ New notebook</button>
                </footer>
            </aside>`}
            ${N?null:(0,r.html)`<div id="sidebar-resizer" onPointerDown=${eH}></div>`}
            <main>
                <div class="main-split ${z}">
                    <div class="editor-card">
                        <nav id="tabs">
                            <div class="tab-scroller">
                                ${C.map(e=>(0,r.html)`<div class="tab ${e.id===O?"active":""}" key=${e.id}>
                                        <button class="title" title=${e.path} onClick=${()=>P(e.id)}>${u(e.path)}</button>
                                        <button class="close" title="Close tab (notebook keeps running)" onClick=${()=>eJ(e.id)}>×</button>
                                    </div>`)}
                                ${eY?(0,r.html)`<div class="tab terminal-tab ${"__terminal__"===O?"active":""}" key="__terminal__">
                                          <button class="title" title="Terminal" onClick=${()=>P("__terminal__")}>
                                              <span class="tab-term-icon">⌨</span>Terminal
                                          </button>
                                          <button class="close" title="Hide terminal" onClick=${()=>{j(!1),P(e=>"__terminal__"===e?null:e)}}>×</button>
                                      </div>`:null}
                            </div>
                            <button class="terminal-toggle ${K?"active":""}" title="Toggle the integrated terminal (runs in the workspace folder)" onClick=${eQ}>⌨ Terminal</button>
                            ${K?(0,r.html)`<button
                                      class="terminal-toggle dock-toggle"
                                      title=${"bottom"===z?"Move terminal to the right":"right"===z?"Embed terminal as an editor tab":"Dock terminal to the bottom"}
                                      onClick=${eV}
                                  >
                                      ${"bottom"===z?"◨":"right"===z?"▭":"⬓"}
                                  </button>`:null}
                        </nav>
                        <div id="frames">
                            ${C.map(e=>"file"===e.kind?(0,r.html)`<div key=${e.id} class="pane ${e.id===O?"active":""}">
                                          <${L} path=${e.path} visible=${e.id===O} />
                                      </div>`:(0,r.html)`<iframe
                                          key=${e.id}
                                          data-tab-id=${e.id}
                                          src=${`./edit?id=${e.id}`}
                                          class=${e.id===O?"active":""}
                                          onLoad=${e=>ea(e.target.contentWindow)}
                                      ></iframe>`)}
                            ${eY?(0,r.html)`<div class="pane terminal-area-pane ${"__terminal__"===O?"active":""}">
                                      ${eX(eY&&"__terminal__"===O)}
                                  </div>`:null}
                            ${0===C.length&&"__terminal__"!==O?(0,r.html)`<div class="empty-state">
                                      <p>Open a notebook from the workspace on the left, or create a new one.</p>
                                      <p class="hint">Agents can work here too: edit any notebook file, or use <code>pluto-collab</code>.</p>
                                  </div>`:null}
                        </div>
                    </div>
                    ${Q.current?(0,r.html)`
                              <div
                                  id="terminal-resizer"
                                  style=${K&&"tab"!==z?"":"display: none"}
                                  onPointerDown=${eT}
                              ></div>
                              <div
                                  id="terminal-panel"
                                  class="bubble"
                                  style=${K&&"tab"!==z?"bottom"===z?`height: ${H}px`:`width: ${B}px`:"display: none"}
                              >
                                  ${"tab"!==z?eX(K&&"tab"!==z):null}
                              </div>
                          `:null}
                </div>
            </main>
            ${null==x?null:(0,r.html)`<div id="land-error">${x}</div>`}
        </div>
    `}} />`,document.querySelector("#land-app"));