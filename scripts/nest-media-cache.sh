#!/usr/bin/env bash
set -euo pipefail

uid="$(id -u)"
: "${XDG_RUNTIME_DIR:=/run/user/$uid}"
export XDG_RUNTIME_DIR
: "${DBUS_SESSION_BUS_ADDRESS:=unix:path=$XDG_RUNTIME_DIR/bus}"
export DBUS_SESSION_BUS_ADDRESS

cache_prefix="/tmp/nest-media-"
retries="${NEST_MEDIA_QUERY_RETRIES:-1}"
selected_player_ready=0
selected_player_value=""

cache_path() {
  printf '%s%s.cache' "$cache_prefix" "$1"
}

first_line() {
  sed -n '1p'
}

selected_player() {
  local attempt player players
  if [[ "$selected_player_ready" == 1 ]]; then
    printf '%s\n' "$selected_player_value"
    return
  fi

  for ((attempt = 0; attempt < retries; attempt++)); do
    players="$(playerctl -l 2>/dev/null || true)"
    if [[ -n "$players" ]]; then
      while IFS= read -r player; do
        if [[ "$(playerctl -p "$player" status 2>/dev/null || true)" == "Playing" ]]; then
          selected_player_value="$player"
          selected_player_ready=1
          printf '%s\n' "$selected_player_value"
          return
        fi
      done <<< "$players"
      selected_player_value="$(printf '%s\n' "$players" | first_line)"
      selected_player_ready=1
      printf '%s\n' "$selected_player_value"
      return
    fi
    sleep 0.1
  done
  selected_player_ready=1
}

playerctl_selected() {
  local player
  player="$(selected_player)"
  if [[ -n "$player" ]]; then
    playerctl -p "$player" "$@"
  else
    playerctl "$@"
  fi
}

cached_value() {
  local cache_name="$1"
  local fallback="$2"
  shift 2

  local value cache
  cache="$(cache_path "$cache_name")"
  value="$(playerctl_selected "$@" 2>/dev/null | first_line || true)"
  if [[ -n "$value" ]]; then
    printf '%s' "$value" > "$cache"
    printf '%s' "$value"
  elif [[ -f "$cache" ]]; then
    cat "$cache"
  else
    printf '%s' "$fallback"
  fi
}

cache_value() {
  local cache_name="$1"
  local fallback="$2"
  local cache
  cache="$(cache_path "$cache_name")"
  if [[ -f "$cache" ]]; then
    cat "$cache"
  else
    printf '%s' "$fallback"
  fi
}

artwork() {
  local url cache key bmp tmp src raw path cached_mtime source_mtime refresh
  cache="$(cache_path art)"
  url="$(playerctl_selected metadata mpris:artUrl 2>/dev/null | first_line || true)"

  if [[ -z "$url" ]]; then
    if [[ -f "$cache" ]]; then
      path="$(cat "$cache")"
      [[ -f "$path" ]] && printf '%s' "$path"
    fi
    return
  fi

  key="$(printf '%s' "$url" | cksum | awk '{print $1}')"
  bmp="/tmp/nest-media-art-$key.bmp"
  tmp="/tmp/nest-media-art-$key.tmp.bmp"
  src="/tmp/nest-media-art-$key.src"

  case "$url" in
    file://*)
      raw="${url#file://}"
      path="$(printf '%s' "$raw" | sed 's/%20/ /g;s/%23/#/g;s/%25/%/g')"
      if [[ -f "$bmp" ]]; then
        cached_mtime="$(stat -c %Y "$bmp" 2>/dev/null || printf 0)"
        source_mtime="$(stat -c %Y "$path" 2>/dev/null || printf 0)"
        if [[ "$cached_mtime" -ge "$source_mtime" ]]; then
          printf '%s' "$bmp" | tee "$cache"
          return
        fi
      fi
      if magick "$path" "$tmp" >/dev/null 2>&1 && mv "$tmp" "$bmp"; then
        printf '%s' "$bmp" | tee "$cache"
      elif [[ -f "$bmp" ]]; then
        printf '%s' "$bmp" | tee "$cache"
      fi
      ;;
    http://*|https://*)
      refresh=0
      if [[ ! -f "$bmp" ]]; then
        refresh=1
      elif [[ -f "$src" && "$src" -nt "$bmp" ]]; then
        refresh=1
      fi
      if [[ "$refresh" == 1 ]]; then
        curl -L -s --max-time 10 -o "$src" "$url" >/dev/null 2>&1 &&
          magick "$src" "$tmp" >/dev/null 2>&1 &&
          mv "$tmp" "$bmp"
      fi
      [[ -f "$bmp" ]] && printf '%s' "$bmp" | tee "$cache"
      ;;
  esac
  rm -f "$tmp"
}

prime() {
  export NEST_MEDIA_QUERY_RETRIES="${NEST_MEDIA_PRIME_RETRIES:-15}"
  retries="$NEST_MEDIA_QUERY_RETRIES"
  cached_value bar-title "No media" metadata --format '{{artist}} - {{title}}' >/dev/null || true
  cached_value bar-status "Stopped" status >/dev/null || true
  artwork >/dev/null || true
}

case "${1:-}" in
  cached)
    shift
    cached_value "$@"
    ;;
  cache)
    shift
    cache_value "$@"
    ;;
  artwork)
    artwork
    ;;
  art-cache)
    cache_value art ""
    ;;
  playerctl)
    shift
    playerctl_selected "$@"
    ;;
  prime)
    prime
    ;;
  *)
    echo "usage: $0 {cached|cache|artwork|art-cache|playerctl|prime} ..." >&2
    exit 64
    ;;
esac
