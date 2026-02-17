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
SKIP_OWN_URLS=0
SKIP_BOOK_UNDERPROMO=0
SKIP_LICHESS_TIME=0
SKIP_PDP_QUEEN=0
SKIP_REP_GUARD=0

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
  --skip-own-urls          Skip OWN-URL parser/ingest regression check
  --skip-book-underpromo   Skip opening-book SAN underpromotion regression check
  --skip-lichess-time      Skip lichess bot time/depth profile regression check
  --skip-pdp-queen         Skip PDPgjgTd random queen-capture regression check
  --skip-rep-guard         Skip repetition guard quiet-move regression check
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
    --skip-own-urls)
      SKIP_OWN_URLS=1
      shift
      ;;
    --skip-book-underpromo)
      SKIP_BOOK_UNDERPROMO=1
      shift
      ;;
    --skip-lichess-time)
      SKIP_LICHESS_TIME=1
      shift
      ;;
    --skip-pdp-queen)
      SKIP_PDP_QUEEN=1
      shift
      ;;
    --skip-rep-guard)
      SKIP_REP_GUARD=1
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

if [[ "$SKIP_OWN_URLS" -eq 0 ]]; then
  echo "==> OWN-URL parser guard (12-char URL handling)"
  (cd "$ROOT_DIR" && bash tests/regression_own_urls_parser.sh)
else
  echo "==> Skipping OWN-URL parser guard"
fi

if [[ "$SKIP_BOOK_UNDERPROMO" -eq 0 ]]; then
  echo "==> Opening-book underpromotion SAN guard"
  (cd "$ROOT_DIR" && bash tests/regression_book_underpromotion.sh)
else
  echo "==> Skipping opening-book underpromotion SAN guard"
fi

if [[ "$SKIP_LICHESS_TIME" -eq 0 ]]; then
  echo "==> Lichess time/depth profile guard"
  (cd "$ROOT_DIR" && bash tests/regression_lichess_time_profile.sh)
else
  echo "==> Skipping lichess time/depth profile guard"
fi

if [[ "$SKIP_PDP_QUEEN" -eq 0 ]]; then
  echo "==> PDPgjgTd guard (avoid random queen capture)"
  (cd "$ROOT_DIR" && perl tests/regression_pdpgjgtd_queen_capture.pl)
else
  echo "==> Skipping PDPgjgTd queen-capture guard"
fi

if [[ "$SKIP_REP_GUARD" -eq 0 ]]; then
  echo "==> Repetition guard quiet-move check"
  (cd "$ROOT_DIR" && perl tests/regression_repetition_guard_quiet_move.pl)
else
  echo "==> Skipping repetition guard quiet-move check"
fi

if [[ "$SKIP_PERFT" -eq 0 ]]; then
  echo "==> Perft sanity depth $PERFT_DEPTH"
  (cd "$ROOT_DIR" && perl tests/perft.pl "$PERFT_DEPTH")
else
  echo "==> Skipping perft sanity"
fi

echo "==> Regression suite complete"
