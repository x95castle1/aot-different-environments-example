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
# dev1's own JVM flags (smaller heap); prod1 uses the image default, which is what the caches were trained with.
# Each environment also has a container memory limit, as it would in a real platform.
DEV1_FLAGS="-XX:+UseG1GC -Xmx384m -XX:+ExitOnOutOfMemoryError"
DEV1_MEMORY=768m
PROD1_MEMORY=1g
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

step "Environments: dev1 and prod1 on the shared infrastructure"
note "  dev1   profiles dev,dev1    container memory ${DEV1_MEMORY}  JVM flags: ${DEV1_FLAGS}"
note "  prod1  profiles prod,prod1  container memory ${PROD1_MEMORY}    JVM flags: image default (the flags the caches were trained with)"
note "  Each gets its tier + environment settings from Config Server and its own Mongo password from Vault."
make -s -C "$ROOT/infra" up >/dev/null 2>&1
"$ROOT/infra/bootstrap.sh" workload-app dev1 prod1 | sed 's/^/  /'
INFRA=(docker compose -f "$ROOT/infra/compose.yml")
# reset_data <env>: empty that environment's orders collection, so every run starts from the same data
reset_data() {
  "${INFRA[@]}" exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin \
    --eval "db.getSiblingDB('workload_$1').orders.drop()" >/dev/null
}

# start_app <env> <image> [extra docker run options...]: starts the image as that environment, waits until healthy.
# The environment is only env vars: APP_ENV + APP_ENV_INDEX (-> profiles), where Config Server and Vault are,
# its Vault token, and its JVM flags. Everything else it fetches at startup.
start_app() {
  local env=$1 img=$2; shift 2
  local opts=(-e "APP_ENV=${env%%[0-9]*}" -e "APP_ENV_INDEX=${env##*[a-z]}"
              -e CONFIG_SERVER_URL=http://config-server:8888 -e VAULT_ADDR=http://vault:8200
              --env-file "$ROOT/.secrets/workload-app/${env}.env")
  if [[ "$env" == dev1 ]]; then opts+=(--memory "$DEV1_MEMORY" -e "JDK_JAVA_OPTIONS=${DEV1_FLAGS}")
  else opts+=(--memory "$PROD1_MEMORY"); fi
  cleanup
  docker run -d --name "$NAME" --network aot-infra -p "${PORT}:8080" "${opts[@]}" "$@" "workload-app:$img" >/dev/null
  wait_for_http "http://localhost:${PORT}/actuator/health" 90
}

declare_times() { eval "T_$1_$2=()"; }
for s in "${SHORT[@]}"; do for m in startup first early warmup; do declare_times "$m" "$s"; done; done

step "Timing the three images in dev1"
note "  ${RUNS} fresh starts per image, round-robin; first request = first POST /orders after ready;"
note "  warm-up = total time of the first 50 and the first ${WARMUP_REQUESTS} requests of run-workload.sh (sequential, same mix every time)"
for run in $(seq 1 "$RUNS"); do
  step "Round ${run}/${RUNS}"
  for i in "${!IMAGES[@]}"; do
    img=${IMAGES[$i]}; s=${SHORT[$i]}
    reset_data dev1
    if ! start_app dev1 "$img"; then
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
step "Classes loaded in dev1 during startup + ${WARMUP_REQUESTS} requests: from the AOT cache vs from the jars"
declare -a OUTSIDE
for i in "${!IMAGES[@]}"; do
  img=${IMAGES[$i]}; s=${SHORT[$i]}
  reset_data dev1
  start_app dev1 "$img" -e "JAVA_TOOL_OPTIONS=-Xlog:disable -Xlog:class+load=info:file=/tmp/cl.log" || { fail "${img}: did not start"; continue; }
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

# ---------------------------------------------------------------------------------------------------- environments
step "The image you'd ship (workload-trained) in each environment"
note "  The same image, started as dev1 (profiles dev,dev1) and as prod1 (profiles prod,prod1)."
ENVS=(dev1 prod1)
EXP_PROFILES=("dev,dev1" "prod,prod1")
EXP_FILES=("workload-app-dev1.yml, workload-app-dev.yml, workload-app.yml" "workload-app-prod1.yml, workload-app-prod.yml, workload-app.yml")
EXP_PAGE=(50 100)
rows=(); env_images=()
for i in "${!ENVS[@]}"; do
  env=${ENVS[$i]}
  reset_data "$env"
  if ! start_app "$env" workload-trained -e "JAVA_TOOL_OPTIONS=-Xlog:disable -Xlog:class+load=info:file=/tmp/cl.log"; then
    docker logs "$NAME" 2>&1 | save_evidence "${env}.failed-start.log"
    expect env.started "$env" no "" "${env}.failed-start.log"; continue
  fi
  expect env.started "$env" yes
  st=$(started_in "$NAME")
  info=$(curl -fs "http://localhost:${PORT}/info/runtime")
  jq . <<<"$info" | save_evidence "${env}.info.json"
  out=$(./run-workload.sh "http://localhost:${PORT}" "$WARMUP_REQUESTS" 1 42 || echo "FAIL")
  first=$(head -1 <<<"$out" | awk '{print $2}')
  read -r cached total < <(docker exec "$NAME" sh -c 'echo "$(grep -c "shared objects file" /tmp/cl.log) $(grep -c "source:" /tmp/cl.log)"')
  printf 'classes loaded (startup + %s requests): %s, from the AOT cache: %s, from the jars: %s\n' \
    "$WARMUP_REQUESTS" "$total" "$cached" "$((total - cached))" | save_evidence "${env}.classes.txt"
  env_images+=("$(docker inspect -f '{{.Image}}' "$NAME")")

  profiles=$(jq -r '.activeProfiles | join(",")' <<<"$info")
  files=$(jq -r '[.configSources[] | select(startswith("configserver:")) | sub("^configserver:file:/config-repo/"; "") | sub(" \\(.*$"; "")] | join(", ")' <<<"$info")
  vault=$(jq -r --arg p "vault:secret/workload-app/${env} " '[.configSources[] | select(startswith($p))][0] // "not loaded" | sub(" \\(.*$"; "")' <<<"$info")
  db=$(jq -r '.mongo.database' <<<"$info")
  page=$(jq -r '.maxPageSize' <<<"$info")
  heap=$(jq -r '.jvm.maxHeapMb' <<<"$info")
  # The environment's own flags: leave out the AOT-cache flag (same everywhere) and the demo's -Xlog instrumentation
  flags=$(jq -r '.jvm.inputArguments | map(select(startswith("-X"))) | map(select((startswith("-XX:AOTCache") or startswith("-Xlog")) | not)) | join(" ")' <<<"$info")
  expect env.profiles "$env" "$profiles" "${EXP_PROFILES[$i]}" "${env}.info.json"
  expect env.config-files "$env" "$files" "${EXP_FILES[$i]}" "${env}.info.json"
  expect env.tier-setting "$env" "$page" "${EXP_PAGE[$i]}" "${env}.info.json"
  expect env.mongo-db "$env" "$db" "workload_${env}" "${env}.info.json"
  expect env.vault "$env" "$vault" "vault:secret/workload-app/${env}" "${env}.info.json"
  expect env.mongo-ping "$env" "$(jq -r '.mongo.ping' <<<"$info")" "" "${env}.info.json"
  expect env.cache "$env" "$(aot_verdict "$cached" "$total")" "" "${env}.classes.txt"
  expect env.jvm "$env" "${flags} (max heap ${heap} MB)"
  expect env.timing "$env" "startup ${st}s, first request ${first}s, $((total - cached)) classes loaded from the jars"
  rows+=("$(printf '%-6s %-11s %-64s %-15s %-14s %-9s %s' "$env" "$profiles" "$files" "$db" "max-page $page" "${heap} MB" "${cached}/${total}")")
done
cleanup
expect env.same-image "" "$(printf '%s\n' "${env_images[@]}" | sort -u | wc -l | tr -d ' ')"
printf '\n  %s%-6s %-11s %-64s %-15s %-14s %-9s %s%s\n' "$C_BOLD" "env" "profiles" "Config Server files (most specific first)" "database" "tier setting" "heap" "AOT cache" "$C_RESET"
printf '  %s\n' "${rows[@]}"

finish
