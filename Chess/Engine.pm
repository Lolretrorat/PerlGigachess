package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::LocationModifer qw(%location_modifiers);
use Chess::EndgameTable;
use Chess::TableUtil qw(canonical_fen_key idx_to_square board_indices);

use Chess::Book;

use List::Util qw(max min);
use Time::HiRes qw(time);

use constant LOCATION_WEIGHT => 0.22;                  # Higher => piece-square tables influence eval more.
use constant QUIESCE_MAX_DEPTH => 6;                   # Higher => deeper quiescence (more tactics, more time).
use constant QUIESCE_CHECK_MAX_DEPTH => 1;             # Higher => include checking moves deeper in quiescence.
use constant QUIESCE_CHECK_BONUS => 128;               # Higher => checks are searched earlier inside quiescence.
use constant INF_SCORE => 1_000_000;                   # Search sentinel bound; should stay above any real eval.
use constant MATE_SCORE => 900_000;                    # Higher => mate threats dominate eval more strongly.
use constant ASPIRATION_WINDOW => 24;                  # Higher => fewer re-searches, but less pruning focus.
use constant TT_FLAG_EXACT => 0;                       # TT exact-score entry type marker.
use constant TT_FLAG_LOWER => 1;                       # TT lower-bound entry type marker (fail-high).
use constant TT_FLAG_UPPER => 2;                       # TT upper-bound entry type marker (fail-low).
use constant SCORE_STABILITY_DELTA => 2;               # Higher => engine treats score shifts as "stable" more easily.
use constant EXTRA_DEPTH_ON_UNSTABLE => 6;             # Higher => search extends more when PV/score is volatile.
use constant TIME_CHECK_INTERVAL_NODES => 2048;        # Lower => checks clock more often, with extra overhead.
use constant TIME_DEFAULT_HORIZON => 34;               # Higher => spreads clock over more future moves (safer).
use constant TIME_INC_WEIGHT => 0.75;                  # Higher => increment contributes more to per-move budget.
use constant TIME_RESERVE_MS => 800;                   # Higher => keeps more clock in reserve for later moves.
use constant TIME_MOVE_OVERHEAD_MS => 100;             # Higher => subtracts more fixed overhead from think time.
use constant TIME_MIN_BUDGET_MS => 20;                 # Higher => guarantees longer minimum think per move.
use constant TIME_HARD_SCALE => 1.5;                   # Higher => hard cutoff sits farther past soft deadline.
use constant TIME_MAX_SHARE => 0.60;                   # Higher => allowed to spend larger share of usable time.
use constant MID_ENDGAME_TIME_MAX_SHARE => 0.70;       # Higher => more aggressive clock use in lighter middlegames.
use constant DEEP_ENDGAME_TIME_MAX_SHARE => 0.76;      # Higher => more aggressive clock use in deep endgames.
use constant MID_ENDGAME_HORIZON_REDUCTION => 8;       # Higher => assumes fewer moves left in middlegame/endgame.
use constant DEEP_ENDGAME_HORIZON_REDUCTION => 12;     # Higher => assumes much fewer moves left in deep endgames.
use constant TIME_EMERGENCY_MS => 1500;                # Higher => enters emergency time-saving mode earlier.
use constant QUIESCE_EMERGENCY_MAX_DEPTH => 2;         # Lower => cuts tactical depth more when low on time.
use constant TIME_PANIC_60S_MS => 60_000;              # Remaining clock threshold for first panic profile.
use constant TIME_PANIC_30S_MS => 30_000;              # Remaining clock threshold for second panic profile.
use constant TIME_PANIC_10S_MS => 10_000;              # Remaining clock threshold for final panic profile.
use constant TIME_PANIC_60S_RESERVE_PCT => 0.14;       # Reserve share below 60s to avoid flagging.
use constant TIME_PANIC_30S_RESERVE_PCT => 0.20;       # Reserve share below 30s to avoid flagging.
use constant TIME_PANIC_10S_RESERVE_PCT => 0.30;       # Reserve share below 10s to avoid flagging.
use constant TIME_PANIC_60S_MIN_HORIZON => 56;         # Minimum move horizon below 60s.
use constant TIME_PANIC_30S_MIN_HORIZON => 80;         # Minimum move horizon below 30s.
use constant TIME_PANIC_10S_MIN_HORIZON => 112;        # Minimum move horizon below 10s.
use constant TIME_PANIC_60S_BUDGET_SHARE => 0.08;      # Soft budget cap share of remaining clock below 60s.
use constant TIME_PANIC_30S_BUDGET_SHARE => 0.055;     # Soft budget cap share of remaining clock below 30s.
use constant TIME_PANIC_10S_BUDGET_SHARE => 0.03;      # Soft budget cap share of remaining clock below 10s.
use constant TIME_PANIC_60S_INC_WEIGHT => 0.32;        # Increment contribution below 60s.
use constant TIME_PANIC_30S_INC_WEIGHT => 0.24;        # Increment contribution below 30s.
use constant TIME_PANIC_10S_INC_WEIGHT => 0.15;        # Increment contribution below 10s.
use constant TIME_PANIC_60S_HARD_SCALE => 1.25;        # Hard-deadline scale below 60s.
use constant TIME_PANIC_30S_HARD_SCALE => 1.18;        # Hard-deadline scale below 30s.
use constant TIME_PANIC_10S_HARD_SCALE => 1.10;        # Hard-deadline scale below 10s.
use constant TIME_PANIC_60S_QUIESCE_MAX_DEPTH => 2;    # Quiesce depth cap below 60s.
use constant TIME_PANIC_30S_QUIESCE_MAX_DEPTH => 1;    # Quiesce depth cap below 30s.
use constant TIME_PANIC_10S_QUIESCE_MAX_DEPTH => 1;    # Quiesce depth cap below 10s.
use constant TT_MAX_ENTRIES => 200_000;                # Higher => larger TT memory footprint, fewer evictions.
use constant TT_TRIM_TARGET_FILL => 0.85;              # Lower => trim deeper when TT is over capacity.
use constant TT_TRIM_SCAN_BASE => 1024;                # Higher => samples more TT entries per trim call.
use constant TT_TRIM_SCAN_PER_EVICTION => 8;           # Higher => samples more TT entries per needed eviction.
use constant TT_TRIM_SCAN_MAX => 8192;                 # Higher => upper bound for sampled TT entries per trim.
use constant TT_TRIM_INSERT_SLACK => 8192;             # Higher => allows larger temporary TT overflow before trimming.
use constant TT_TRIM_HARD_EVICT_MAX => 2048;           # Higher => allows more forced evictions per trim call.
use constant TT_STALE_GEN_AGE => 3;                    # Lower => evicts older TT generations more aggressively.
use constant TT_SHALLOW_DEPTH => 2;                    # Higher => treats more shallow TT entries as weak.
use constant HISTORY_DECAY_FACTOR => 0.85;             # Lower => quiet-history bonuses fade faster across thinks.
use constant HISTORY_RENORM_MIN_SCALE => 0.02;         # Higher => normalizes/prunes history table more frequently.
use constant COUNTERMOVE_BONUS => 180;                 # Higher => counter-move heuristic impacts ordering more.
use constant EASY_MOVE_MIN_DEPTH => 4;                 # Higher => require deeper confirmation before early stop.
use constant EASY_MOVE_DEPTH_CAP => 5;                 # Higher => allow easier early-stop logic at deeper levels.
use constant MID_ENDGAME_PIECE_THRESHOLD => 16;        # Higher => applies endgame heuristics earlier.
use constant DEEP_ENDGAME_PIECE_THRESHOLD => 10;       # Higher => applies deep-endgame heuristics earlier.
use constant MID_ENDGAME_DEPTH_BOOST => 1;             # Higher => extra nominal depth in middlegame/endgame.
use constant DEEP_ENDGAME_DEPTH_BOOST => 2;            # Higher => extra nominal depth in deep endgames.
use constant MID_ENDGAME_EASY_MOVE_EXTRA_DEPTH => 2;   # Higher => delay easy-move exits in lighter positions.
use constant OPENING_PIECE_COUNT_THRESHOLD => 26;      # Higher => "opening" development incentives persist longer.
use constant OPENING_DEVELOPMENT_EXTRA_PENALTY => 1;   # Higher => extra penalty per undeveloped minor in opening.
use constant MIDDLEGAME_MIN_PIECE_COUNT => 18;         # Lower => pawn-candidate extra think starts earlier.
use constant MIDDLEGAME_MAX_PIECE_COUNT => 28;         # Higher => pawn-candidate extra think applies closer to opening.
use constant PAWN_CANDIDATE_MIN_BUDGET_MS => 120;      # Lower => allow pawn-candidate extra think in tighter clocks.
use constant PAWN_CANDIDATE_EXTRA_TIME_SHARE => 0.08;  # Higher => larger soft-deadline extension on pawn candidates.
use constant PAWN_CANDIDATE_EXTRA_TIME_MAX_MS => 180;  # Higher => larger absolute cap for pawn-candidate extension.
use constant ROOT_NEAR_TIE_DELTA => 6;                 # Lower => fewer positions treated as contested at the root.
use constant ROOT_CLEAR_BEST_DELTA => 18;              # Higher => require larger lead before treating root as forced/easy.
use constant CRITICAL_EXTRA_TIME_SHARE => 0.28;        # Higher => spend more budget in contested/volatile root positions.
use constant CRITICAL_EXTRA_TIME_MAX_MS => 260;        # Higher => larger absolute cap for critical-position time boosts.
use constant CRITICAL_EXTENSION_MAX_HITS => 2;         # Higher => allow more repeated critical extensions per move.
use constant DEVELOPMENT_MINOR_PENALTY => 2;           # Higher => punishes undeveloped minors more.
use constant EARLY_ROOK_MOVE_PENALTY => 3;             # Higher => discourages early rook moves before development.
use constant EARLY_QUEEN_MOVE_PENALTY => 4;            # Higher => discourages early queen activity.
use constant UNCASTLED_KING_PENALTY => 5;              # Higher => penalizes staying uncastled more.
use constant CENTRAL_KING_PENALTY => 3;                # Higher => penalizes central uncastled king more.
use constant HANGING_DEFENDED_SCALE => 0.4;           # Higher => softens hanging penalty less when defended.
use constant HANGING_MOVE_GUARD_BONUS => 18;           # Higher => penalizes quiet self-pins/hangs more.
use constant LMR_KING_DANGER_THRESHOLD => 4;          # Lower => disables LMR sooner in king-danger positions.
use constant UNSAFE_CAPTURE_HANGING_BONUS => 51;       # Higher => stronger penalty for grabbing into danger.
use constant UNSAFE_CAPTURE_DEFENDED_SCALE => 0.55;    # Higher => keep more penalty even if capture square defended.
use constant UNSAFE_CAPTURE_KING_EXPOSURE_WEIGHT => 7; # Higher => prioritize king shelter over greedy captures.
use constant KING_DANGER_RING_ATTACK_PENALTY => 6;     # Higher => penalize attacked king-ring squares more.
use constant KING_DANGER_RING_UNDEFENDED_PENALTY => 3; # Higher => penalize undefended ring attacks more.
use constant KING_DANGER_CHECK_PENALTY => 22;          # Higher => direct check against king hurts eval more.
use constant KING_DANGER_SHIELD_MISSING_PENALTY => 3;  # Higher => missing pawn shield costs more.
use constant KING_DANGER_OPEN_FILE_PENALTY => 3;       # Higher => open king file is punished more.
use constant KING_DANGER_ADJ_FILE_PENALTY => 2;        # Higher => adjacent open files near king hurt more.
use constant KING_AGGRESSION_ENEMY_PIECE_START => 10;  # Higher => king aggression starts earlier as enemy material shrinks.
use constant KING_AGGRESSION_RANK_BONUS => 6;          # Higher => reward for king penetration in late game.

my %history_scores;
my $history_scale = 1.0;
my @killer_moves;
my %transposition_table;
my $tt_size = 0;
my %counter_moves;
my $tt_generation = 0;
my %root_search_stats;

my $search_has_deadline = 0;
my $search_soft_deadline = 0;
my $search_hard_deadline = 0;
my $search_nodes = 0;
my $search_quiesce_limit = QUIESCE_MAX_DEPTH;
my $search_time_abort = "__TIMEUP__";

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 6; # bigger number more thinky

  # hi ken
  return bless \%self, $class;
}

my %piece_values = (
  KING, 5590,
  PAWN, 10,
  BISHOP, 30,
  KNIGHT, 30,
  ROOK, 50,
  QUEEN, 90,
  OPP_KING, -5590,
  OPP_PAWN, -10,
  OPP_BISHOP, -30,
  OPP_KNIGHT, -30,
  OPP_ROOK, -50,
  OPP_QUEEN, -90,
  EMPTY, 0,
  OOB, 0,
);

my %piece_alias = map { $_ => $_ } qw(
  KING QUEEN ROOK BISHOP KNIGHT PAWN
  OPP_KING OPP_QUEEN OPP_ROOK OPP_BISHOP OPP_KNIGHT OPP_PAWN
);

$piece_alias{KING()}       = 'KING';
$piece_alias{QUEEN()}      = 'QUEEN';
$piece_alias{ROOK()}       = 'ROOK';
$piece_alias{BISHOP()}     = 'BISHOP';
$piece_alias{KNIGHT()}     = 'KNIGHT';
$piece_alias{PAWN()}       = 'PAWN';
$piece_alias{OPP_KING()}   = 'OPP_KING';
$piece_alias{OPP_QUEEN()}  = 'OPP_QUEEN';
$piece_alias{OPP_ROOK()}   = 'OPP_ROOK';
$piece_alias{OPP_BISHOP()} = 'OPP_BISHOP';
$piece_alias{OPP_KNIGHT()} = 'OPP_KNIGHT';
$piece_alias{OPP_PAWN()}   = 'OPP_PAWN';

my @board_indices = board_indices();
my @square_by_idx;
my @rank_by_idx;
my @file_by_idx;
for my $idx (@board_indices) {
  my $file = ($idx % 10) - 1;
  my $rank = int($idx / 10) - 1;
  $square_by_idx[$idx] = chr(ord('a') + $file) . $rank;
  $rank_by_idx[$idx] = $rank;
  $file_by_idx[$idx] = $file + 1;
}
my %normalized_location_tables = _normalize_location_modifiers();
my @passed_pawn_bonus_by_rank = (0, 0, 0, 2, 4, 7, 11, 16, 0);
my @enemy_passed_pawn_penalty_by_rank = (0, 0, 17, 12, 8, 5, 3, 2, 0);
my %hanging_piece_penalty = (
  KNIGHT() => 6,
  BISHOP() => 6,
  ROOK() => 10,
  QUEEN() => 18,
);

sub _normalize_location_modifiers {
  my %normalized;
  for my $raw_key (keys %location_modifiers) {
    my $table = $location_modifiers{$raw_key};
    next unless ref $table eq 'HASH' && keys %{$table};
    my $canonical = $piece_alias{$raw_key} or next;
    my $max_abs = max(map { abs($_ // 0) } values %{$table}) || 0;
    my %relative = map {
      my $value = $table->{$_} // 0;
      my $ratio = $max_abs ? _clamp($value / $max_abs, -1, 1) : 0;
      $_ => $ratio;
    } keys %{$table};
    $normalized{$canonical} = \%relative;
  }
  return %normalized;
}

sub _clamp {
  my ($value, $min, $max) = @_;
  $value = $min if $value < $min;
  $value = $max if $value > $max;
  return $value;
}

sub _location_modifier_percent {
  my ($piece, $square) = @_;
  my $canonical = $piece_alias{$piece} or return 0;
  my $table = $normalized_location_tables{$canonical} or return 0;
  return $table->{$square} // 0;
}

sub _location_bonus {
  my ($piece, $square, $base_value) = @_;
  my $percent = _location_modifier_percent($piece, $square);
  return 0 unless $percent;
  return $base_value * LOCATION_WEIGHT * $percent;
}

sub _flip_idx {
  my ($idx) = @_;
  my $rank_base = int($idx / 10) * 10;
  my $file = $idx % 10;
  return 110 - $rank_base + $file;
}

sub _rank_of_idx {
  my ($idx) = @_;
  my $cached = $rank_by_idx[$idx];
  return $cached if defined $cached;
  return int($idx / 10) - 1;
}

sub _file_of_idx {
  my ($idx) = @_;
  my $cached = $file_by_idx[$idx];
  return $cached if defined $cached;
  return $idx % 10;
}

sub _square_of_idx {
  my ($idx) = @_;
  return $square_by_idx[$idx] // idx_to_square($idx, 0);
}

sub _is_square_attacked_by_side {
  my ($board, $idx, $attacker_sign, $cache) = @_;
  return 0 unless $attacker_sign == 1 || $attacker_sign == -1;

  my $cache_key;
  if (ref($cache) eq 'HASH') {
    $cache_key = ($idx << 1) | ($attacker_sign > 0 ? 1 : 0);
    return $cache->{$cache_key} if exists $cache->{$cache_key};
  }

  my $pawn = $attacker_sign * PAWN;
  my $knight = $attacker_sign * KNIGHT;
  my $bishop = $attacker_sign * BISHOP;
  my $rook = $attacker_sign * ROOK;
  my $queen = $attacker_sign * QUEEN;
  my $king = $attacker_sign * KING;

  if ($attacker_sign > 0) {
    if (($board->[$idx - 11] // OOB) == $pawn || ($board->[$idx - 9] // OOB) == $pawn) {
      $cache->{$cache_key} = 1 if defined $cache_key;
      return 1;
    }
  } else {
    if (($board->[$idx + 11] // OOB) == $pawn || ($board->[$idx + 9] // OOB) == $pawn) {
      $cache->{$cache_key} = 1 if defined $cache_key;
      return 1;
    }
  }

  for my $inc (-21, -19, -12, -8, 8, 12, 19, 21) {
    if (($board->[$idx + $inc] // OOB) == $knight) {
      $cache->{$cache_key} = 1 if defined $cache_key;
      return 1;
    }
  }

  for my $inc (-11, -10, -9, -1, 1, 9, 10, 11) {
    if (($board->[$idx + $inc] // OOB) == $king) {
      $cache->{$cache_key} = 1 if defined $cache_key;
      return 1;
    }
  }

  for my $inc (-10, -1, 1, 10) {
    my $dest = $idx;
    while (1) {
      $dest += $inc;
      my $piece = $board->[$dest] // OOB;
      next unless $piece;
      if ($piece == $rook || $piece == $queen) {
        $cache->{$cache_key} = 1 if defined $cache_key;
        return 1;
      }
      last;
    }
  }

  for my $inc (-11, -9, 9, 11) {
    my $dest = $idx;
    while (1) {
      $dest += $inc;
      my $piece = $board->[$dest] // OOB;
      next unless $piece;
      if ($piece == $bishop || $piece == $queen) {
        $cache->{$cache_key} = 1 if defined $cache_key;
        return 1;
      }
      last;
    }
  }

  $cache->{$cache_key} = 0 if defined $cache_key;
  return 0;
}

sub _find_piece_idx {
  my ($board, $target_piece) = @_;
  for my $idx (@board_indices) {
    return $idx if ($board->[$idx] // 0) == $target_piece;
  }
  return;
}

sub _is_passed_pawn {
  my ($board, $idx, $side_sign) = @_;
  return 0 unless $side_sign == 1 || $side_sign == -1;

  my $file = _file_of_idx($idx);
  my $rank = _rank_of_idx($idx);
  my $enemy_pawn = -$side_sign * PAWN;

  for my $check_file ($file - 1 .. $file + 1) {
    next if $check_file < 1 || $check_file > 8;
    if ($side_sign > 0) {
      for (my $check_rank = $rank + 1; $check_rank <= 8; $check_rank++) {
        my $check_idx = ($check_rank + 1) * 10 + $check_file;
        return 0 if ($board->[$check_idx] // 0) == $enemy_pawn;
      }
    } else {
      for (my $check_rank = $rank - 1; $check_rank >= 1; $check_rank--) {
        my $check_idx = ($check_rank + 1) * 10 + $check_file;
        return 0 if ($board->[$check_idx] // 0) == $enemy_pawn;
      }
    }
  }

  return 1;
}

sub _development_score {
  my ($board, $opts) = @_;
  $opts ||= {};
  my $score = 0;

  my $piece_count = $opts->{piece_count};
  if (!defined $piece_count) {
    $piece_count = 0;
    for my $idx (@board_indices) {
      my $abs_piece = abs($board->[$idx] // 0);
      $piece_count++ if $abs_piece >= PAWN && $abs_piece <= KING;
    }
  }

  my $king_idx = exists $opts->{king_idx} ? $opts->{king_idx} : _find_piece_idx($board, KING);
  my $is_castled = defined $king_idx && ($king_idx == 23 || $king_idx == 27);
  my $uncastled = defined $king_idx && !$is_castled;
  my $undeveloped_minors = 0;
  $undeveloped_minors++ if ($board->[22] // 0) == KNIGHT;
  $undeveloped_minors++ if ($board->[27] // 0) == KNIGHT;
  $undeveloped_minors++ if ($board->[23] // 0) == BISHOP;
  $undeveloped_minors++ if ($board->[26] // 0) == BISHOP;

  $score -= $undeveloped_minors * DEVELOPMENT_MINOR_PENALTY;
  if ($piece_count >= OPENING_PIECE_COUNT_THRESHOLD) {
    $score -= $undeveloped_minors * OPENING_DEVELOPMENT_EXTRA_PENALTY;
  }

  if ($uncastled && $undeveloped_minors > 0) {
    my $rook_count = $opts->{rook_count};
    my $rook_home_count = $opts->{rook_home_count};
    if (!defined $rook_count || !defined $rook_home_count) {
      $rook_count = 0;
      $rook_home_count = 0;
      for my $idx (@board_indices) {
        next unless ($board->[$idx] // 0) == ROOK;
        $rook_count++;
        $rook_home_count++ if $idx == 21 || $idx == 28;
      }
    }
    my $moved_rooks = max(0, $rook_count - $rook_home_count);
    $score -= EARLY_ROOK_MOVE_PENALTY * $moved_rooks if $moved_rooks;

    my $queen_idx = exists $opts->{queen_idx} ? $opts->{queen_idx} : _find_piece_idx($board, QUEEN);
    if (defined $queen_idx && $queen_idx != 24 && $undeveloped_minors >= 2) {
      $score -= EARLY_QUEEN_MOVE_PENALTY;
    }
  }

  my $opponent_has_queen = exists $opts->{opponent_has_queen}
    ? ($opts->{opponent_has_queen} ? 1 : 0)
    : (defined _find_piece_idx($board, OPP_QUEEN) ? 1 : 0);
  if ($uncastled && $opponent_has_queen) {
    $score -= UNCASTLED_KING_PENALTY;
    my $file = _file_of_idx($king_idx);
    $score -= CENTRAL_KING_PENALTY if $file >= 4 && $file <= 6;
  }

  return $score;
}

sub _passed_pawn_score {
  my ($board) = @_;
  my $score = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    if ($piece == PAWN && _is_passed_pawn($board, $idx, 1)) {
      my $rank = _rank_of_idx($idx);
      $score += $passed_pawn_bonus_by_rank[$rank] // 0;
      if ($rank >= 6 && ($board->[$idx + 10] // OOB) == EMPTY) {
        $score += 2;
      }
    } elsif ($piece == OPP_PAWN && _is_passed_pawn($board, $idx, -1)) {
      my $rank = _rank_of_idx($idx);
      $score -= $enemy_passed_pawn_penalty_by_rank[$rank] // 0;
      if ($rank <= 3 && ($board->[$idx - 10] // OOB) == EMPTY) {
        $score -= 2;
      }
    }
  }

  return $score;
}

sub _hanging_piece_score {
  my ($board, $attack_cache) = @_;
  my $score = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    my $abs_piece = abs($piece);
    my $penalty = $hanging_piece_penalty{$abs_piece} // 0;
    next unless $penalty;

    if ($piece > 0) {
      next unless _is_square_attacked_by_side($board, $idx, -1, $attack_cache);
      my $defended = _is_square_attacked_by_side($board, $idx, 1, $attack_cache) ? 1 : 0;
      my $delta = $defended ? int($penalty * HANGING_DEFENDED_SCALE) : $penalty;
      $score -= $delta;
    } else {
      next unless _is_square_attacked_by_side($board, $idx, 1, $attack_cache);
      my $defended = _is_square_attacked_by_side($board, $idx, -1, $attack_cache) ? 1 : 0;
      my $delta = $defended ? int($penalty * HANGING_DEFENDED_SCALE) : $penalty;
      $score += $delta;
    }
  }

  return $score;
}

sub _is_quiet_hanging_move {
  my ($new_state, $move, $is_capture) = @_;
  return 0 if $is_capture;
  return 0 if defined $move->[2] || defined $move->[3];
  return 0 if $new_state->is_checked;

  my $new_board = $new_state->[Chess::State::BOARD];
  my $dest_idx = _flip_idx($move->[1]);
  my $moved_piece = $new_board->[$dest_idx] // 0;
  return 0 unless $moved_piece < 0;
  my $abs_piece = abs($moved_piece);
  return 0 if $abs_piece < KNIGHT;

  return 0 unless _is_square_attacked_by_side($new_board, $dest_idx, 1);
  return 0 if _is_square_attacked_by_side($new_board, $dest_idx, -1);
  return 1;
}

sub _hanging_move_penalty {
  my ($new_state, $move) = @_;
  my $new_board = $new_state->[Chess::State::BOARD];
  my $dest_idx = _flip_idx($move->[1]);
  my $moved_piece = abs($new_board->[$dest_idx] // 0);
  my $base = $hanging_piece_penalty{$moved_piece} // 0;
  return 0 unless $base;
  return $base + HANGING_MOVE_GUARD_BONUS;
}

sub _king_ring_indices {
  my ($board, $king_idx) = @_;
  return unless defined $king_idx;

  my @ring;
  for my $inc (-11, -10, -9, -1, 1, 9, 10, 11) {
    my $idx = $king_idx + $inc;
    next if ($board->[$idx] // OOB) == OOB;
    push @ring, $idx;
  }
  return @ring;
}

sub _king_danger_for_piece {
  my ($board, $king_piece, $attack_cache, $king_idx_hint) = @_;
  my $king_idx = defined $king_idx_hint ? $king_idx_hint : _find_piece_idx($board, $king_piece);
  return 0 unless defined $king_idx;

  my $friendly_sign = $king_piece > 0 ? 1 : -1;
  my $enemy_sign = -$friendly_sign;
  my $friendly_pawn = $friendly_sign * PAWN;
  my $danger = 0;

  my @ring = _king_ring_indices($board, $king_idx);
  my $ring_attacked = 0;
  my $ring_undefended = 0;
  for my $idx (@ring) {
    next unless _is_square_attacked_by_side($board, $idx, $enemy_sign, $attack_cache);
    $ring_attacked++;
    $ring_undefended++ unless _is_square_attacked_by_side($board, $idx, $friendly_sign, $attack_cache);
  }

  $danger += $ring_attacked * KING_DANGER_RING_ATTACK_PENALTY;
  $danger += $ring_undefended * KING_DANGER_RING_UNDEFENDED_PENALTY;
  $danger += KING_DANGER_CHECK_PENALTY if _is_square_attacked_by_side($board, $king_idx, $enemy_sign, $attack_cache);

  my @shield_offsets = $friendly_sign > 0 ? (9, 10, 11) : (-9, -10, -11);
  for my $inc (@shield_offsets) {
    my $shield_idx = $king_idx + $inc;
    next if ($board->[$shield_idx] // OOB) == OOB;
    my $piece = $board->[$shield_idx] // OOB;
    $danger += KING_DANGER_SHIELD_MISSING_PENALTY if $piece != $friendly_pawn;
  }

  my $king_file = _file_of_idx($king_idx);
  for my $file ($king_file - 1 .. $king_file + 1) {
    next if $file < 1 || $file > 8;
    my $has_friendly_pawn = 0;
    for my $rank (1 .. 8) {
      my $idx = ($rank + 1) * 10 + $file;
      if (($board->[$idx] // 0) == $friendly_pawn) {
        $has_friendly_pawn = 1;
        last;
      }
    }
    next if $has_friendly_pawn;
    $danger += ($file == $king_file) ? KING_DANGER_OPEN_FILE_PENALTY : KING_DANGER_ADJ_FILE_PENALTY;
  }

  return $danger;
}

sub _king_danger_score {
  my ($board, $attack_cache, $our_king_idx, $opp_king_idx) = @_;
  my $our_danger = _king_danger_for_piece($board, KING, $attack_cache, $our_king_idx);
  my $opp_danger = _king_danger_for_piece($board, OPP_KING, $attack_cache, $opp_king_idx);
  return $opp_danger - $our_danger;
}

sub _non_king_piece_count {
  my ($board, $side_sign) = @_;
  my $count = 0;
  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    next unless ($side_sign > 0 && $piece > 0) || ($side_sign < 0 && $piece < 0);
    my $abs_piece = abs($piece);
    next if $abs_piece == KING;
    $count++ if $abs_piece >= PAWN && $abs_piece <= QUEEN;
  }
  return $count;
}

sub _king_aggression_for_piece {
  my ($board, $king_piece, $enemy_piece_count) = @_;
  return 0 unless defined $enemy_piece_count;
  return 0 if $enemy_piece_count >= KING_AGGRESSION_ENEMY_PIECE_START;
  my $phase = (KING_AGGRESSION_ENEMY_PIECE_START - $enemy_piece_count) / KING_AGGRESSION_ENEMY_PIECE_START;
  return int(KING_AGGRESSION_RANK_BONUS * $phase + 0.5);
}

sub _king_aggression_score {
  my ($board, $friendly_piece_count, $enemy_piece_count) = @_;
  $enemy_piece_count = _non_king_piece_count($board, -1) unless defined $enemy_piece_count;
  $friendly_piece_count = _non_king_piece_count($board, 1) unless defined $friendly_piece_count;
  my $our_bonus = _king_aggression_for_piece($board, KING, $enemy_piece_count);
  my $opp_bonus = _king_aggression_for_piece($board, OPP_KING, $friendly_piece_count);
  return $our_bonus - $opp_bonus;
}

sub _is_king_safety_critical_move {
  my ($state, $move, $new_state, $own_king_danger) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = abs($board->[$move->[0]] // 0);
  return 1 if $from_piece == KING;
  return 1 if $new_state->is_checked;

  my $king_idx = $state->[Chess::State::KING_IDX];
  $king_idx = _find_piece_idx($board, KING) unless defined $king_idx;
  return 1 if defined $own_king_danger && $own_king_danger >= LMR_KING_DANGER_THRESHOLD;
  return 0 unless defined $king_idx;

  my $king_file = _file_of_idx($king_idx);
  if ($from_piece == PAWN && abs(_file_of_idx($move->[0]) - $king_file) <= 1) {
    return 1;
  }

  my @ring = _king_ring_indices($board, $king_idx);
  my %ring = map { $_ => 1 } @ring;
  return 1 if $ring{$move->[0]} || $ring{$move->[1]};

  return 0;
}

sub _is_tactical_queen_move {
  my ($state, $move, $new_state, $is_capture) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = abs($board->[$move->[0]] // 0);
  return 0 unless $from_piece == QUEEN;

  # Captures and direct checks are already tactical by definition.
  return 1 if $is_capture;
  return 1 if $new_state->is_checked;

  # Preserve quiet queen moves that pressure enemy king/ring from LMR.
  my $new_board = $new_state->[Chess::State::BOARD];
  my $enemy_king_idx = $new_state->[Chess::State::KING_IDX];
  $enemy_king_idx = _find_piece_idx($new_board, KING) unless defined $enemy_king_idx;
  return 0 unless defined $enemy_king_idx;

  my @ring = _king_ring_indices($new_board, $enemy_king_idx);
  for my $sq ($enemy_king_idx, @ring) {
    return 1 if _is_square_attacked_by_side($new_board, $sq, -1);
  }

  return 0;
}

sub _unsafe_capture_penalty {
  my ($state, $move, $from_piece, $to_piece) = @_;
  return 0 unless $to_piece < 0;

  my $board = $state->[Chess::State::BOARD];
  my $dest_idx = $move->[1];
  my $king_danger_before = _king_danger_for_piece($board, KING);

  my $attacker_value = abs($piece_values{$from_piece} || 0);
  my $victim_value = abs($piece_values{$to_piece} || 0);
  my $exchange_loss = max(0, $attacker_value - $victim_value);
  my $enemy_attacks = _is_square_attacked_by_side($board, $dest_idx, -1) ? 1 : 0;
  my $defended = _is_square_attacked_by_side($board, $dest_idx, 1) ? 1 : 0;

  my $penalty = 0;
  if ($enemy_attacks) {
    $penalty = $exchange_loss;
    if ($defended) {
      $penalty = int($penalty * UNSAFE_CAPTURE_DEFENDED_SCALE);
    } else {
      $penalty += UNSAFE_CAPTURE_HANGING_BONUS;
    }
  }

  if ($king_danger_before >= int(LMR_KING_DANGER_THRESHOLD / 2)) {
    my $new_state = $state->make_move($move);
    if (defined $new_state) {
      my $new_board = $new_state->[Chess::State::BOARD];
      my $king_danger_after = _king_danger_for_piece($new_board, OPP_KING);
      my $delta = $king_danger_after - $king_danger_before;
      $penalty += $delta * UNSAFE_CAPTURE_KING_EXPOSURE_WEIGHT if $delta > 0;
    }
  }

  return $penalty;
}

sub _ordered_moves {
  my ($state, $ply, $tt_move_key, $prev_move_key) = @_;
  my @scored;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $move_key = _move_key($move);
    my $is_capture = _is_capture_state($state, $move);
    push @scored, [
      _move_order_score($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key),
      $move,
      $move_key,
      $is_capture,
    ];
  }
  @scored = _sort_scored_desc(@scored);
  return @scored;
}

sub _sort_scored_desc {
  my (@scored) = @_;
  my $count = scalar @scored;
  return @scored if $count <= 1;

  if ($count == 2) {
    if ($scored[0][0] < $scored[1][0]) {
      @scored = ($scored[1], $scored[0]);
    }
    return @scored;
  }

  return sort { $b->[0] <=> $a->[0] } @scored;
}

sub _move_order_score {
  my ($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = $board->[$move->[0]] || 0;
  my $to_piece = $board->[$move->[1]] || 0;
  my $score = 0;

  if (defined $tt_move_key && $move_key == $tt_move_key) {
    $score += 5000;
  }

  if ($to_piece < 0) {
    my $victim_value = abs($piece_values{$to_piece} || 0);
    my $attacker_value = abs($piece_values{$from_piece} || 0);
    $score += 1000 + 10 * $victim_value - $attacker_value;
    $score -= _unsafe_capture_penalty($state, $move, $from_piece, $to_piece);
  }

  if (defined $move->[2]) {
    my $promo = abs($piece_values{$move->[2]} || 0);
    my $pawn = abs($piece_values{PAWN} || 1);
    $score += 500 + ($promo - $pawn);
  }

  if (defined $move->[3]) {
    $score += 50;
  }

  my $from_square = _square_of_idx($move->[0]);
  my $to_square = _square_of_idx($move->[1]);
  if (defined $to_square) {
    my $from_bonus = defined $from_square ? _location_modifier_percent($from_piece, $from_square) : 0;
    my $to_bonus = _location_modifier_percent($from_piece, $to_square);
    $score += 30 * ($to_bonus - $from_bonus);
  }

  if (! $is_capture) {
    $score += _history_bonus($move_key);
    $score += _killer_bonus($move_key, $ply);
    $score += _countermove_bonus($move_key, $prev_move_key);
  }

  return $score;
}

sub _is_capture_state {
  my ($state, $move) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $to_piece = $board->[$move->[1]] // 0;
  return 1 if $to_piece < 0;

  my $from_piece = $board->[$move->[0]] // 0;
  return 0 unless $from_piece == PAWN;

  my $ep = $state->[Chess::State::EP];
  return 0 unless defined $ep && $move->[1] == $ep;
  return 0 unless ($move->[1] - $move->[0] == 9 || $move->[1] - $move->[0] == 11);

  return $to_piece == EMPTY ? 1 : 0;
}

sub _move_key {
  my ($move) = @_;
  my $from = $move->[0] // 0;
  my $to = $move->[1] // 0;
  my $promo = defined $move->[2] ? (($move->[2] + 8) & 0x0f) : 0;
  return (($from & 0x7f) << 11) | (($to & 0x7f) << 4) | $promo;
}

sub _history_bonus {
  my ($move_key) = @_;
  my $raw = $history_scores{$move_key};
  return 0 unless defined $raw;
  my $scaled = int($raw * $history_scale);
  if ($scaled <= 0) {
    delete $history_scores{$move_key};
    return 0;
  }
  return $scaled;
}

sub _killer_bonus {
  my ($move_key, $ply) = @_;
  my $slot = $killer_moves[$ply] || [];
  return 200 if defined $slot->[0] && $slot->[0] == $move_key;
  return 150 if defined $slot->[1] && $slot->[1] == $move_key;
  return 0;
}

sub _countermove_bonus {
  my ($move_key, $prev_move_key) = @_;
  return 0 unless defined $prev_move_key;
  my $counter = $counter_moves{$prev_move_key};
  return 0 unless defined $counter;
  return $move_key == $counter ? COUNTERMOVE_BONUS : 0;
}

sub _store_killer {
  my ($ply, $move_key) = @_;
  $killer_moves[$ply] ||= [];
  return if defined $killer_moves[$ply][0] && $killer_moves[$ply][0] == $move_key;
  $killer_moves[$ply][1] = $killer_moves[$ply][0] if defined $killer_moves[$ply][0];
  $killer_moves[$ply][0] = $move_key;
}

sub _store_countermove {
  my ($prev_move_key, $move_key) = @_;
  return unless defined $prev_move_key;
  $counter_moves{$prev_move_key} = $move_key;
}

sub _update_history {
  my ($move_key, $depth) = @_;
  my $bonus = $depth * $depth;
  my $scale = $history_scale > 0 ? $history_scale : 1;
  my $unscaled_bonus = int($bonus / $scale);
  $unscaled_bonus = 1 if $unscaled_bonus < 1;
  $history_scores{$move_key} = ($history_scores{$move_key} // 0) + $unscaled_bonus;
}

sub _decay_history {
  $history_scale *= HISTORY_DECAY_FACTOR;
  return if $history_scale >= HISTORY_RENORM_MIN_SCALE;

  for my $key (keys %history_scores) {
    my $scaled = int(($history_scores{$key} // 0) * $history_scale);
    if ($scaled > 0) {
      $history_scores{$key} = $scaled;
    } else {
      delete $history_scores{$key};
    }
  }
  $history_scale = 1.0;
}

sub _trim_transposition_table {
  return if $tt_size <= TT_MAX_ENTRIES;

  my $target = int(TT_MAX_ENTRIES * TT_TRIM_TARGET_FILL);
  my $needed = $tt_size - $target;
  my $scan_budget = TT_TRIM_SCAN_BASE + ($needed > 0 ? $needed * TT_TRIM_SCAN_PER_EVICTION : 0);
  $scan_budget = TT_TRIM_SCAN_MAX if $scan_budget > TT_TRIM_SCAN_MAX;

  my @preferred;
  my @fallback;
  while ($scan_budget-- > 0 && $tt_size > $target) {
    my ($key, $entry) = each %transposition_table;
    if (!defined $key) {
      keys %transposition_table; # reset hash iterator without materializing all keys
      last;
    }

    push @fallback, $key;
    next unless ref($entry) eq 'HASH';

    my $entry_gen = $entry->{gen} // 0;
    my $entry_depth = $entry->{depth} // 0;
    if (($tt_generation - $entry_gen) >= TT_STALE_GEN_AGE || $entry_depth <= TT_SHALLOW_DEPTH) {
      push @preferred, $key;
    }
  }

  for my $key (@preferred, @fallback) {
    last if $tt_size <= $target;
    next unless exists $transposition_table{$key};
    delete $transposition_table{$key};
    $tt_size--;
  }

  if ($tt_size > TT_MAX_ENTRIES) {
    my $hard_budget = min(TT_TRIM_HARD_EVICT_MAX, $tt_size - TT_MAX_ENTRIES);
    while ($hard_budget-- > 0 && $tt_size > TT_MAX_ENTRIES) {
      my ($key, undef) = each %transposition_table;
      if (!defined $key) {
        keys %transposition_table;
        next;
      }
      next unless exists $transposition_table{$key};
      delete $transposition_table{$key};
      $tt_size--;
    }
  }
}

sub _piece_count {
  my ($state) = @_;
  my $cached = $state->[Chess::State::PIECE_COUNT];
  return $cached if defined $cached;
  my $board = $state->[Chess::State::BOARD];
  my $count = 0;
  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    my $abs_piece = abs($piece);
    $count++ if $abs_piece >= PAWN && $abs_piece <= KING;
  }
  return $count;
}

sub _is_middlegame_piece_count {
  my ($piece_count) = @_;
  return 0 unless defined $piece_count;
  return $piece_count >= MIDDLEGAME_MIN_PIECE_COUNT
    && $piece_count <= MIDDLEGAME_MAX_PIECE_COUNT;
}

sub _is_pawn_move_in_state {
  my ($state, $move) = @_;
  return 0 unless $state && ref($move) eq 'ARRAY';
  my $board = $state->[Chess::State::BOARD];
  return 0 unless ref($board) eq 'ARRAY';
  my $from_piece = $board->[$move->[0]] // 0;
  return abs($from_piece) == PAWN ? 1 : 0;
}

sub _configure_time_limits {
  my ($state, $opts) = @_;
  $opts ||= {};

  $search_has_deadline = 0;
  $search_soft_deadline = 0;
  $search_hard_deadline = 0;
  $search_nodes = 0;
  $search_quiesce_limit = QUIESCE_MAX_DEPTH;

  my $start = time();
  my $piece_count = _piece_count($state);
  my $move_overhead_ms = max(0, int($opts->{move_overhead_ms} // TIME_MOVE_OVERHEAD_MS));
  my $movetime_ms = $opts->{movetime_ms};
  my $remaining_ms;
  my $budget_ms;
  my $hard_ms;
  my $has_clock = 0;
  my $panic_level = 0;

  if (defined $movetime_ms && $movetime_ms > 0) {
    my $mt = max(1, int($movetime_ms));
    $budget_ms = max(TIME_MIN_BUDGET_MS, $mt - $move_overhead_ms);
    $hard_ms = max($budget_ms, $mt);
    $has_clock = 1;
  } elsif (defined $opts->{remaining_ms} && $opts->{remaining_ms} > 0) {
    $remaining_ms = max(1, int($opts->{remaining_ms}));
    my $inc_ms = max(0, int($opts->{increment_ms} // 0));
    my $panic_reserve_pct = 0.05;
    my $panic_min_horizon = 0;
    my $panic_budget_share = 0;
    my $panic_inc_weight = TIME_INC_WEIGHT;
    my $panic_hard_scale = TIME_HARD_SCALE;

    if ($remaining_ms <= TIME_PANIC_10S_MS) {
      $panic_level = 3;
      $panic_reserve_pct = TIME_PANIC_10S_RESERVE_PCT;
      $panic_min_horizon = TIME_PANIC_10S_MIN_HORIZON;
      $panic_budget_share = TIME_PANIC_10S_BUDGET_SHARE;
      $panic_inc_weight = TIME_PANIC_10S_INC_WEIGHT;
      $panic_hard_scale = TIME_PANIC_10S_HARD_SCALE;
      $search_quiesce_limit = min($search_quiesce_limit, TIME_PANIC_10S_QUIESCE_MAX_DEPTH);
    } elsif ($remaining_ms <= TIME_PANIC_30S_MS) {
      $panic_level = 2;
      $panic_reserve_pct = TIME_PANIC_30S_RESERVE_PCT;
      $panic_min_horizon = TIME_PANIC_30S_MIN_HORIZON;
      $panic_budget_share = TIME_PANIC_30S_BUDGET_SHARE;
      $panic_inc_weight = TIME_PANIC_30S_INC_WEIGHT;
      $panic_hard_scale = TIME_PANIC_30S_HARD_SCALE;
      $search_quiesce_limit = min($search_quiesce_limit, TIME_PANIC_30S_QUIESCE_MAX_DEPTH);
    } elsif ($remaining_ms <= TIME_PANIC_60S_MS) {
      $panic_level = 1;
      $panic_reserve_pct = TIME_PANIC_60S_RESERVE_PCT;
      $panic_min_horizon = TIME_PANIC_60S_MIN_HORIZON;
      $panic_budget_share = TIME_PANIC_60S_BUDGET_SHARE;
      $panic_inc_weight = TIME_PANIC_60S_INC_WEIGHT;
      $panic_hard_scale = TIME_PANIC_60S_HARD_SCALE;
      $search_quiesce_limit = min($search_quiesce_limit, TIME_PANIC_60S_QUIESCE_MAX_DEPTH);
    }

    my $movestogo = int($opts->{movestogo} // 0);
    $movestogo = 0 if $movestogo < 0;
    my $horizon = $movestogo ? min(40, max(8, $movestogo)) : TIME_DEFAULT_HORIZON;
    if ($piece_count <= MID_ENDGAME_PIECE_THRESHOLD) {
      $horizon = max(8, $horizon - MID_ENDGAME_HORIZON_REDUCTION);
    }
    if ($piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD) {
      $horizon = max(6, $horizon - DEEP_ENDGAME_HORIZON_REDUCTION);
    }
    if ($panic_min_horizon > 0) {
      $horizon = max($horizon, $panic_min_horizon);
    }

    my $reserve_ms = $opts->{reserve_ms};
    if (!defined $reserve_ms) {
      $reserve_ms = max(TIME_RESERVE_MS, int($remaining_ms * $panic_reserve_pct));
    }
    $reserve_ms = max(0, int($reserve_ms));

    my $usable_ms = max(0, $remaining_ms - $reserve_ms - $move_overhead_ms);
    my $base_ms = $horizon ? int($usable_ms / $horizon) : $usable_ms;
    $budget_ms = int($base_ms + $inc_ms * $panic_inc_weight);

    my $max_share = TIME_MAX_SHARE;
    $max_share = MID_ENDGAME_TIME_MAX_SHARE if $piece_count <= MID_ENDGAME_PIECE_THRESHOLD;
    $max_share = DEEP_ENDGAME_TIME_MAX_SHARE if $piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD;
    my $max_budget_ms = int($usable_ms * $max_share) + $inc_ms;
    $max_budget_ms = max(TIME_MIN_BUDGET_MS, $max_budget_ms);
    $budget_ms = min($budget_ms, $max_budget_ms);
    $budget_ms = max(TIME_MIN_BUDGET_MS, $budget_ms);
    if ($panic_level > 0) {
      my $panic_cap = int($remaining_ms * $panic_budget_share + $inc_ms * $panic_inc_weight);
      $panic_cap = max(TIME_MIN_BUDGET_MS, $panic_cap);
      $budget_ms = min($budget_ms, $panic_cap);
    }

    if ($remaining_ms <= TIME_EMERGENCY_MS) {
      my $emergency_cap = max(TIME_MIN_BUDGET_MS, int(($remaining_ms - $move_overhead_ms) * 0.35));
      $budget_ms = min($budget_ms, $emergency_cap);
      $search_quiesce_limit = QUIESCE_EMERGENCY_MAX_DEPTH;
    }

    if (defined $opts->{max_budget_ms}) {
      $budget_ms = min($budget_ms, max(TIME_MIN_BUDGET_MS, int($opts->{max_budget_ms})));
    }

    $hard_ms = min(
      int($budget_ms * $panic_hard_scale),
      max($budget_ms, $remaining_ms - int($reserve_ms * 0.5) - $move_overhead_ms)
    );
    $hard_ms = max($budget_ms, $hard_ms);
    $has_clock = 1;
  }

  if ($has_clock) {
    $search_has_deadline = 1;
    $search_soft_deadline = $start + ($budget_ms / 1000.0);
    $search_hard_deadline = $start + ($hard_ms / 1000.0);
    return {
      has_clock => 1,
      panic_level => $panic_level // 0,
      remaining_ms => $remaining_ms // undef,
      budget_ms => $budget_ms,
      hard_ms => $hard_ms,
      move_overhead_ms => $move_overhead_ms,
    };
  }

  return {
    has_clock => 0,
    panic_level => 0,
    remaining_ms => undef,
    budget_ms => 0,
    hard_ms => 0,
    move_overhead_ms => $move_overhead_ms,
  };
}

sub _time_up_soft {
  return $search_has_deadline && time() >= $search_soft_deadline;
}

sub _extend_soft_deadline {
  my ($extra_ms) = @_;
  return unless $search_has_deadline;
  return unless defined $extra_ms && $extra_ms > 0;
  my $extended = $search_soft_deadline + ($extra_ms / 1000.0);
  my $hard_ceiling = $search_hard_deadline - 0.001;
  $extended = $hard_ceiling if $extended > $hard_ceiling;
  $search_soft_deadline = $extended if $extended > $search_soft_deadline;
}

sub _check_time_or_abort {
  return unless $search_has_deadline;
  $search_nodes++;
  return if $search_nodes % TIME_CHECK_INTERVAL_NODES;
  die $search_time_abort if time() >= $search_hard_deadline;
}

sub _state_key {
  my ($state) = @_;
  my $cached = $state->[Chess::State::STATE_KEY];
  return $cached if defined $cached;
  return canonical_fen_key($state);
}

sub _find_move_by_key {
  my ($state, $target_key) = @_;
  return unless defined $target_key;

  for my $move (@{$state->generate_pseudo_moves}) {
    next unless _move_key($move) == $target_key;
    my $new_state = $state->make_move($move);
    return $move if defined $new_state;
  }

  return;
}

sub _quiesce {
  my ($state, $alpha, $beta, $depth) = @_;
  $depth //= 0;
  _check_time_or_abort();

  my $stand_pat = _evaluate_board($state);
  $alpha = max($alpha, $stand_pat);
  return $alpha if $alpha >= $beta || $depth >= $search_quiesce_limit;

  my @forcing;
  for my $move (@{$state->generate_pseudo_moves}) {
    my $is_capture = _is_capture_state($state, $move);
    next if ! $is_capture && $depth >= QUIESCE_CHECK_MAX_DEPTH;
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $is_check = $new_state->is_checked ? 1 : 0;
    next unless $is_capture || $is_check;
    my $move_key = _move_key($move);
    my $score = _move_order_score($state, $move, $move_key, 1, 0) + ($is_check ? QUIESCE_CHECK_BONUS : 0);
    push @forcing, [ $score, $move, $new_state ];
  }
  return $alpha unless @forcing;

  my @ordered = _sort_scored_desc(@forcing);

  foreach my $entry (@ordered) {
    my ($move, $new_state) = @{$entry}[1, 2];
    my $score = -_quiesce($new_state, -$beta, -$alpha, $depth + 1);
    if ($score > $alpha) {
      $alpha = $score;
      last if $alpha >= $beta;
    }
  }

  return $alpha;
}

sub _evaluate_board {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $score = 0;
  my $piece_count = 0;
  my $friendly_non_king = 0;
  my $enemy_non_king = 0;
  my $rook_count = 0;
  my $rook_home_count = 0;
  my $our_king_idx;
  my $opp_king_idx;
  my $queen_idx;
  my $opponent_has_queen = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;

    my $abs_piece = abs($piece);
    if ($abs_piece >= PAWN && $abs_piece <= KING) {
      $piece_count++;
    }
    if ($abs_piece >= PAWN && $abs_piece <= QUEEN) {
      if ($piece > 0) {
        $friendly_non_king++;
      } else {
        $enemy_non_king++;
      }
    }

    if ($piece == KING) {
      $our_king_idx = $idx;
    } elsif ($piece == OPP_KING) {
      $opp_king_idx = $idx;
    } elsif ($piece == QUEEN) {
      $queen_idx = $idx;
    } elsif ($piece == OPP_QUEEN) {
      $opponent_has_queen = 1;
    } elsif ($piece == ROOK) {
      $rook_count++;
      $rook_home_count++ if $idx == 21 || $idx == 28;
    }

    my $base_value = $piece_values{$piece} // 0;
    next unless $base_value;

    my $square = _square_of_idx($idx) or next;
    my $bonus = _location_bonus($piece, $square, $base_value);
    $score += $base_value + $bonus;
  }

  my %attack_cache;
  $score += _development_score($board, {
    piece_count => $piece_count,
    king_idx => $our_king_idx,
    rook_count => $rook_count,
    rook_home_count => $rook_home_count,
    queen_idx => $queen_idx,
    opponent_has_queen => $opponent_has_queen,
  });
  $score += _passed_pawn_score($board);
  $score += _hanging_piece_score($board, \%attack_cache);
  $score += _king_danger_score($board, \%attack_cache, $our_king_idx, $opp_king_idx);
  $score += _king_aggression_score($board, $friendly_non_king, $enemy_non_king);

  return $score;
}

sub _search {
  my ($state, $depth, $alpha, $beta, $ply, $prev_move_key) = @_;
  $ply //= 0;
  if ($ply == 0) {
    %root_search_stats = (
      legal_moves => 0,
      best_value => undef,
      second_value => undef,
      best_move_key => undef,
    );
  }
  _check_time_or_abort();

  if ($depth <= 0) {
    return (_quiesce($state, $alpha, $beta, 0), undef);
  }

  my $key = _state_key($state);
  my $tt_entry = $transposition_table{$key};

  if ($tt_entry && $tt_entry->{depth} >= $depth) {
    my $tt_score = $tt_entry->{score};
    if ($tt_entry->{flag} == TT_FLAG_EXACT) {
      return ($tt_score, _find_move_by_key($state, $tt_entry->{best_move_key}));
    }
    if ($tt_entry->{flag} == TT_FLAG_LOWER) {
      $alpha = max($alpha, $tt_score);
    } elsif ($tt_entry->{flag} == TT_FLAG_UPPER) {
      $beta = min($beta, $tt_score);
    }
    if ($alpha >= $beta) {
      return ($tt_score, _find_move_by_key($state, $tt_entry->{best_move_key}));
    }
  }

  my $alpha_orig = $alpha;
  my $beta_orig = $beta;
  my $tt_move_key = $tt_entry ? $tt_entry->{best_move_key} : undef;
  my $best_value = -INF_SCORE;
  my $best_move;
  my $best_move_key;
  my $legal_moves = 0;
  my $move_index = 0;
  my $in_check = $state->is_checked ? 1 : 0;
  my $own_king_danger = _king_danger_for_piece($state->[Chess::State::BOARD], KING);

  foreach my $entry (_ordered_moves($state, $ply, $tt_move_key, $prev_move_key)) {
    my ($move, $child_prev_move_key, $is_capture) = @{$entry}[1, 2, 3];
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $gives_check = $new_state->is_checked ? 1 : 0;
    my $quiet_hanging_move = _is_quiet_hanging_move($new_state, $move, $is_capture);
    my $king_safety_critical = _is_king_safety_critical_move($state, $move, $new_state, $own_king_danger);
    my $tactical_queen_move = _is_tactical_queen_move($state, $move, $new_state, $is_capture);

    $legal_moves++;

    my $value;
    if ($move_index == 0) {
      ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key);
      $value = -$value;
    } else {
      my $reduction = 0;
      if (! $in_check
        && $depth >= 4
        && $move_index >= 3
        && !defined $move->[2]
        && !defined $move->[3]
        && ! $is_capture
        && ! $gives_check
        && ! $quiet_hanging_move
        && ! $king_safety_critical
        && ! $tactical_queen_move
        && $own_king_danger < LMR_KING_DANGER_THRESHOLD)
      {
        $reduction = 1;
        $reduction = 2 if $depth >= 6 && $move_index >= 8;
      }

      if ($reduction) {
        my $reduced_depth = $depth - 1 - $reduction;
        $reduced_depth = 0 if $reduced_depth < 0;
        ($value) = _search($new_state, $reduced_depth, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key);
        $value = -$value;

        if ($value > $alpha) {
          ($value) = _search($new_state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key);
          $value = -$value;
          if ($value > $alpha && $value < $beta) {
            ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key);
            $value = -$value;
          }
        }
      } else {
        ($value) = _search($new_state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key);
        $value = -$value;
        if ($value > $alpha && $value < $beta) {
          ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key);
          $value = -$value;
        }
      }
    }
    $move_index++;
    if ($quiet_hanging_move) {
      $value -= _hanging_move_penalty($new_state, $move);
    }

    if ($ply == 0) {
      $root_search_stats{legal_moves} = $legal_moves;
      my $best_root = $root_search_stats{best_value};
      if (!defined $best_root || $value > $best_root) {
        $root_search_stats{second_value} = $best_root if defined $best_root;
        $root_search_stats{best_value} = $value;
        $root_search_stats{best_move_key} = $child_prev_move_key;
      } else {
        my $second_root = $root_search_stats{second_value};
        if (!defined $second_root || $value > $second_root) {
          $root_search_stats{second_value} = $value;
        }
      }
    }

    if ($value > $best_value) {
      $best_value = $value;
      $best_move = $move;
      $best_move_key = $child_prev_move_key;
    }

    if ($value > $alpha) {
      $alpha = $value;
      if ($alpha >= $beta) {
        unless ($is_capture) {
          _store_killer($ply, $child_prev_move_key);
          _update_history($child_prev_move_key, $depth);
          _store_countermove($prev_move_key, $child_prev_move_key);
        }
        last;
      }
    }
  }

  if (! $legal_moves) {
    if ($ply == 0) {
      $root_search_stats{legal_moves} = 0;
      $root_search_stats{best_value} = undef;
      $root_search_stats{second_value} = undef;
      $root_search_stats{best_move_key} = undef;
    }
    my $mate_or_draw = $state->is_checked ? (-MATE_SCORE + $ply) : 0;
    return ($mate_or_draw, undef);
  }

  my $flag = TT_FLAG_EXACT;
  if ($best_value <= $alpha_orig) {
    $flag = TT_FLAG_UPPER;
  } elsif ($best_value >= $beta_orig) {
    $flag = TT_FLAG_LOWER;
  }

  my $existing = $transposition_table{$key};
  if (!defined $existing || $depth >= ($existing->{depth} // -1) || ($existing->{gen} // 0) != $tt_generation) {
    $tt_size++ unless defined $existing;
    $transposition_table{$key} = {
      depth => $depth,
      score => $best_value,
      flag => $flag,
      gen => $tt_generation,
      best_move_key => $best_move_key,
    };
    if ($tt_size > TT_MAX_ENTRIES + TT_TRIM_INSERT_SLACK) {
      _trim_transposition_table();
    }
  }

  return ($best_value, $best_move);
}

#  mainly a converience wrapper around rec_think.
sub think {
  my $self = shift;
  my $on_update;
  $on_update = shift if @_ && ref($_[0]) eq 'CODE';
  $on_update = undef unless defined $on_update && ref($on_update) eq 'CODE';
  my %think_opts;
  if (scalar(@_) == 1 && ref($_[0]) eq 'HASH') {
    %think_opts = %{$_[0]};
  } elsif (@_ % 2 == 0) {
    %think_opts = @_;
  }
  my $use_book = exists $think_opts{use_book} ? ($think_opts{use_book} ? 1 : 0) : 1;
  my $state = ${$self->{state}};
  my $piece_count = _piece_count($state);

  if ($use_book && (my $book_move = Chess::Book::choose_move($state))) {
    return $book_move;
  }

  if (my $table_move = Chess::EndgameTable::choose_move($state)) {
    return $table_move;
  }

  _decay_history();
  @killer_moves = ();
  $tt_generation++;
  _trim_transposition_table();

  my $target_depth = max(1, $self->{depth});
  $target_depth += MID_ENDGAME_DEPTH_BOOST if $piece_count <= MID_ENDGAME_PIECE_THRESHOLD;
  $target_depth += DEEP_ENDGAME_DEPTH_BOOST if $piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD;
  $target_depth = min(20, $target_depth);
  my $max_depth = min(20, $target_depth + EXTRA_DEPTH_ON_UNSTABLE);
  if ($think_opts{strict_depth}) {
    $max_depth = $target_depth;
  }
  my $easy_move_depth = max(EASY_MOVE_MIN_DEPTH, min($target_depth, EASY_MOVE_DEPTH_CAP));
  if ($piece_count <= MID_ENDGAME_PIECE_THRESHOLD) {
    $easy_move_depth = min($target_depth, $easy_move_depth + MID_ENDGAME_EASY_MOVE_EXTRA_DEPTH);
  }
  my $time_policy = _configure_time_limits($state, \%think_opts);
  my $best_move;
  my $prev_score = 0;
  my $last_completed_depth = 0;
  my $last_completed_score;
  my $stability_hits = 0;
  my $stable_best_hits = 0;
  my $prev_best_move_key;
  my $had_prev_score = 0;
  my $pawn_candidate_extension_used = 0;
  my $critical_extension_hits = 0;

  DEPTH_LOOP:
  for my $depth (1 .. $max_depth) {
    last DEPTH_LOOP if $last_completed_depth && _time_up_soft();
    my $alpha = -INF_SCORE;
    my $beta = INF_SCORE;
    my $window = ASPIRATION_WINDOW;
    my $iteration_score;
    my $iteration_move;
    my $aspiration_expansions = 0;

    if ($depth >= 3) {
      $alpha = max(-INF_SCORE, $prev_score - $window);
      $beta = min(INF_SCORE, $prev_score + $window);
    }

    while (1) {
      my ($score, $move);
      my $ok = eval {
        ($score, $move) = _search($state, $depth, $alpha, $beta, 0, undef);
        1;
      };
      if (! $ok) {
        my $err = $@;
        if (defined $err && $err =~ /\Q$search_time_abort\E/) {
          last DEPTH_LOOP;
        }
        die $err;
      }
      $best_move = $move if defined $move;
      $iteration_score = $score;
      $iteration_move = $move if defined $move;

      if ($score <= $alpha) {
        $aspiration_expansions++;
        $alpha = max(-INF_SCORE, $alpha - $window);
        $window *= 2;
        last if $last_completed_depth && _time_up_soft();
        next;
      }
      if ($score >= $beta) {
        $aspiration_expansions++;
        $beta = min(INF_SCORE, $beta + $window);
        $window *= 2;
        last if $last_completed_depth && _time_up_soft();
        next;
      }

      last;
    }

    next unless defined $iteration_score;
    $last_completed_depth = $depth;
    $last_completed_score = $iteration_score;
    my $iteration_move_key = defined $iteration_move ? _move_key($iteration_move) : undef;
    my $pv_changed = defined $iteration_move_key && defined $prev_best_move_key && $iteration_move_key != $prev_best_move_key;
    if (defined $iteration_move_key && defined $prev_best_move_key && $iteration_move_key == $prev_best_move_key) {
      $stable_best_hits++;
    } else {
      $stable_best_hits = 0;
    }

    my $score_delta = $had_prev_score ? abs($iteration_score - $prev_score) : 0;
    my $volatile = $pv_changed || $score_delta > (SCORE_STABILITY_DELTA * 4) || $aspiration_expansions >= 2;
    my $root_legal_moves = $root_search_stats{legal_moves} // 0;
    my $root_gap;
    if (defined $root_search_stats{best_value} && defined $root_search_stats{second_value}) {
      $root_gap = $root_search_stats{best_value} - $root_search_stats{second_value};
    }
    my $near_tie_root = defined $root_gap
      && $root_legal_moves >= 3
      && $root_gap <= ROOT_NEAR_TIE_DELTA;
    my $clear_best_root = defined $root_gap && $root_gap >= ROOT_CLEAR_BEST_DELTA;
    my $forced_or_easy_root = $root_legal_moves == 1
      || ($root_legal_moves >= 2 && $root_legal_moves <= 3
        && $clear_best_root
        && !$pv_changed
        && $aspiration_expansions == 0
        && $score_delta <= (SCORE_STABILITY_DELTA * 2));
    my $critical_position = $volatile || $near_tie_root;

    if ($had_prev_score && abs($iteration_score - $prev_score) <= SCORE_STABILITY_DELTA) {
      $stability_hits++;
    } else {
      $stability_hits = 0;
    }
    $prev_score = $iteration_score;
    $had_prev_score = 1;
    $prev_best_move_key = $iteration_move_key if defined $iteration_move_key;
    if ($on_update && defined $best_move) {
      eval { $on_update->($depth, $iteration_score, $best_move); };
    }

    if ($time_policy->{has_clock}
      && !$time_policy->{panic_level}
      && $critical_position
      && !$forced_or_easy_root
      && $critical_extension_hits < CRITICAL_EXTENSION_MAX_HITS)
    {
      my $extra_share = $near_tie_root ? CRITICAL_EXTRA_TIME_SHARE : 0.20;
      my $extra_ms = int(($time_policy->{budget_ms} || 0) * $extra_share);
      $extra_ms = min(CRITICAL_EXTRA_TIME_MAX_MS, $extra_ms);
      if ($extra_ms > 0) {
        _extend_soft_deadline($extra_ms);
        $critical_extension_hits++;
      }
    }

    if ($time_policy->{has_clock}
      && $forced_or_easy_root
      && !$critical_position
      && $depth >= max(3, $easy_move_depth - 1)
      && $stable_best_hits >= 1)
    {
      last DEPTH_LOOP;
    }

    if ($time_policy->{has_clock}
      && !$time_policy->{panic_level}
      && !$pawn_candidate_extension_used
      && $depth >= 3
      && _is_middlegame_piece_count($piece_count)
      && ($time_policy->{budget_ms} || 0) >= PAWN_CANDIDATE_MIN_BUDGET_MS
      && defined $iteration_move
      && _is_pawn_move_in_state($state, $iteration_move))
    {
      my $extra_ms = int(($time_policy->{budget_ms} || 0) * PAWN_CANDIDATE_EXTRA_TIME_SHARE);
      $extra_ms = min(PAWN_CANDIDATE_EXTRA_TIME_MAX_MS, $extra_ms);
      if ($extra_ms > 0) {
        _extend_soft_deadline($extra_ms);
        $pawn_candidate_extension_used = 1;
      }
    }

    if ($time_policy->{has_clock} && $depth >= $easy_move_depth) {
      my $easy_move = !$critical_position
        && $stable_best_hits >= 2
        && $score_delta <= SCORE_STABILITY_DELTA
        && $aspiration_expansions == 0;
      last DEPTH_LOOP if $easy_move;
    }

    if ($depth >= $target_depth) {
      last if $stability_hits >= 1;
      last if _time_up_soft();
    }
  }

  if (!defined $best_move) {
    my @legal = $state->generate_moves;
    $best_move = $legal[0] if @legal;
  }

  $last_completed_score = _evaluate_board($state) unless defined $last_completed_score;
  $last_completed_depth = 1 unless $last_completed_depth;
  return wantarray
    ? ($best_move, $last_completed_score, $last_completed_depth)
    : $best_move;
}

1;
