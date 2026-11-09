#!/usr/bin/env bash
# Example 02: one image (Spring AOT on), profiles decided at startup from APP_ENV + APP_ENV_INDEX.
# Shows that profile-specific VALUES and a @Bean-method choice follow the environment, while
# @Profile / @ConditionalOnProperty beans are frozen at build time. Then the same prod run with AOT off.
# Instances and expected results: expectations.json. Writes reports/02-dynamic-profiles/<run>/report.md.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=profiles-app:1.0.0
cleanup() { docker rm -f $(docker ps -aq --filter 'name=^aot-02-') >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

report_init 02-dynamic-profiles
report_image "$IMAGE"

instances() { jq -r '.instances[] | [.name, .env, .index, .spa, .aot, (.port|tostring), .profiles, .db, .notifier, .pitfall] | join("\u001f")' expectations.json; }

step "Starting six instances of ${IMAGE}"
while IFS=$'\x1f' read -r name env idx spa aot port _; do
  opts=(-d --name "aot-02-profiles-${port}" -p "${port}:8080" -e "APP_ENV=${env}" -e "APP_ENV_INDEX=${idx}")
  [[ -n "$spa" ]] && opts+=(-e "SPRING_PROFILES_ACTIVE=${spa}")
  if [[ "$aot" == "off" ]]; then
    # Same image, but without the AOT-generated bean definitions: Spring evaluates @Profile etc. at runtime.
    docker run "${opts[@]}" --entrypoint java "$IMAGE" -jar /app/app.jar >/dev/null
  else
    docker run "${opts[@]}" "$IMAGE" >/dev/null
  fi
  note "  ${name}: APP_ENV=${env} APP_ENV_INDEX=${idx}${spa:+ SPRING_PROFILES_ACTIVE=${spa}} (Spring AOT ${aot}) -> :${port}"
done < <(instances)

rows=()
while IFS=$'\x1f' read -r name env idx spa aot port exp_profiles exp_db exp_notifier pitfall; do
  step "${name}"
  slug=$(tr ' ,+' '---' <<<"$name" | tr -s '-')
  ok=yes; wait_for_http "http://localhost:${port}/info/profiles" 60 || ok=no
  docker logs "aot-02-profiles-${port}" 2>&1 | save_evidence "${slug}.startup.log"
  expect started "$name" "$ok" "" "${slug}.startup.log"
  [[ "$ok" == yes ]] || continue
  info=$(curl -fs "http://localhost:${port}/info/profiles")
  jq . <<<"$info" | save_evidence "${slug}.info.json"
  profiles=$(jq -r '.activeProfiles | join(",")' <<<"$info")
  db=$(jq -r '.values["app.db-name"]' <<<"$info")
  notifier=$(jq -r '.notifier' <<<"$info")
  p1=$(jq -r '.pitfall.profileProdBeanExists' <<<"$info")
  p2=$(jq -r '.pitfall.conditionalOnPropertyBeanExists' <<<"$info")
  note "  app.message: $(jq -r '.values["app.message"]' <<<"$info")"
  expect aot "$name" "$(jq -r '.springAotGeneratedCode' <<<"$info")" "$([[ $aot == on ]] && echo true || echo false)" "${slug}.info.json"
  expect profiles "$name" "$profiles" "$exp_profiles" "${slug}.info.json"
  expect db-name "$name" "$db" "$exp_db" "${slug}.info.json"
  expect notifier "$name" "$notifier" "$exp_notifier" "${slug}.info.json"
  expect "pitfall.profile.${pitfall}" "$name" "$p1" "" "${slug}.info.json"
  expect "pitfall.conditional.${pitfall}" "$name" "$p2" "" "${slug}.info.json"
  expect startup-time "$name" "$(started_in "aot-02-profiles-${port}")s"
  rows+=("$(printf '%-22s %-4s %-17s %-13s %-14s %-9s %s' "$name" "$aot" "$profiles" "$db" "$notifier" "$p1" "$p2")")
done < <(instances)

step "Summary"
printf '  %s%-22s %-4s %-17s %-13s %-14s %-9s %s%s\n' "$C_BOLD" "instance" "AOT" "profiles" "app.db-name" "notifier" "@Profile" "@ConditionalOnProperty" "$C_RESET"
printf '  %s\n' "${rows[@]}"
finish
