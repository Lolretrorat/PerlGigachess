#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT_DIR/scripts"
SELF_NAME="$(basename "$0")"

usage() {
  cat <<'USAGE'
Usage:
  scripts/initialize_iteration.sh [init options]
  scripts/initialize_iteration.sh list
  scripts/initialize_iteration.sh run <script_name> [args...]

Commands:
  init (default)  Run iteration bootstrap sequence.
  list            List runnable scripts in scripts/.
  run             Run a specific script from scripts/.

Init options:
  --skip-env                  Skip environment setup (scripts/setup_env.sh)
  --with-syzygy-tools         Also run scripts/setup_syzygy_tools.sh
  --syzygy-tools-dir <dir>    Target dir for syzygy setup (default: /tmp/perlgigachess-syzygy)
  --lichess-url <url>         Lichess .pgn.zst URL for rebuild_from_lichess.sh
  --confirm-lichess-source <source_id>
                              Required with --lichess-url; must match URL basename
  --allow-duplicate-source    Allow ingesting a source already listed in manifest
  --tmp-dir <dir>             Temp dir passed to rebuild_from_lichess.sh (default: /tmp)
  --keep-download             Keep downloaded Lichess archive
  --skip-rebuild              Do not run rebuild_from_lichess.sh
  --skip-dry-run              Skip scripts/lichess_dry_run.pl
  --location-json <path>      Import external location table via update_location_modifiers.pl
  --rebuild-opt <arg>         Extra arg for rebuild_from_lichess.sh (repeatable)
  -h, --help                  Show this message

Examples:
  scripts/initialize_iteration.sh
  scripts/initialize_iteration.sh --with-syzygy-tools
  scripts/initialize_iteration.sh --lichess-url https://database.lichess.org/standard/lichess_db_standard_rated_2025-01.pgn.zst --confirm-lichess-source lichess_db_standard_rated_2025-01.pgn.zst
  scripts/initialize_iteration.sh run rebuild_from_lichess.sh --url https://database.lichess.org/standard/lichess_db_standard_rated_2025-01.pgn.zst
USAGE
}

list_scripts() {
  find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' \
    | sort \
    | grep -v "^${SELF_NAME}$" || true
}

run_script() {
  local script_name="$1"
  shift || true

  local script_path="$SCRIPT_DIR/$script_name"
  if [[ ! -f "$script_path" ]]; then
    echo "Unknown script: $script_name" >&2
    echo "Use 'scripts/$SELF_NAME list' to see available scripts." >&2
    exit 1
  fi
  if [[ "$script_name" == "$SELF_NAME" ]]; then
    echo "Refusing to execute wrapper recursively: $script_name" >&2
    exit 1
  fi

  echo "==> Running $script_name"
  case "$script_path" in
    *.sh) bash "$script_path" "$@" ;;
    *.pl) perl "$script_path" "$@" ;;
    *) "$script_path" "$@" ;;
  esac
}

init_iteration() {
  local run_env=1
  local run_syzygy_tools=0
  local run_rebuild=auto
  local run_dry_run=1

  local syzygy_tools_dir="/tmp/perlgigachess-syzygy"
  local lichess_url=""
  local confirm_lichess_source=""
  local allow_duplicate_source=0
  local tmp_dir="/tmp"
  local keep_download=0
  local location_json=""

  local -a rebuild_opts=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-env)
        run_env=0
        shift
        ;;
      --with-syzygy-tools)
        run_syzygy_tools=1
        shift
        ;;
      --syzygy-tools-dir)
        syzygy_tools_dir="${2:-}"
        shift 2
        ;;
      --lichess-url)
        lichess_url="${2:-}"
        shift 2
        ;;
      --confirm-lichess-source)
        confirm_lichess_source="${2:-}"
        shift 2
        ;;
      --allow-duplicate-source)
        allow_duplicate_source=1
        shift
        ;;
      --tmp-dir)
        tmp_dir="${2:-}"
        shift 2
        ;;
      --keep-download)
        keep_download=1
        shift
        ;;
      --skip-rebuild)
        run_rebuild=0
        shift
        ;;
      --skip-dry-run)
        run_dry_run=0
        shift
        ;;
      --location-json)
        location_json="${2:-}"
        shift 2
        ;;
      --rebuild-opt)
        rebuild_opts+=("${2:-}")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$run_rebuild" == "auto" ]]; then
    if [[ -n "$lichess_url" ]]; then
      run_rebuild=1
    else
      run_rebuild=0
    fi
  fi

  if [[ "$run_rebuild" -eq 1 && -z "$lichess_url" ]]; then
    echo "--lichess-url is required unless --skip-rebuild is set" >&2
    exit 1
  fi

  local expected_source_id=""
  if [[ "$run_rebuild" -eq 1 ]]; then
    expected_source_id="$(basename "${lichess_url%%\?*}")"
    if [[ -z "$confirm_lichess_source" ]]; then
      echo "--confirm-lichess-source is required for rebuilds (expected: $expected_source_id)" >&2
      exit 1
    fi
    if [[ "$confirm_lichess_source" != "$expected_source_id" ]]; then
      echo "--confirm-lichess-source mismatch: expected '$expected_source_id', got '$confirm_lichess_source'" >&2
      exit 1
    fi
  fi

  if [[ "$run_env" -eq 1 ]]; then
    run_script setup_env.sh
  else
    echo "==> Skipping setup_env.sh"
  fi

  if [[ "$run_syzygy_tools" -eq 1 ]]; then
    run_script setup_syzygy_tools.sh "$syzygy_tools_dir"
  else
    echo "==> Skipping setup_syzygy_tools.sh"
  fi

  if [[ "$run_rebuild" -eq 1 ]]; then
    local -a cmd_args=(
      --append
      --confirm-source "$confirm_lichess_source"
      --url "$lichess_url"
      --tmp-dir "$tmp_dir"
    )
    if [[ "$keep_download" -eq 1 ]]; then
      cmd_args+=(--keep-download)
    fi
    if [[ "$allow_duplicate_source" -eq 1 ]]; then
      cmd_args+=(--allow-duplicate-source)
    fi
    if [[ "${#rebuild_opts[@]}" -gt 0 ]]; then
      cmd_args+=("${rebuild_opts[@]}")
    fi
    run_script rebuild_from_lichess.sh "${cmd_args[@]}"
  else
    echo "==> Skipping rebuild_from_lichess.sh (no --lichess-url provided)"
  fi

  if [[ -n "$location_json" ]]; then
    run_script update_location_modifiers.pl "$location_json"
  else
    echo "==> Skipping update_location_modifiers.pl"
  fi

  if [[ "$run_dry_run" -eq 1 ]]; then
    run_script lichess_dry_run.pl
  else
    echo "==> Skipping lichess_dry_run.pl"
  fi

  echo "==> Iteration initialization complete"
}

main() {
  local command="init"
  if [[ $# -gt 0 && "$1" != -* ]]; then
    command="$1"
    shift
  fi

  case "$command" in
    init)
      init_iteration "$@"
      ;;
    list)
      list_scripts
      ;;
    run)
      local script_name="${1:-}"
      if [[ -z "$script_name" ]]; then
        echo "Usage: scripts/$SELF_NAME run <script_name> [args...]" >&2
        exit 1
      fi
      shift
      run_script "$script_name" "$@"
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown command: $command" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
