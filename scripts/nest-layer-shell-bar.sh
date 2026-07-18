#!/usr/bin/env bash
set -euo pipefail

repo_dir="/home/dneumann/.workspace/nest"
log_file="${NEST_LAYER_SHELL_BAR_LOG_FILE:-/tmp/nest-layer-shell-bar.log}"

kill_existing_bar() {
  if command -v swaymsg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local pids
    pids="$(swaymsg -t get_tree 2>/dev/null | jq -r '
      def children: .nodes[]?, .floating_nodes[]?;
      [recurse(children)
       | select(.app_id? == "io.highpoint.alatar"
                or .name? == "alatar"
                or .name? == "Nest Layer Shell Bar"
                or .app_id? == "nest-layer-shell-bar")
       | .pid?]
      | map(select(. != null))
      | unique
      | .[]?')"
    if [[ -n "${pids:-}" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
      done <<< "$pids"
    fi
  fi

  pkill -f 'io.highpoint.alatar|alatar:main|swank:create-server|slynk:create-server' 2>/dev/null || true
  pkill -f '/home/dneumann/.workspace/nest/nest run example/layerShellBar' 2>/dev/null || true
  pkill -f './nest run example/layerShellBar' 2>/dev/null || true
}

kill_existing_bar

cd "$repo_dir"
exec ./nest run example/layerShellBar >>"$log_file" 2>&1
