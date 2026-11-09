#!/usr/bin/env bash
# Example 02: one image (Spring AOT on), profiles decided at startup from APP_ENV + APP_ENV_INDEX.
# Shows that profile-specific VALUES and a @Bean-method choice follow the environment, while
# @Profile / @ConditionalOnProperty beans are frozen at build time. Then the same prod run with AOT off.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=profiles-app:1.0.0

#          name           | APP_ENV | INDEX | SPRING_PROFILES_ACTIVE | AOT | port | profiles          | db-name      | notifier       | pitfall beans
RUNS=(
  "dev1                   | dev     | 1     |                        | on  | 8201 | dev,dev1          | orders_dev1  | LogNotifier    | false"
  "dev2                   | dev     | 2     |                        | on  | 8202 | dev,dev2          | orders_dev2  | LogNotifier    | false"
  "qa1                    | qa      | 1     |                        | on  | 8203 | qa,qa1            | orders_qa1   | EmailNotifier  | false"
  "prod1                  | prod    | 1     |                        | on  | 8204 | prod,prod1        | orders_prod1 | PagerNotifier  | false"
  "prod1 + debug profile  | prod    | 1     | debug                  | on  | 8205 | prod,prod1,debug  | orders_prod1 | PagerNotifier  | false"
  "prod1, Spring AOT OFF  | prod    | 1     |                        | off | 8206 | prod,prod1        | orders_prod1 | PagerNotifier  | true"
)

trim() { sed -e 's/^ *//' -e 's/ *$//' <<<"$1"; }
cleanup() { docker rm -f $(docker ps -aq --filter 'name=^aot-02-') >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "Starting six instances of ${IMAGE}"
for r in "${RUNS[@]}"; do
  IFS='|' read -r name env idx spa aot port _ <<<"$r"
  name=$(trim "$name"); env=$(trim "$env"); idx=$(trim "$idx"); spa=$(trim "$spa"); aot=$(trim "$aot"); port=$(trim "$port")
  opts=(-d --name "aot-02-profiles-${port}" -p "${port}:8080" -e "APP_ENV=${env}" -e "APP_ENV_INDEX=${idx}")
  [[ -n "$spa" ]] && opts+=(-e "SPRING_PROFILES_ACTIVE=${spa}")
  if [[ "$aot" == "off" ]]; then
    # Same image, but without the AOT-generated bean definitions: Spring evaluates @Profile etc. at runtime.
    docker run "${opts[@]}" --entrypoint java "$IMAGE" -jar /app/app.jar >/dev/null
  else
    docker run "${opts[@]}" "$IMAGE" >/dev/null
  fi
  note "  ${name}: APP_ENV=${env} APP_ENV_INDEX=${idx}${spa:+ SPRING_PROFILES_ACTIVE=${spa}} (Spring AOT ${aot}) -> :${port}"
done

rows=()
for r in "${RUNS[@]}"; do
  IFS='|' read -r name env idx spa aot port exp_profiles exp_db exp_notifier exp_pitfall <<<"$r"
  name=$(trim "$name"); aot=$(trim "$aot"); port=$(trim "$port")
  exp_profiles=$(trim "$exp_profiles"); exp_db=$(trim "$exp_db"); exp_notifier=$(trim "$exp_notifier"); exp_pitfall=$(trim "$exp_pitfall")
  step "${name}"
  if ! wait_for_http "http://localhost:${port}/info/profiles" 60; then fail "did not start"; continue; fi
  info=$(curl -fs "http://localhost:${port}/info/profiles")
  profiles=$(jq -r '.activeProfiles | join(",")' <<<"$info")
  db=$(jq -r '.values["app.db-name"]' <<<"$info")
  message=$(jq -r '.values["app.message"]' <<<"$info")
  notifier=$(jq -r '.notifier' <<<"$info")
  p1=$(jq -r '.pitfall.profileProdBeanExists' <<<"$info")
  p2=$(jq -r '.pitfall.conditionalOnPropertyBeanExists' <<<"$info")
  note "  app.message: ${message}"
  [[ "$(jq -r '.values["app.extra"]' <<<"$info")" != "<unset>" ]] && note "  app.extra:   $(jq -r '.values["app.extra"]' <<<"$info")"
  check "Spring AOT generated code" "$(jq -r '.springAotGeneratedCode' <<<"$info")" "$([[ $aot == on ]] && echo true || echo false)"
  check "profiles (decided at startup)" "$profiles" "$exp_profiles"
  check "app.db-name (from application-<env>.yml)" "$db" "$exp_db"
  check "notifier (@Bean method, decided at startup)" "$notifier" "$exp_notifier"
  check "@Profile(\"prod\") bean exists" "$p1" "$exp_pitfall"
  check "@ConditionalOnProperty bean exists" "$p2" "$exp_pitfall"
  rows+=("$(printf '%-22s %-4s %-17s %-13s %-14s %-9s %s' "$name" "$aot" "$profiles" "$db" "$notifier" "$p1" "$p2")")
done

step "Summary"
printf '  %s%-22s %-4s %-17s %-13s %-14s %-9s %s%s\n' "$C_BOLD" "instance" "AOT" "profiles" "app.db-name" "notifier" "@Profile" "@ConditionalOnProperty" "$C_RESET"
printf '  %s\n' "${rows[@]}"
note "  Values and the @Bean-method choice follow each environment. @Profile/@ConditionalOnProperty beans"
note "  only appear with AOT off: with AOT on they were decided at build time, when no profile was active."
finish
