#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PARAM_EXTRACTION_SCRIPT="$ROOT_DIR/DO_PARAMATER_EXTRACTION.sh"
NOTEBOOK_RUNNER="$ROOT_DIR/scripts/run_notebook_noninteractive.py"
LOCATION_NOTEBOOK="$ROOT_DIR/analysis/location_modifer_training.ipynb"

MODE="engine"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"
forward_args=()

usage() {
  cat <<'USAGE'
Usage:
  ./DO_DATA_SCIENCE.sh [--engine-training|--location-training] [options]

Purpose:
  Run analytics notebooks in explicit data-science mode. This mode is allowed to
  clear consumed OWN-URL logs after ingest; all other wrappers retain URLs by
  default.

Modes:
  --engine-training              Run DO_PARAMATER_EXTRACTION.sh in data-science mode (default)
  --location-training            Run analysis/location_modifer_training.ipynb non-interactively

Options:
  --python <path>                Python executable for notebook execution
  -h, --help                     Show this message

Engine-mode arguments are forwarded to `DO_PARAMATER_EXTRACTION.sh`.
Location mode is configured via `LOCATION_TRAINING_*` environment variables.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine-training)
      MODE="engine"
      shift
      ;;
    --location-training)
      MODE="location"
      shift
      ;;
    --python)
      require_value "--python" "${2:-}"
      PYTHON_BIN="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      forward_args+=("$1")
      shift
      ;;
  esac
done

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

if [[ "$MODE" == "engine" ]]; then
  if [[ ! -x "$PARAM_EXTRACTION_SCRIPT" ]]; then
    echo "Missing executable: $PARAM_EXTRACTION_SCRIPT" >&2
    exit 1
  fi
  exec env \
    DO_DATA_SCIENCE=1 \
    ENGINE_TRAINING_CLEAR_GAME_URL_LOG=1 \
    "$PARAM_EXTRACTION_SCRIPT" \
    --clear-url-log \
    "${forward_args[@]}"
fi

if [[ "${#forward_args[@]}" -gt 0 ]]; then
  echo "Location training mode does not accept extra CLI args; use LOCATION_TRAINING_* environment variables." >&2
  exit 1
fi

if [[ ! -f "$LOCATION_NOTEBOOK" ]]; then
  echo "Missing notebook: $LOCATION_NOTEBOOK" >&2
  exit 1
fi
if [[ ! -f "$NOTEBOOK_RUNNER" ]]; then
  echo "Missing runner: $NOTEBOOK_RUNNER" >&2
  exit 1
fi

exec env \
  DO_DATA_SCIENCE=1 \
  LOCATION_TRAINING_CLEAR_GAME_URL_LOG=1 \
  "$PYTHON_BIN" \
  "$NOTEBOOK_RUNNER" \
  --notebook "$LOCATION_NOTEBOOK" \
  "${forward_args[@]}"
