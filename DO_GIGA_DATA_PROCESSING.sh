#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_PIPELINE_SCRIPT="$ROOT_DIR/DO_ENGINE_PIPELINE.sh"
LOCATION_PIPELINE_SCRIPT="$ROOT_DIR/DO_LOCATION_MODIFIER.sh"

RUN_LOCATION_VALIDATION=1
BATCH_MONTHS=1
EXPLICIT_MONTH=""

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

previous_month() {
  local value="$1"
  local year="${value%-*}"
  local month="${value#*-}"
  local y=$((10#$year))
  local m=$((10#$month))
  m=$((m - 1))
  if [[ "$m" -eq 0 ]]; then
    y=$((y - 1))
    m=12
  fi
  printf '%04d-%02d\n' "$y" "$m"
}

usage() {
  cat <<'USAGE'
Usage:
  ./DO_GIGA_DATA_PROCESSING.sh [options-for-engine-pipeline]

Purpose:
  End-to-end combined data processing:
  1) run DO_ENGINE_PIPELINE.sh with location ingress enabled
     (ingest + location training + parameter extraction + engine patch/perft)
  2) run DO_LOCATION_MODIFIER.sh --skip-ingress for location JSON validation/syntax checks

Options:
  --batch-months <int>            Run month ingest/training for N months in a row
                                  ending at --month YYYY-MM (default: 1)
  --skip-location-validation      Skip DO_LOCATION_MODIFIER.sh --skip-ingress pass
  -h, --help                      Show this message

All other options are forwarded to DO_ENGINE_PIPELINE.sh.
Note: --skip-ingress is not supported in this wrapper because it disables
location + parameter ingestion/training.
USAGE
}

if [[ ! -x "$ENGINE_PIPELINE_SCRIPT" ]]; then
  echo "Missing executable: $ENGINE_PIPELINE_SCRIPT" >&2
  exit 1
fi
if [[ ! -x "$LOCATION_PIPELINE_SCRIPT" ]]; then
  echo "Missing executable: $LOCATION_PIPELINE_SCRIPT" >&2
  exit 1
fi

engine_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --batch-months)
      require_value "--batch-months" "${2:-}"
      BATCH_MONTHS="${2:-}"
      shift 2
      ;;
    --month)
      require_value "--month" "${2:-}"
      EXPLICIT_MONTH="${2:-}"
      shift 2
      ;;
    --skip-location-validation)
      RUN_LOCATION_VALIDATION=0
      shift
      ;;
    --skip-ingress)
      echo "--skip-ingress is not allowed for DO_GIGA_DATA_PROCESSING.sh." >&2
      echo "Use DO_ENGINE_PIPELINE.sh directly if you need to skip ingress." >&2
      exit 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      engine_args+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$BATCH_MONTHS" =~ ^[0-9]+$ ]] || [[ "$BATCH_MONTHS" -lt 1 ]]; then
  echo "Invalid --batch-months value '$BATCH_MONTHS' (expected integer >= 1)" >&2
  exit 1
fi

if [[ -n "$EXPLICIT_MONTH" ]] && ! validate_year_month "$EXPLICIT_MONTH"; then
  echo "Invalid --month value '$EXPLICIT_MONTH' (expected YYYY-MM)" >&2
  exit 1
fi

if [[ "$BATCH_MONTHS" -gt 1 ]] && [[ -z "$EXPLICIT_MONTH" ]]; then
  echo "--batch-months requires --month YYYY-MM as the batch end month." >&2
  exit 1
fi

run_engine_for_month() {
  local month="$1"
  echo "==> Running combined pipeline for month: $month"
  (cd "$ROOT_DIR" && "$ENGINE_PIPELINE_SCRIPT" "${engine_args[@]}" --month "$month" --include-location-ingress)
}

if [[ "$BATCH_MONTHS" -gt 1 ]]; then
  month_cursor="$EXPLICIT_MONTH"
  months_to_run=("$month_cursor")
  for ((i = 1; i < BATCH_MONTHS; i++)); do
    month_cursor="$(previous_month "$month_cursor")"
    months_to_run=("$month_cursor" "${months_to_run[@]}")
  done

  echo "==> Running combined pipeline (location + parameter + engine patch/perft)"
  echo "    Batch months: ${months_to_run[*]}"
  for month in "${months_to_run[@]}"; do
    run_engine_for_month "$month"
  done
elif [[ -n "$EXPLICIT_MONTH" ]]; then
  run_engine_for_month "$EXPLICIT_MONTH"
else
  echo "==> Running combined pipeline (location + parameter + engine patch/perft)"
  (cd "$ROOT_DIR" && "$ENGINE_PIPELINE_SCRIPT" "${engine_args[@]}" --include-location-ingress)
fi

if [[ "$RUN_LOCATION_VALIDATION" -eq 1 ]]; then
  echo "==> Running location validation pass"
  (cd "$ROOT_DIR" && "$LOCATION_PIPELINE_SCRIPT" --skip-ingress)
else
  echo "==> Skipping location validation (--skip-location-validation)"
fi

echo "==> Combined data processing complete"
