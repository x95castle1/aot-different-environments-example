#!/usr/bin/env bash
# Example 06: train the AOT cache with a real workload (training-pipeline.sh), then measure what it buys.
#
# Three images of the same app, all measured in the "real" dev1 environment (shared infra, its own
# credentials), never in the training stack:
#   untrained          no AOT cache at all
#   context-trained    cache trained in the build on startup only (-Dspring.context.exit=onRefresh)
#   workload-trained   cache trained by training-pipeline.sh with the request mix in run-workload.sh
# Per image, RUNS fresh starts (round-robin, data reset before each): startup time, first request,
# and the first WARMUP_REQUESTS requests (warm-up). Plus one run counting classes from the cache.
# Expected results: expectations.json. Writes reports/06-training-workload/<run>/report.md.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

RUNS=${RUNS:-3}
WARMUP_REQUESTS=${WARMUP_REQUESTS:-300}
export RUNS
IMAGES=(untrained context-trained workload-trained)
SHORT=(untrained context workload)
PORT=8602
NAME=aot-06-measure-$$
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

report_init 06-training-workload

# ---------------------------------------------------------------------------------------------------- training
./training-pipeline.sh
for img in "${IMAGES[@]}"; do report_image "workload-app:$img"; done

# ---------------------------------------------------------------------------------------------------- measure
step "The three images"
note "  untrained         no AOT cache at all"
note "  context-trained   cache recorded in docker build by only starting the app (Spring context up, JVM exits"
note "                    before any request): startup code only"
note "  workload-trained  cache recorded by training-pipeline.sh while the app served real requests: startup + request-path code"

step "Measurement environment: dev1 on the shared infrastructure"
make -s -C "$ROOT/infra" up >/dev/null 2>&1
"$ROOT/infra/bootstrap.sh" workload-app dev1 | sed 's/^/  /'
INFRA=(docker compose -f "$ROOT/infra/compose.yml")
reset_data() {
  "${INFRA[@]}" exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin \
    --eval "db.getSiblingDB('workload_dev1').orders.drop()" >/dev/null
}

# start_app <image> [extra docker run options...]: dev1 environment, waits until healthy
start_app() {
  local img=$1; shift
  cleanup
  docker run -d --name "$NAME" --network aot-infra -p "${PORT}:8080" \
    -e APP_ENV=dev -e APP_ENV_INDEX=1 -e CONFIG_SERVER_URL=http://config-server:8888 -e VAULT_ADDR=http://vault:8200 \
    --env-file "$ROOT/.secrets/workload-app/dev1.env" "$@" "workload-app:$img" >/dev/null
  wait_for_http "http://localhost:${PORT}/actuator/health" 90
}

declare_times() { eval "T_$1_$2=()"; }
for s in "${SHORT[@]}"; do for m in startup first early warmup; do declare_times "$m" "$s"; done; done

note "  ${RUNS} fresh starts per image, round-robin; first request = first POST /orders after ready;"
note "  warm-up = total time of the first 50 and the first ${WARMUP_REQUESTS} requests of run-workload.sh (sequential, same mix every time)"
for run in $(seq 1 "$RUNS"); do
  step "Round ${run}/${RUNS}"
  for i in "${!IMAGES[@]}"; do
    img=${IMAGES[$i]}; s=${SHORT[$i]}
    reset_data
    if ! start_app "$img"; then
      docker logs "$NAME" 2>&1 | save_evidence "${s}.failed-start.log"
      eval "T_startup_${s}+=(FAIL); T_first_${s}+=(FAIL); T_early_${s}+=(FAIL); T_warmup_${s}+=(FAIL)"
      fail "${img}: did not start"; continue
    fi
    st=$(started_in "$NAME")
    out=$(./run-workload.sh "http://localhost:${PORT}" "$WARMUP_REQUESTS" 1 42 || echo "FAIL")
    first=$(head -1 <<<"$out" | awk '{print $2}')
    early=$(awk '$2 ~ /^[0-9.]+$/ && NR <= 50 {t += $2} END {printf "%.3f", t}' <<<"$out")
    total=$(awk '$2 ~ /^[0-9.]+$/ {t += $2} END {printf "%.3f", t}' <<<"$out")
    [[ "$run" == 1 ]] && docker logs "$NAME" 2>&1 | save_evidence "${s}.startup.log"
    eval "T_startup_${s}+=($st); T_first_${s}+=($first); T_early_${s}+=($early); T_warmup_${s}+=($total)"
    printf '  %-17s startup %6ss   first request %7ss   first 50 %6ss   first %s %6ss\n' "$img" "$st" "$first" "$early" "$WARMUP_REQUESTS" "$total"
  done
done
cleanup

for s in "${SHORT[@]}"; do
  for m in startup first early warmup; do
    eval "vals=(\"\${T_${m}_${s}[@]}\")"
    record_timing "${m}.${s}" "${vals[@]}"
  done
done

# ---------------------------------------------------------------------------------------------------- classes
step "Classes loaded during startup + ${WARMUP_REQUESTS} requests: from the AOT cache vs from the jars"
declare -a OUTSIDE
for i in "${!IMAGES[@]}"; do
  img=${IMAGES[$i]}; s=${SHORT[$i]}
  reset_data
  start_app "$img" -e "JAVA_TOOL_OPTIONS=-Xlog:disable -Xlog:class+load=info:file=/tmp/cl.log" || { fail "${img}: did not start"; continue; }
  ./run-workload.sh "http://localhost:${PORT}" "$WARMUP_REQUESTS" 1 42 >/dev/null || true
  read -r cached total < <(docker exec "$NAME" sh -c 'echo "$(grep -c "shared objects file" /tmp/cl.log) $(grep -c "source:" /tmp/cl.log)"')
  outside=$(( total - cached ))
  OUTSIDE[$i]=$outside
  printf 'classes loaded (startup + %s requests): %s, from the AOT cache: %s, from the jars: %s\n' \
    "$WARMUP_REQUESTS" "$total" "$cached" "$outside" | save_evidence "${s}.classes.txt"
  printf '  %-17s %6s classes loaded, %6s from the AOT cache, %5s from the jars\n' "$img" "$total" "$cached" "$outside"
  if [[ "$img" == untrained ]]; then expect cache.untrained "" "$(aot_verdict "$cached" "$total")" "" "${s}.classes.txt"
  else expect "cache.${s}" "" "$(aot_verdict "$cached" "$total")" "" "${s}.classes.txt"; fi
  expect "outside.${s}" "" "${outside} classes"
done
cleanup
if [[ -n "${OUTSIDE[1]:-}" && -n "${OUTSIDE[2]:-}" ]]; then
  expect fewer-outside "" "$([[ ${OUTSIDE[2]} -lt ${OUTSIDE[1]} ]] && echo yes || echo no)" "" workload.classes.txt
fi

finish
