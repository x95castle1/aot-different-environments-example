#!/usr/bin/env bash
# Example 01: the same image started with different JVM flags.
# For each scenario: did the JVM use the AOT cache (trained with the prod flags), and how fast did
# Spring start (median of RUNS)? Compatible flags keep the fast startup; only flags that make the
# cache unusable (e.g. ZGC on JDK 25) fall back to a normal, slower start.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"

IMAGE=jvm-args-app:1.0.0
RUNS=${RUNS:-5}
PROD=$(image_jvm_flags "$IMAGE")

#            label                          | JDK_JAVA_OPTIONS ("" = image default = prod) | docker opts         | expected cache
SCENARIOS=(
  "prod flags (trained with these)|                                                       ||USED"
  "smaller heap|-XX:+UseG1GC -Xmx256m -XX:+ExitOnOutOfMemoryError                           ||USED"
  "bigger fixed heap|-XX:+UseG1GC -Xms2g -Xmx2g -XX:+ExitOnOutOfMemoryError                  ||USED"
  "512 MB container, 50% RAM|-XX:+UseG1GC -XX:MaxRAMPercentage=50                         |--memory 512m|USED"
  "1 CPU|                                                                                 |--cpus 1|USED"
  "1 CPU, AOT cache off (reference)|${PROD} -XX:AOTMode=off                               |--cpus 1|not used"
  "extra -D props + GC log|${PROD} -Dfeature.x=on -Duser.timezone=UTC -Xlog:gc            ||USED"
  "Parallel GC|-XX:+UseParallelGC -XX:MaxRAMPercentage=75                                 ||USED"
  "ZGC|-XX:+UseZGC -XX:MaxRAMPercentage=75                                                ||not used"
  "AOT cache switched off|${PROD} -XX:AOTMode=off                                         ||not used"
)

trim() { sed -e 's/^ *//' -e 's/ *$//' <<<"$1"; }

# set_opts <flags> <docker opts>: fills OPTS with the docker run options for a scenario
set_opts() {
  OPTS=()
  [[ -n "$1" ]] && OPTS+=(-e "JDK_JAVA_OPTIONS=$1")
  # shellcheck disable=SC2206
  [[ -n "$2" ]] && OPTS+=($2)
  return 0
}

# start_once <flags> <docker opts>: start the app once, print Spring's startup seconds
start_once() {
  local name="aot-01-jvm-args-run"
  set_opts "$1" "$2"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" ${OPTS[@]+"${OPTS[@]}"} "$IMAGE" >/dev/null
  started_in "$name"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

step "Image ${IMAGE}"
note "  AOT cache trained with (image default JDK_JAVA_OPTIONS): ${PROD}"
note "  ${RUNS} timed runs per scenario; Spring's \"Started ... in X seconds\""
start_once "" "" >/dev/null   # warm-up

rows=()
baseline=""
for s in "${SCENARIOS[@]}"; do
  IFS='|' read -r label flags dopts expect <<<"$s"
  label=$(trim "$label"); flags=$(trim "$flags"); dopts=$(trim "$dopts"); expect=$(trim "$expect")
  step "$label"
  note "  flags: ${flags:-<image default>} ${dopts}"

  set_opts "$flags" "$dopts"
  read -r cached total < <(docker run --rm ${OPTS[@]+"${OPTS[@]}"} --entrypoint sh "$IMAGE" -c "$AOT_USAGE_SCRIPT")
  verdict=$(aot_verdict "$cached" "$total")

  times=()
  for _ in $(seq 1 "$RUNS"); do times+=("$(start_once "$flags" "$dopts")"); done
  med=$(median "${times[@]}")
  [[ -z "$baseline" ]] && baseline=$med
  ratio=$(awk -v a="$med" -v b="$baseline" 'BEGIN { printf "%.1fx", a / b }')

  note "  classes from AOT cache: ${cached} / ${total}   startup: ${times[*]}"
  if [[ "$expect" == "?" ]]; then pass "AOT cache: ${verdict} (no expectation, measured)"; else check "AOT cache" "$verdict" "$expect"; fi
  rows+=("$(printf '%-32s %-9s %6s / %-6s %8ss %7s' "$label" "$verdict" "$cached" "$total" "$med" "$ratio")")
done

step "Guardrail: -XX:AOTMode=on makes an unusable cache a hard failure"
set +e
out=$(docker run --rm -e "JDK_JAVA_OPTIONS=-XX:+UseZGC -XX:AOTMode=on" -e "JAVA_TOOL_OPTIONS=-Dspring.context.exit=onRefresh" "$IMAGE" 2>&1)
code=$?
set -e
grep -m2 -iE "aot" <<<"$out" | sed 's/^/    /' || true
check "ZGC + AOTMode=on refuses to start" "$([[ $code -ne 0 ]] && echo yes || echo no)" "yes"

step "Summary (startup = median of ${RUNS}; vs = relative to prod flags)"
printf '  %s%-32s %-9s %15s %9s %7s%s\n' "$C_BOLD" "scenario" "cache" "cached/total" "startup" "vs" "$C_RESET"
printf '  %s\n' "${rows[@]}"
finish
