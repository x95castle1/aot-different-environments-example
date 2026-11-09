#!/usr/bin/env bash
# Follow one container's logs. With a container name, follows it directly; without one, pick from
# every running container of every example (all named aot-*) with fzf. The preview shows recent lines.
set -euo pipefail

container=${1:-}

if [[ -z "$container" ]]; then
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf)"; exit 1; }
  running=$(docker ps --filter 'name=^aot-' --format '{{.Names}}\t{{.Status}}' | sort)
  [[ -n "$running" ]] || { echo "No aot-* containers running. Start an example first (make help)."; exit 1; }
  container=$(fzf --delimiter='\t' --with-nth=1,2 --prompt='logs> ' \
      --header='Select a container (Enter = follow logs, Esc = cancel)' \
      --preview='docker logs --tail 40 {1} 2>&1' --preview-window='down,60%,follow' <<<"$running" \
    | cut -f1) || exit 0
  [[ -n "$container" ]] || exit 0
fi

exec docker logs -f "$container"
