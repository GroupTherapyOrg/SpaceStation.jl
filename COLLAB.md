# SpaceStation collaboration: humans and agents on one live notebook

SpaceStation's **lazy reactive mode** (the default): a human in the browser and any number of
external tools (coding agents, scripts, CI) work on the **same live notebook session** —
same kernel, same state, both sides see everything in real time — using nothing but
**files, plain HTTP, and a tiny CLI**. No MCP servers, no plugins, no agent integrations:
any tool that can edit a file and run `curl` already works.

## Start

```julia
import SpaceStation
SpaceStation.run()        # lazy collab mode is the default
```

(or `spacestation` from a terminal, once installed as an app). Lazy mode means three things:

1. **Edits mark cells stale instead of running them.** When the notebook `.jl` file changes
   on disk (lazy mode watches it automatically), the edited cells get the familiar yellow
   *modified* marker in the browser — the exact same look as typing in a cell yourself —
   within about a second, and **nothing executes**. A "N cells are stale (RUN)" notice
   appears; click it (or run any cell) when *you* decide. Exactly like normal Pluto: running
   a cell re-runs its dependents reactively, and *other* cells' pending changes are never
   dragged in — they apply only when their own cells run (one by one, or all at once with
   Ctrl+S). The one exception is workspace-cold cells restored from cache after a restart:
   those are pulled in automatically when needed, because their values don't exist in the
   kernel yet.

2. **Outputs survive restarts.** After every run, outputs and execution keys are written to
   `<notebook>.jl.pluto-cache.toml` — a plain-TOML, deletable cache sidecar. Reopening the
   notebook restores every output whose code (and upstream results) are unchanged, instantly,
   without running anything. Cells edited while the server was off show up stale.
   The sidecar doubles as a *machine-readable view of all outputs*: any tool can read
   results by reading that file. (Add `*.pluto-cache.toml` to `.gitignore`.)

3. **A live HTTP API + CLI.** Every running server writes a connection file to
   `~/.local/state/pluto/servers/<node>-<port>.json` (port + access secret — the Jupyter
   connection-file idiom; the `<node>` prefix keeps servers on a shared `$HOME`, one per
   HPC compute node, from colliding). The `bin/pluto-collab` CLI uses it to find your server:

   ```
   pluto-collab status notebook.jl            # per-cell: stale / cold / errored / output (digest)
   pluto-collab run notebook.jl --stale       # run all stale cells; blocks; exit 1 on error
   pluto-collab run notebook.jl --cell <id>   # run one cell (+ its stale/cold ancestors)
   pluto-collab output notebook.jl --cell <id>  # read one cell's full output (status truncates; this doesn't)
   pluto-collab figure notebook.jl --cell <id>  # save one cell's rendered image to a file (PNG/SVG/…)
   pluto-collab interrupt notebook.jl         # stop a running notebook
   pluto-collab restart notebook.jl           # restart kernel + re-run all — recover a dead worker
   pluto-collab status notebook.jl --json     # same, structured
   ```

   **Cross-platform:** `pluto-collab` is a bash script (needs `curl`/`sed`, i.e. Unix). The exact
   same commands are also built into the app as `spacestation collab <cmd> …` — pure Julia, no
   external dependencies — so the agent surface works identically in a Windows PowerShell/cmd
   terminal. Either form uses `PLUTOSPACE_PORT`/`PLUTOSPACE_SECRET` when set (inside a SpaceStation
   terminal) and the connection file otherwise.

   **`status` reflects the file, always.** It re-syncs the notebook from disk on every call, so an
   agent that edits `nb.jl` and immediately runs `status` sees the correct stale set right away —
   it never has to wait for the ~½-second file watcher to catch up. (Syncing is read-only in lazy
   mode: it marks cells stale, never runs or rewrites the file.)

   Runs requested over HTTP go through the same execution queue as browser runs — you watch
   the agent's cells turn amber → running → green live in your browser, and vice versa.

## Staleness is verified, not guessed

Each cell records an **execution key**: a hash of its own code plus the *result hashes* of
the cells it depends on (a verifying trace, as in build systems). Stale marks are checked
against these keys, so:

- **Reverting an edit un-stales everything** — no runs needed.
- **Early cutoff**: if a cell re-runs but produces the same result, its dependents are
  un-marked automatically.
- **Restart verification**: cached outputs are only trusted when the keys prove that code
  and upstream results are unchanged.

Impure cells (`rand()`, time, I/O) can opt out with cell metadata `always_stale = true`
(in the file: a `# ╠═╡ always_stale = true` line) — their cached outputs are never trusted.

A restored notebook's cells are **workspace-cold**: the display is current, but the kernel
hasn't computed them in this process. Cold cells are pulled in exactly like stale ones the
first time something downstream runs (including bond/slider updates), so the session heals
itself on demand.

## The agent workflow (any agent, any terminal)

```text
1. (human)  spacestation nb.jl
2. (agent)  edits nb.jl with its normal file tools         ← human sees cells go stale, live
3. (agent)  pluto-collab status nb.jl                      ← sees exactly what's stale
4. (agent)  pluto-collab run nb.jl --stale                 ← human watches cells run, live
5. (agent)  reads outputs from the run response, status, or nb.jl.pluto-cache.toml
```

Expensive unrelated cells are never re-run: only the stale closure executes.

### Unattended / overnight loops (recovering a dead worker)

A notebook's worker can die mid-run — out-of-memory, a segfault in native code (CUDA/BLAS),
an explicit `exit()`. The editor then shows **"Process exited — restart"** and Pluto raises
`Malt.TerminatedWorkerException`. At that point `interrupt` is useless (nothing is running) and
`run` has no live process to run into — an unattended agent must **restart**:

```
pluto-collab restart nb.jl     # fresh kernel, re-runs the whole notebook; blocks; exit 1 on error
```

`restart` re-runs *everything*, so reserve it for an actual crash — on a plain cell error, fix the
cell and `run` again instead. A self-healing "run all night" loop is then:

```bash
while :; do
  pluto-collab run nb.jl --stale && { sleep 60; continue; }   # clean → wait, go again
  # run failed; if the worker is gone (not just a cell error) bring it back, then keep looping
  pluto-collab status nb.jl | grep -q 'process: no_process' && pluto-collab restart nb.jl
  sleep 60
done
```

### AGENTS.md stanza

**SpaceStation writes this automatically.** When you open a folder as a workspace, its `AGENTS.md`
and `CLAUDE.md` get a managed collab block (a single marked region, updated idempotently — the rest
of each file is untouched). Opt out with `spacestation --no-agents-md` or `PLUTOSPACE_AGENTS_MD=0`.
Or drop the stanza in by hand (works for Claude Code's CLAUDE.md too):

```markdown
## Working on Pluto notebooks

**Almost everything you do in a notebook is plain Julia coding you already know how to do** —
writing functions, wrangling data, fixing bugs, making plots, refactoring. A Pluto notebook is just
a **plain Julia file** (`*.jl` starting with `### A Pluto.jl notebook ###`); **edit it with your
normal file tools** (Read/Edit/Write the `.jl` directly). There is no special API for changing a
notebook, and `pluto-collab` (below) is only for *running* your edits, not for making them. Do not
overthink it: it's ordinary Julia in ordinary cells.

The only Pluto-specific parts are a few lightweight conventions wrapped around that Julia code —
learn them so your edits land in the right cell and stay valid:

- **Cells** are delimited by `# ╔═╡ <uuid>` markers. A cell's code runs from its marker to the next
  one. The `<uuid>` is that cell's stable id (a v4 UUID) — used everywhere else in the file.
- **Cell order and fold state** live in the `# ╔═╡ Cell order:` block at the END of the file. It
  lists every cell's UUID in the order it appears in the notebook, each line prefixed by a pipe that
  sets whether that cell's **code (its input) is shown or folded**:
  - `# ╠═<uuid>` → code **shown**
  - `# ╟─<uuid>` → code **hidden / folded** (input collapsed; the normal state for Markdown / prose
    cells, which then display only their rendered output)
- The **Cell order block is authoritative** for display order — not where the `# ╔═╡ <uuid>`
  definition physically sits above.

### How to make common changes (edit the `.jl`)

- **Show or hide a cell's code:** flip that cell's prefix in the Cell order block between `╠═` (show)
  and `╟─` (fold). Do not touch the cell's code — this only changes visibility.
- **Move / reorder a cell:** move its `# ╠═<uuid>` (or `# ╟─<uuid>`) line up or down within the Cell
  order block to the new position. That is what reorders it. (Keeping the `# ╔═╡ <uuid>` definitions
  in the same order is tidy but the Cell order block is what actually decides.)
- **Add a cell:** add a `# ╔═╡ <new-uuid>` block with the code, AND a matching `# ╠═<new-uuid>`
  (or `# ╟─<new-uuid>`) line at the right spot in the Cell order block. Any fresh unique UUID works.
- **Delete a cell:** remove BOTH its `# ╔═╡ <uuid>` code block AND its line in the Cell order block.
- **Cell metadata** (optional) sits on `# ╠═╡ key = value` lines directly after the `# ╔═╡ <uuid>`
  marker — e.g. `disabled = true`, `skip_as_script = true`, `always_stale = true`. A `disabled` cell
  additionally has its code wrapped in `#=╠═╡ … ╠═╡ =#`.

Pluto is **reactive**: what runs, and in what order, follows variable dependencies (topological), not
file order — and each variable/function is defined in exactly **one** cell (duplicate definitions
error; wrap multiple statements in a `begin … end` or `let … end` block). So reordering or folding
cells never changes what executes, only how the notebook reads.

**Bottom line:** write Julia the way you always do. The only extra habits are — keep each definition
in one cell, put multi-statement cells in `begin`/`let` blocks, and when you add, remove, or move a
cell, update the `# ╔═╡ Cell order:` block to match.

### Running your edits (live collaborative session)

Notebooks here may be OPEN in a live lazy-mode SpaceStation server shared with a human. Editing the
`.jl` only marks the changed cells (and everything downstream) **stale** — nothing runs until asked.

- `pluto-collab status <nb.jl>` — per-cell state (stale / cold / errored / output digest).
- `pluto-collab output <nb.jl> --cell <id>` — one cell's FULL (untruncated) output.
- `pluto-collab figure <nb.jl> --cell <id>` — save a cell's rendered plot to an image file.
- `pluto-collab run <nb.jl> --stale` — run exactly what's outdated (blocking; exit 1 on error).
  **Never re-run the whole notebook.**
- `pluto-collab restart <nb.jl>` — restart the kernel and re-run everything. Use ONLY to recover a
  dead/exited worker ("Process exited" / `TerminatedWorkerException`); interrupt/run can't revive one.
- All cell outputs are also in `<nb.jl>.pluto-cache.toml` (plain TOML; a deletable cache).

On Windows or where bash/curl are missing, use the identical `spacestation collab <command> …`.
```

## Compatibility

- `--autorun` / `on_code_change="autorun"` is byte-for-byte vanilla Pluto behavior.
- Notebook files stay fully compatible with upstream Pluto in both directions.
- The sidecar and connection files are pure caches/metadata — safe to delete at any time.

## End-to-end test

```
bash test/collab_acceptance.sh
```
