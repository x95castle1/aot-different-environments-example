#!/usr/bin/env bash
# Example 01: the same image started with different JVM flags.
# For each scenario (defined in expectations.json): did the JVM use the AOT cache (trained with the
# prod flags), and how fast did Spring start (RUNS timed starts)? Writes reports/01-jvm-args/<run>/report.md.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq

IMAGE=jvm-args-app:1.0.0
RUNS=${RUNS:-5}
export RUNS

report_init 01-jvm-args
report_image "$IMAGE"
PROD=$(image_jvm_flags "$IMAGE")

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
  [[ -n "${3:-}" ]] && docker logs "$name" 2>&1 | save_evidence "$3"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

step "Image ${IMAGE}"
note "  AOT cache trained with (image default JDK_JAVA_OPTIONS): ${PROD}"
note "  ${RUNS} timed runs per scenario; Spring's \"Started ... in X seconds\""
start_once "" "" >/dev/null   # warm-up

# Fields are separated by \x1f, not tabs: read would merge consecutive tabs and lose empty fields.
while IFS=$'\x1f' read -r id label flags dopts; do
  flags=${flags//\{PROD\}/$PROD}
  step "$label"
  note "  flags: ${flags:-<image default>} ${dopts}"

  set_opts "$flags" "$dopts"
  aot_usage "${id}.aot-cache.txt" docker run --rm ${OPTS[@]+"${OPTS[@]}"} --entrypoint sh "$IMAGE" -c
  expect "cache.${id}" "" "$AOT_VERDICT" "" "${id}.aot-cache.txt"
  note "  classes from AOT cache: ${CACHED} / ${TOTAL}"

  times=()
  for i in $(seq 1 "$RUNS"); do
    times+=("$(start_once "$flags" "$dopts" "$([[ $i == 1 ]] && echo "${id}.startup.log")")")
  done
  started=yes; [[ " ${times[*]} " == *" FAIL "* ]] && started=no
  expect started "$label" "$started" "" "${id}.startup.log"
  record_timing "$id" "${times[@]}"
  note "  startup (s): ${times[*]}   median $(median "${times[@]}")"
done < <(jq -r '.scenarios[] | [.id, .label, .flags, .dockerOpts] | join("\u001f")' expectations.json)

step "Guardrail: -XX:AOTMode=on makes an unusable cache a hard failure"
set +e
docker run --rm -e "JDK_JAVA_OPTIONS=-XX:+UseZGC -XX:AOTMode=on" -e "JAVA_TOOL_OPTIONS=-Dspring.context.exit=onRefresh" \
  "$IMAGE" 2>&1 | save_evidence guardrail.log
code=${PIPESTATUS[0]}
set -e
expect guardrail "" "$([[ $code -ne 0 ]] && echo "refused to start" || echo "started")" "" guardrail.log

finish
