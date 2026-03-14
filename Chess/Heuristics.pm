package Chess::Heuristics;
use strict;
use warnings;

use Exporter qw(import);
use Chess::Constant;

use constant LOCATION_WEIGHT => 0.18; # Eval mix weight for piece-square table term; [FIXED VALUE].
use constant QUIESCE_MAX_DEPTH => 6; # Max quiescence recursion depth; [FIXED VALUE].
use constant QUIESCE_CHECK_MAX_DEPTH => 2; # Quiescence check extension depth cap; min=1 max=4.
use constant QUIESCE_CHECK_BONUS => 128; # Move-order bonus for checking moves in quiescence; min=40 max=260.
use constant INF_SCORE => 1_000_000; # Search infinity sentinel score; [FIXED VALUE].
use constant MATE_SCORE => 900_000; # Mate score base used in negamax bounds; [FIXED VALUE].
use constant ASPIRATION_WINDOW => 18; # Aspiration half-window around prior score; min=12 max=80.
use constant TT_FLAG_EXACT => 0; # Transposition-table exact bound marker; [FIXED VALUE].
use constant TT_FLAG_LOWER => 1; # Transposition-table lower-bound marker; [FIXED VALUE].
use constant TT_FLAG_UPPER => 2; # Transposition-table upper-bound marker; [FIXED VALUE].
use constant SCORE_STABILITY_DELTA => 1; # Eval swing tolerated before marking unstable; min=1 max=8.
use constant EXTRA_DEPTH_ON_UNSTABLE => 7; # Extra iterative depth for unstable PV/score; min=1 max=10.
use constant TIME_CHECK_INTERVAL_NODES => 2048; # Node interval between soft/hard time checks; [FIXED VALUE].
use constant TIME_DEFAULT_HORIZON => 34; # Default moves-to-go horizon for time budgeting; [FIXED VALUE].
use constant TIME_INC_WEIGHT => 0.75; # Increment contribution weight in budget calculation; [FIXED VALUE].
use constant TIME_RESERVE_MS => 800; # Reserved milliseconds kept back under normal play; [FIXED VALUE].
use constant TIME_MOVE_OVERHEAD_MS => 100; # Per-move overhead subtracted from available clock; [FIXED VALUE].
use constant TIME_MIN_BUDGET_MS => 20; # Minimum soft budget for a move; [FIXED VALUE].
use constant TIME_HARD_SCALE => 1.5; # Hard deadline multiplier over soft budget; [FIXED VALUE].
use constant TIME_MOVETIME_HARD_SCALE => 1.25; # Hard deadline scale when explicit movetime is set; [FIXED VALUE].
use constant TIME_MOVETIME_HARD_CAP_MS => 1200; # Max hard-cap add-on for explicit movetime; [FIXED VALUE].
use constant TIME_MAX_SHARE => 0.60; # Max share of usable clock for one move; [FIXED VALUE].
use constant MID_ENDGAME_TIME_MAX_SHARE => 0.70; # Max clock share in lighter middlegame/endgame; [FIXED VALUE].
use constant DEEP_ENDGAME_TIME_MAX_SHARE => 0.76; # Max clock share in deep endgames; [FIXED VALUE].
use constant MID_ENDGAME_HORIZON_REDUCTION => 8; # Horizon reduction in middlegame/endgame profile; [FIXED VALUE].
use constant DEEP_ENDGAME_HORIZON_REDUCTION => 12; # Extra horizon reduction in deep-endgame profile; [FIXED VALUE].
use constant TIME_EMERGENCY_MS => 1500; # Emergency threshold to switch to low-time profile; [FIXED VALUE].
use constant QUIESCE_EMERGENCY_MAX_DEPTH => 2; # Quiescence depth cap in emergency mode; [FIXED VALUE].
use constant TIME_PANIC_60S_MS => 60_000; # Panic profile threshold at 60 seconds; [FIXED VALUE].
use constant TIME_PANIC_30S_MS => 30_000; # Panic profile threshold at 30 seconds; [FIXED VALUE].
use constant TIME_PANIC_10S_MS => 10_000; # Panic profile threshold at 10 seconds; [FIXED VALUE].
use constant TIME_PANIC_60S_RESERVE_PCT => 0.14; # Reserve percent in 60s panic band; [FIXED VALUE].
use constant TIME_PANIC_30S_RESERVE_PCT => 0.20; # Reserve percent in 30s panic band; [FIXED VALUE].
use constant TIME_PANIC_10S_RESERVE_PCT => 0.30; # Reserve percent in 10s panic band; [FIXED VALUE].
use constant TIME_PANIC_60S_MIN_HORIZON => 56; # Minimum horizon under 60s panic profile; [FIXED VALUE].
use constant TIME_PANIC_30S_MIN_HORIZON => 80; # Minimum horizon under 30s panic profile; [FIXED VALUE].
use constant TIME_PANIC_10S_MIN_HORIZON => 112; # Minimum horizon under 10s panic profile; [FIXED VALUE].
use constant TIME_PANIC_60S_BUDGET_SHARE => 0.08; # Clock-share cap in 60s panic profile; [FIXED VALUE].
use constant TIME_PANIC_30S_BUDGET_SHARE => 0.055; # Clock-share cap in 30s panic profile; [FIXED VALUE].
use constant TIME_PANIC_10S_BUDGET_SHARE => 0.03; # Clock-share cap in 10s panic profile; [FIXED VALUE].
use constant TIME_PANIC_60S_INC_WEIGHT => 0.32; # Increment weight in 60s panic profile; [FIXED VALUE].
use constant TIME_PANIC_30S_INC_WEIGHT => 0.24; # Increment weight in 30s panic profile; [FIXED VALUE].
use constant TIME_PANIC_10S_INC_WEIGHT => 0.15; # Increment weight in 10s panic profile; [FIXED VALUE].
use constant TIME_PANIC_60S_HARD_SCALE => 1.25; # Hard deadline multiplier in 60s panic profile; [FIXED VALUE].
use constant TIME_PANIC_30S_HARD_SCALE => 1.18; # Hard deadline multiplier in 30s panic profile; [FIXED VALUE].
use constant TIME_PANIC_10S_HARD_SCALE => 1.10; # Hard deadline multiplier in 10s panic profile; [FIXED VALUE].
use constant TIME_PANIC_60S_QUIESCE_MAX_DEPTH => 2; # Quiescence depth cap in 60s panic profile; [FIXED VALUE].
use constant TIME_PANIC_30S_QUIESCE_MAX_DEPTH => 1; # Quiescence depth cap in 30s panic profile; [FIXED VALUE].
use constant TIME_PANIC_10S_QUIESCE_MAX_DEPTH => 1; # Quiescence depth cap in 10s panic profile; [FIXED VALUE].
use constant TT_MAX_ENTRIES => 200_000; # Maximum transposition-table entries; [FIXED VALUE].
use constant TT_CLUSTER_SIZE => 4; # Entries per TT bucket cluster; [FIXED VALUE].
use constant TT_REPLACE_AGE_WEIGHT => 2; # Replacement bias toward newer TT entries; [FIXED VALUE].
use constant HISTORY_DECAY_FACTOR => 0.85; # Decay factor for history heuristic scores; [FIXED VALUE].
use constant HISTORY_RENORM_MIN_SCALE => 0.02; # Lower scale threshold for history renormalization; [FIXED VALUE].
use constant COUNTERMOVE_BONUS => 220; # Move-order bonus for learned countermoves; min=80 max=320.
use constant EASY_MOVE_MIN_DEPTH => 4; # Earliest depth where easy-move early-exit is considered; [FIXED VALUE].
use constant EASY_MOVE_DEPTH_CAP => 5; # Depth cap for easy-move shortcut logic; [FIXED VALUE].
use constant MID_ENDGAME_PIECE_THRESHOLD => 16; # Piece-count threshold for middlegame/endgame logic; [FIXED VALUE].
use constant DEEP_ENDGAME_PIECE_THRESHOLD => 10; # Piece-count threshold for deep-endgame logic; [FIXED VALUE].
use constant MID_ENDGAME_DEPTH_BOOST => 1; # Added depth in middlegame/endgame; [FIXED VALUE].
use constant DEEP_ENDGAME_DEPTH_BOOST => 2; # Added depth in deep endgames; [FIXED VALUE].
use constant MID_ENDGAME_EASY_MOVE_EXTRA_DEPTH => 2; # Extra depth before easy-move exit on lighter boards; [FIXED VALUE].
use constant OPENING_PIECE_COUNT_THRESHOLD => 26; # Piece-count threshold for opening discipline heuristics; [FIXED VALUE].
use constant OPENING_DEVELOPMENT_EXTRA_PENALTY => 1; # Extra opening development lag penalty unit; [FIXED VALUE].
use constant MIDDLEGAME_MIN_PIECE_COUNT => 18; # Lower piece-count bound for middlegame classification; [FIXED VALUE].
use constant MIDDLEGAME_MAX_PIECE_COUNT => 28; # Upper piece-count bound for middlegame classification; [FIXED VALUE].
use constant PAWN_CANDIDATE_MIN_BUDGET_MS => 120; # Minimum budget for pawn-candidate time extension; [FIXED VALUE].
use constant PAWN_CANDIDATE_EXTRA_TIME_SHARE => 0.08; # Budget share used for pawn-candidate extension; [FIXED VALUE].
use constant PAWN_CANDIDATE_EXTRA_TIME_MAX_MS => 180; # Max milliseconds added for pawn-candidate extension; [FIXED VALUE].
use constant SAC_MOVE_ORDER_PENALTY => 68; # Move-order penalty for speculative piece-for-pawn sac candidates; min=0 max=220.
use constant SAC_SCORE_DROP_CP => 259; # Score-drop threshold used to scrutinize sac candidates; [FIXED VALUE].
use constant SAC_CANDIDATE_MIN_BUDGET_MS => 140; # Minimum budget before extending time on sac candidates; [FIXED VALUE].
use constant SAC_EXTRA_TIME_SHARE => 0.10; # Budget share used for sac-candidate extension; [FIXED VALUE].
use constant SAC_EXTRA_TIME_MAX_MS => 260; # Max milliseconds added for sac-candidate extension; [FIXED VALUE].
use constant ROOT_NEAR_TIE_DELTA => 10; # Root score gap considered a near tie; [FIXED VALUE].
use constant ROOT_CLEAR_BEST_DELTA => 24; # Root score gap considered a clear best; [FIXED VALUE].
use constant ROOT_SCORE_DROP_THRESHOLD_CP => 45; # Root candidate score-drop threshold before applying a regression penalty; min=10 max=180.
use constant ROOT_SCORE_DROP_PENALTY_SCALE => 0.45; # Penalty scale applied to root candidates whose score collapses between iterations; min=0.1 max=1.5.
use constant ROOT_SCORE_DROP_MAX_PENALTY_CP => 120; # Max root regression penalty applied to a collapsing candidate line; min=20 max=300.
use constant ROOT_SCORE_DROP_MIN_DEPTH => 4; # Minimum iterative depth before root regression penalties activate; min=2 max=10.
use constant DEVELOPMENT_MINOR_PENALTY => 4; # Opening penalty per undeveloped minor piece; min=1 max=10.
use constant EARLY_ROOK_MOVE_PENALTY => 3; # Opening penalty for early rook moves; min=1 max=10.
use constant EARLY_QUEEN_MOVE_PENALTY => 6; # Opening penalty for early queen sorties; min=1 max=14.
use constant UNCASTLED_KING_PENALTY => 8; # Penalty for remaining uncastled; min=2 max=14.
use constant CENTRAL_KING_PENALTY => 3; # Penalty for central king exposure before castling; [FIXED VALUE].
use constant EARLY_KING_WALK_HOME_PENALTY => 3; # Penalty for early king movement off home square; [FIXED VALUE].
use constant EARLY_KING_WALK_EXPOSED_FILE_PENALTY => 1; # Extra penalty for early king on exposed files; [FIXED VALUE].
use constant EARLY_KING_WALK_CENTRAL_FILE_PENALTY => 2; # Extra penalty for early king on central files; [FIXED VALUE].
use constant EARLY_KING_WALK_ADVANCED_RANK_PENALTY => 2; # Extra penalty for early king on advanced ranks; [FIXED VALUE].
use constant HANGING_DEFENDED_SCALE => 0.5; # Retained hanging penalty multiplier when defended; min=0.1 max=0.85.
use constant HANGING_MOVE_GUARD_BONUS => 26; # Extra penalty for quiet moves leaving loose material; min=6 max=40.
use constant LMR_KING_DANGER_THRESHOLD => 4; # Disable/reduce LMR when king danger reaches this level; min=4 max=24.
use constant LMP_MAX_DEPTH => 6; # Max depth where late-move pruning can skip quiet tail moves; min=3 max=10.
use constant LMP_BASE_MOVES => 4; # Base quiet-move count searched before enabling LMP tail skips; min=2 max=10.
use constant LMP_DEPTH_FACTOR => 3; # Additional LMP allowance per depth; min=1 max=8.
use constant NULL_MOVE_MIN_DEPTH => 3; # Minimum depth required for null-move pruning; [FIXED VALUE].
use constant NULL_MOVE_REDUCTION => 2; # Base depth reduction for null-move pruning; [FIXED VALUE].
use constant NULL_MOVE_DEEP_DEPTH => 7; # Depth where null-move applies extra reduction; [FIXED VALUE].
use constant NULL_MOVE_MATE_GUARD => 1500; # Guard band preventing null-move near mate scores; [FIXED VALUE].
use constant STATIC_NULL_PRUNE_MAX_DEPTH => 6; # Max depth for static null-move pruning shortcut; min=3 max=10.
use constant STATIC_NULL_PRUNE_MARGIN_BASE => 120; # Base margin for static null-move pruning vs beta; min=40 max=260.
use constant STATIC_NULL_PRUNE_MARGIN_PER_DEPTH => 70; # Per-depth margin added for static null-move pruning; min=20 max=140.
use constant RFP_MAX_DEPTH => 5; # Max depth for reverse futility pruning; min=2 max=8.
use constant RFP_MARGIN_BASE => 75; # Base reverse-futility margin; min=20 max=180.
use constant RFP_MARGIN_PER_DEPTH => 55; # Per-depth reverse-futility margin; min=15 max=120.
use constant IID_MIN_DEPTH => 6; # Minimum depth to trigger internal iterative deepening; min=4 max=12.
use constant IID_REDUCTION => 2; # Depth reduction used by IID probe search; min=1 max=4.
use constant UNSAFE_CAPTURE_HANGING_BONUS => 74; # Capture-risk penalty for exposing hanging pieces; min=8 max=96.
use constant UNSAFE_CAPTURE_DEFENDED_SCALE => 0.68; # Capture-risk retention when target square is defended; min=0.2 max=0.9.
use constant UNSAFE_CAPTURE_KING_EXPOSURE_WEIGHT => 10; # Extra capture-risk weight for king exposure; min=1 max=14.
use constant KING_DANGER_RING_ATTACK_PENALTY => 5; # Penalty per attacked king-ring square; min=1 max=12.
use constant KING_DANGER_RING_UNDEFENDED_PENALTY => 2; # Extra ring penalty for attacked but undefended king-ring squares; min=1 max=10.
use constant KING_DANGER_CHECK_PENALTY => 22; # Penalty for check/forcing-check danger; min=4 max=36.
use constant KING_DANGER_SHIELD_MISSING_PENALTY => 3; # Penalty for missing pawn shield near king; min=1 max=10.
use constant KING_DANGER_OPEN_FILE_PENALTY => 3; # Penalty for open file in front of king; min=1 max=8.
use constant KING_DANGER_ADJ_FILE_PENALTY => 2; # Penalty for open adjacent king files; min=1 max=6.
use constant KING_AGGRESSION_ENEMY_PIECE_START => 10; # Enemy material threshold to enable king aggression scoring; [FIXED VALUE].
use constant KING_AGGRESSION_RANK_BONUS => 4; # Rank-scaling factor for active king bonus; [FIXED VALUE].
use constant UNGUARDED_TARGET_VALUE_MARGIN => 8; # Capture-ordering viability margin for loose targets; [FIXED VALUE].
use constant UNGUARDED_CAPTURE_ORDER_BONUS => 85; # Move-order bonus for captures on loose targets; [FIXED VALUE].
use constant UNGUARDED_CAPTURE_VIABLE_ORDER_BONUS => 45; # Extra move-order bonus when exchange looks favorable; [FIXED VALUE].
use constant KING_SHUFFLE_MIDGAME_MIN_PIECES => 18; # Min material before king-shuffle ordering penalty applies; [FIXED VALUE].
use constant KING_SHUFFLE_ORDER_PENALTY => 160; # Move-order penalty for aimless king shuffles; [FIXED VALUE].
use constant PROMOTION_CHECK_ORDER_BONUS => 220; # Move-order bonus for checking promotions; [FIXED VALUE].
use constant SEE_ORDER_WEIGHT => 1; # Weight of SEE term in move ordering; [FIXED VALUE].
use constant SEE_BAD_CAPTURE_THRESHOLD => 0; # SEE threshold classifying captures as bad; [FIXED VALUE].
use constant SEE_PRUNE_THRESHOLD => -30; # SEE threshold used to prune clearly losing captures; [FIXED VALUE].
use constant QUIESCE_SEE_PRUNE_THRESHOLD => -45; # SEE threshold for pruning clearly losing quiescence captures; min=-120 max=0.
use constant MAX_ROOT_WORKERS => 64; # Maximum parallel root workers supported; [FIXED VALUE].
use constant MAX_MULTIPV => 16; # Maximum MultiPV lines supported; [FIXED VALUE].
use constant EVAL_CACHE_MAX_ENTRIES => 200_000; # Eval-cache size limit before reset; [FIXED VALUE].
use constant PASSED_PAWN_BONUS_BY_RANK => [0, 0, 0, 2, 4, 7, 11, 16, 0]; # Passed-pawn bonus table by rank index; [FIXED VALUE].
use constant ENEMY_PASSED_PAWN_PENALTY_BY_RANK => [0, 0, 17, 12, 8, 5, 3, 2, 0]; # Enemy passed-pawn penalty table by rank index; [FIXED VALUE].
use constant PAWN_ISOLATED_PENALTY => 4; # Penalty for isolated pawns lacking neighboring pawn support; min=1 max=10.
use constant PAWN_DOUBLED_PENALTY => 3; # Penalty for doubled pawns on the same file; min=1 max=10.
use constant PAWN_CONNECTED_BONUS => 2; # Bonus for connected pawns supporting each other; min=0 max=8.
use constant PAWN_CANDIDATE_BONUS => 3; # Bonus for candidate passers with clear advance potential; min=0 max=10.
use constant PAWN_ISLAND_PENALTY => 2; # Penalty per extra pawn island beyond the first; min=0 max=6.
use constant KNIGHT_MOBILITY_BONUS => 1; # Bonus per safe knight mobility square; min=0 max=4.
use constant BISHOP_MOBILITY_BONUS => 1; # Bonus per bishop mobility square; min=0 max=4.
use constant ROOK_MOBILITY_BONUS => 1; # Bonus per rook mobility square; min=0 max=4.
use constant QUEEN_MOBILITY_BONUS => 1; # Bonus per queen mobility square; min=0 max=3.
use constant BISHOP_PAIR_BONUS => 8; # Bonus for owning the bishop pair; min=0 max=20.
use constant KNIGHT_OUTPOST_BONUS => 5; # Bonus for a protected knight outpost that enemy pawns cannot chase; min=0 max=16.
use constant ROOK_OPEN_FILE_BONUS => 6; # Bonus for rooks on fully open files; min=0 max=16.
use constant ROOK_SEMIOPEN_FILE_BONUS => 3; # Bonus for rooks on semi-open files; min=0 max=12.
use constant ROOK_SEVENTH_RANK_BONUS => 4; # Bonus for active rooks on the seventh rank; min=0 max=12.
use constant THREAT_ATTACK_BONUS => 4; # Bonus for safe attacks on loose or weakly defended enemy pieces; min=0 max=16.
use constant THREAT_SAFE_CHECK_BONUS => 8; # Bonus for safe checking pressure in the static evaluation; min=0 max=24.
use constant KING_DANGER_ATTACK_UNIT_PENALTY => 2; # Extra king-danger penalty per quality attacking unit near the king; min=0 max=8.
use constant ENDGAME_KING_CENTER_BONUS => 2; # Endgame bonus for centralizing the king; min=0 max=8.
use constant ENDGAME_PASSED_PAWN_BONUS => 3; # Endgame bonus for supporting our advanced passers / restraining enemy ones; min=0 max=12.
use constant HANGING_PIECE_PENALTY => {
  KNIGHT() => 6, # Piece-specific hanging penalty for knights; [FIXED VALUE].
  BISHOP() => 6, # Piece-specific hanging penalty for bishops; [FIXED VALUE].
  ROOK() => 10, # Piece-specific hanging penalty for rooks; [FIXED VALUE].
  QUEEN() => 18, # Piece-specific hanging penalty for queens; [FIXED VALUE].
};
use constant TIME_POLICY => {
  default_horizon => TIME_DEFAULT_HORIZON,
  inc_weight => TIME_INC_WEIGHT,
  reserve_ms => TIME_RESERVE_MS,
  move_overhead_ms => TIME_MOVE_OVERHEAD_MS,
  min_budget_ms => TIME_MIN_BUDGET_MS,
  hard_scale => TIME_HARD_SCALE,
  movetime_hard_scale => TIME_MOVETIME_HARD_SCALE,
  movetime_hard_cap_ms => TIME_MOVETIME_HARD_CAP_MS,
  max_share => TIME_MAX_SHARE,
};
use constant TIME_PANIC_POLICY => {
  '60s' => {
    threshold_ms => TIME_PANIC_60S_MS,
    reserve_pct => TIME_PANIC_60S_RESERVE_PCT,
    min_horizon => TIME_PANIC_60S_MIN_HORIZON,
    budget_share => TIME_PANIC_60S_BUDGET_SHARE,
    inc_weight => TIME_PANIC_60S_INC_WEIGHT,
    hard_scale => TIME_PANIC_60S_HARD_SCALE,
    quiesce_max_depth => TIME_PANIC_60S_QUIESCE_MAX_DEPTH,
  },
  '30s' => {
    threshold_ms => TIME_PANIC_30S_MS,
    reserve_pct => TIME_PANIC_30S_RESERVE_PCT,
    min_horizon => TIME_PANIC_30S_MIN_HORIZON,
    budget_share => TIME_PANIC_30S_BUDGET_SHARE,
    inc_weight => TIME_PANIC_30S_INC_WEIGHT,
    hard_scale => TIME_PANIC_30S_HARD_SCALE,
    quiesce_max_depth => TIME_PANIC_30S_QUIESCE_MAX_DEPTH,
  },
  '10s' => {
    threshold_ms => TIME_PANIC_10S_MS,
    reserve_pct => TIME_PANIC_10S_RESERVE_PCT,
    min_horizon => TIME_PANIC_10S_MIN_HORIZON,
    budget_share => TIME_PANIC_10S_BUDGET_SHARE,
    inc_weight => TIME_PANIC_10S_INC_WEIGHT,
    hard_scale => TIME_PANIC_10S_HARD_SCALE,
    quiesce_max_depth => TIME_PANIC_10S_QUIESCE_MAX_DEPTH,
  },
};
use constant SEARCH_POLICY => {
  aspiration_window => ASPIRATION_WINDOW,
  score_stability_delta => SCORE_STABILITY_DELTA,
  extra_depth_on_unstable => EXTRA_DEPTH_ON_UNSTABLE,
  easy_move_min_depth => EASY_MOVE_MIN_DEPTH,
  easy_move_depth_cap => EASY_MOVE_DEPTH_CAP,
  null_move_min_depth => NULL_MOVE_MIN_DEPTH,
  null_move_reduction => NULL_MOVE_REDUCTION,
  null_move_deep_depth => NULL_MOVE_DEEP_DEPTH,
};
use constant ROOT_POLICY => {
  near_tie_delta => ROOT_NEAR_TIE_DELTA,
  clear_best_delta => ROOT_CLEAR_BEST_DELTA,
  max_workers => MAX_ROOT_WORKERS,
  max_multipv => MAX_MULTIPV,
};

our @ENGINE_EXPORTS = qw(
  LOCATION_WEIGHT
  QUIESCE_MAX_DEPTH
  QUIESCE_CHECK_MAX_DEPTH
  QUIESCE_CHECK_BONUS
  INF_SCORE
  MATE_SCORE
  ASPIRATION_WINDOW
  TT_FLAG_EXACT
  TT_FLAG_LOWER
  TT_FLAG_UPPER
  SCORE_STABILITY_DELTA
  EXTRA_DEPTH_ON_UNSTABLE
  TIME_CHECK_INTERVAL_NODES
  TIME_DEFAULT_HORIZON
  TIME_INC_WEIGHT
  TIME_RESERVE_MS
  TIME_MOVE_OVERHEAD_MS
  TIME_MIN_BUDGET_MS
  TIME_HARD_SCALE
  TIME_MOVETIME_HARD_SCALE
  TIME_MOVETIME_HARD_CAP_MS
  TIME_MAX_SHARE
  MID_ENDGAME_TIME_MAX_SHARE
  DEEP_ENDGAME_TIME_MAX_SHARE
  MID_ENDGAME_HORIZON_REDUCTION
  DEEP_ENDGAME_HORIZON_REDUCTION
  TIME_EMERGENCY_MS
  QUIESCE_EMERGENCY_MAX_DEPTH
  TIME_PANIC_60S_MS
  TIME_PANIC_30S_MS
  TIME_PANIC_10S_MS
  TIME_PANIC_60S_RESERVE_PCT
  TIME_PANIC_30S_RESERVE_PCT
  TIME_PANIC_10S_RESERVE_PCT
  TIME_PANIC_60S_MIN_HORIZON
  TIME_PANIC_30S_MIN_HORIZON
  TIME_PANIC_10S_MIN_HORIZON
  TIME_PANIC_60S_BUDGET_SHARE
  TIME_PANIC_30S_BUDGET_SHARE
  TIME_PANIC_10S_BUDGET_SHARE
  TIME_PANIC_60S_INC_WEIGHT
  TIME_PANIC_30S_INC_WEIGHT
  TIME_PANIC_10S_INC_WEIGHT
  TIME_PANIC_60S_HARD_SCALE
  TIME_PANIC_30S_HARD_SCALE
  TIME_PANIC_10S_HARD_SCALE
  TIME_PANIC_60S_QUIESCE_MAX_DEPTH
  TIME_PANIC_30S_QUIESCE_MAX_DEPTH
  TIME_PANIC_10S_QUIESCE_MAX_DEPTH
  TT_MAX_ENTRIES
  TT_CLUSTER_SIZE
  TT_REPLACE_AGE_WEIGHT
  HISTORY_DECAY_FACTOR
  HISTORY_RENORM_MIN_SCALE
  COUNTERMOVE_BONUS
  EASY_MOVE_MIN_DEPTH
  EASY_MOVE_DEPTH_CAP
  MID_ENDGAME_PIECE_THRESHOLD
  DEEP_ENDGAME_PIECE_THRESHOLD
  MID_ENDGAME_DEPTH_BOOST
  DEEP_ENDGAME_DEPTH_BOOST
  MID_ENDGAME_EASY_MOVE_EXTRA_DEPTH
  OPENING_PIECE_COUNT_THRESHOLD
  OPENING_DEVELOPMENT_EXTRA_PENALTY
  MIDDLEGAME_MIN_PIECE_COUNT
  MIDDLEGAME_MAX_PIECE_COUNT
  PAWN_CANDIDATE_MIN_BUDGET_MS
  PAWN_CANDIDATE_EXTRA_TIME_SHARE
  PAWN_CANDIDATE_EXTRA_TIME_MAX_MS
  SAC_MOVE_ORDER_PENALTY
  SAC_SCORE_DROP_CP
  SAC_CANDIDATE_MIN_BUDGET_MS
  SAC_EXTRA_TIME_SHARE
  SAC_EXTRA_TIME_MAX_MS
  ROOT_NEAR_TIE_DELTA
  ROOT_CLEAR_BEST_DELTA
  ROOT_SCORE_DROP_THRESHOLD_CP
  ROOT_SCORE_DROP_PENALTY_SCALE
  ROOT_SCORE_DROP_MAX_PENALTY_CP
  ROOT_SCORE_DROP_MIN_DEPTH
  DEVELOPMENT_MINOR_PENALTY
  EARLY_ROOK_MOVE_PENALTY
  EARLY_QUEEN_MOVE_PENALTY
  UNCASTLED_KING_PENALTY
  CENTRAL_KING_PENALTY
  EARLY_KING_WALK_HOME_PENALTY
  EARLY_KING_WALK_EXPOSED_FILE_PENALTY
  EARLY_KING_WALK_CENTRAL_FILE_PENALTY
  EARLY_KING_WALK_ADVANCED_RANK_PENALTY
  HANGING_DEFENDED_SCALE
  HANGING_MOVE_GUARD_BONUS
  LMR_KING_DANGER_THRESHOLD
  LMP_MAX_DEPTH
  LMP_BASE_MOVES
  LMP_DEPTH_FACTOR
  NULL_MOVE_MIN_DEPTH
  NULL_MOVE_REDUCTION
  NULL_MOVE_DEEP_DEPTH
  NULL_MOVE_MATE_GUARD
  STATIC_NULL_PRUNE_MAX_DEPTH
  STATIC_NULL_PRUNE_MARGIN_BASE
  STATIC_NULL_PRUNE_MARGIN_PER_DEPTH
  RFP_MAX_DEPTH
  RFP_MARGIN_BASE
  RFP_MARGIN_PER_DEPTH
  IID_MIN_DEPTH
  IID_REDUCTION
  UNSAFE_CAPTURE_HANGING_BONUS
  UNSAFE_CAPTURE_DEFENDED_SCALE
  UNSAFE_CAPTURE_KING_EXPOSURE_WEIGHT
  KING_DANGER_RING_ATTACK_PENALTY
  KING_DANGER_RING_UNDEFENDED_PENALTY
  KING_DANGER_CHECK_PENALTY
  KING_DANGER_SHIELD_MISSING_PENALTY
  KING_DANGER_OPEN_FILE_PENALTY
  KING_DANGER_ADJ_FILE_PENALTY
  KING_AGGRESSION_ENEMY_PIECE_START
  KING_AGGRESSION_RANK_BONUS
  UNGUARDED_TARGET_VALUE_MARGIN
  UNGUARDED_CAPTURE_ORDER_BONUS
  UNGUARDED_CAPTURE_VIABLE_ORDER_BONUS
  KING_SHUFFLE_MIDGAME_MIN_PIECES
  KING_SHUFFLE_ORDER_PENALTY
  PROMOTION_CHECK_ORDER_BONUS
  SEE_ORDER_WEIGHT
  SEE_BAD_CAPTURE_THRESHOLD
  SEE_PRUNE_THRESHOLD
  QUIESCE_SEE_PRUNE_THRESHOLD
  MAX_ROOT_WORKERS
  MAX_MULTIPV
  EVAL_CACHE_MAX_ENTRIES
  PASSED_PAWN_BONUS_BY_RANK
  ENEMY_PASSED_PAWN_PENALTY_BY_RANK
  PAWN_ISOLATED_PENALTY
  PAWN_DOUBLED_PENALTY
  PAWN_CONNECTED_BONUS
  PAWN_CANDIDATE_BONUS
  PAWN_ISLAND_PENALTY
  KNIGHT_MOBILITY_BONUS
  BISHOP_MOBILITY_BONUS
  ROOK_MOBILITY_BONUS
  QUEEN_MOBILITY_BONUS
  BISHOP_PAIR_BONUS
  KNIGHT_OUTPOST_BONUS
  ROOK_OPEN_FILE_BONUS
  ROOK_SEMIOPEN_FILE_BONUS
  ROOK_SEVENTH_RANK_BONUS
  THREAT_ATTACK_BONUS
  THREAT_SAFE_CHECK_BONUS
  KING_DANGER_ATTACK_UNIT_PENALTY
  ENDGAME_KING_CENTER_BONUS
  ENDGAME_PASSED_PAWN_BONUS
  HANGING_PIECE_PENALTY
  TIME_POLICY
  TIME_PANIC_POLICY
  SEARCH_POLICY
  ROOT_POLICY
);

our @EXPORT_OK = @ENGINE_EXPORTS;
our %EXPORT_TAGS = (
  engine => \@ENGINE_EXPORTS,
);

1;
