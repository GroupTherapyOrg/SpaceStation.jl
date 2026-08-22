// The "official" Pluto notebook file extensions.
//
// The authoritative list is `pluto_file_extensions` in `src/notebook/path helpers.jl`; this is the
// frontend's copy of it, for the two places that must guess whether a name the user is *typing*
// would become a notebook (the file is not on disk yet, so the server cannot answer). Where the
// server can answer it does: the hub's sidebar gets each entry's `type` from the backend, and the
// hub prefers the list served at `/api/v1/config` over this one.
//
// `test/WorkspaceTree.jl` asserts this array equals the Julia one, so the two cannot drift apart.
export const pluto_file_extensions = [".pluto.jl", ".Pluto.jl", ".nb.jl", ".jl", ".plutojl", ".pluto", ".nbjl", ".pljl", ".pluto.jl.txt", ".jl.txt"]

/** Does this filename end in an extension that Pluto opens as a notebook? */
export const has_pluto_file_extension = (/** @type {String} */ name, /** @type {Array<String>} */ extensions = pluto_file_extensions) =>
    extensions.some((e) => name.endsWith(e))
