#!/usr/bin/env bash
# The workspace file tree over HTTP: the lazy per-folder listing the sidebar uses, and the
# confinement that keeps it inside the workspace.
#
# The point of the lazy tree is that cost tracks what the user has OPEN, not the size of the
# workspace — so this builds a deliberately large workspace and checks that the root response
# stays small, that folders are reachable one at a time to any depth, and that a folder nobody
# expanded is never read.
#
# Usage: bash test/workspace_tree.sh
# Needs: julia (with this repo as --project), curl, python3.

set -u
cd "$(dirname "$0")/.."
REPO=$(pwd)
PORT=7996
WORKDIR=$(mktemp -d)
WS="$WORKDIR/workspace"
SERVER_LOG="$WORKDIR/server.log"
PASS=0
FAIL=0

check() { # check <description> <command...>
    desc=$1; shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS+1)); echo "ok: $desc"
    else
        FAIL=$((FAIL+1)); echo "FAIL: $desc" >&2
    fi
}

cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
    sleep 1
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# The API always wants the secret, so pick it up the documented way: the connection file the
# server writes on startup, which is how pluto-collab finds a server too. The name is
# <node>-<port>.json and the node prefix comes from gethostname(), so match it by port.
CONNDIR="${XDG_STATE_HOME:-$HOME/.local/state}/pluto/servers"
conn_file() { ls "$CONNDIR"/*-"$PORT".json 2>/dev/null | head -1; }

api() { # api <path-and-query>
    case "$1" in
        *\?*) curl -s --max-time 20 "http://127.0.0.1:$PORT$1&secret=$SECRET" ;;
        *)    curl -s --max-time 20 "http://127.0.0.1:$PORT$1?secret=$SECRET" ;;
    esac
}
urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"; }
jqp() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# `check` runs its command through `bash -c`, which is a fresh shell — these have to be exported
# for it to see them at all (a missing function silently 'passes' a negated check otherwise).
export -f api urlenc jqp
export PORT

# --- a workspace big enough that walking all of it would be silly ---
mkdir -p "$WS"
for i in $(seq 1 40); do
    for j in $(seq 1 25); do mkdir -p "$WS/dir_$i/sub_$j"; : > "$WS/dir_$i/sub_$j/leaf.txt"; done
done
# a chain deeper than any fixed depth limit, with a real notebook at the bottom
DEEP="$WS/deep/a/b/c/d/e/f/g/h"
mkdir -p "$DEEP"
printf '### A Pluto.jl notebook ###\n# v0.19.0\n' > "$DEEP/buried.jl"
printf '### A Pluto.jl notebook ###\n# v0.19.0\n' > "$WS/top.jl"
printf 'x = 1\n' > "$WS/plain.jl"
mkdir -p "$WS/.venv/lib/python3.13/site-packages/pkg"   # must never be listed

rm -f "$CONNDIR"/*-"$PORT".json   # a stale file from an earlier run would hand us the wrong secret

echo "--- starting server on $WS (log: $SERVER_LOG)"
# don't seed AGENTS.md/CLAUDE.md into the workspace — this test counts entries
export SPACESTATION_AGENTS_MD=0
julia --project="$REPO" -e "
    import SpaceStation
    SpaceStation.run(
        port=$PORT,
        launch_browser=false,
        require_secret_for_access=false,
        workspace=\"$WS\",
        workspace_use_distributed=false,
    )" >>"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 180); do
    [ -n "$(conn_file)" ] && break
    sleep 1
done
if [ -z "$(conn_file)" ]; then
    echo "FAIL: server never wrote its connection file in $CONNDIR; see $SERVER_LOG" >&2
    tail -20 "$SERVER_LOG" >&2
    exit 1
fi
SECRET=$(jqp "d['secret']" < "$(conn_file)")
export SECRET

for _ in $(seq 1 60); do
    api "/api/v1/workspace" | grep -q '"root"' && break
    sleep 1
done

echo "--- 1. the root response is one folder, not a tree"
check "root lists the workspace's own entries (40 dir_N + deep/ + 2 files)" \
    bash -c "api '/api/v1/workspace' | jqp \"len(d['entries'])\" | grep -qx 43"
check "no folder carries pre-walked children" \
    bash -c "api '/api/v1/workspace' | jqp \"all(not e.get('children') for e in d['entries'])\" | grep -qx True"
check "the notebook header is detected, a plain .jl is not" \
    bash -c "api '/api/v1/workspace' | jqp \"{e['name']: e['type'] for e in d['entries'] if e['name'].endswith('.jl')}\" | grep -qx \"{'plain.jl': 'file', 'top.jl': 'notebook'}\""
check ".venv is skipped entirely" \
    bash -c "! api '/api/v1/workspace' | grep -q '\.venv'"

echo "--- 2. the root stays small however big the workspace gets"
ROOT_BYTES=$(api "/api/v1/workspace" | wc -c)
TREE_BYTES=$(api "/api/v1/workspace?depth=6" | wc -c)
echo "    root=${ROOT_BYTES}B   depth=6 tree=${TREE_BYTES}B"
check "the lazy root is far smaller than the pre-walked tree" \
    bash -c "[ $ROOT_BYTES -lt $((TREE_BYTES / 10)) ]"

echo "--- 3. folders are reachable one at a time, to any depth"
AT="$WS"
DEPTH_OK=yes
for step in deep a b c d e f g h; do
    api "/api/v1/workspace/listing?path=$(urlenc "$AT")" | grep -q "\"$step\"" || DEPTH_OK=no
    AT="$AT/$step"
done
check "eight levels down, each folder listed on request" bash -c "[ '$DEPTH_OK' = yes ]"
check "the buried notebook is found at the bottom" \
    bash -c "api '/api/v1/workspace/listing?path=$(urlenc "$AT")' | grep -q '\"buried.jl\"'"
check "a listing reports the folder it answered for" \
    bash -c "api '/api/v1/workspace/listing?path=$(urlenc "$WS/dir_3")' | jqp \"d['path']\" | grep -qx '$WS/dir_3'"
check "and only that folder's entries (25 subfolders, nothing below them)" \
    bash -c "api '/api/v1/workspace/listing?path=$(urlenc "$WS/dir_3")' | jqp \"len(d['entries'])\" | grep -qx 25"

echo "--- 4. the listing cannot leave the workspace"
check "an absolute path outside the workspace is refused" \
    bash -c "api '/api/v1/workspace/listing?path=%2Fetc' | grep -q 'outside the workspace'"
check "a ../ escape is refused (tamepath resolves it before the check)" \
    bash -c "api '/api/v1/workspace/listing?path=$(urlenc "$WS/../..")' | grep -q 'outside the workspace'"
check "a sibling sharing the root's name prefix is refused" \
    bash -c "api '/api/v1/workspace/listing?path=$(urlenc "${WS}_other")' | grep -q 'outside the workspace'"
check "a file (not a folder) is a 404" \
    bash -c "api '/api/v1/workspace/listing?path=$(urlenc "$WS/top.jl")' | grep -q 'not a directory'"
check "a bad depth is a 400" \
    bash -c "api '/api/v1/workspace?depth=abc' | grep -q 'depth must be an integer'"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
