#!/usr/bin/env bash
# Example 01: the same image started with different JVM flags.
#
#   1. The image: which JVM flags its AOT cache was trained with (the prod flags)
#   2. Each scenario in expectations.json: did the JVM use the AOT cache, and how fast did Spring start
#      (RUNS timed starts)?
#   3. Guardrail: -XX:AOTMode=on turns an unusable cache into a failed start
# Writes reports/01-jvm-args/<run>/report.md.
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq

IMAGE=jvm-args-app:1.0.0
RUNS=${RUNS:-5}
export RUNS
PROD=""            # the image's JDK_JAVA_OPTIONS: the flags its AOT cache was trained with (show_image)
OPTS=()            # the docker run options of the current scenario (set_opts)

# ---------------------------------------------------------------------------------------------------- helpers

# scenarios: one line per scenario in expectations.json: id, label, JVM flags, docker options.
# Fields are separated by \x1f, not tabs: read would merge consecutive tabs and lose empty fields.
scenarios() { jq -r '.scenarios[] | [.id, .label, .flags, .dockerOpts] | join("\u001f")' expectations.json; }

# set_opts <flags> <docker opts>: fills OPTS with the docker run options for a scenario
set_opts() {
  OPTS=()
  [[ -n "$1" ]] && OPTS+=(-e "JDK_JAVA_OPTIONS=$1")
  # shellcheck disable=SC2206
  [[ -n "$2" ]] && OPTS+=($2)
  return 0
}

# start_once <flags> <docker opts> [log name]: start the app once, print Spring's startup seconds
start_once() {
  local name="aot-01-jvm-args-run-$$"
  set_opts "$1" "$2"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" ${OPTS[@]+"${OPTS[@]}"} "$IMAGE" >/dev/null
  started_in "$name"
  if [[ -n "${3:-}" ]]; then docker logs "$name" 2>&1 | save_evidence "$3"; fi
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------------- steps

show_image() {
  step "Image ${IMAGE}"
  report_image "$IMAGE"
  PROD=$(image_jvm_flags "$IMAGE")
  note "  JDK AOT cache trained with (image default JDK_JAVA_OPTIONS): ${PROD}"
  note "  ${RUNS} timed runs per scenario; Spring's \"Started ... in X seconds\""
  start_once "" "" >/dev/null   # warm-up
}

run_scenarios() {
  local id label flags dopts
  while IFS=$'\x1f' read -r id label flags dopts; do
    run_scenario "$id" "$label" "${flags//\{PROD\}/$PROD}" "$dopts"
  done < <(scenarios)
}

# run_scenario <id> <label> <flags> <docker opts>: AOT cache used or not, then RUNS timed starts
run_scenario() {
  local id=$1 label=$2 flags=$3 dopts=$4
  step "$label"
  # No flags = JDK_JAVA_OPTIONS isn't overridden: the JVM runs with the image's default, the prod flags
  note "  flags: ${flags:-${PROD}  (image default JDK_JAVA_OPTIONS, not overridden)} ${dopts}"

  set_opts "$flags" "$dopts"
  aot_usage "${id}.aot-cache.txt" docker run --rm ${OPTS[@]+"${OPTS[@]}"} --entrypoint sh "$IMAGE" -c
  expect "cache.${id}" "" "$AOT_VERDICT" "" "${id}.aot-cache.txt"
  note "  classes from JDK AOT cache: ${CACHED} / ${TOTAL}"

  local times=() i started=yes
  for i in $(seq 1 "$RUNS"); do
    times+=("$(start_once "$flags" "$dopts" "$([[ $i == 1 ]] && echo "${id}.startup.log")")")
  done
  if [[ " ${times[*]} " == *" FAIL "* ]]; then started=no; fi
  expect started "$label" "$started" "" "${id}.startup.log"
  record_timing "$id" "${times[@]}"
  note "  startup (s): ${times[*]}   median $(median "${times[@]}")"
}

check_guardrail() {
  step "Guardrail: -XX:AOTMode=on makes an unusable cache a hard failure"
  local code=0
  docker run --rm -e "JDK_JAVA_OPTIONS=-XX:+UseZGC -XX:AOTMode=on" -e "JAVA_TOOL_OPTIONS=-Dspring.context.exit=onRefresh" \
    "$IMAGE" 2>&1 | save_evidence guardrail.log || code=$?
  expect guardrail "" "$([[ $code -ne 0 ]] && echo "refused to start" || echo "started")" "" guardrail.log
}

# ---------------------------------------------------------------------------------------------------- main

report_init 01-jvm-args
show_image
run_scenarios
check_guardrail
finish
