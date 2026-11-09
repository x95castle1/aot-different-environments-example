#!/usr/bin/env bash
# Example 04: build once, promote the exact same image (by digest) through dev1 -> qa1 -> prod1.
#   1. Build once and push to a local registry; from here on only the digest is used.
#   2. Scan the image: no environment names, hosts or settings inside.
#   3. Promote: deploy the digest to each environment with that environment's env file + config dir.
#   4. Check every environment runs the same build, with its own settings, and uses the AOT cache.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

REPO=localhost:5001/one-image-app
TAG=${REVISION:-dev}
ENVS=(dev1 qa1 prod1)
PORTS=(8401 8402 8403)

step "1. Build once, push to the registry"
docker compose up -d --wait registry >/dev/null 2>&1 || docker compose up -d registry >/dev/null
docker build -q -f "$ROOT/docker/app.Dockerfile" \
  --build-arg MODULE=examples/04-one-image/app --build-arg APP=one-image-app \
  --build-arg REVISION="$TAG" --build-arg CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -t "$REPO:$TAG" "$ROOT" >/dev/null
docker push -q "$REPO:$TAG" >/dev/null
DIGEST_REF=$(docker image inspect -f '{{index .RepoDigests 0}}' "$REPO:$TAG")
note "  built ${REPO}:${TAG}"
note "  promoted artifact: ${DIGEST_REF}"
docker image inspect -f '{{range $k, $v := .Config.Labels}}{{if or (eq $k "org.opencontainers.image.revision") (eq $k "org.opencontainers.image.created") (eq $k "org.opencontainers.image.title")}}    label {{$k}}={{$v}}{{"\n"}}{{end}}{{end}}' "$REPO:$TAG"
# Drop the local tag: every environment must pull the digest from the registry.
docker image rm "$REPO:$TAG" >/dev/null 2>&1 || true
export IMAGE_REF=$DIGEST_REF

step "2. Scan the image for environment-specific settings"
docker pull -q "$DIGEST_REF" >/dev/null
scan_dir=$(mktemp -d)
cid=$(docker create "$DIGEST_REF")
docker cp -q "$cid:/app/app.jar" "$scan_dir/app.jar"
docker rm "$cid" >/dev/null
config_in_image=$(unzip -p "$scan_dir/app.jar" '*.yml' '*.yaml' '*.properties' 2>/dev/null || true)
image_env=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DIGEST_REF")
rm -rf "$scan_dir"
for marker in dev1 qa1 prod1 dev-db.internal qa-db.internal prod-db.internal oncall@example.com; do
  hits=$( (grep -c -- "$marker" <<<"$config_in_image$image_env") || true)
  check "image contains '${marker}'" "${hits:-0}" "0"
done

step "3. Promote: dev1 -> qa1 -> prod1"
ids=(); builds=(); rows=()
for i in "${!ENVS[@]}"; do
  env=${ENVS[$i]}; port=${PORTS[$i]}
  docker compose up -d --force-recreate "app-${env}" >/dev/null 2>&1
  if ! wait_for_http "http://localhost:${port}/info" 60; then fail "${env} did not start"; continue; fi
  info=$(curl -fs "http://localhost:${port}/info")
  read -r cached total < <(docker compose run --rm --no-deps -T --entrypoint sh "app-${env}" -c "$AOT_USAGE_SCRIPT")
  ref=$(docker inspect -f '{{.Config.Image}}' "$(docker compose ps -q "app-${env}")")
  ids+=("$(docker inspect -f '{{.Image}}' "$(docker compose ps -q "app-${env}")")")
  builds+=("$(jq -r '.build.time' <<<"$info")")
  note "  ${env}: deployed ${ref}"
  check "${env} runs the promoted digest" "$ref" "$DIGEST_REF"
  check "${env} profiles" "$(jq -r '.activeProfiles | join(",")' <<<"$info")" "${env%%[0-9]*},${env}"
  check "${env} message (from envs/${env}/config)" "$(jq -r '.values["app.message"]' <<<"$info")" "Hello from ${env}"
  check "${env} AOT cache" "$(aot_verdict "$cached" "$total")" "USED"
  flags=$(jq -r '.jvm.inputArguments | map(select(startswith("-Xmx") or startswith("-XX:MaxRAM"))) | join(" ")' <<<"$info")
  short=${DIGEST_REF##*@sha256:}
  rows+=("$(printf '%-6s %-14s %-48s %-26s %s' "$env" "${short:0:12}" "$(jq -r '.values["app.db-url"]' <<<"$info")" "$flags" "${cached}/${total}")")
done

step "4. Across environments"
check "distinct images running" "$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')" "1"
check "distinct build times reported by the apps" "$(printf '%s\n' "${builds[@]}" | sort -u | wc -l | tr -d ' ')" "1"
printf '\n  %s%-6s %-14s %-48s %-26s %s%s\n' "$C_BOLD" "env" "digest" "app.db-url" "heap flags" "AOT cache" "$C_RESET"
printf '  %s\n' "${rows[@]}"
finish
