#!/usr/bin/env bash
set -euo pipefail

repo_dir="/home/dneumann/.workspace/nest"
log_file="${NEST_LAYER_SHELL_BAR_LOG_FILE:-/tmp/nest-layer-shell-bar.log}"

kill_existing_bar() {
  local pids=()

  if command -v swaymsg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local sway_pids
    sway_pids="$(swaymsg -t get_tree 2>/dev/null | jq -r '
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
    if [[ -n "${sway_pids:-}" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
      done <<< "$sway_pids"
    fi
  fi

  if command -v pgrep >/dev/null 2>&1; then
    local match_pids
    match_pids="$(pgrep -f 'io.highpoint.alatar|alatar:main|swank:create-server|slynk:create-server|nest run .*example/layerShellBar' 2>/dev/null || true)"
    if [[ -n "${match_pids:-}" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" && "$pid" != "$$" ]] && pids+=("$pid")
      done <<< "$match_pids"
    fi
  fi

  if ((${#pids[@]} == 0)); then
    return
  fi

  mapfile -t pids < <(printf '%s\n' "${pids[@]}" | awk '!seen[$0]++')
  kill "${pids[@]}" 2>/dev/null || true

  local deadline=$((SECONDS + 2))
  local alive=()
  while ((SECONDS < deadline)); do
    alive=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        alive+=("$pid")
      fi
    done
    ((${#alive[@]} == 0)) && return
    sleep 0.05
  done

  if ((${#alive[@]} > 0)); then
    kill -KILL "${alive[@]}" 2>/dev/null || true
  fi
}

kill_existing_bar

cd "$repo_dir"
exec ./nest run example/layerShellBar >>"$log_file" 2>&1
