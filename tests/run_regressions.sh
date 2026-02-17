#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

PERFT_DEPTH=4
KG8_DEPTH=3
KG8_MOVETIME=20000
PROMO_DEPTH=4
PROMO_MOVETIME=1500
SKIP_PERFT=0
SKIP_KG8=0
SKIP_PROMO=0

usage() {
  cat <<'USAGE'
Usage:
  tests/run_regressions.sh [options]

Options:
  --perft-depth <N>        Perft depth for regression sanity (default: 4)
  --kg8-depth <N>          Depth for hyhMjQD2 guard position (default: 3)
  --kg8-movetime <MS>      Movetime for hyhMjQD2 guard position (default: 20000)
  --promo-depth <N>        Depth for promotion-mate regression (default: 4)
  --promo-movetime <MS>    Movetime for promotion-mate regression (default: 1500)
  --skip-perft             Skip perft sanity pass
  --skip-kg8               Skip hyhMjQD2 regression check
  --skip-promo             Skip promotion-mate regression check
  -h, --help               Show help
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
    --perft-depth)
      require_value "--perft-depth" "${2:-}"
      PERFT_DEPTH="${2:-}"
      shift 2
      ;;
    --kg8-depth)
      require_value "--kg8-depth" "${2:-}"
      KG8_DEPTH="${2:-}"
      shift 2
      ;;
    --kg8-movetime)
      require_value "--kg8-movetime" "${2:-}"
      KG8_MOVETIME="${2:-}"
      shift 2
      ;;
    --promo-depth)
      require_value "--promo-depth" "${2:-}"
      PROMO_DEPTH="${2:-}"
      shift 2
      ;;
    --promo-movetime)
      require_value "--promo-movetime" "${2:-}"
      PROMO_MOVETIME="${2:-}"
      shift 2
      ;;
    --skip-perft)
      SKIP_PERFT=1
      shift
      ;;
    --skip-kg8)
      SKIP_KG8=1
      shift
      ;;
    --skip-promo)
      SKIP_PROMO=1
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

echo "==> Regression suite start"

if [[ "$SKIP_KG8" -eq 0 ]]; then
  echo "==> hyhMjQD2 guard (no ...Kg8)"
  (cd "$ROOT_DIR" && perl tests/regression_hyhMjQD2_kg8.pl --depth "$KG8_DEPTH" --movetime "$KG8_MOVETIME")
else
  echo "==> Skipping hyhMjQD2 guard"
fi

if [[ "$SKIP_PROMO" -eq 0 ]]; then
  echo "==> Promotion mate guard (2nd/7th rank queen promotion)"
  (cd "$ROOT_DIR" && perl tests/regression_promotion_mate.pl --depth "$PROMO_DEPTH" --movetime "$PROMO_MOVETIME")
else
  echo "==> Skipping promotion mate guard"
fi

if [[ "$SKIP_PERFT" -eq 0 ]]; then
  echo "==> Perft sanity depth $PERFT_DEPTH"
  (cd "$ROOT_DIR" && perl tests/perft.pl "$PERFT_DEPTH")
else
  echo "==> Skipping perft sanity"
fi

echo "==> Regression suite complete"
