#!/usr/bin/env bash
# End-to-end test for the collab agent surface:
#   1. the cross-platform `spacestation collab …` CLI (Julia, no bash/curl needed on the client),
#   2. the status-sync fix — `status` reflects a disk edit IMMEDIATELY, not after the watcher debounce,
#      which is what makes the two-tier "edit stages → review → run applies" flow deterministic.
#
# Usage: bash test/collab_cli.sh    (needs julia --project=this, curl for the fast-status probe)

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
PORT=7996
REGISTRY_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pluto/servers"
WORKDIR=$(mktemp -d)
NB="$WORKDIR/cli_nb.jl"
MARK="$WORKDIR/mark.txt"
LOG="$WORKDIR/server.log"
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
# run a command (function or program, in THIS shell) and assert its stdout contains / lacks a pattern
assert_has()  { desc=$1; pat=$2; shift 2; if "$@" 2>/dev/null | grep -q "$pat"; then pass "$desc"; else fail "$desc"; fi; }
assert_lacks(){ desc=$1; pat=$2; shift 2; if "$@" 2>/dev/null | grep -q "$pat"; then fail "$desc"; else pass "$desc"; fi; }
assert_rc()   { desc=$1; want=$2; got=$3; [ "$got" = "$want" ] && pass "$desc" || fail "$desc (rc=$got)"; }

cleanup() { [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null; sleep 1; rm -rf "$WORKDIR"; }
trap cleanup EXIT

# the CLI under test — the built-in cross-platform form, run from source
collab() { julia --project="$REPO" -m SpaceStation collab "$@"; }
secret_for_port() { sed -n 's/.*"secret": "\([^"]*\)".*/\1/p' "$REGISTRY_DIR"/*-"$PORT".json 2>/dev/null | head -1; }
# a FAST status read (curl, not the slow CLI boot) so we can probe within ms of an edit
fast_status() { curl -sf -G --data-urlencode "path=$NB" -d "format=text" -d "secret=$(secret_for_port)" "http://127.0.0.1:$PORT/api/v1/notebook"; }

write_nb() { # write_nb <TAG>
    cat > "$WORKDIR/nb.tmp" <<EOF
### A Pluto.jl notebook ###
# v0.20.21

# ╔═╡ 11111111-1111-1111-1111-111111111111
begin
    write(raw"$MARK", "$1")
    tag = "$1"
end

# ╔═╡ Cell order:
# ╠═11111111-1111-1111-1111-111111111111
EOF
    mv "$WORKDIR/nb.tmp" "$NB"   # atomic, agent-style
}

write_nb V1
# distributed=true (a real Malt worker) so interrupt/restart are exercised realistically; the
# first run pays a one-time worker precompile.
julia --project="$REPO" -e "
    import SpaceStation
    SpaceStation.run(port=$PORT, launch_browser=false, require_secret_for_open_links=true,
                     on_code_change=\"lazy\", workspace_use_distributed=true, notebook=\"$NB\")" >>"$LOG" 2>&1 &
SPID=$!

echo "--- waiting for the server to open the notebook"
opened=1
for _ in $(seq 1 180); do
    if fast_status 2>/dev/null | grep -q "11111111"; then opened=0; break; fi
    sleep 1
done
[ "$opened" = 0 ] && pass "server opened the notebook" || { fail "server opened the notebook"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

echo "--- 1. the cross-platform CLI: discovery + status"
assert_has "collab servers lists the live server" ":$PORT" collab servers
assert_has "collab notebooks lists the open notebook" "$NB" collab notebooks
assert_has "collab status shows the cell" "11111111" collab status "$NB"

echo "--- 2. baseline run via the CLI (exit 0, cell executed)"
collab run "$NB" --stale >/dev/null 2>&1; rc=$?
assert_rc "collab run --stale exited 0" 0 "$rc"
[ -f "$MARK" ] && [ "$(cat "$MARK")" = V1 ] && pass "V1 executed (marker = V1)" || fail "V1 executed"

echo "--- 3. THE STATUS-SYNC FIX: edit V2, then read status with NO sleep — must show STALE immediately"
write_nb V2
# fast_status probes within ms, well under the ~0.4s watcher debounce; without the sync-on-status
# fix the edited cell would still read 'fresh' here.
assert_has "status reflects the disk edit immediately (STALE)" "STALE" fast_status

echo "--- 4. run the freshly-staged edit, verify it applied"
collab run "$NB" --stale >/dev/null 2>&1; rc=$?
assert_rc "collab run --stale after edit exited 0" 0 "$rc"
[ "$(cat "$MARK")" = V2 ] && pass "V2 executed (the new code ran)" || fail "V2 executed"
assert_lacks "nothing STALE after running" "STALE" fast_status

echo "--- 5. restart re-runs the whole notebook (exit 0, cell re-executed)"
rm -f "$MARK"
collab restart "$NB" >/dev/null 2>&1; rc=$?
assert_rc "collab restart exited 0" 0 "$rc"
[ -f "$MARK" ] && [ "$(cat "$MARK")" = V2 ] && pass "restart re-executed the cell (marker rewritten)" || fail "restart re-executed the cell"

echo "--- 6. interrupt stops a long run early"
cat > "$WORKDIR/nb.tmp" <<EOF
### A Pluto.jl notebook ###
# v0.20.21

# ╔═╡ 11111111-1111-1111-1111-111111111111
begin
    sleep(25)
    tag = "slept"
end

# ╔═╡ Cell order:
# ╠═11111111-1111-1111-1111-111111111111
EOF
mv "$WORKDIR/nb.tmp" "$NB"   # edit → the cell goes stale
start=$(date +%s)
collab run "$NB" --stale >/dev/null 2>&1 &   # background: blocks until done OR interrupted
RUNPID=$!
sleep 7                                        # let the run boot + the cell enter its sleep
collab interrupt "$NB" >/dev/null 2>&1
wait $RUNPID 2>/dev/null
elapsed=$(( $(date +%s) - start ))
# Interrupted: the run returns before the 25s sleep can finish. Un-interrupted would be
# (CLI boot ~2s) + 25s ≈ 27s+, so anything comfortably under 25 means the cell was cut short.
[ "$elapsed" -lt 24 ] && pass "interrupt stopped the run early (${elapsed}s < 25s sleep)" || fail "interrupt did not stop the run (took ${elapsed}s)"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] && echo "COLLAB CLI + STATUS-SYNC TESTS PASSED" || echo "COLLAB TESTS FAILED"
exit "$FAIL"
