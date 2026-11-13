#!/usr/bin/env bash
# warmup-sweep.sh: -XX:CICompilerCount vs startup, warm-up and throughput under example 06's request mix,
# on the workload-trained image running as prod1.
# Needs example 06's images and environments: make -C examples/06-training-workload train envs
#
#   ./warmup-sweep.sh                          # 3 rounds, every config
#   ROUNDS=1 ONLY="1g-default nolimit-3" ./warmup-sweep.sh
#   LONG=6 ./warmup-sweep.sh                   # plus 6 phases of 10000 more requests each (long_rps)
#
# Prints one line per (round, config):
#   <config> c1=<C1 thread starts> c2=<C2 thread starts> startup=<s> [long_rps=[...]] warmup300=<s> cold_rps=<req/s> warm_rps=<req/s>
#   c1, c2     compiler threads STARTED (the JVM retires idle ones and starts them again, so this can exceed the max)
#   warmup300  the first 300 requests of run-workload.sh, sequential (what example 06 calls warm-up)
#   cold_rps   the next 3000 requests, 8 workers in parallel (JIT still busy)
#   warm_rps   the next 6000 requests, 8 workers in parallel
#   long_rps   LONG more phases. The mix is 40% creates, so the data keeps growing and Mongo becomes the bottleneck:
#              use peak-sweep.sh for peak throughput.
# The configs run round-robin, so background drift hits every config equally.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE/../../examples/06-training-workload"
ROUNDS=${ROUNDS:-3}
ENVC=(docker compose -f compose.yml)
NOLIMIT=(docker compose -f compose.yml -f "$HERE/nolimit.yml")
LOG="-Xlog:jit+thread=debug:file=/tmp/jit.log"
# name | compose variant (1g = prod1 as compose.yml defines it, nolimit = its mem_limit removed) | extra JVM flags
CFGS=("1g-default|1g|" "1g-2|1g|-XX:CICompilerCount=2" "1g-3|1g|-XX:CICompilerCount=3"
      "1g-4|1g|-XX:CICompilerCount=4" "1g-6|1g|-XX:CICompilerCount=6"
      "nolimit-default|nolimit|" "nolimit-3|nolimit|-XX:CICompilerCount=3" "nolimit-4|nolimit|-XX:CICompilerCount=4")

now() { date +%s.%N; }
rps() { awk -v n="$1" -v a="$2" -v b="$3" 'BEGIN {printf "%.0f", n / (b - a)}'; }

# one <name> <variant> <flags>: a fresh prod1 with empty data, then the timed phases
one() {
  local name=$1 variant=$2 flags=$3 c id port st w0 w1 c0 c1 s0 s1 threads long="" i l0 l1
  if [[ $variant == nolimit ]]; then c=("${NOLIMIT[@]}"); else c=("${ENVC[@]}"); fi
  "${ENVC[@]}" rm -sf app-dev1 app-prod1 >/dev/null 2>&1 || true
  "${ENVC[@]}" exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin \
    --eval "db.getSiblingDB('workload_prod1').orders.drop()" >/dev/null
  # JAVA_TOOL_OPTIONS adds flags on top of prod1's JDK_JAVA_OPTIONS (the image default, the trained flags)
  JAVA_TOOL_OPTIONS="$LOG $flags" "${c[@]}" up -d --no-deps --force-recreate app-prod1 >/dev/null 2>&1
  id=$("${ENVC[@]}" ps -q app-prod1)
  port=$("${ENVC[@]}" port app-prod1 8080 | sed 's/.*://')
  [[ -n "$id" && -n "$port" ]] || { echo "$name FAIL no-container"; return 0; }
  for ((i = 0; i < 90; i++)); do curl -fs "http://localhost:$port/actuator/health" >/dev/null 2>&1 && break; sleep 0.5; done
  st=$(docker logs "$id" 2>&1 | grep -o 'Started [A-Za-z]* in [0-9.]*' | awk '{print $4}') || st=FAIL
  w0=$(now); ./run-workload.sh "http://localhost:$port" 300 1 42 >/dev/null 2>&1 || st="$st(workload-err)"; w1=$(now)
  c0=$(now); ./run-workload.sh "http://localhost:$port" 3000 8 43 >/dev/null 2>&1 || st="$st(cold-err)"; c1=$(now)
  s0=$(now); ./run-workload.sh "http://localhost:$port" 6000 8 44 >/dev/null 2>&1 || st="$st(warm-err)"; s1=$(now)
  for ((i = 1; i <= ${LONG:-0}; i++)); do
    l0=$(now); ./run-workload.sh "http://localhost:$port" 10000 8 $((50 + i)) >/dev/null 2>&1 || st="$st(long-err)"; l1=$(now)
    long="$long $(rps 10000 "$l0" "$l1")"
  done
  [[ -n "$long" ]] && st="$st long_rps=[${long# }]"
  # "Added ...": the log also has a "Removing compiler thread ..." line for every thread the JVM retires
  threads=$(docker exec "$id" sh -c 'echo "c1=$(grep -c "Added.*compiler thread C1" /tmp/jit.log) c2=$(grep -c "Added.*compiler thread C2" /tmp/jit.log)"') \
    || threads="c1=? c2=?"
  printf '%s %s startup=%s warmup300=%s cold_rps=%s warm_rps=%s\n' "$name" "$threads" "$st" \
    "$(awk -v a="$w0" -v b="$w1" 'BEGIN {printf "%.3f", b - a}')" "$(rps 3000 "$c0" "$c1")" "$(rps 6000 "$s0" "$s1")"
}

for ((r = 1; r <= ROUNDS; r++)); do
  for cfg in "${CFGS[@]}"; do
    IFS='|' read -r name variant flags <<<"$cfg"
    [[ -z "${ONLY:-}" || " $ONLY " == *" $name "* ]] || continue
    one "$name" "$variant" "$flags"
  done
done
"${ENVC[@]}" rm -sf app-dev1 app-prod1 >/dev/null 2>&1 || true
