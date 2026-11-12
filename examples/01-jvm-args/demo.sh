#!/usr/bin/env bash
# Example 01: the same image started with different JVM flags.
#
#   1. Build the image (Dockerfile): Spring AOT + a JDK AOT cache trained with the prod JVM flags
#   2. The image: which JVM flags its AOT cache was trained with (the prod flags)
#   3. Each scenario in expectations.json: did the JVM use the AOT cache, and how fast did Spring start
#      (RUNS timed starts)? The two "cache off" baselines start the same image as a plain JVM.
#   4. Guardrail: -XX:AOTMode=on turns an unusable cache into a failed start
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
REVISION=${REVISION:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}   # recorded in the image's labels
PROD=""            # the image's JDK_JAVA_OPTIONS: the flags its AOT cache was trained with (show_image)
OPTS=()            # the docker run options of the current scenario (set_opts)

# ---------------------------------------------------------------------------------------------------- helpers

# scenarios: one line per scenario in expectations.json: id, label, JVM flags, docker options, cache on|off.
# Fields are separated by \x1f, not tabs: read would merge consecutive tabs and lose empty fields.
scenarios() { jq -r '.scenarios[] | [.id, .label, .flags, .dockerOpts, (.cache // "on")] | join("\u001f")' expectations.json; }

# set_opts <flags> <docker opts>: fills OPTS with the docker run options for a scenario
set_opts() {
  OPTS=()
  [[ -n "$1" ]] && OPTS+=(-e "JDK_JAVA_OPTIONS=$1")
  # shellcheck disable=SC2206
  [[ -n "$2" ]] && OPTS+=($2)
  return 0
}

# run_app <on|off> <docker run options...>: start the image with its JDK AOT cache (its ENTRYPOINT) or without
run_app() {
  local cache=$1; shift
  if [[ "$cache" == "off" ]]; then
    # The same image without -XX:AOTCache: a plain JVM, which still uses the JDK's own default class archive (CDS).
    # Not -XX:AOTMode=off: that switches every class archive off, which a JVM without an AOT cache doesn't do.
    docker run "$@" --entrypoint java "$IMAGE" -Dspring.aot.enabled=true -jar /app/app.jar >/dev/null
  else
    docker run "$@" "$IMAGE" >/dev/null
  fi
}

# start_once <cache on|off> <flags> <docker opts> [log name]: start the app once, print Spring's startup seconds
start_once() {
  local name="aot-01-jvm-args-run-$$"
  set_opts "$2" "$3"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_app "$1" -d --name "$name" ${OPTS[@]+"${OPTS[@]}"}
  started_in "$name"
  if [[ -n "${4:-}" ]]; then docker logs "$name" 2>&1 | save_evidence "$4"; fi
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------------- steps

# build_image: this folder's Dockerfile -> jvm-args-app:1.0.0. Docker reuses its build cache, so this is quick when nothing changed;
# the first build takes a few minutes (Maven downloads, Spring AOT, AOT-cache training).
build_image() {
  step "Build the image jvm-args-app:1.0.0"
  note "  docker build -t jvm-args-app:1.0.0 .   (Dockerfile: offline Maven build with Spring AOT, then the JDK AOT cache"
  note "                                    trained with the prod JVM flags; see the Dockerfile's comments)"
  docker build -q --build-arg REVISION="$REVISION" -t "$IMAGE" . >/dev/null
}

show_image() {
  step "Image ${IMAGE}"
  report_image "$IMAGE"
  PROD=$(image_jvm_flags "$IMAGE")
  note "  JDK AOT cache trained with (image default JDK_JAVA_OPTIONS): ${PROD}"
  note "  ${RUNS} timed runs per scenario; Spring's \"Started ... in X seconds\""
  start_once on "" "" >/dev/null   # warm-up
}

run_scenarios() {
  local id label flags dopts cache
  while IFS=$'\x1f' read -r id label flags dopts cache; do
    run_scenario "$id" "$label" "${flags//\{PROD\}/$PROD}" "$dopts" "$cache"
  done < <(scenarios)
}

# run_scenario <id> <label> <flags> <docker opts> <cache on|off>: AOT cache used or not, then RUNS timed starts
run_scenario() {
  local id=$1 label=$2 flags=$3 dopts=$4 cache=$5
  step "$label"
  # No flags = JDK_JAVA_OPTIONS isn't overridden: the JVM runs with the image's default, the prod flags
  note "  flags: ${flags:-${PROD}  (image default JDK_JAVA_OPTIONS, not overridden)} ${dopts}"

  set_opts "$flags" "$dopts"
  if [[ "$cache" == "off" ]]; then
    note "  started without -XX:AOTCache (entrypoint overridden): a plain JVM"
    aot_usage_with "-Dspring.aot.enabled=true" "${id}.aot-cache.txt" docker run --rm ${OPTS[@]+"${OPTS[@]}"} --entrypoint sh "$IMAGE" -c
    note "  classes from the JDK's default class archive (CDS): ${CACHED} / ${TOTAL}"
  else
    aot_usage "${id}.aot-cache.txt" docker run --rm ${OPTS[@]+"${OPTS[@]}"} --entrypoint sh "$IMAGE" -c
    note "  classes from JDK AOT cache: ${CACHED} / ${TOTAL}"
  fi
  expect "cache.${id}" "" "$AOT_VERDICT" "" "${id}.aot-cache.txt"

  local times=() i started=yes
  for i in $(seq 1 "$RUNS"); do
    times+=("$(start_once "$cache" "$flags" "$dopts" "$([[ $i == 1 ]] && echo "${id}.startup.log")")")
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
build_image
show_image
run_scenarios
check_guardrail
finish
