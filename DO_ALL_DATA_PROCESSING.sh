#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_PIPELINE_SCRIPT="$ROOT_DIR/DO_ENGINE_PIPELINE.sh"
LOCATION_PIPELINE_SCRIPT="$ROOT_DIR/DO_LOCATION_MODIFIER.sh"

RUN_LOCATION_VALIDATION=1

usage() {
  cat <<'USAGE'
Usage:
  ./DO_ALL_DATA_PROCESSING.sh [options-for-engine-pipeline]

Purpose:
  End-to-end combined data processing:
  1) run DO_ENGINE_PIPELINE.sh with location ingress enabled
     (ingest + location training + parameter extraction + engine patch/perft)
  2) run DO_LOCATION_MODIFIER.sh --skip-ingress for location JSON validation/syntax checks

Options:
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
    --skip-location-validation)
      RUN_LOCATION_VALIDATION=0
      shift
      ;;
    --skip-ingress)
      echo "--skip-ingress is not allowed for DO_ALL_DATA_PROCESSING.sh." >&2
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

echo "==> Running combined pipeline (location + parameter + engine patch/perft)"
(cd "$ROOT_DIR" && "$ENGINE_PIPELINE_SCRIPT" "${engine_args[@]}" --include-location-ingress)

if [[ "$RUN_LOCATION_VALIDATION" -eq 1 ]]; then
  echo "==> Running location validation pass"
  (cd "$ROOT_DIR" && "$LOCATION_PIPELINE_SCRIPT" --skip-ingress)
else
  echo "==> Skipping location validation (--skip-location-validation)"
fi

echo "==> Combined data processing complete"
