#!/usr/bin/env bash
# Stress test: a hub must keep answering while the filesystems under HANG_PREFIXES are hung.
#
#   stress_hub.sh <app-dir> <julia> <port> <hang-prefixes> [hang-seconds]
#
# Starts a hub from <app-dir> under hangtrace (system-call level hang injection), lets it start and serve one warm-up session,
# then raises the hang flag and keeps asking (ping, config, workspace list, the page, an asset). The hub
# runs a garbage collection twice a second throughout: a hub thread held in a call only shows once a
# collection needs it, and the test must not pass by luck. It FAILS when any request during the hang
# took longer than LIMIT seconds, and when the hub PROCESS ITSELF made even one call into the hung
# trees (hangtrace names the process of every held call). SCENARIO=userfiles adds the sidebar's
# requests for a directory that is hung, and requires: those are refused (504) quickly, the calls
# that do get stuck belong to helper processes, and the listing works again after the hang.
set -u
APP=$1; J=$2; PORT=$3; PREFIXES=$4; HANG=${5:-40}; LIMIT=${LIMIT:-2}
here=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d "${TMPDIR:-/tmp}/hubstress.XXXXXX")
gcc -O2 -o "$d/hangtrace" "$here/hangtrace.c" || exit 3
mkdir -p "$d/state" "$d/depot"
export SPACESTATION_HUB=1 SPACESTATION_STATE_HOME="$d/state" SPACESTATION_NODE_DIR="$d"
export JULIA_DEPOT_PATH="${STRESS_DEPOT_PATH:-$d/depot:${JULIA_DEPOT_PATH:-$HOME/.julia}:}"
cd "$d"; : > "$d/calls.log"
nohup "$d/hangtrace" -b -p "$PREFIXES" -f "$d/hang" -l "$d/calls.log" -- "$J" --threads=4,1 --project="$APP" -e "@async while true; GC.gc(false); sleep(0.5); end; import SpaceStation; SpaceStation.run(launch_browser=false, hub=true, port=$PORT, require_secret_for_access=false, require_secret_for_open_links=false)" > "$d/hub.log" 2>&1 &
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
if [ "${SCENARIO:-}" = userfiles ]; then # the helpers come up in the background: wait for a first listing
    for i in $(seq 1 120); do [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/browse?path=${USERFILES_DIR}")" = 200 ] && break; sleep 2; done
fi
# Positive control: the injector must be attached and must see THIS hub. Julia itself was started from
# under the prefixes or not; either way a deliberate touch has to show up, tagged with the right process.
probe="${PREFIXES%%:*}"
before=$(wc -l < "$d/calls.log")
"$d/hangtrace" -p "$PREFIXES" -l "$d/control.log" -- stat "$probe" > /dev/null 2>&1
grep -q "root$" "$d/control.log" 2>/dev/null || { echo "FAIL: the injector does not see path calls (positive control)"; exit 5; }
if [ "${SCENARIO:-}" = userfiles ]; then
    curl -s -m 9 -o /dev/null "http://127.0.0.1:$PORT/api/v1/browse?path=${USERFILES_DIR}"
    [ "$(tail -n +"$((before + 1))" "$d/calls.log" | awk -F'\t' '$5=="child"' | wc -l)" -ge 1 ] || { echo "FAIL: a listing through the hub left no trace from a helper process (positive control)"; exit 5; }
fi
read -r w n b < <(ask 10); echo "warm-up:      worst ${w}s over $n requests, $b failed"
calls_before=$(wc -l < "$d/calls.log")
touch "$d/hang"
# SCENARIO=userfiles: meanwhile a browser keeps asking for a listing of a directory that IS on the hung
# filesystem (the sidebar during a home-directory hang). Those requests may fail or time out; every
# OTHER request must still be answered at once.
if [ "${SCENARIO:-}" = userfiles ]; then
    ( while [ -e "$d/hang" ]; do curl -s -m 9 -o /dev/null -w "%{http_code} %{time_total}\n" "http://127.0.0.1:$PORT/api/v1/browse?path=${USERFILES_DIR}" >> "$d/browse.log"; sleep 0.5; done ) &
fi
read -r w n b < <(ask "$HANG"); echo "during hang:  worst ${w}s over $n requests, $b failed   (hang of ${HANG}s on $PREFIXES)"
blocked=$(( $(wc -l < "$d/calls.log") - calls_before ))
echo "path calls into the hung trees during the hang: $blocked"
: > "$d/held.log"
if [ "$blocked" -gt 0 ]; then
    tail -n "$blocked" "$d/calls.log" > "$d/held.log"
    echo "  held calls by process (root = the hub itself, child = a process it started):"
    awk -F'\t' 'NF>=5 {print "    "$5"\t"$1"\t"$2}' "$d/held.log" | sort | uniq -c | sort -rn | head -12
    if awk -F'\t' 'NF>=5 && $5=="root"' "$d/held.log" | grep -q .; then
        echo "  stacks of the calls the HUB made:"; python3 "$here/resolve_stack.py" "$d/held.log" | awk '/\troot$/{p=1} /\tchild$/{p=0} p' | head -120
    fi
fi
rm -f "$d/hang"
read -r w2 n2 b2 < <(ask 5); echo "after:        worst ${w2}s over $n2 requests, $b2 failed"
verdict=0
hub_calls=$(awk -F'\t' 'NF>=5 && $5=="root"' "$d/held.log" 2>/dev/null | wc -l)
[ "$hub_calls" -eq 0 ] || { echo "FAIL: the hub process itself made $hub_calls call(s) into the hung trees"; verdict=1; }
if [ "${SCENARIO:-}" = userfiles ]; then
    helper_calls=$(awk -F'\t' 'NF>=5 && $5=="child"' "$d/held.log" 2>/dev/null | wc -l)
    [ "$helper_calls" -ge 1 ] || { echo "FAIL: no helper process was seen asking the hung directory: the scenario did not exercise anything"; verdict=1; }
    refused=$(awk '$1==504' "$d/browse.log" | wc -l); slowest=$(awk '{ if ($2>m) m=$2 } END { print m+0 }' "$d/browse.log")
    echo "listings of the hung directory: $(wc -l < "$d/browse.log") asked, $refused refused with 504, slowest ${slowest}s"
    [ "$refused" -ge 1 ] || { echo "FAIL: a listing of a hung directory was never refused"; verdict=1; }
    awk -v m="$slowest" 'BEGIN{ exit !(m+0 > 8) }' && { echo "FAIL: a refusal took longer than 8 s"; verdict=1; }
    back=000; for i in $(seq 1 30); do back=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/browse?path=${USERFILES_DIR}"); [ "$back" = 200 ] && break; sleep 1; done
    [ "$back" = 200 ] && echo "the listing works again ${i}s after the hang" || { echo "FAIL: the listing did not come back after the hang (last status $back)"; verdict=1; }
fi
awk -v w="$w" -v l="$LIMIT" -v b="$b" 'BEGIN{ exit !(w+0 > l+0 || b+0 > 0) }' && { echo "FAIL: requests waited on the hung filesystem (worst ${w}s, $b failed)"; verdict=1; }
[ "$verdict" -eq 0 ] && echo "PASS: the hub never waited on the hung filesystem, and never asked it anything"
exit "$verdict"
