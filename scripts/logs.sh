#!/usr/bin/env bash
# Follow one container's logs. With a container name, follows it directly; without one, pick from
# every running container of every example (all named aot-*) with fzf. The preview shows recent lines.
#
#   1. Pick a container (fzf), unless one was given
#   2. Follow its logs
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail

# ---------------------------------------------------------------------------------------------------- steps

# pick_container: prints the chosen container's name; nothing when cancelled
pick_container() {
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf)" >&2; exit 1; }
  local running
  running=$(docker ps --filter 'name=^aot-' --format '{{.Names}}\t{{.Status}}' | sort)
  [[ -n "$running" ]] || { echo "No aot-* containers running. Start an example first (make help)." >&2; exit 1; }
  fzf --delimiter='\t' --with-nth=1,2 --prompt='logs> ' \
      --header='Select a container (Enter = follow logs, Esc = cancel)' \
      --preview='docker logs --tail 40 {1} 2>&1' --preview-window='down,60%,follow' <<<"$running" \
    | cut -f1 || true
}

# ---------------------------------------------------------------------------------------------------- main

container=${1:-}
if [[ -z "$container" ]]; then container=$(pick_container); fi
[[ -n "$container" ]] || exit 0
exec docker logs -f "$container"
