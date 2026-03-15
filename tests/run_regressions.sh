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
SKIP_BOOK_POLICY=0
SKIP_BOOK_PLAN=0
SKIP_LICHESS_TIME=0
SKIP_ENGINE_REGISTRY=0
SKIP_ENGINE_RECOMMEND=0
SKIP_PDP_QUEEN=0
SKIP_REP_GUARD=0
SKIP_QSEARCH_IN_CHECK=0
SKIP_SEARCH_REPETITION=0
SKIP_MODULE_UNIT=0
SKIP_EVAL_THREAT_PLAN=0
SKIP_UNGUARDED_PLAN=0
SKIP_PROMO_CHECK=0
SKIP_XXGZ_REBUILD=0
SKIP_PROTOCOL=0
SKIP_IMMEDIATE_STOP=0
SKIP_SEARCHMOVES=0
SKIP_DATA_RETENTION=0
SKIP_R9GKSIYT=0

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
  --skip-book-policy       Skip opening-book policy/depth/overlay regression check
  --skip-book-plan         Skip opening-book plan metadata regression check
  --skip-lichess-time      Skip lichess bot time/depth profile regression check
  --skip-engine-registry   Skip engine tuning registry sync regression check
  --skip-engine-recommend  Skip engine recommendation threshold regression check
  --skip-pdp-queen         Skip PDPgjgTd random queen-capture regression check
  --skip-rep-guard         Skip repetition guard quiet-move regression check
  --skip-qsearch-check     Skip qsearch in-check mate/evasion regression check
  --skip-search-repetition Skip search repetition threefold-only regression check
  --skip-module-unit       Skip module-level unit regressions (state/TT/picker/time/etc.)
  --skip-eval-threat-plan  Skip eval threat/planning integration regression check
  --skip-unguarded-plan    Skip unguarded-material capture-plan regression check
  --skip-promo-check       Skip promotion-with-check regression check
  --skip-xxgz-rebuild      Skip xXgzD7zW state-rebuild regression check
  --skip-protocol          Skip UCI protocol contract regression check
  --skip-immediate-stop    Skip immediate go/stop legal-bestmove regression check
  --skip-searchmoves       Skip UCI searchmoves filtering regression check
  --skip-data-retention    Skip analytics URL-retention policy regression check
  --skip-r9gksiyt          Skip r9GKsIYt promotion/mate regression check
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
    --skip-book-policy)
      SKIP_BOOK_POLICY=1
      shift
      ;;
    --skip-book-plan)
      SKIP_BOOK_PLAN=1
      shift
      ;;
    --skip-lichess-time)
      SKIP_LICHESS_TIME=1
      shift
      ;;
    --skip-engine-registry)
      SKIP_ENGINE_REGISTRY=1
      shift
      ;;
    --skip-engine-recommend)
      SKIP_ENGINE_RECOMMEND=1
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
    --skip-qsearch-check)
      SKIP_QSEARCH_IN_CHECK=1
      shift
      ;;
    --skip-search-repetition)
      SKIP_SEARCH_REPETITION=1
      shift
      ;;
    --skip-module-unit)
      SKIP_MODULE_UNIT=1
      shift
      ;;
    --skip-eval-threat-plan)
      SKIP_EVAL_THREAT_PLAN=1
      shift
      ;;
    --skip-unguarded-plan)
      SKIP_UNGUARDED_PLAN=1
      shift
      ;;
    --skip-promo-check)
      SKIP_PROMO_CHECK=1
      shift
      ;;
    --skip-xxgz-rebuild)
      SKIP_XXGZ_REBUILD=1
      shift
      ;;
    --skip-protocol)
      SKIP_PROTOCOL=1
      shift
      ;;
    --skip-immediate-stop)
      SKIP_IMMEDIATE_STOP=1
      shift
      ;;
    --skip-searchmoves)
      SKIP_SEARCHMOVES=1
      shift
      ;;
    --skip-data-retention)
      SKIP_DATA_RETENTION=1
      shift
      ;;
    --skip-r9gksiyt)
      SKIP_R9GKSIYT=1
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

if [[ "$SKIP_DATA_RETENTION" -eq 0 ]]; then
  echo "==> Analytics URL-retention policy guard"
  (cd "$ROOT_DIR" && bash tests/regression_data_ingress_retention_policy.sh)
else
  echo "==> Skipping analytics URL-retention policy guard"
fi

if [[ "$SKIP_BOOK_UNDERPROMO" -eq 0 ]]; then
  echo "==> Opening-book underpromotion SAN guard"
  (cd "$ROOT_DIR" && bash tests/regression_book_underpromotion.sh)
else
  echo "==> Skipping opening-book underpromotion SAN guard"
fi

if [[ "$SKIP_BOOK_POLICY" -eq 0 ]]; then
  echo "==> Opening-book policy/depth/overlay guard"
  (cd "$ROOT_DIR" && bash tests/regression_book_policy_depth_overlay.sh)
else
  echo "==> Skipping opening-book policy/depth/overlay guard"
fi

if [[ "$SKIP_BOOK_PLAN" -eq 0 ]]; then
  echo "==> Opening-book plan metadata guard"
  (cd "$ROOT_DIR" && bash tests/regression_book_plan_metadata.sh)
else
  echo "==> Skipping opening-book plan metadata guard"
fi

if [[ "$SKIP_LICHESS_TIME" -eq 0 ]]; then
  echo "==> Lichess time/depth profile guard"
  (cd "$ROOT_DIR" && bash tests/regression_lichess_time_profile.sh)
else
  echo "==> Skipping lichess time/depth profile guard"
fi

if [[ "$SKIP_ENGINE_REGISTRY" -eq 0 ]]; then
  echo "==> Engine tuning registry sync guard"
  (cd "$ROOT_DIR" && bash tests/regression_engine_registry_sync.sh)
else
  echo "==> Skipping engine tuning registry sync guard"
fi

if [[ "$SKIP_ENGINE_RECOMMEND" -eq 0 ]]; then
  echo "==> Engine recommendation safeguard guard"
  (cd "$ROOT_DIR" && bash tests/regression_engine_recommendation_thresholds.sh)
else
  echo "==> Skipping engine recommendation safeguard guard"
fi

if [[ "$SKIP_PDP_QUEEN" -eq 0 ]]; then
  echo "==> PDPgjgTd guard (avoid random queen capture)"
  (cd "$ROOT_DIR" && perl tests/regression_pdpgjgtd_queen_capture.pl)
else
  echo "==> Skipping PDPgjgTd queen-capture guard"
fi

echo "==> SEE qrlijiqK guard (Qxd3 losing capture)"
(cd "$ROOT_DIR" && perl tests/regression_see_qxd3_losing_capture.pl)

if [[ "$SKIP_REP_GUARD" -eq 0 ]]; then
  echo "==> Repetition guard quiet-move check"
  (cd "$ROOT_DIR" && perl tests/regression_repetition_guard_quiet_move.pl)
  echo "==> Repetition guard jlPas6bb bishop-sac override check"
  (cd "$ROOT_DIR" && perl tests/regression_repetition_guard_jlpas6bb.pl)
  echo "==> Repetition guard black-side scoring check"
  (cd "$ROOT_DIR" && perl tests/regression_repetition_guard_black_side.pl)
else
  echo "==> Skipping repetition guard quiet-move check"
fi

if [[ "$SKIP_QSEARCH_IN_CHECK" -eq 0 ]]; then
  echo "==> Qsearch in-check mate/evasion guard"
  (cd "$ROOT_DIR" && perl tests/regression_qsearch_in_check.pl)
else
  echo "==> Skipping qsearch in-check mate/evasion guard"
fi

if [[ "$SKIP_SEARCH_REPETITION" -eq 0 ]]; then
  echo "==> Search repetition threefold-only guard"
  (cd "$ROOT_DIR" && perl tests/regression_search_threefold_only.pl)
else
  echo "==> Skipping search repetition threefold-only guard"
fi

if [[ "$SKIP_MODULE_UNIT" -eq 0 ]]; then
  echo "==> State core unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_state_core.pl)
  echo "==> Transposition table unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_transposition_table.pl)
  echo "==> Move picker unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_move_picker.pl)
  echo "==> Plan heuristics unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_plan_heuristics.pl)
  echo "==> Table util unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_table_util_core.pl)
  echo "==> Time manager unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_time_manager.pl)
  echo "==> Zobrist token unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_zobrist_tokens.pl)
  echo "==> Search root-stats unit guard"
  (cd "$ROOT_DIR" && perl tests/regression_search_root_stats.pl)
else
  echo "==> Skipping module-level unit guards"
fi

if [[ "$SKIP_EVAL_THREAT_PLAN" -eq 0 ]]; then
  echo "==> Eval threat/planning integration guard"
  (cd "$ROOT_DIR" && perl tests/regression_eval_threat_planning.pl)
else
  echo "==> Skipping eval threat/planning integration guard"
fi

if [[ "$SKIP_UNGUARDED_PLAN" -eq 0 ]]; then
  echo "==> Unguarded-material capture-plan check"
  (cd "$ROOT_DIR" && perl tests/regression_unguarded_material_plan.pl)
else
  echo "==> Skipping unguarded-material capture-plan check"
fi

if [[ "$SKIP_PROMO_CHECK" -eq 0 ]]; then
  echo "==> Promotion-with-check move-order check"
  (cd "$ROOT_DIR" && perl tests/regression_promotion_check.pl)
else
  echo "==> Skipping promotion-with-check move-order check"
fi

if [[ "$SKIP_XXGZ_REBUILD" -eq 0 ]]; then
  echo "==> xXgzD7zW state-rebuild guard"
  (cd "$ROOT_DIR" && perl tests/regression_xxgzd7zw_state_rebuild.pl)
else
  echo "==> Skipping xXgzD7zW state-rebuild guard"
fi

if [[ "$SKIP_PROTOCOL" -eq 0 ]]; then
  echo "==> UCI protocol contract guard"
  (cd "$ROOT_DIR" && perl tests/regression_uci_protocol.pl)
else
  echo "==> Skipping UCI protocol contract guard"
fi

if [[ "$SKIP_IMMEDIATE_STOP" -eq 0 ]]; then
  echo "==> UCI immediate-stop legal-bestmove guard"
  (cd "$ROOT_DIR" && perl tests/regression_uci_immediate_stop_legal.pl)
else
  echo "==> Skipping UCI immediate-stop legal-bestmove guard"
fi

if [[ "$SKIP_SEARCHMOVES" -eq 0 ]]; then
  echo "==> UCI searchmoves filter guard"
  (cd "$ROOT_DIR" && perl tests/regression_uci_searchmoves.pl)
else
  echo "==> Skipping UCI searchmoves filter guard"
fi

if [[ "$SKIP_R9GKSIYT" -eq 0 ]]; then
  echo "==> r9GKsIYt promotion/mate guard"
  (cd "$ROOT_DIR" && perl tests/regression_r9gksiyt_game.pl)
else
  echo "==> Skipping r9GKsIYt promotion/mate guard"
fi

if [[ "$SKIP_PERFT" -eq 0 ]]; then
  echo "==> Perft sanity depth $PERFT_DEPTH"
  (cd "$ROOT_DIR" && perl tests/perft.pl "$PERFT_DEPTH")
else
  echo "==> Skipping perft sanity"
fi

echo "==> Regression suite complete"
