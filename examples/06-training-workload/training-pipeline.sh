#!/usr/bin/env bash
# training-pipeline.sh: the "train the AOT cache with a real workload" pipeline, as a CI job would run it.
#
#   1. Build the image WITHOUT a cache        docker build --target untrained        -> workload-app:untrained
#      (and the usual build-time-trained one  docker build (default target)          -> workload-app:context-trained)
#   2. Start throwaway services               docker compose -f training/compose.yml up config-server vault mongo
#   3. Run the untrained image against them   docker compose -f training/compose.yml up trainer
#                                             (java -XX:AOTCacheOutput=/tmp/app.aot -Xmx1g ..., prod flags, Spring AOT on)
#   4. Drive the workload                     run-workload.sh (the same request mix the app sees in prod)
#   5. Stop it cleanly                        docker compose ... stop trainer: SIGTERM -> clean exit -> JVM writes
#                                             app.aot (stop_grace_period 300s), then docker compose ... cp it out
#   6. Bake the cache into the final image    Dockerfile.trained: FROM workload-app:untrained + COPY app.aot
#                                             -> workload-app:workload-trained
#
# The two trained images differ only in what the JVM was doing while it recorded the cache:
#   context-trained   recorded in docker build (this example's Dockerfile, default target) by only STARTING
#                     the app: -Dspring.context.exit=onRefresh exits once the Spring context is ready, before any
#                     request, so the cache holds startup code only. Needs no network or services.
#   workload-trained  recorded here (steps 3-5) while the app SERVED the workload, so the cache also holds the
#                     request path (validation, JSON, Mongo queries, error handling) and its method profiles.
#
# Step 6 builds on workload-app:untrained itself (not a fresh build) because the JVM only accepts a cache recorded
# with the same JDK build and the same /app files (sizes and timestamps) it was trained with. The step checks the
# final image is the untrained image's layers plus exactly one. In CI, pass the untrained image by digest.
#
# Everything that runs is described in training/compose.yml; this script only does the steps in order and checks
# them. Real environment systems are never contacted; the training stack is deleted afterwards.
# When run from demo.sh, results go into its report (expect / save_evidence).
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl
expect_init 06-training-workload

TRAIN_REQUESTS=${TRAIN_REQUESTS:-3000}
TRAIN_PARALLEL=${TRAIN_PARALLEL:-8}
TRAINING=(docker compose -f training/compose.yml)
TRAINER=http://localhost:8601         # the trainer's port in training/compose.yml
OUT=$(mktemp -d)                       # the trainer's log, the workload's output, app.aot
cleanup() {
  "${TRAINING[@]}" down -v >/dev/null 2>&1 || true
  rm -rf "$OUT"
}

# ---------------------------------------------------------------------------------------------------- helpers

# build <docker build options...>: build this example's Dockerfile (build context: this folder)
build() {
  docker build -q -f Dockerfile "$@" \
    --build-arg REVISION="${REVISION:-unknown}" . >/dev/null
}

# save_training_log: the trainer's log -> $OUT/training.log and the report's raw/training.log
# (to a file first: "docker logs | grep -q" can fail under pipefail when grep stops reading early)
save_training_log() {
  "${TRAINING[@]}" logs --no-log-prefix trainer > "$OUT/training.log" 2>&1
  save_evidence training.log < "$OUT/training.log"
}

# cache_written: app.aot was copied out, and the JVM logged that it finished writing it
cache_written() { [[ -s "$OUT/app.aot" ]] && grep -q "AOTCache creation is complete" "$OUT/training.log"; }

# extra_layers <base image> <image>: how many layers <image> adds on top of <base image>; -1 if it isn't built on it
extra_layers() {
  jq -n --argjson b "$(layers "$1")" --argjson f "$(layers "$2")" \
    'if $f[0:($b | length)] == $b then ($f | length) - ($b | length) else -1 end'
}
layers() { docker image inspect -f '{{json .RootFS.Layers}}' "$1"; }

# image_cache_mb <image>: the size of the image's /app/app.aot, in MB
image_cache_mb() { docker run --rm --entrypoint sh "$1" -c 'du -m /app/app.aot | cut -f1'; }

# ---------------------------------------------------------------------------------------------------- steps

build_images() {
  step "1. Build the image without a cache (and the build-time-trained one, for comparison)"
  build --target untrained -t workload-app:untrained
  build -t workload-app:context-trained
  note "  workload-app:untrained, workload-app:context-trained"
}

start_training_services() {
  step "2. Throwaway training services (fake data, deleted afterwards)"
  "${TRAINING[@]}" up -d --wait --build config-server vault mongo >/dev/null 2>&1
  note "  docker compose -f training/compose.yml up -d --wait --build config-server vault mongo"
  COMPOSE_FILE=training/compose.yml ./bootstrap.sh training | sed 's/^/  /'
}

# start_trainer: stops the run (finish) if the app doesn't come up
start_trainer() {
  step "3. Run the untrained image against them, recording a cache"
  "${TRAINING[@]}" up -d trainer >/dev/null 2>&1
  note "  docker compose -f training/compose.yml up -d trainer"
  note "  trainer: java -XX:AOTCacheOutput=/tmp/app.aot -Xmx1g -Dspring.aot.enabled=true -jar /app/app.jar"
  note "  (prod JVM flags from the image's JDK_JAVA_OPTIONS: $(image_jvm_flags workload-app:untrained))"
  local ok=yes
  wait_for_http "$TRAINER/actuator/health" 90 || ok=no
  expect training.started "" "$ok"
  if [[ "$ok" != yes ]]; then save_training_log; finish; fi
}

run_training_workload() {
  step "4. Training workload: ${TRAIN_REQUESTS} requests, ${TRAIN_PARALLEL} in parallel"
  local status=0
  ./run-workload.sh "$TRAINER" "$TRAIN_REQUESTS" "$TRAIN_PARALLEL" 7 > "$OUT/workload.out" || status=$?
  note "  HTTP status counts: $(awk '{c[$1]++} END {for (k in c) printf "%s×%d ", k, c[k]}' "$OUT/workload.out")"
  expect training.workload "" "$([[ $status -eq 0 ]] && echo "no server errors" || echo "server errors")"
}

# stop_and_copy_cache: stops the run (finish) if there's no cache
stop_and_copy_cache() {
  step "5. Stop cleanly: the JVM writes the cache on exit"
  local start=$SECONDS
  "${TRAINING[@]}" stop trainer >/dev/null 2>&1      # waits up to stop_grace_period (300s) for the cache
  note "  docker compose -f training/compose.yml stop trainer"
  save_training_log
  grep -E "AOTConfiguration recorded|assemble AOT cache|AOTCache creation is complete" "$OUT/training.log" \
    | sed 's/^/    /' || true
  note "  stop + cache assembly took $((SECONDS - start))s"
  "${TRAINING[@]}" cp trainer:/tmp/app.aot "$OUT/app.aot" >/dev/null 2>&1 || true
  note "  docker compose -f training/compose.yml cp trainer:/tmp/app.aot <dir>/app.aot"
  local written=missing
  if cache_written; then written="written on clean exit"; fi
  expect training.cache-written "" "$written" "" training.log
  [[ "$written" != missing ]] || finish
}

build_final_image() {
  step "6. Final image: the untrained image + app.aot"
  docker build -q -f Dockerfile.trained --build-arg BASE=workload-app:untrained \
    --build-arg REVISION="${REVISION:-unknown}" --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t workload-app:workload-trained "$OUT" >/dev/null
  # The final image must be the untrained image's layers plus exactly one layer with app.aot.
  local extra
  extra=$(extra_layers workload-app:untrained workload-app:workload-trained)
  docker history --no-trunc --format '{{.CreatedBy}}  {{.Size}}' workload-app:workload-trained | head -6 | save_evidence final-image-history.txt
  expect training.final-image "" "$([[ $extra == 1 ]] && echo "untrained layers + 1 layer (app.aot)" || echo "layers differ (extra=$extra)")" "" final-image-history.txt
  expect training.cache-size "" "context-trained $(image_cache_mb workload-app:context-trained) MB, workload-trained $(( $(wc -c < "$OUT/app.aot") / 1048576 )) MB"
  note "  workload-app:workload-trained"
}

# ---------------------------------------------------------------------------------------------------- main

trap cleanup EXIT
build_images
start_training_services
start_trainer
run_training_workload
stop_and_copy_cache
build_final_image

# When run on its own, report the result; demo.sh carries on with the measurements.
[[ -n "${REPORT_DIR:-}" ]] || finish
