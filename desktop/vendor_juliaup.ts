// Build-time: fetch juliaup's PORTABLE build (a small static Rust pair — juliaup + julialauncher,
// no self-install) for a target, into vendor/<deno-target>/, which the bundle ships (--include).
// With these aboard, a machine with NO Julia needs no installer script: the app runs
// `juliaup add release` itself and launches through julialauncher — on Windows too.
//
//   deno run -A vendor_juliaup.ts [deno-target]     (defaults to the current platform)

const JULIAUP_VERSION = "1.22.2" // bump deliberately; the asset set is stable per release

const MAP: Record<string, string> = {
    "aarch64-apple-darwin": "aarch64-apple-darwin",
    "x86_64-apple-darwin": "x86_64-apple-darwin",
    "x86_64-pc-windows-msvc": "x86_64-pc-windows-gnu", // portable builds are -gnu; standalone exes
    "aarch64-pc-windows-msvc": "x86_64-pc-windows-gnu", // no arm64 portable yet; x64 runs emulated
    "x86_64-unknown-linux-gnu": "x86_64-unknown-linux-musl", // musl = static, runs anywhere
    "aarch64-unknown-linux-gnu": "aarch64-unknown-linux-musl",
}

const current = () => {
    const arch = Deno.build.arch === "aarch64" ? "aarch64" : "x86_64"
    return Deno.build.os === "darwin" ? `${arch}-apple-darwin` : Deno.build.os === "windows" ? `${arch}-pc-windows-msvc` : `${arch}-unknown-linux-gnu`
}

const target = Deno.args[0] ?? current()
const jt = MAP[target]
if (jt == null) {
    console.error(`no juliaup portable build mapping for target ${target}`)
    Deno.exit(1)
}

const here = import.meta.dirname! // OS-native (URL .pathname breaks on Windows drive letters)
const dir = `${here}/vendor/${target}`
const exe = jt.includes("windows") ? ".exe" : ""
try {
    Deno.statSync(`${dir}/juliaup${exe}`)
    console.log(`vendor: juliaup ${JULIAUP_VERSION} for ${target} already present`)
    Deno.exit(0)
} catch {
    // not vendored yet
}

const url = `https://github.com/JuliaLang/juliaup/releases/download/v${JULIAUP_VERSION}/juliaup-${JULIAUP_VERSION}-${jt}-portable.tar.gz`
console.log(`vendor: fetching ${url}`)
const res = await fetch(url)
if (!res.ok) {
    console.error(`download failed: HTTP ${res.status}`)
    Deno.exit(1)
}
Deno.mkdirSync(dir, { recursive: true })
const tarball = `${dir}/juliaup.tar.gz`
Deno.writeFileSync(tarball, new Uint8Array(await res.arrayBuffer()))
const tar = await new Deno.Command("tar", { args: ["xzf", tarball, "-C", dir] }).output()
if (!tar.success) {
    console.error("tar extraction failed")
    Deno.exit(1)
}
Deno.removeSync(tarball)

// The portable tarball ships `juliaup` and the launcher already named `julia`; find them
// wherever they landed and hoist them to the vendor root.
const wanted = new Set([`juliaup${exe}`, `julia${exe}`])
const hoist = (d: string) => {
    for (const entry of Deno.readDirSync(d)) {
        const p = `${d}/${entry.name}`
        if (entry.isDirectory) hoist(p)
        else if (wanted.has(entry.name) && p !== `${dir}/${entry.name}`) Deno.renameSync(p, `${dir}/${entry.name}`)
    }
}
hoist(dir)
for (const name of wanted) {
    Deno.statSync(`${dir}/${name}`) // throws loudly if the asset layout changed
    if (exe === "") Deno.chmodSync(`${dir}/${name}`, 0o755)
}
console.log(`vendor: juliaup ${JULIAUP_VERSION} ready in vendor/${target}/`)
