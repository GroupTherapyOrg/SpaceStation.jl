// Build-time source pin, overwritten by gen_buildinfo.ts during `deno task build*` (and restored
// after). The committed defaults mean "no pin": dev runs detect the checkout, and a managed
// environment falls back to the General registry.
//
// - `project`: absolute path of the repo the app was built from — used when it still exists on
//   the machine running the app (the build machine), so the app runs the checkout directly.
// - `source`: git url+rev to install into the managed environment on OTHER machines, so a build
//   from a branch runs that branch's code, not whatever the registry last released.

export const project: string | null = null
export const source: { url: string; rev: string } | null = null
