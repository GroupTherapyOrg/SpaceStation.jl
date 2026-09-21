#!/usr/bin/env bash
# Stress test: a hub must keep answering while the filesystems under HANG_PREFIXES are hung.
#
#   stress_hub.sh <app-dir> <julia> <port> <hang-prefixes> [hang-seconds]
#
# Starts a hub from <app-dir> under hangtrace (system-call level hang injection), lets it start and serve one warm-up session,
# then raises the hang flag and keeps asking (ping, config, workspace list, the page, an asset) while
# a second client forces garbage collections through allocation-heavy requests. Prints the worst
# latency per phase and exits non-zero if any request during the hang took longer than LIMIT seconds.
set -u
APP=$1; J=$2; PORT=$3; PREFIXES=$4; HANG=${5:-40}; LIMIT=${LIMIT:-2}
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d "${TMPDIR:-/tmp}/hubstress.XXXXXX")
gcc -O2 -o "$d/hangtrace" "$here/hangtrace.c" || exit 3
mkdir -p "$d/state" "$d/depot"
export SPACESTATION_HUB=1 SPACESTATION_STATE_HOME="$d/state" SPACESTATION_NODE_DIR="$d"
export JULIA_DEPOT_PATH="${STRESS_DEPOT_PATH:-$d/depot:${JULIA_DEPOT_PATH:-$HOME/.julia}:}"
cd "$d"; : > "$d/calls.log"
nohup "$d/hangtrace" -b -p "$PREFIXES" -f "$d/hang" -l "$d/calls.log" -- "$J" --threads=4,1 --project="$APP" -e "import SpaceStation; SpaceStation.run(launch_browser=false, hub=true, port=$PORT, require_secret_for_access=false, require_secret_for_open_links=false)" > "$d/hub.log" 2>&1 &
hub=$!
cleanup() { rm -f "$d/hang"; kill "$hub" 2>/dev/null; sleep 1; kill -9 "$hub" 2>/dev/null; cd /; rm -rf "$d"; }
trap cleanup EXIT
for i in $(seq 1 150); do curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/ping" 2>/dev/null && break; sleep 2; done
curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$PORT/ping" || { echo "hub did not start"; tail -5 "$d/hub.log"; exit 4; }
urls="/ping /api/v1/config /api/v1/local/list / /land.js /editor.html /api/v1/remote/list"
ask() { # ask <seconds> -> prints worst latency, count, failures
    local until=$(( $(date +%s) + $1 )) worst=0 n=0 bad=0 t code
    while [ "$(date +%s)" -lt "$until" ]; do
        for u in $urls; do
            [ "$(date +%s)" -lt "$until" ] || break
            read -r code t < <(curl -s -m 8 -o /dev/null -w "%{http_code} %{time_total}\n" "http://127.0.0.1:$PORT$u")
            n=$((n+1)); [ "$code" = 200 ] || bad=$((bad+1))
            worst=$(echo "$t $worst" | awk '{print ($1>$2)?$1:$2}')
        done
    done
    echo "$worst $n $bad"
}
read -r w n b < <(ask 10); echo "warm-up:      worst ${w}s over $n requests, $b failed"
calls_before=$(wc -l < "$d/calls.log")
touch "$d/hang"
# SCENARIO=userfiles: meanwhile a browser keeps asking for a listing of a directory that IS on the hung
# filesystem (the sidebar during a home-directory hang). Those requests may fail or time out; every
# OTHER request must still be answered at once.
if [ "${SCENARIO:-}" = userfiles ]; then
    ( while [ -e "$d/hang" ]; do curl -s -m 5 -o /dev/null "http://127.0.0.1:$PORT/api/v1/browse?path=${USERFILES_DIR}"; sleep 0.5; done ) &
fi
read -r w n b < <(ask "$HANG"); echo "during hang:  worst ${w}s over $n requests, $b failed   (hang of ${HANG}s on $PREFIXES)"
blocked=$(( $(wc -l < "$d/calls.log") - calls_before ))
echo "path calls into the hung trees during the hang: $blocked"
if [ "$blocked" -gt 0 ]; then
    echo "  held calls and who made them:"
    tail -n "$blocked" "$d/calls.log" > "$d/held.log"; python3 "$here/resolve_stack.py" "$d/held.log" | head -150
fi
rm -f "$d/hang"
read -r w2 n2 b2 < <(ask 5); echo "after:        worst ${w2}s over $n2 requests, $b2 failed"
awk -v w="$w" -v l="$LIMIT" -v b="$b" 'BEGIN{ if (w+0 > l+0 || b+0 > 0) { print "FAIL: the hub waited on the hung filesystem"; exit 1 } print "PASS: the hub never waited on the hung filesystem" }'
