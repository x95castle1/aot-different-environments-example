#!/usr/bin/env bash
# peak-sweep.sh: -XX:CICompilerCount vs time to PEAK throughput, on fixed data, with example 06's workload-trained
# image running as prod1.
# Needs example 06's images and environments: make -C examples/06-training-workload train envs
#
#   ./peak-sweep.sh                                    # 2 rounds, 8 phases of 20000 requests
#   ROUNDS=1 PHASES=4 ONLY="nolimit-default nolimit-4" ./peak-sweep.sh
#   WORKERS=16 ONLY=nolimit-default ./peak-sweep.sh   # more load: does the plateau move? Then it's the load path's
#
# Per (round, config): a fresh prod1 with empty data, seeded with run-workload.sh's first 300 requests, then PHASES
# phases of PER_PHASE read-only GETs (60% list by customer, 30% get by id, 10% stats) over WORKERS (8) keep-alive
# curl workers. Read-only, so the data stays fixed and the curve shows the JIT, not a growing collection.
# Prints: <config> startup=<s> rps=[phase1 phase2 ...]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/../../examples/06-training-workload"
ROUNDS=${ROUNDS:-2}
PHASES=${PHASES:-8}
PER_PHASE=${PER_PHASE:-20000}
WORKERS=${WORKERS:-8}
ENVC=(docker compose -f compose.yml)
NOLIMIT=(docker compose -f compose.yml -f "$HERE/nolimit.yml")
# name | compose variant (1g = prod1 as compose.yml defines it, nolimit = its mem_limit removed) | extra JVM flags
CFGS=("nolimit-default|nolimit|" "nolimit-3|nolimit|-XX:CICompilerCount=3" "nolimit-4|nolimit|-XX:CICompilerCount=4"
      "1g-default|1g|" "1g-2|1g|-XX:CICompilerCount=2" "1g-3|1g|-XX:CICompilerCount=3")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

now() { date +%s.%N; }

# configs <port> <ids>: one curl config per worker, PER_PHASE GETs dealt round-robin, fixed seed
configs() {
  awk -v n="$PER_PHASE" -v ids="$2" -v base="http://localhost:$1" -v workers="$WORKERS" -v dir="$WORK" '
    BEGIN { srand(7); k = split(ids, id, " ")
      for (i = 0; i < n; i++) {
        f = dir "/w" (i % workers) ".cfg"; r = rand()
        if      (r < 0.6) u = "/orders?customer=c" sprintf("%02d", int(rand() * 20)) "&limit=20"
        else if (r < 0.9) u = "/orders/" id[int(rand() * k) + 1]
        else              u = "/orders/stats"
        print "url = \"" base u "\"\noutput = \"/dev/null\"" > f
      } }'
}

# one <name> <variant> <flags>: start, seed, then the timed read-only phases
one() {
  local name=$1 variant=$2 flags=$3 c id port st ids p i t0 t1 rps="" w pids fail=0
  : > "$WORK/err"
  if [[ $variant == nolimit ]]; then c=("${NOLIMIT[@]}"); else c=("${ENVC[@]}"); fi
  "${ENVC[@]}" rm -sf app-dev1 app-prod1 >/dev/null 2>&1 || true
  "${ENVC[@]}" exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin \
    --eval "db.getSiblingDB('workload_prod1').orders.drop()" >/dev/null
  # JAVA_TOOL_OPTIONS adds flags on top of prod1's JDK_JAVA_OPTIONS (the image default, the trained flags)
  JAVA_TOOL_OPTIONS="$flags" "${c[@]}" up -d --no-deps --force-recreate app-prod1 >/dev/null 2>&1
  id=$("${ENVC[@]}" ps -q app-prod1)
  port=$("${ENVC[@]}" port app-prod1 8080 | sed 's/.*://')
  [[ -n "$id" && -n "$port" ]] || { echo "$name FAIL no-container"; return 0; }
  for ((i = 0; i < 90; i++)); do curl -fs "http://localhost:$port/actuator/health" >/dev/null 2>&1 && break; sleep 0.5; done
  st=$(docker logs "$id" 2>&1 | grep -o 'Started [A-Za-z]* in [0-9.]*' | awk '{print $4}') || st=FAIL
  ./run-workload.sh "http://localhost:$port" 300 1 42 >/dev/null 2>&1 || { echo "$name FAIL seed"; return 0; }
  ids=$(curl -fsS "http://localhost:$port/orders?customer=c01&limit=20" | jq -r '.. | objects | .id? // empty' | head -20 | tr '\n' ' ') \
    || { echo "$name FAIL ids"; return 0; }
  [[ -n "$ids" ]] || { echo "$name FAIL no-ids"; return 0; }
  rm -f "$WORK"/w*.cfg
  configs "$port" "$ids"
  for ((p = 1; p <= PHASES; p++)); do
    t0=$(now); pids=()
    # curl -f --fail-early: the first 404 (bad id) or 5xx stops that worker, and the line says "(curl errors: ...)".
    # Without --fail-early curl reports only its LAST request, so failed (and fast) requests would go unnoticed.
    for w in "$WORK"/w*.cfg; do curl -fsS --fail-early -K "$w" 2>>"$WORK/err" & pids+=($!); done
    for w in "${pids[@]}"; do wait "$w" || fail=1; done
    t1=$(now)
    rps="$rps $(awk -v n="$PER_PHASE" -v a="$t0" -v b="$t1" 'BEGIN {printf "%.0f", n / (b - a)}')"
  done
  printf '%s startup=%s rps=[%s]%s\n' "$name" "$st" "${rps# }" "$([[ $fail == 1 ]] && echo " (curl errors: $(head -1 "$WORK/err"))")"
}

for ((r = 1; r <= ROUNDS; r++)); do
  for cfg in "${CFGS[@]}"; do
    IFS='|' read -r name variant flags <<<"$cfg"
    [[ -z "${ONLY:-}" || " $ONLY " == *" $name "* ]] || continue
    one "$name" "$variant" "$flags"
  done
done
"${ENVC[@]}" rm -sf app-dev1 app-prod1 >/dev/null 2>&1 || true
