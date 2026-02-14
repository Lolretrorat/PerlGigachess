#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MIGRATION_ROOT="$REPO_ROOT/engineMigration"
GAME_URL_LOG="$REPO_ROOT/data/lichess_game_urls.log"
GAMES_EXPORT_PGN="$REPO_ROOT/data/lichess_games_export.pgn"

usage() {
  cat <<'USAGE'
Usage:
  scripts/apply_engine_migration.sh list
  scripts/apply_engine_migration.sh check <migration_name_or_fragment>
  scripts/apply_engine_migration.sh apply <migration_name_or_fragment> [--dry-run]
  scripts/apply_engine_migration.sh reverse <migration_name_or_fragment> [--dry-run]

Notes:
  - Migrations are read from engineMigration/VYYYYMMDDHHMMSS__description/
  - Patch file is detected as *_engine_patch.diff (typically 001_engine_patch.diff)
  - Name matching supports exact directory names or unique substring matches
USAGE
}

list_migrations() {
  [[ -d "$MIGRATION_ROOT" ]] || return 0
  find "$MIGRATION_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'V*__*' -printf '%f\n' | sort
}

resolve_migration_dir() {
  local query="$1"
  local candidate="$MIGRATION_ROOT/$query"
  if [[ -d "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  mapfile -t matches < <(list_migrations | grep -F "$query" || true)
  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "No migration matched: $query" >&2
    return 1
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Migration query is ambiguous: $query" >&2
    printf 'Matches:\n' >&2
    printf '  %s\n' "${matches[@]}" >&2
    return 1
  fi

  printf '%s/%s\n' "$MIGRATION_ROOT" "${matches[0]}"
}

find_patch_file() {
  local migration_dir="$1"
  local patch_file
  patch_file="$(find "$migration_dir" -mindepth 1 -maxdepth 1 -type f -name '*_engine_patch.diff' | sort | head -n 1 || true)"
  if [[ -z "$patch_file" ]]; then
    echo "No *_engine_patch.diff file found in $migration_dir" >&2
    return 1
  fi
  printf '%s\n' "$patch_file"
}

normalize_patch_paths() {
  local in_patch="$1"
  local out_patch="$2"
  sed \
    -e "s|^--- $REPO_ROOT/|--- a/|" \
    -e "s|^+++ $REPO_ROOT/|+++ b/|" \
    "$in_patch" > "$out_patch"
}

patch_state() {
  local patch_file="$1"
  if git -C "$REPO_ROOT" apply --check "$patch_file" >/dev/null 2>&1; then
    printf 'can_apply\n'
    return 0
  fi
  if git -C "$REPO_ROOT" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    printf 'already_applied\n'
    return 0
  fi
  printf 'conflict\n'
}

reset_ingest_inputs() {
  mkdir -p "$REPO_ROOT/data"
  : > "$GAME_URL_LOG"
  : > "$GAMES_EXPORT_PGN"
  echo "Cleared ingestion inputs:"
  echo "  $GAME_URL_LOG"
  echo "  $GAMES_EXPORT_PGN"
}

run_apply() {
  local patch_file="$1"
  local dry_run="$2"
  local state
  state="$(patch_state "$patch_file")"

  case "$state" in
    can_apply)
      if [[ "$dry_run" == "1" ]]; then
        echo "Dry run OK: patch can be applied."
        echo "Dry run: would clear ingestion inputs."
      else
        git -C "$REPO_ROOT" apply "$patch_file"
        echo "Applied migration patch."
        reset_ingest_inputs
      fi
      ;;
    already_applied)
      if [[ "$dry_run" == "1" ]]; then
        echo "Patch is already applied; nothing to do."
        echo "Dry run: would clear ingestion inputs."
      else
        echo "Patch is already applied; refreshing ingestion inputs."
        reset_ingest_inputs
      fi
      ;;
    conflict)
      echo "Patch cannot be applied cleanly (conflict). Check current Engine.pm state." >&2
      return 1
      ;;
  esac
}

run_reverse() {
  local patch_file="$1"
  local dry_run="$2"
  local state
  state="$(patch_state "$patch_file")"

  case "$state" in
    already_applied)
      if [[ "$dry_run" == "1" ]]; then
        echo "Dry run OK: patch can be reversed."
      else
        git -C "$REPO_ROOT" apply --reverse "$patch_file"
        echo "Reversed migration patch."
      fi
      ;;
    can_apply)
      echo "Patch is not currently applied; nothing to reverse."
      ;;
    conflict)
      echo "Patch cannot be cleanly reversed (conflict)." >&2
      return 1
      ;;
  esac
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

command="$1"
shift || true

case "$command" in
  -h|--help|help)
    usage
    ;;
  list)
    list_migrations
    ;;
  check|apply|reverse)
    if [[ $# -lt 1 ]]; then
      echo "Missing migration name." >&2
      usage
      exit 1
    fi
    migration_query="$1"
    shift || true

    dry_run=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dry-run)
          dry_run=1
          shift
          ;;
        *)
          echo "Unknown option: $1" >&2
          usage
          exit 1
          ;;
      esac
    done

    migration_dir="$(resolve_migration_dir "$migration_query")"
    raw_patch="$(find_patch_file "$migration_dir")"
    tmp_patch="$(mktemp)"
    trap 'rm -f "$tmp_patch"' EXIT
    normalize_patch_paths "$raw_patch" "$tmp_patch"

    echo "Migration: $(basename "$migration_dir")"
    echo "Patch: $raw_patch"

    if [[ "$command" == "check" ]]; then
      state="$(patch_state "$tmp_patch")"
      case "$state" in
        can_apply) echo "Status: not applied (can apply cleanly)." ;;
        already_applied) echo "Status: already applied." ;;
        conflict) echo "Status: conflict (cannot apply/reverse cleanly)." ;;
      esac
    elif [[ "$command" == "apply" ]]; then
      run_apply "$tmp_patch" "$dry_run"
    else
      run_reverse "$tmp_patch" "$dry_run"
    fi
    ;;
  *)
    echo "Unknown command: $command" >&2
    usage
    exit 1
    ;;
esac
