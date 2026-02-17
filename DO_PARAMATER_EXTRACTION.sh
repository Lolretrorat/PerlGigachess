#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_INGRESS_SCRIPT="$ROOT_DIR/scripts/data_ingress.sh"
NOTEBOOK_RUNNER="$ROOT_DIR/scripts/run_notebook_noninteractive.py"
ENGINE_NOTEBOOK="$ROOT_DIR/analysis/engine_training.ipynb"
MIGRATION_HELPER="$ROOT_DIR/scripts/apply_engine_migration.sh"

RUN_INGRESS=1
RUN_OWN_URLS=1
RUN_LICHESS_DB=0
LICHESS_MONTH=""
OWN_URL_LOG="$ROOT_DIR/data/lichess_game_urls.log"
PGN_PATH="$ROOT_DIR/data/lichess_games_export.pgn"
CLEAR_OWN_URL_LOG=1
SKIP_LOCATION_INGRESS=1

TMP_DIR="${PERLGIGACHESS_TMP_DIR:-/mnt/throughput/perlgigachess-tmp}"
KEEP_DOWNLOAD=0
ALLOW_DUPLICATE_SOURCE=0

PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
MIN_PARAM_SCORE=""
TRAINING_REFERENCE_GAMES=""
MAX_GAMES=""
MIGRATION_SUFFIX="engine_training_recommendations"
MIGRATION_TIMESTAMP=""
ALLOW_GENERIC_PGN_GAMES=0
REQUIRE_PATCH=0
BUNDLE_OUT=""

usage() {
  cat <<'USAGE'
Usage:
  ./DO_PARAMATER_EXTRACTION.sh [options]

Purpose:
  End-to-end parameter extraction pipeline that can:
  1) ingest games (default: OWN-URLS from data/lichess_game_urls.log)
  2) run analysis/engine_training.ipynb non-interactively
  3) emit a migration bundle under engineMigration/

Options:
  --skip-ingress                  Skip scripts/data_ingress.sh
  --no-own-urls                   Disable default OWN-URLS ingestion
  --month <YYYY-MM>               Also ingest Lichess monthly dump via LICHESS-DB-PGNS
  --own-url-log <path>            URL log path (default: data/lichess_game_urls.log)
  --pgn <path>                    Training PGN path (default: data/lichess_games_export.pgn)
  --keep-url-log                  Do not clear URL log after OWN-URLS ingest
  --include-location-ingress      Keep location training enabled during ingest
  --tmp-dir <dir>                 Temp directory for ingest (default: /mnt/throughput/perlgigachess-tmp)
  --keep-download                 Keep monthly archive download
  --allow-duplicate-source        Allow duplicate monthly ingest source
  --python <path>                 Python executable (default: .venv/bin/python)
  --min-param-score <float>       ENGINE_TRAINING_MIN_PARAM_SCORE override
  --reference-games <int>         ENGINE_TRAINING_REFERENCE_GAMES override
  --max-games <int>               ENGINE_TRAINING_MAX_GAMES override
  --migration-suffix <name>       ENGINE_TRAINING_MIGRATION_SUFFIX override
  --migration-timestamp <ts>      ENGINE_TRAINING_MIGRATION_TIMESTAMP override
  --allow-generic-pgn-games       ENGINE_TRAINING_ALLOW_GENERIC_PGN_GAMES=1
  --require-patch                 Exit non-zero if no *_engine_patch.diff is produced
  --bundle-out <path>             Write generated migration bundle name to a file
  -h, --help                      Show this message
USAGE
}

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "$flag requires a value" >&2
    exit 1
  fi
}

validate_year_month() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ingress)
      RUN_INGRESS=0
      shift
      ;;
    --no-own-urls)
      RUN_OWN_URLS=0
      shift
      ;;
    --month)
      require_value "--month" "${2:-}"
      RUN_LICHESS_DB=1
      LICHESS_MONTH="${2:-}"
      shift 2
      ;;
    --own-url-log)
      require_value "--own-url-log" "${2:-}"
      OWN_URL_LOG="${2:-}"
      shift 2
      ;;
    --pgn)
      require_value "--pgn" "${2:-}"
      PGN_PATH="${2:-}"
      shift 2
      ;;
    --keep-url-log)
      CLEAR_OWN_URL_LOG=0
      shift
      ;;
    --include-location-ingress)
      SKIP_LOCATION_INGRESS=0
      shift
      ;;
    --tmp-dir)
      require_value "--tmp-dir" "${2:-}"
      TMP_DIR="${2:-}"
      shift 2
      ;;
    --keep-download)
      KEEP_DOWNLOAD=1
      shift
      ;;
    --allow-duplicate-source)
      ALLOW_DUPLICATE_SOURCE=1
      shift
      ;;
    --python)
      require_value "--python" "${2:-}"
      PYTHON_BIN="${2:-}"
      shift 2
      ;;
    --min-param-score)
      require_value "--min-param-score" "${2:-}"
      MIN_PARAM_SCORE="${2:-}"
      shift 2
      ;;
    --reference-games)
      require_value "--reference-games" "${2:-}"
      TRAINING_REFERENCE_GAMES="${2:-}"
      shift 2
      ;;
    --max-games)
      require_value "--max-games" "${2:-}"
      MAX_GAMES="${2:-}"
      shift 2
      ;;
    --migration-suffix)
      require_value "--migration-suffix" "${2:-}"
      MIGRATION_SUFFIX="${2:-}"
      shift 2
      ;;
    --migration-timestamp)
      require_value "--migration-timestamp" "${2:-}"
      MIGRATION_TIMESTAMP="${2:-}"
      shift 2
      ;;
    --allow-generic-pgn-games)
      ALLOW_GENERIC_PGN_GAMES=1
      shift
      ;;
    --require-patch)
      REQUIRE_PATCH=1
      shift
      ;;
    --bundle-out)
      require_value "--bundle-out" "${2:-}"
      BUNDLE_OUT="${2:-}"
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

if [[ "$RUN_LICHESS_DB" -eq 1 ]] && ! validate_year_month "$LICHESS_MONTH"; then
  echo "Invalid --month value '$LICHESS_MONTH' (expected YYYY-MM)" >&2
  exit 1
fi

if [[ ! -x "$DATA_INGRESS_SCRIPT" ]]; then
  echo "Missing executable: $DATA_INGRESS_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$ENGINE_NOTEBOOK" ]]; then
  echo "Missing notebook: $ENGINE_NOTEBOOK" >&2
  exit 1
fi
if [[ ! -f "$NOTEBOOK_RUNNER" ]]; then
  echo "Missing runner: $NOTEBOOK_RUNNER" >&2
  exit 1
fi
if [[ ! -x "$MIGRATION_HELPER" ]]; then
  echo "Missing executable: $MIGRATION_HELPER" >&2
  exit 1
fi
if [[ "$PYTHON_BIN" == */* ]]; then
  if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python executable not found: $PYTHON_BIN" >&2
    exit 1
  fi
else
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    echo "Python executable not found in PATH: $PYTHON_BIN" >&2
    exit 1
  fi
fi

if [[ "$RUN_INGRESS" -eq 1 ]]; then
  ingress_args=(--tmp-dir "$TMP_DIR")

  if [[ "$KEEP_DOWNLOAD" -eq 1 ]]; then
    ingress_args+=(--keep-download)
  fi
  if [[ "$ALLOW_DUPLICATE_SOURCE" -eq 1 ]]; then
    ingress_args+=(--allow-duplicate-source)
  fi
  if [[ "$SKIP_LOCATION_INGRESS" -eq 1 ]]; then
    ingress_args+=(--skip-location)
  fi
  if [[ "$RUN_LICHESS_DB" -eq 1 ]]; then
    ingress_args+=(LICHESS-DB-PGNS "$LICHESS_MONTH")
  fi
  if [[ "$RUN_OWN_URLS" -eq 1 ]]; then
    ingress_args+=(
      OWN-URLS
      --own-url-log "$OWN_URL_LOG"
      --own-pgn-output "$PGN_PATH"
    )
    if [[ "$CLEAR_OWN_URL_LOG" -eq 1 ]]; then
      ingress_args+=(--clear-own-url-log)
    fi
  fi

  if [[ "$RUN_OWN_URLS" -eq 0 && "$RUN_LICHESS_DB" -eq 0 ]]; then
    echo "No ingest source selected. Use --month and/or leave OWN-URLS enabled." >&2
    exit 1
  fi

  echo "==> Running ingress"
  (cd "$ROOT_DIR" && "$DATA_INGRESS_SCRIPT" "${ingress_args[@]}")
else
  echo "==> Skipping ingest"
fi

ENGINE_INPUT_SOURCE_MODE="existing_pgn"
ENGINE_LICHESS_DB_URLS=""
if [[ "$RUN_LICHESS_DB" -eq 1 && "$RUN_OWN_URLS" -eq 0 ]]; then
  ENGINE_INPUT_SOURCE_MODE="lichess_db_urls"
  ENGINE_LICHESS_DB_URLS="https://database.lichess.org/standard/lichess_db_standard_rated_${LICHESS_MONTH}.pgn.zst"
fi

if [[ "$ENGINE_INPUT_SOURCE_MODE" == "existing_pgn" && ! -f "$PGN_PATH" ]]; then
  echo "Missing PGN for training: $PGN_PATH" >&2
  exit 1
fi

RUN_MIGRATION_TIMESTAMP="$MIGRATION_TIMESTAMP"
if [[ -z "$RUN_MIGRATION_TIMESTAMP" ]]; then
  RUN_MIGRATION_TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
fi
RUN_MIGRATION_BUNDLE="V${RUN_MIGRATION_TIMESTAMP}__${MIGRATION_SUFFIX}"

nb_env=(
  ENGINE_TRAINING_INPUT_SOURCE_MODE="$ENGINE_INPUT_SOURCE_MODE"
  ENGINE_TRAINING_PGN_PATH="$PGN_PATH"
  ENGINE_TRAINING_APPLY_ENGINE_PATCH=0
  ENGINE_TRAINING_MIGRATION_SUFFIX="$MIGRATION_SUFFIX"
  ENGINE_TRAINING_MIGRATION_TIMESTAMP="$RUN_MIGRATION_TIMESTAMP"
)

if [[ "$ENGINE_INPUT_SOURCE_MODE" == "lichess_db_urls" ]]; then
  nb_env+=(
    ENGINE_TRAINING_LICHESS_DB_URLS="$ENGINE_LICHESS_DB_URLS"
    ENGINE_TRAINING_LICHESS_DB_TMP_DIR="$TMP_DIR"
  )
  if [[ "$KEEP_DOWNLOAD" -eq 1 ]]; then
    nb_env+=(ENGINE_TRAINING_KEEP_DB_DOWNLOADS=1)
  fi
fi

if [[ -n "$MIN_PARAM_SCORE" ]]; then
  nb_env+=(ENGINE_TRAINING_MIN_PARAM_SCORE="$MIN_PARAM_SCORE")
fi
if [[ -n "$TRAINING_REFERENCE_GAMES" ]]; then
  nb_env+=(ENGINE_TRAINING_REFERENCE_GAMES="$TRAINING_REFERENCE_GAMES")
fi
if [[ -n "$MAX_GAMES" ]]; then
  nb_env+=(ENGINE_TRAINING_MAX_GAMES="$MAX_GAMES")
fi
if [[ "$ALLOW_GENERIC_PGN_GAMES" -eq 1 ]]; then
  nb_env+=(ENGINE_TRAINING_ALLOW_GENERIC_PGN_GAMES=1)
fi

echo "==> Running engine parameter extraction notebook"
(cd "$ROOT_DIR" && env "${nb_env[@]}" "$PYTHON_BIN" "$NOTEBOOK_RUNNER" --notebook "$ENGINE_NOTEBOOK")

latest_bundle="$RUN_MIGRATION_BUNDLE"
bundle_dir="$ROOT_DIR/engineMigration/$latest_bundle"
if [[ ! -d "$bundle_dir" ]]; then
  echo "Expected migration bundle from this run not found: $bundle_dir" >&2
  exit 1
fi

shopt -s nullglob
patches=("$bundle_dir"/*_engine_patch.diff)
shopt -u nullglob

echo "==> Bundle: $latest_bundle"
echo "    Path: $bundle_dir"
if [[ "${#patches[@]}" -gt 0 ]]; then
  echo "    Patch: ${patches[0]}"
  (cd "$ROOT_DIR" && "$MIGRATION_HELPER" check "$latest_bundle")
else
  echo "    Patch: none (no proposed constant updates)"
  if [[ "$REQUIRE_PATCH" -eq 1 ]]; then
    echo "Patch was required but not produced." >&2
    exit 2
  fi
fi

if [[ -n "$BUNDLE_OUT" ]]; then
  mkdir -p "$(dirname "$BUNDLE_OUT")"
  printf '%s\n' "$latest_bundle" > "$BUNDLE_OUT"
fi

echo "==> Parameter extraction pipeline complete"
