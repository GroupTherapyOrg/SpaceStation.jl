# SpaceStation on clusters: never wait on shared storage

Status: design of record, 2026-09-21. Evidence, prior art and the rules the implementation is held to.
The acceptance tests live in `test/hangfs/` and run in `.github/workflows/StorageHang.yml`.

## The failure

On an HPC cluster the home directory is NFS and the Julia install and depot sit on a parallel
filesystem (BeeGFS, Lustre, GPFS). Those filesystems stop answering for seconds to tens of minutes,
several times a day. A thread that touches them then sits in the kernel in uninterruptible sleep.

Julia's garbage collector stops the world, and it cannot stop a thread that is stuck in the kernel,
so it waits for it, and every other thread waits at its safepoint for the collector. **One blocked
thread is the whole process.** Reproduced: one thread blocked 8 s in a plain foreign call froze an
idle `:interactive` thread for 8.24 s; with the call marked `gc_safe` the gap was 0.26 s. The same
mechanism is documented for the JVM (time-to-safepoint stalls from mmap page faults and blocking I/O;
Elasticsearch's `bootstrap.memory_lock`); Go avoids it for system calls but not for page faults.

Ways a server process reaches the shared filesystem, each one measured, each one enough to freeze it:

| Path | Evidence |
|---|---|
| A page fault on code mapped from the depot or the Julia install | hub mapped 843 MB from BeeGFS, 39 MB resident |
| Any Base file function on the user's files (sidebar listing, `isdir`) | stress test: one `statx` of a hung directory, worst latency 8 s |
| **Throwing any exception through package code**: the unwinder opens the package image file to find its unwind tables (`ijl_throw → record_backtrace → libunwind → elf_map_image → open`) | captured stack in the stress test |
| Symbolicating a backtrace for a log message | reads debug info from the system image and package images |
| Path objects that re-check the install directory (`RelocatableFolders`) | idle hub: 8 `access()` calls per second on the NFS home |
| Pkg's usage log and scratch spaces (pidfile lock, `stat` walks) | earlier SIGUSR1 captures |
| Connection files and logs under `$HOME` | design |
| Starting a process: the parent waits until the child's `execve` (and `chdir`) completes | libuv semantics |
| Remote discovery over SSH: every command starts a shell that reads startup files from `$HOME` | measured 0.5 s to more than 60 s per command |

The set is open-ended. Removing call sites one by one does not converge; four rounds of that failed.

## Prior art

How established tools answer the same problem (sources in the research notes at the end):

- **One artifact on shared storage, staged to node-local disk.** NERSC (Shifter, podman-hpc), OLCF
  (conda-pack + `sbcast` to NVMe), TACC (copy the environment to `/tmp`), LLNL Spindle ("a library
  load storm resembles a denial-of-service attack" on the filesystem), Alliance Canada, ETH, CSC, and
  the JuliaHPC FAQ (tar the depot, ship it to node-local storage, multiversioned `JULIA_CPU_TARGET`).
- **Ephemeral runtime state is node-local and relocatable by an environment variable.** Jupyter's
  `JUPYTER_RUNTIME_DIR`, VS Code's `remote.SSH.serverInstallPath` and `lockfilesInTmp` (MIT CSAIL
  requires both for network homes), tmux sockets under `/tmp`. No locks, sockets, pid files or SQLite
  on shared filesystems (SQLite's own FAQ; IPython's `hist_file` guidance).
- **Discovery must not walk the filesystem.** VS Code issue #8000: its running-server check hangs when
  any one NFS mount on the host is dead. batchspawner pushes the port over the network; Open OnDemand
  polls a file in the shared home. Zed and Eternal Terminal use one idempotent attach-or-start path
  addressed by a known key.
- **The part that must stay responsive does no blocking work.** Browser process versus utility
  processes, editor versus extension host, Jupyter server versus kernel.
- **SSH.** sshd always runs a command through the user's shell, and bash reads `~/.bashrc` whenever it
  detects sshd, so startup files cannot be skipped from the client; only a subsystem (sftp) avoids
  them. Mitogen, Mutagen and Ansible pipelining start ONE remote agent and speak a protocol over its
  stdin/stdout. `ConnectTimeout` and keepalives do not bound a hung remote command. A loopback TCP port
  on a shared node is reachable by every local user (VS Code offers unix sockets for that reason).
  Centers terminate or block users whose tools pile up processes and connections on login nodes.

## The rules

1. **A hub or workspace server holds no path into shared storage** except the user's own files, and
   never touches those itself. Its Julia, its depot, its application source, its state, its logs,
   its working directory, its `HOME` and its `TMPDIR` are on node-local disk.
2. **The runtime is one bundle**: Julia + a depot holding exactly what SpaceStation needs + the app,
   built once per (SpaceStation version, Julia version, CPU target), stored as one compressed file on
   shared storage, restored with one sequential read into a fixed per-user node-local root. Fixed,
   because the compile-cache key includes the project path, the julia binary path, the system image
   path, the flags and the CPU target. Multiversioned `JULIA_CPU_TARGET`, part of the key.
3. **The user's files are reached through disposable helper processes** with deadlines. A helper may
   get stuck; the hub answers `filesystem_busy` for those requests only. Processes are started by a
   pre-started helper with a local working directory, never by the hub during a hang.
4. **Notebook workers keep the user's Julia and depot** (their packages stay compiled). A worker can
   stall with the storage; that is one notebook. Notebook package operations run in a disposable
   worker, not in the workspace server.
5. **Defence in depth inside the process**: code pages pinned (`PinCode.jl`), no backtrace
   symbolication in hubs and helpers, install directories resolved once.
6. **Transport**: reconnect goes to the known server first (tunnel + one authenticated request, no
   shell); discovery and bootstrap move to one remote agent per connection with deadlines at both
   ends; no probes on login nodes; backoff with a cap.
7. **Everything above is a test, not a belief.** `hangtrace` hangs chosen directory trees at the
   system-call level for one process and names the caller of every held call; the stress scenarios
   assert worst-case latency while the trees are hung. A change that reaches shared storage from a
   hub fails CI. Verification on a real cluster never launches Julia from shared storage in bulk.

## Delivery order

1. Test harness and scenarios (done: `test/hangfs`, workflow).
2. Hub hygiene: install directories resolved once, backtrace-free logging, file helpers (done).
3. Node-local runtime bundle for the hub, with the environment scrubbed (HOME, TMPDIR, cwd, PATH,
   LD_LIBRARY_PATH, load path); staging root selection and validation; bundle build without internet
   by copying the Manifest's packages out of the shared depot; atomic, hash-verified, two kept.
4. Workspace server on the bundle; notebook Pkg operations and registry lookups in a disposable
   worker on the user's Julia; PlutoRunner boot environment shipped in the bundle.
5. Process starts (terminals, children) through a pre-started spawn helper.
6. Transport: single remote agent, unix-socket forwards where available, supervised reconnect.
7. An external stall recorder (outside the Julia process) that names the blocking call on the node.
