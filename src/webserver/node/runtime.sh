#!/usr/bin/env bash
# Stage SpaceStation's own runtime on a node's local disk, and print where it is.
#
#   runtime.sh <julia> <app-dir> [bundle-dir]
#
# <julia>    the user's julia binary (absolute path; on a cluster it lives on shared storage)
# <app-dir>  a SpaceStation checkout with an instantiated Manifest (on shared storage too)
# bundle-dir where finished runtimes are kept as one file each (default ~/.spacestation/bundles)
#
# Why: on a cluster the Julia install, the depot and this checkout sit on filesystems that stop
# answering for minutes at a time, and a Julia process that touches them then stops whole
# (docs/design/cluster-robustness.md). Even throwing an exception opens a package image in the
# depot. So the hub runs from a copy on the node's own disk: julia, a depot holding exactly the
# packages this app needs with their compiled caches, and the app. The copy is made once per
# (app version, julia version, CPU target, place): built with a few minutes of precompilation, kept
# as ONE file on shared storage (one sequential read to restore: what parallel filesystems are good
# at, instead of thousands of small-file lookups), and restored in seconds on every other node or
# job. The place is FIXED per user (/tmp/spacestation-<uid> by default) because Julia's compile-cache
# key includes the paths of the project, the julia binary and the system image: the same paths on
# every node mean the caches in the bundle are valid everywhere.
#
# Prints, on success, exactly one line:  RUNTIME <dir>   (then <dir>/julia/bin/julia, <dir>/depot, <dir>/app)
# On any failure prints  NORUNTIME <reason>  and exits 0: the caller then starts the hub the old way.
# Everything it writes outside <bundle-dir> is on the node. Progress goes to stderr.
set -u
say() { echo "runtime: $*" >&2; }
fail() { echo "NORUNTIME $*"; exit 0; }

JULIA=${1:?julia}; APP=${2:?app dir}; BUNDLES=${3:-${SPACESTATION_BUNDLE_DIR:-$HOME/.spacestation/bundles}}
[ -x "$JULIA" ] || fail "julia is not executable: $JULIA"
[ -f "$APP/Project.toml" ] || fail "no Project.toml in $APP"
[ "${SPACESTATION_NODE_RUNTIME:-1}" = 0 ] && fail "turned off (SPACESTATION_NODE_RUNTIME=0)"
# Every node must be able to run what any node built: a generic fallback plus the common server CPUs.
CPU_TARGET=${SPACESTATION_CPU_TARGET:-"generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)"}
case "$(uname -m)" in x86_64) ;; *) CPU_TARGET=${SPACESTATION_CPU_TARGET:-generic} ;; esac
NEED_KB=$((3 * 1024 * 1024)) # julia + depot + caches + headroom

# --- where ------------------------------------------------------------------------------------------
# A directory on the node's own disk. Told apart from network filesystems by name only
# (/proc/self/mountinfo: reading it touches no mount); unknown types count as network.
fstype_of() {
    awk -v p="$1" '{ mp=$5; gsub(/\\040/," ",mp); n=length(mp); if ((p==mp || index(p, mp=="/" ? "/" : mp "/")==1) && n>=best) { best=n; for (i=7;i<=NF;i++) if ($i=="-") { t=$(i+1); break } } } END { print t }' /proc/self/mountinfo 2>/dev/null
}
is_local_fs() { case "$1" in ext2|ext3|ext4|xfs|btrfs|zfs|f2fs|jfs|reiserfs|overlay|tmpfs|ramfs|apfs|ufs) return 0 ;; *) return 1 ;; esac; }
mem_available_kb() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null; }
pick_root() {
    local pass cand real t free root
    # /tmp first: it is the same PATH on every node and in every job (a private per-job /tmp included),
    # which is what keeps the compiled caches valid. The others vary per job: they work, and cost a rebuild.
    # Memory-backed places come last, and only with memory to spare: what is stored there is charged to the job.
    for pass in disk memory; do
        for cand in "${SPACESTATION_LOCAL_ROOT:-}" /tmp "${SLURM_TMPDIR:-}" "${PBS_JOBFS:-}" "${FLUX_JOB_TMPDIR:-}" "${TMPDIR:-}" /dev/shm; do
            [ -n "$cand" ] && [ -d "$cand" ] && [ -w "$cand" ] || continue
            real=$(cd "$cand" 2>/dev/null && pwd -P) || continue # a symlink into shared storage is judged by where it leads
            if [ -r /proc/self/mountinfo ]; then
                t=$(fstype_of "$real"); is_local_fs "$t" || { [ "$pass" = disk ] && say "skipping $cand ($t is not a local filesystem)"; continue; }
                case "$t" in tmpfs|ramfs)
                    [ "$pass" = memory ] || continue
                    [ "$(mem_available_kb)" -ge $((16 * 1024 * 1024)) ] 2>/dev/null || { say "skipping $cand (memory-backed, and memory is short)"; continue; } ;;
                *) [ "$pass" = disk ] || continue ;;
                esac
            else
                [ "$pass" = disk ] || continue
            fi
            free=$(df -Pk "$real" 2>/dev/null | awk 'NR==2 {print $4}'); [ "${free:-0}" -ge "$NEED_KB" ] || { say "skipping $cand (not enough room)"; continue; }
            root="$real/spacestation-$(id -u)"
            mkdir -m 700 "$root" 2>/dev/null
            # ours, a real directory, closed to others: anything else (somebody made it first) is not used
            if [ -d "$root" ] && [ ! -L "$root" ] && [ -O "$root" ] && chmod 700 "$root" 2>/dev/null; then
                [ "$real" = /tmp ] || [ "$cand" = "${SPACESTATION_LOCAL_ROOT:-}" ] && echo fixed > "$root/.place" || echo varying > "$root/.place"
                echo "$root"; return 0
            fi
            say "skipping $root (exists and is not ours)"
        done
    done
    return 1
}
ROOT=$(pick_root) || fail "no usable directory on this node's own disk"

# --- which ------------------------------------------------------------------------------------------
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
# Ask julia where it lives: the path we were given may be a symlink in /usr/local/bin or a launcher shim,
# and copying "its directory" would then copy /usr/local, or a shim that needs the user's home.
read -r JULIA_VERSION JULIA_ROOT < <("$JULIA" --startup-file=no --history-file=no -e 'print(VERSION, " ", dirname(Sys.BINDIR))' 2>/dev/null)
[ -n "${JULIA_VERSION:-}" ] && [ -n "${JULIA_ROOT:-}" ] || fail "julia does not run: $JULIA"
[ -x "$JULIA_ROOT/bin/julia" ] && [ -d "$JULIA_ROOT/lib/julia" ] || fail "not a julia install: $JULIA_ROOT"
APP_ID=$(cd "$APP" && { git rev-parse HEAD 2>/dev/null || true; cat Project.toml Manifest.toml 2>/dev/null | sha | cut -c1-16; } | tr '\n' ' ')
KEY=$(printf '%s\n' "format-1" "$APP_ID" "$JULIA_VERSION" "$(uname -m)" "$CPU_TARGET" "$ROOT" | sha | cut -c1-16)
RT="$ROOT/rt-$KEY"
BUNDLE="$BUNDLES/$KEY.tar.gz"

ready() { [ -f "$RT/.complete" ] && [ -x "$RT/julia/bin/julia" ]; }
# A runtime a live process runs from is never removed, whatever else looks wrong with it (a tmp cleaner
# may have aged its marker away): a hub is serving from it.
in_use() {
    local exe
    for exe in /proc/[0-9]*/exe; do
        case "$(readlink "$exe" 2>/dev/null)" in "$1"/*) return 0 ;; esac
    done
    return 1
}
if ! ready && [ -x "$RT/julia/bin/julia" ] && in_use "$RT"; then touch "$RT/.complete"; fi
ready && { touch "$RT/.complete" 2>/dev/null; echo "RUNTIME $RT"; exit 0; }

# One builder per node at a time. The lock names its owner: it is taken over only from a process that
# no longer exists (same node, so that can be told), never because time has passed.
LOCK="$ROOT/rt-$KEY.lock"
have_lock=0
for i in $(seq 1 1800); do
    if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; have_lock=1; break; fi
    ready && { echo "RUNTIME $RT"; exit 0; }
    owner=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
    [ -z "$owner" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ] && { rm -rf "$LOCK"; continue; } # died between mkdir and echo
    sleep 1
done
[ "$have_lock" = 1 ] || fail "another launch is still building the runtime"
unlock() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; }
trap unlock EXIT
ready && { echo "RUNTIME $RT"; exit 0; }
in_use "$RT" && fail "the runtime at $RT is in use but incomplete"
rm -rf "$RT"
give_up() { rm -rf "$RT"; fail "$@"; } # never leave a partial runtime behind

# --- restore: one sequential read ----------------------------------------------------------------------
if [ -f "$BUNDLE" ] && [ -f "$BUNDLE.sha256" ]; then
    say "restoring $BUNDLE"
    if [ "$(sha "$BUNDLE" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$BUNDLE.sha256")" ] && tar -xzf "$BUNDLE" -C "$ROOT" && [ -x "$RT/julia/bin/julia" ]; then
        mkdir -p "$RT/home" "$RT/tmp" "$RT/depot/logs"; touch "$RT/.complete"; echo "RUNTIME $RT"; exit 0
    fi
    say "the bundle is damaged: building afresh"; rm -rf "$RT"
fi

# --- build (once per key, anywhere) -----------------------------------------------------------------------
# AT its final path, never somewhere else and moved: the paths go into the compile-cache key.
say "building the node-local runtime (a few minutes, once per version)"
mkdir -p "$RT/depot" "$RT/home" "$RT/tmp" || give_up "cannot create $RT"
cp -a "$JULIA_ROOT" "$RT/julia" || give_up "could not copy julia"
rm -rf "$RT/julia/share/doc" "$RT/julia/share/julia/test" "$RT/julia/share/man" 2>/dev/null
# the app, mtimes kept (its cache is validated by path and mtime), without its history
# and only what a running server reads: not the bundler, the desktop shell, the tests
mkdir -p "$RT/app" && (cd "$APP" && for f in Project.toml Manifest.toml src frontend frontend-dist bin sample assets; do [ -e "$f" ] && echo "$f"; done | tar --exclude=node_modules --exclude=.parcel-cache -cf - -T -) | tar -xf - -C "$RT/app" || give_up "could not copy the app"
# the packages and artifacts this app's Manifest names, copied out of the user's depot: no network needed
"$JULIA" --startup-file=no --history-file=no --project="$APP" -e '
    import Pkg
    target = ARGS[1]
    seen = Set{String}()
    function copy_tree(src, dst)
        (isdir(src) && !ispath(dst)) || return
        mkpath(dirname(dst)); run(`cp -a $src $dst`)
    end
    for (uuid, info) in Pkg.dependencies()
        src = info.source
        (src === nothing || !isdir(src)) && continue
        depot = findfirst(d -> startswith(src, joinpath(d, "packages") * "/"), DEPOT_PATH)
        depot === nothing && continue # a stdlib, or a dev/path package: loaded from where it is
        copy_tree(src, joinpath(target, relpath(src, DEPOT_PATH[depot])))
        for name in ("Artifacts.toml", "JuliaArtifacts.toml")
            toml = joinpath(src, name); isfile(toml) || continue
            for (_, meta) in Pkg.Artifacts.select_downloadable_artifacts(toml; include_lazy=false)
                metas = meta isa AbstractVector ? meta : [meta]
                for m in metas
                    hash = Base.SHA1(m["git-tree-sha1"])
                    Pkg.Artifacts.artifact_exists(hash) && copy_tree(Pkg.Artifacts.artifact_path(hash), joinpath(target, "artifacts", bytes2hex(hash.bytes)))
                end
            end
        end
    end
' "$RT/depot" >&2 || give_up "could not copy the packages"
# compile with the LOCAL julia against the LOCAL depot alone: these are the caches the hub will load
( cd "$RT" && env -u JULIA_LOAD_PATH -u JULIA_PROJECT HOME="$RT/home" TMPDIR="$RT/tmp" JULIA_DEPOT_PATH="$RT/depot:" JULIA_CPU_TARGET="$CPU_TARGET" JULIA_PKG_OFFLINE=true \
    "$RT/julia/bin/julia" --startup-file=no --history-file=no --project="$RT/app" -e 'import SpaceStation' >&2 ) || give_up "the app does not load from the local runtime"
echo "$CPU_TARGET" > "$RT/cpu-target"
touch "$RT/.complete"
echo "RUNTIME $RT"

# older runtimes of this user that nothing runs from: the two newest stay
ls -dt "$ROOT"/rt-*/ 2>/dev/null | tail -n +3 | while read -r old; do old=${old%/}; [ "$old" = "$RT" ] || in_use "$old" || rm -rf "$old"; done

# A runtime in a place that changes from job to job is of no use to the next job: no bundle for it.
[ "$(cat "$ROOT/.place" 2>/dev/null)" = fixed ] || exit 0

# keep it as one file for every other node and job: in the background, the hub does not wait for it
(
    mkdir -p "$BUNDLES" && chmod 700 "$BUNDLES" 2>/dev/null
    tmp="$BUNDLE.tmp.$(hostname).$$"
    if tar -C "$ROOT" --exclude="rt-$KEY/.complete" --exclude="rt-$KEY/home" --exclude="rt-$KEY/tmp" --exclude="rt-$KEY/depot/logs" --exclude="rt-$KEY/depot/scratchspaces" -czf "$tmp" "rt-$KEY" 2>/dev/null; then
        sha "$tmp" | cut -d' ' -f1 > "$BUNDLE.sha256.tmp.$$" && mv -f "$tmp" "$BUNDLE" && mv -f "$BUNDLE.sha256.tmp.$$" "$BUNDLE.sha256"
        ls -t "$BUNDLES"/*.tar.gz 2>/dev/null | tail -n +3 | while read -r old; do rm -f "$old" "$old.sha256"; done # the two newest stay
    else
        rm -f "$tmp"
    fi
) >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
