#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DEFAULT_LIST_FILE="$REPO_ROOT/data/lichess_game_urls.log"
DEFAULT_OUT_FILE="$REPO_ROOT/data/lichess_games_export.pgn"

LIST_FILE="${1:-$DEFAULT_LIST_FILE}"
OUT_FILE="${2:-$DEFAULT_OUT_FILE}"
APPEND_MODE="${APPEND_MODE:-0}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/fetch_own_lichess_pgns.sh [list_file] [out_file]

Defaults:
  list_file: <repo>/data/lichess_game_urls.log
  out_file:  <repo>/data/lichess_games_export.pgn

Environment:
  APPEND_MODE=1   Append to out_file instead of truncating it first
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$LIST_FILE" ]]; then
  echo "List file not found: $LIST_FILE" >&2
  exit 1
fi

out_dir="$(dirname "$OUT_FILE")"
mkdir -p "$out_dir"

if [[ "$APPEND_MODE" != "1" ]]; then
  : > "$OUT_FILE"
fi

extract_game_id() {
  local raw="$1"
  local line="${raw#"${raw%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"

  [[ -z "$line" ]] && return 1
  [[ "$line" =~ ^# ]] && return 1

  # Accept raw game id, e.g. "abcdefgh".
  if [[ "$line" =~ ^([A-Za-z0-9]{8})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  # Accept full lichess game URL, e.g. https://lichess.org/abcdefgh or with suffix/query.
  if [[ "$line" =~ ^https?://lichess\.org/([A-Za-z0-9]{8})([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  # Accept bare path-style entries, e.g. /abcdefgh/black.
  if [[ "$line" =~ ^/?([A-Za-z0-9]{8})([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

declare -A seen=()
total=0
fetched=0
skipped=0
failed=0

while IFS= read -r line || [[ -n "$line" ]]; do
  total=$((total + 1))
  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [[ -z "$trimmed" || "$trimmed" =~ ^# ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  game_id=""
  if ! game_id="$(extract_game_id "$line")"; then
    skipped=$((skipped + 1))
    echo "Skipping unrecognized line: $line" >&2
    continue
  fi

  if [[ -n "${seen[$game_id]:-}" ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  seen[$game_id]=1

  url="https://lichess.org/game/export/$game_id"
  if curl -fsSL "$url" >> "$OUT_FILE"; then
    printf '\n\n' >> "$OUT_FILE"
    fetched=$((fetched + 1))
    echo "Fetched $game_id" >&2
  else
    failed=$((failed + 1))
    echo "Failed $game_id ($url)" >&2
  fi
done < "$LIST_FILE"

echo "Done: total=$total fetched=$fetched skipped=$skipped failed=$failed out=$OUT_FILE" >&2
