#!/usr/bin/env bash
# Example 04: build once, promote the exact same image (by digest) through dev1 -> qa1 -> prod1.
#
#   1. Build once and push to a local registry; from here on only the digest is used.
#   2. Scan the image: no environment names, hosts or settings inside.
#   3. Promote: deploy the digest to each environment with that environment's env file + config dir.
#   4. Check every environment runs the same build, with its own settings, and uses the AOT cache.
# Expected results: expectations.json. Writes reports/04-one-image/<run>/report.md.
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl unzip

REPO=localhost:5001/one-image-app
TAG=${REVISION:-dev}
ENVS=(dev1 qa1 prod1)
PORTS=(8401 8402 8403)   # app-dev1, app-qa1, app-prod1 in compose.yml
DIGEST_REF=""            # <repo>@sha256:...: what every environment deploys (build_and_push)
IDS=()                   # the image id each environment ran (deploy_env)
BUILDS=()                # the build time each environment's app reports (deploy_env)
ROWS=()                  # the environments table (deploy_env)

# ---------------------------------------------------------------------------------------------------- helpers

# scan_dump <image>: the config files bundled in the image's /app/app.jar, their contents, and the image's env vars
scan_dump() {
  local dir cid
  dir=$(mktemp -d)
  cid=$(docker create "$1")
  docker cp -q "$cid:/app/app.jar" "$dir/app.jar"
  docker rm "$cid" >/dev/null
  # (unzip exits non-zero when a pattern matches nothing, e.g. no *.yaml files; that's fine here)
  echo "### config files bundled in /app/app.jar"
  { unzip -l "$dir/app.jar" '*.yml' '*.yaml' '*.properties' 2>/dev/null || true; } | awk 'NR>3 && $4 != "" && $4 != "Name" {print $4}'
  echo; echo "### their contents"; unzip -p "$dir/app.jar" '*.yml' '*.yaml' '*.properties' 2>/dev/null || true
  echo; echo "### image env vars"; docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1"
  rm -rf "$dir"
}

# count_distinct <values...>: how many different values
count_distinct() { printf '%s\n' "$@" | sort -u | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------------------------------- steps

build_and_push() {
  step "1. Build once, push to the registry"
  docker compose up -d --wait registry >/dev/null 2>&1 || docker compose up -d registry >/dev/null
  docker build -q --build-arg REVISION="$TAG" --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -t "$REPO:$TAG" . >/dev/null
  docker push -q "$REPO:$TAG" >/dev/null
  DIGEST_REF=$(docker image inspect -f '{{index .RepoDigests 0}}' "$REPO:$TAG")
  report_image "$REPO:$TAG"
  expect promoted-digest "" "$DIGEST_REF"
  docker image inspect -f '{{range $k, $v := .Config.Labels}}{{if or (eq $k "org.opencontainers.image.revision") (eq $k "org.opencontainers.image.created")}}    label {{$k}}={{$v}}{{"\n"}}{{end}}{{end}}' "$REPO:$TAG"
  # Drop the local tag: every environment must pull the digest from the registry.
  docker image rm "$REPO:$TAG" >/dev/null 2>&1 || true
  export IMAGE_REF=$DIGEST_REF   # compose.yml deploys ${IMAGE_REF}
}

scan_image() {
  step "2. Scan the image for environment-specific settings"
  docker pull -q "$DIGEST_REF" >/dev/null
  scan_dump "$DIGEST_REF" | save_evidence image-scan.txt
  local marker hits
  for marker in dev1 qa1 prod1 dev-db.internal qa-db.internal prod-db.internal oncall@example.com; do
    hits=$( (sed -n '/^### config files bundled/,$p' "$RAW/image-scan.txt" | grep -v '^###' | grep -c -- "$marker") || true)
    expect scan "'${marker}'" "${hits:-0}" "" image-scan.txt
  done
}

promote() {
  step "3. Promote: dev1 -> qa1 -> prod1"
  local i
  for i in "${!ENVS[@]}"; do deploy_env "${ENVS[$i]}" "${PORTS[$i]}"; done
}

# deploy_env <env> <port>: deploy the digest as <env>, check it got that environment's settings and used the
# AOT cache. Adds to IDS, BUILDS and ROWS.
deploy_env() {
  local env=$1 port=$2
  docker compose up -d --force-recreate "app-${env}" >/dev/null 2>&1
  local ok=yes
  wait_for_http "http://localhost:${port}/info" 60 || ok=no
  docker compose logs --no-log-prefix "app-${env}" 2>&1 | save_evidence "${env}.startup.log"
  expect started "$env" "$ok" "" "${env}.startup.log"
  [[ "$ok" == yes ]] || return 0

  local info container flags short
  info=$(curl -fs "http://localhost:${port}/info")
  jq . <<<"$info" | save_evidence "${env}.info.json"
  aot_usage "${env}.aot-cache.txt" docker compose run --rm --no-deps -T --entrypoint sh "app-${env}" -c
  container=$(docker compose ps -q "app-${env}")
  IDS+=("$(docker inspect -f '{{.Image}}' "$container")")
  BUILDS+=("$(jq -r '.build.time' <<<"$info")")
  note "  ${env}: deployed $(docker inspect -f '{{.Config.Image}}' "$container")"
  expect digest "$env" "$(docker inspect -f '{{.Config.Image}}' "$container")" "$DIGEST_REF"
  expect profiles "$env" "$(jq -r '.activeProfiles | join(",")' <<<"$info")" "${env%%[0-9]*},${env}" "${env}.info.json"
  expect message "$env" "$(jq -r '.values["app.message"]' <<<"$info")" "Hello from ${env}" "${env}.info.json"
  expect cache "$env" "$AOT_VERDICT" "" "${env}.aot-cache.txt"
  flags=$(jq -r '.jvm.inputArguments | map(select(startswith("-Xmx") or startswith("-XX:MaxRAM"))) | join(" ")' <<<"$info")
  short=${DIGEST_REF##*@sha256:}
  ROWS+=("$(printf '%-6s %-14s %-48s %-26s %s' "$env" "${short:0:12}" "$(jq -r '.values["app.db-url"]' <<<"$info")" "$flags" "${CACHED}/${TOTAL}")")
}

compare_envs() {
  step "4. Across environments"
  expect across.images "" "$(count_distinct "${IDS[@]}")"
  expect across.builds "" "$(count_distinct "${BUILDS[@]}")"
  printf '\n  %s%-6s %-14s %-48s %-26s %s%s\n' "$C_BOLD" "env" "digest" "app.db-url" "heap flags" "JDK AOT cache" "$C_RESET"
  printf '  %s\n' "${ROWS[@]}"
}

# ---------------------------------------------------------------------------------------------------- main

report_init 04-one-image
build_and_push
scan_image
promote
compare_envs
finish
