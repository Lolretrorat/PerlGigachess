#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_INGRESS_SCRIPT="$ROOT_DIR/scripts/data_ingress.sh"
UPDATE_LOCATION_SCRIPT="$ROOT_DIR/scripts/update_location_modifiers.pl"

RUN_INGRESS=1
RUN_OWN_URLS=1
RUN_LICHESS_DB=0
LICHESS_MONTH=""

OWN_URL_LOG="$ROOT_DIR/data/lichess_game_urls.log"
OWN_PGN_OUTPUT="$ROOT_DIR/data/lichess_games_export.pgn"
CLEAR_OWN_URL_LOG=1

DEFAULT_TMP_DIR="${PERLGIGACHESS_TMP_DIR:-/mnt/throughput/perlgigachess-tmp}"
TMP_DIR="$DEFAULT_TMP_DIR"
KEEP_DOWNLOAD=0
ALLOW_DUPLICATE_SOURCE=0

LOCATION_OUTPUT="$ROOT_DIR/data/location_modifiers.json"
LOCATION_GAMES=5000
LOCATION_SCALE=""
RUN_VALIDATION=1

usage() {
  cat <<'USAGE'
Usage:
  ./DO_LOCATION_MODIFIER.sh [options]

Purpose:
  End-to-end location modifier pipeline that can:
  1) ingest games (default: OWN-URLS)
  2) train/update data/location_modifiers.json
  3) validate output and syntax-check Chess::LocationModifer

Options:
  --skip-ingress                  Skip scripts/data_ingress.sh
  --no-own-urls                   Disable default OWN-URLS ingestion
  --month <YYYY-MM>               Also ingest Lichess monthly dump via LICHESS-DB-PGNS
  --own-url-log <path>            URL log path (default: data/lichess_game_urls.log)
  --own-pgn-output <path>         OWN-URLS PGN output path
  --keep-url-log                  Do not clear URL log after OWN-URLS ingest
  --tmp-dir <dir>                 Temp directory for ingest (default: $PERLGIGACHESS_TMP_DIR or /mnt/throughput/perlgigachess-tmp)
  --keep-download                 Keep monthly archive download
  --allow-duplicate-source        Allow duplicate monthly ingest source
  --location-output <path>        Location output path (default: data/location_modifiers.json)
  --location-games <int>          Max games for location training (default: 5000)
  --location-scale <num>          Scale passed to ./init train-location
  --skip-validation               Skip update_location_modifiers.pl validation pass
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
    --own-pgn-output)
      require_value "--own-pgn-output" "${2:-}"
      OWN_PGN_OUTPUT="${2:-}"
      shift 2
      ;;
    --keep-url-log)
      CLEAR_OWN_URL_LOG=0
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
    --location-output)
      require_value "--location-output" "${2:-}"
      LOCATION_OUTPUT="${2:-}"
      shift 2
      ;;
    --location-games)
      require_value "--location-games" "${2:-}"
      LOCATION_GAMES="${2:-}"
      shift 2
      ;;
    --location-scale)
      require_value "--location-scale" "${2:-}"
      LOCATION_SCALE="${2:-}"
      shift 2
      ;;
    --skip-validation)
      RUN_VALIDATION=0
      shift
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
if [[ ! -f "$UPDATE_LOCATION_SCRIPT" ]]; then
  echo "Missing script: $UPDATE_LOCATION_SCRIPT" >&2
  exit 1
fi
mkdir -p "$TMP_DIR"

if [[ "$RUN_INGRESS" -eq 1 ]]; then
  ingress_args=(
    --tmp-dir "$TMP_DIR"
    --skip-book
    --location-output "$LOCATION_OUTPUT"
    --location-games "$LOCATION_GAMES"
  )

  if [[ -n "$LOCATION_SCALE" ]]; then
    ingress_args+=(--location-scale "$LOCATION_SCALE")
  fi
  if [[ "$KEEP_DOWNLOAD" -eq 1 ]]; then
    ingress_args+=(--keep-download)
  fi
  if [[ "$ALLOW_DUPLICATE_SOURCE" -eq 1 ]]; then
    ingress_args+=(--allow-duplicate-source)
  fi
  if [[ "$RUN_LICHESS_DB" -eq 1 ]]; then
    ingress_args+=(LICHESS-DB-PGNS "$LICHESS_MONTH")
  fi
  if [[ "$RUN_OWN_URLS" -eq 1 ]]; then
    ingress_args+=(
      OWN-URLS
      --own-url-log "$OWN_URL_LOG"
      --own-pgn-output "$OWN_PGN_OUTPUT"
    )
    if [[ "$CLEAR_OWN_URL_LOG" -eq 1 ]]; then
      ingress_args+=(--clear-own-url-log)
    fi
  fi

  if [[ "$RUN_OWN_URLS" -eq 0 && "$RUN_LICHESS_DB" -eq 0 ]]; then
    echo "No ingest source selected. Use --month and/or leave OWN-URLS enabled." >&2
    exit 1
  fi

  echo "==> Running location-modifier ingress/training"
  (cd "$ROOT_DIR" && "$DATA_INGRESS_SCRIPT" "${ingress_args[@]}")
else
  echo "==> Skipping ingress"
fi

if [[ "$RUN_VALIDATION" -eq 1 ]]; then
  if [[ ! -f "$LOCATION_OUTPUT" ]]; then
    echo "Missing location output for validation: $LOCATION_OUTPUT" >&2
    exit 1
  fi
  echo "==> Validating location modifiers JSON"
  (cd "$ROOT_DIR" && perl "$UPDATE_LOCATION_SCRIPT" --output "$LOCATION_OUTPUT" "$LOCATION_OUTPUT")
fi

echo "==> Syntax check Chess::LocationModifer"
(cd "$ROOT_DIR" && perl -I"$ROOT_DIR" -c Chess/LocationModifer.pm)

echo "==> Location modifier pipeline complete"
