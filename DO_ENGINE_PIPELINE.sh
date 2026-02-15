#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTION_SCRIPT="$ROOT_DIR/DO_PARAMATER_EXTRACTION.sh"
MIGRATION_HELPER="$ROOT_DIR/scripts/apply_engine_migration.sh"

APPLY_PATCH=1
REQUIRE_PATCH=0
RUN_PERFT=1
PERFT_DEPTH=4

usage() {
  cat <<'USAGE'
Usage:
  ./DO_ENGINE_PIPELINE.sh [engine-options] [parameter-extraction-options]

Purpose:
  End-to-end engine pipeline:
  1) run DO_PARAMATER_EXTRACTION.sh
  2) apply generated engine migration patch (if present)
  3) run syntax and perft validation

Engine options:
  --no-apply                      Do not apply migration patch to Chess/Engine.pm
  --require-patch                 Exit non-zero when no patch was generated
  --skip-perft                    Skip perl perft.pl validation
  --perft-depth <int>             Perft depth (default: 4)
  -h, --help                      Show this message

All other options are forwarded to DO_PARAMATER_EXTRACTION.sh.
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

if [[ ! -x "$EXTRACTION_SCRIPT" ]]; then
  echo "Missing executable: $EXTRACTION_SCRIPT" >&2
  exit 1
fi
if [[ ! -x "$MIGRATION_HELPER" ]]; then
  echo "Missing executable: $MIGRATION_HELPER" >&2
  exit 1
fi

extraction_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-apply)
      APPLY_PATCH=0
      shift
      ;;
    --require-patch)
      REQUIRE_PATCH=1
      shift
      ;;
    --skip-perft)
      RUN_PERFT=0
      shift
      ;;
    --perft-depth)
      require_value "--perft-depth" "${2:-}"
      PERFT_DEPTH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      extraction_args+=("$1")
      shift
      ;;
  esac
done

bundle_file="$(mktemp)"
trap 'rm -f "$bundle_file"' EXIT

echo "==> Running parameter extraction stage"
"$EXTRACTION_SCRIPT" "${extraction_args[@]}" --bundle-out "$bundle_file"

bundle_name="$(tr -d '\r\n' < "$bundle_file")"
if [[ -z "$bundle_name" ]]; then
  echo "Parameter extraction did not return a migration bundle name." >&2
  exit 1
fi

bundle_dir="$ROOT_DIR/engineMigration/$bundle_name"
shopt -s nullglob
patches=("$bundle_dir"/*_engine_patch.diff)
shopt -u nullglob

if [[ "${#patches[@]}" -eq 0 ]]; then
  echo "==> No patch generated for bundle: $bundle_name"
  if [[ "$REQUIRE_PATCH" -eq 1 ]]; then
    echo "Patch was required but not produced." >&2
    exit 2
  fi
else
  echo "==> Patch available: ${patches[0]}"
  (cd "$ROOT_DIR" && "$MIGRATION_HELPER" check "$bundle_name")
  if [[ "$APPLY_PATCH" -eq 1 ]]; then
    echo "==> Applying migration patch"
    (cd "$ROOT_DIR" && "$MIGRATION_HELPER" apply "$bundle_name")
  else
    echo "==> Skipping apply (--no-apply)"
  fi
fi

echo "==> Syntax check Chess::Engine"
(cd "$ROOT_DIR" && perl -I"$ROOT_DIR" -c Chess/Engine.pm)

if [[ "$RUN_PERFT" -eq 1 ]]; then
  echo "==> Running perft depth $PERFT_DEPTH"
  (cd "$ROOT_DIR" && perl perft.pl "$PERFT_DEPTH")
else
  echo "==> Skipping perft (--skip-perft)"
fi

echo "==> Engine pipeline complete"
