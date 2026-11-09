#!/usr/bin/env bash
# Follow one container's logs. With a service name, follows it directly;
# without one, pick from the running containers with fzf (preview shows recent lines).
set -euo pipefail
cd "$(dirname "$0")/.."

service=${1:-}

if [[ -z "$service" ]]; then
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf), or run: make logs ENV=dev1"; exit 1; }
  running=$(docker compose ps --format '{{.Service}}\t{{.Status}}')
  [[ -n "$running" ]] || { echo "No containers running. Start them with: make start"; exit 1; }
  service=$(sort <<<"$running" | fzf --delimiter='\t' --with-nth=1,2 --prompt='logs> ' \
      --header='Select a container (Enter = follow logs, Esc = cancel)' \
      --preview='docker compose logs --no-log-prefix --tail 40 {1}' --preview-window='down,60%,follow' \
    | cut -f1) || exit 0
  [[ -n "$service" ]] || exit 0
fi

exec docker compose logs -f "$service"
