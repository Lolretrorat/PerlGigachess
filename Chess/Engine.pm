package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::EndgameTable;
use Chess::TableUtil qw(canonical_fen_key);
use Chess::TranspositionTable;
use Chess::See;
use Chess::TimeManager;
use Chess::Eval qw(evaluate_position);
use Chess::Heuristics qw(:engine);
use Chess::Plan qw(
  is_quiet_plan_move
  pressure_score_for_side
  quiet_move_order_bonus
  state_plan_tags
);
use Chess::EvalTerms qw(
  piece_values
  flip_idx
  square_of_idx
  location_modifier_percent
  location_bonus
  is_square_attacked_by_side
  find_piece_idx
  development_score
  passed_pawn_score
  hanging_piece_score
  threatened_material_summary
  least_attacker_value
  is_quiet_hanging_move
  hanging_move_penalty
  king_ring_indices
  king_danger_for_piece
  king_danger_score
  non_king_piece_count
  king_aggression_for_piece
  king_aggression_score
  is_king_safety_critical_move
  is_tactical_queen_move
  unsafe_capture_penalty
  capture_plan_order_bonus
  promotion_check_order_bonus
  piece_count
  is_middlegame_piece_count
  is_pawn_move_in_state
  is_sac_candidate_move_in_state
  has_non_pawn_material
  make_null_move_state
);
use Chess::Search qw(
  reset_root_search_stats
  finalize_root_search_stats
  root_search_stats
  maybe_randomize_tied_root_move
  has_sac_candidate_with_score_drop
  collect_root_pv_lines
);

use Chess::Book;
use Chess::MovePicker qw(generate_moves collect_legal_moves);
use Chess::See ();

use List::Util qw(max min);


my $THREADING_AVAILABLE = eval {
  require threads;
  require Thread::Queue;
  1;
} ? 1 : 0;

my $root_search_stats = root_search_stats();
my $transposition_table = Chess::TranspositionTable->new(
  max_entries => TT_MAX_ENTRIES,
  cluster_size => TT_CLUSTER_SIZE,
  age_weight => TT_REPLACE_AGE_WEIGHT,
  shared => $THREADING_AVAILABLE,
);
my %eval_cache;
my %piece_values = %{piece_values()};
my @board_indices = Chess::TableUtil::board_indices();
my $move_order = Chess::MovePicker::MoveOrder->new(
  piece_values => \%piece_values,
  location_modifier_percent_cb => \&location_modifier_percent,
  square_of_idx_cb => \&square_of_idx,
  unsafe_capture_penalty_cb => \&unsafe_capture_penalty,
  capture_plan_order_bonus_cb => \&capture_plan_order_bonus,
  quiet_plan_order_bonus_cb => \&_quiet_plan_order_bonus,
  promotion_check_order_bonus_cb => \&promotion_check_order_bonus,
  is_sac_candidate_move_cb => \&is_sac_candidate_move_in_state,
  piece_count_cb => \&piece_count,
);

my $search_time_manager = Chess::TimeManager->new(
  check_interval_nodes => TIME_CHECK_INTERVAL_NODES,
);
my $search_quiesce_limit = QUIESCE_MAX_DEPTH;
my $search_time_abort = "__TIMEUP__";
my $eval_cache_tag = 'core';
my %root_regression_prev_scores;
my %root_regression_current_scores;
my $root_plan_tags = [];

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 8; # bigger number more thinky
  my $opts = shift;
  my $workers = 1;
  if (defined $opts) {
    if (ref($opts) eq 'HASH') {
      $workers = exists $opts->{workers} ? $opts->{workers} : 1;
    } else {
      $workers = $opts;
    }
  }
  $self{workers} = _normalize_worker_count($workers);

  # hi ken
  return bless \%self, $class;
}

sub _normalize_worker_count {
  my ($value) = @_;
  $value = 1 unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = 1 if $value < 1;
  $value = MAX_ROOT_WORKERS if $value > MAX_ROOT_WORKERS;
  return $value;
}

sub _normalize_multipv {
  my ($value) = @_;
  $value = 1 unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = 1 if $value < 1;
  $value = MAX_MULTIPV if $value > MAX_MULTIPV;
  return $value;
}

sub _reset_root_search_stats {
  reset_root_search_stats();
  $root_search_stats = root_search_stats();
}

sub _finalize_root_search_stats {
  my ($legal_moves) = @_;
  finalize_root_search_stats($legal_moves);
  $root_search_stats = root_search_stats();
}

sub _reset_root_regression_state {
  %root_regression_prev_scores = ();
  %root_regression_current_scores = ();
}

sub _begin_root_regression_depth {
  %root_regression_current_scores = ();
}

sub _commit_root_regression_depth {
  %root_regression_prev_scores = %root_regression_current_scores;
}

sub _root_regression_penalty {
  my ($move_key, $raw_score, $depth) = @_;
  return 0 unless defined $move_key && defined $raw_score;
  return 0 unless defined $depth && $depth >= ROOT_SCORE_DROP_MIN_DEPTH;
  my $prev_score = $root_regression_prev_scores{$move_key};
  return 0 unless defined $prev_score;
  return 0 if abs($prev_score) >= (MATE_SCORE - NULL_MOVE_MATE_GUARD);
  return 0 if abs($raw_score) >= (MATE_SCORE - NULL_MOVE_MATE_GUARD);

  my $drop = int($prev_score - $raw_score);
  return 0 unless $drop > ROOT_SCORE_DROP_THRESHOLD_CP;

  my $penalty = int(($drop - ROOT_SCORE_DROP_THRESHOLD_CP) * ROOT_SCORE_DROP_PENALTY_SCALE + 0.5);
  $penalty = 0 if $penalty < 0;
  $penalty = ROOT_SCORE_DROP_MAX_PENALTY_CP if $penalty > ROOT_SCORE_DROP_MAX_PENALTY_CP;
  return $penalty;
}

sub _maybe_randomize_tied_root_move {
  my ($state, $best_move, $opts) = @_;
  return maybe_randomize_tied_root_move($state, $best_move, $opts, \&_find_move_by_key);
}

sub _clamp {
  my ($value, $min, $max) = @_;
  return Chess::EvalTerms::clamp($value, $min, $max);
}

sub _location_bonus {
  my ($piece, $square, $base_value) = @_;
  return location_bonus($piece, $square, $base_value);
}

sub _flip_idx {
  my ($idx) = @_;
  return flip_idx($idx);
}

sub _rank_of_idx {
  my ($idx) = @_;
  return Chess::EvalTerms::rank_of_idx($idx);
}

sub _file_of_idx {
  my ($idx) = @_;
  return Chess::EvalTerms::file_of_idx($idx);
}

sub _square_of_idx {
  my ($idx) = @_;
  return square_of_idx($idx);
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

sub _is_candidate_passed_pawn {
  my ($board, $idx, $side_sign) = @_;
  return 0 unless $side_sign == 1 || $side_sign == -1;
  return 0 if _is_passed_pawn($board, $idx, $side_sign);

  my $file = _file_of_idx($idx);
  my $rank = _rank_of_idx($idx);
  my $enemy_pawn = -$side_sign * PAWN;
  my $friendly_pawn = $side_sign * PAWN;
  my $has_support = 0;

  for my $adj_file ($file - 1, $file + 1) {
    next if $adj_file < 1 || $adj_file > 8;
    for my $support_rank ($rank - 1 .. $rank + 1) {
      next if $support_rank < 1 || $support_rank > 8;
      my $support_idx = ($support_rank + 1) * 10 + $adj_file;
      if (($board->[$support_idx] // 0) == $friendly_pawn) {
        $has_support = 1;
        last;
      }
    }
  }
  return 0 unless $has_support;

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

sub _pawns_by_file_counts {
  my ($board, $side_sign) = @_;
  my @counts = (0) x 9;
  my $target = $side_sign * PAWN;
  for my $idx (@board_indices) {
    next unless ($board->[$idx] // 0) == $target;
    my $file = _file_of_idx($idx);
    $counts[$file]++;
  }
  return \@counts;
}

sub _pawn_island_count {
  my ($counts) = @_;
  return 0 unless ref($counts) eq 'ARRAY';
  my $islands = 0;
  my $in_island = 0;
  for my $file (1 .. 8) {
    if (($counts->[$file] // 0) > 0) {
      if (!$in_island) {
        $islands++;
        $in_island = 1;
      }
    } else {
      $in_island = 0;
    }
  }
  return $islands;
}

sub _king_distance {
  my ($from_idx, $to_idx) = @_;
  return 0 unless defined $from_idx && defined $to_idx;
  my $file_delta = abs(_file_of_idx($from_idx) - _file_of_idx($to_idx));
  my $rank_delta = abs(_rank_of_idx($from_idx) - _rank_of_idx($to_idx));
  return max($file_delta, $rank_delta);
}

sub _centralization_bonus {
  my ($idx) = @_;
  return 0 unless defined $idx;
  my $file = _file_of_idx($idx);
  my $rank = _rank_of_idx($idx);
  my $file_dist = abs(4.5 - $file);
  my $rank_dist = abs(4.5 - $rank);
  my $bonus = 4 - ($file_dist + $rank_dist) / 2;
  return int($bonus + ($bonus < 0 ? -0.5 : 0.5));
}

sub _piece_attacks_square {
  my ($board, $from_idx, $piece, $target_idx) = @_;
  return 0 unless defined $from_idx && defined $target_idx && defined $piece;
  my $abs_piece = abs($piece);
  my $side_sign = $piece > 0 ? 1 : -1;
  my $delta = $target_idx - $from_idx;

  if ($abs_piece == PAWN) {
    return 1 if $side_sign > 0 && ($delta == 9 || $delta == 11);
    return 1 if $side_sign < 0 && ($delta == -9 || $delta == -11);
    return 0;
  }

  if ($abs_piece == KNIGHT) {
    for my $inc (-21, -19, -12, -8, 8, 12, 19, 21) {
      return 1 if $delta == $inc;
    }
    return 0;
  }

  if ($abs_piece == KING) {
    for my $inc (-11, -10, -9, -1, 1, 9, 10, 11) {
      return 1 if $delta == $inc;
    }
    return 0;
  }

  my @directions;
  if ($abs_piece == BISHOP) {
    @directions = (-11, -9, 9, 11);
  } elsif ($abs_piece == ROOK) {
    @directions = (-10, -1, 1, 10);
  } elsif ($abs_piece == QUEEN) {
    @directions = (-11, -10, -9, -1, 1, 9, 10, 11);
  } else {
    return 0;
  }

  for my $inc (@directions) {
    my $cursor = $from_idx;
    while (1) {
      $cursor += $inc;
      my $occupant = $board->[$cursor] // OOB;
      last if $occupant == OOB;
      return 1 if $cursor == $target_idx;
      last if $occupant != EMPTY;
    }
  }
  return 0;
}

sub _piece_mobility_count {
  my ($board, $idx, $piece) = @_;
  my $abs_piece = abs($piece);
  my $side_sign = $piece > 0 ? 1 : -1;
  my $count = 0;

  if ($abs_piece == KNIGHT || $abs_piece == KING) {
    my @incs = $abs_piece == KNIGHT
      ? (-21, -19, -12, -8, 8, 12, 19, 21)
      : (-11, -10, -9, -1, 1, 9, 10, 11);
    for my $inc (@incs) {
      my $dest = $idx + $inc;
      my $occupant = $board->[$dest] // OOB;
      next if $occupant == OOB;
      next if ($occupant * $side_sign) > 0;
      $count++;
    }
    return $count;
  }

  if ($abs_piece == PAWN) {
    my $push_inc = $side_sign > 0 ? 10 : -10;
    my $one_step = $idx + $push_inc;
    $count++ if ($board->[$one_step] // OOB) == EMPTY;
    for my $cap_inc ($side_sign > 0 ? (9, 11) : (-9, -11)) {
      my $dest = $idx + $cap_inc;
      my $occupant = $board->[$dest] // OOB;
      next if $occupant == OOB;
      next if ($occupant * $side_sign) > 0;
      $count++;
    }
    return $count;
  }

  my @directions = $abs_piece == BISHOP
    ? (-11, -9, 9, 11)
    : $abs_piece == ROOK
      ? (-10, -1, 1, 10)
      : (-11, -10, -9, -1, 1, 9, 10, 11);
  for my $inc (@directions) {
    my $cursor = $idx;
    while (1) {
      $cursor += $inc;
      my $occupant = $board->[$cursor] // OOB;
      last if $occupant == OOB;
      last if ($occupant * $side_sign) > 0;
      $count++;
      last if $occupant != EMPTY;
    }
  }

  return $count;
}

sub _is_knight_outpost {
  my ($board, $idx, $side_sign, $attack_cache) = @_;
  my $piece = $board->[$idx] // 0;
  return 0 unless abs($piece) == KNIGHT;
  my $rank = _rank_of_idx($idx);
  return 0 if $side_sign > 0 && $rank < 5;
  return 0 if $side_sign < 0 && $rank > 4;
  return 0 unless _is_square_attacked_by_side($board, $idx, $side_sign, $attack_cache);

  my $enemy_pawn = -$side_sign * PAWN;
  my $file = _file_of_idx($idx);
  for my $adj_file ($file - 1, $file + 1) {
    next if $adj_file < 1 || $adj_file > 8;
    if ($side_sign > 0) {
      for (my $check_rank = $rank + 1; $check_rank <= 8; $check_rank++) {
        my $check_idx = ($check_rank + 1) * 10 + $adj_file;
        return 0 if ($board->[$check_idx] // 0) == $enemy_pawn;
      }
    } else {
      for (my $check_rank = $rank - 1; $check_rank >= 1; $check_rank--) {
        my $check_idx = ($check_rank + 1) * 10 + $adj_file;
        return 0 if ($board->[$check_idx] // 0) == $enemy_pawn;
      }
    }
  }

  return 1;
}

sub _development_score {
  my ($board, $opts) = @_;
  $opts ||= {};
  my $piece_count = $opts->{piece_count};
  if (!defined $piece_count) {
    $piece_count = 0;
    for my $idx (@board_indices) {
      my $abs_piece = abs($board->[$idx] // 0);
      $piece_count++ if $abs_piece >= PAWN && $abs_piece <= KING;
    }
  }

  return _development_score_for_side($board, 1, $piece_count)
    - _development_score_for_side($board, -1, $piece_count);
}

sub _development_score_for_side {
  my ($board, $side_sign, $piece_count) = @_;
  return 0 unless $side_sign == 1 || $side_sign == -1;

  my $score = 0;
  my $king_walk_phase = 0;
  if ($piece_count > MID_ENDGAME_PIECE_THRESHOLD) {
    my $phase_span = max(1, OPENING_PIECE_COUNT_THRESHOLD - MID_ENDGAME_PIECE_THRESHOLD);
    $king_walk_phase = _clamp(($piece_count - MID_ENDGAME_PIECE_THRESHOLD) / $phase_span, 0, 1);
  }

  my $king_piece = $side_sign * KING;
  my $queen_piece = $side_sign * QUEEN;
  my $rook_piece = $side_sign * ROOK;
  my $opp_queen_piece = -$side_sign * QUEEN;

  my ($king_home, $queen_home, $castle_a, $castle_b, $rook_homes, $knight_homes, $bishop_homes)
    = $side_sign > 0
      ? (25, 24, 23, 27, [21, 28], [22, 27], [23, 26])
      : (95, 94, 93, 97, [91, 98], [92, 97], [93, 96]);

  my $king_idx = _find_piece_idx($board, $king_piece);
  return 0 unless defined $king_idx;

  my $is_castled = ($king_idx == $castle_a || $king_idx == $castle_b) ? 1 : 0;
  my $uncastled = defined $king_idx && !$is_castled;
  my $undeveloped_minors = 0;
  for my $home (@{$knight_homes}) {
    $undeveloped_minors++ if ($board->[$home] // 0) == ($side_sign * KNIGHT);
  }
  for my $home (@{$bishop_homes}) {
    $undeveloped_minors++ if ($board->[$home] // 0) == ($side_sign * BISHOP);
  }

  $score -= $undeveloped_minors * DEVELOPMENT_MINOR_PENALTY;
  if ($piece_count >= OPENING_PIECE_COUNT_THRESHOLD) {
    $score -= $undeveloped_minors * OPENING_DEVELOPMENT_EXTRA_PENALTY;
  }

  if ($uncastled && $undeveloped_minors > 0) {
    my ($rook_count, $rook_home_count) = (0, 0);
    for my $idx (@board_indices) {
      next unless ($board->[$idx] // 0) == $rook_piece;
      $rook_count++;
      $rook_home_count++ if grep { $_ == $idx } @{$rook_homes};
    }
    my $moved_rooks = max(0, $rook_count - $rook_home_count);
    $score -= EARLY_ROOK_MOVE_PENALTY * $moved_rooks if $moved_rooks;

    my $queen_idx = _find_piece_idx($board, $queen_piece);
    if (defined $queen_idx && $queen_idx != $queen_home && $undeveloped_minors >= 2) {
      $score -= EARLY_QUEEN_MOVE_PENALTY;
    }
  }

  if ($uncastled && $king_idx != $king_home && $king_walk_phase > 0) {
    my $file = _file_of_idx($king_idx);
    my $rank = _rank_of_idx($king_idx);
    my $advance_steps = $side_sign > 0 ? max(0, $rank - 1) : max(0, 8 - $rank);
    my $walk_penalty = EARLY_KING_WALK_HOME_PENALTY;
    $walk_penalty += EARLY_KING_WALK_EXPOSED_FILE_PENALTY if $file >= 3 && $file <= 6;
    $walk_penalty += EARLY_KING_WALK_CENTRAL_FILE_PENALTY if $file >= 4 && $file <= 6;
    $walk_penalty += EARLY_KING_WALK_ADVANCED_RANK_PENALTY if $advance_steps >= 1;
    $score -= int($walk_penalty * $king_walk_phase + 0.5);
  }

  my $opponent_has_queen = defined _find_piece_idx($board, $opp_queen_piece) ? 1 : 0;
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
      $score += PASSED_PAWN_BONUS_BY_RANK->[$rank] // 0;
      if ($rank >= 6 && ($board->[$idx + 10] // OOB) == EMPTY) {
        $score += 2;
      }
    } elsif ($piece == OPP_PAWN && _is_passed_pawn($board, $idx, -1)) {
      my $rank = _rank_of_idx($idx);
      $score -= ENEMY_PASSED_PAWN_PENALTY_BY_RANK->[$rank] // 0;
      if ($rank <= 3 && ($board->[$idx - 10] // OOB) == EMPTY) {
        $score -= 2;
      }
    }
  }

  return $score;
}

sub _pawn_structure_score {
  my ($board) = @_;
  my $score = 0;
  my $friendly_counts = _pawns_by_file_counts($board, 1);
  my $enemy_counts = _pawns_by_file_counts($board, -1);

  for my $file (1 .. 8) {
    my $friendly = $friendly_counts->[$file] // 0;
    my $enemy = $enemy_counts->[$file] // 0;
    $score -= ($friendly - 1) * PAWN_DOUBLED_PENALTY if $friendly > 1;
    $score += ($enemy - 1) * PAWN_DOUBLED_PENALTY if $enemy > 1;
  }

  my $friendly_islands = _pawn_island_count($friendly_counts);
  my $enemy_islands = _pawn_island_count($enemy_counts);
  $score -= max(0, $friendly_islands - 1) * PAWN_ISLAND_PENALTY;
  $score += max(0, $enemy_islands - 1) * PAWN_ISLAND_PENALTY;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece == PAWN || $piece == OPP_PAWN;
    my $side_sign = $piece > 0 ? 1 : -1;
    my $file = _file_of_idx($idx);
    my $rank = _rank_of_idx($idx);
    my $counts = $side_sign > 0 ? $friendly_counts : $enemy_counts;
    my $delta = 0;

    my $left = $file > 1 ? ($counts->[$file - 1] // 0) : 0;
    my $right = $file < 8 ? ($counts->[$file + 1] // 0) : 0;
    $delta -= PAWN_ISOLATED_PENALTY if !$left && !$right;

    my $connected = 0;
    for my $adj_file ($file - 1, $file + 1) {
      next if $adj_file < 1 || $adj_file > 8;
      for my $adj_rank ($rank - 1 .. $rank + 1) {
        next if $adj_rank < 1 || $adj_rank > 8;
        my $adj_idx = ($adj_rank + 1) * 10 + $adj_file;
        if (($board->[$adj_idx] // 0) == $piece) {
          $connected = 1;
          last;
        }
      }
      last if $connected;
    }
    $delta += PAWN_CONNECTED_BONUS if $connected;
    $delta += PAWN_CANDIDATE_BONUS if _is_candidate_passed_pawn($board, $idx, $side_sign);

    $score += $side_sign > 0 ? $delta : -$delta;
  }

  return $score;
}

sub _piece_activity_score {
  my ($board, $attack_cache) = @_;
  my $score = 0;
  my $friendly_counts = _pawns_by_file_counts($board, 1);
  my $enemy_counts = _pawns_by_file_counts($board, -1);
  my ($friendly_bishops, $enemy_bishops) = (0, 0);

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    my $side_sign = $piece > 0 ? 1 : -1;
    my $abs_piece = abs($piece);
    my $delta = 0;

    if ($abs_piece == BISHOP) {
      if ($side_sign > 0) {
        $friendly_bishops++;
      } else {
        $enemy_bishops++;
      }
    }

    if ($abs_piece == KNIGHT) {
      $delta += _piece_mobility_count($board, $idx, $piece) * KNIGHT_MOBILITY_BONUS;
      $delta += KNIGHT_OUTPOST_BONUS if _is_knight_outpost($board, $idx, $side_sign, $attack_cache);
    } elsif ($abs_piece == BISHOP) {
      $delta += _piece_mobility_count($board, $idx, $piece) * BISHOP_MOBILITY_BONUS;
    } elsif ($abs_piece == ROOK) {
      $delta += _piece_mobility_count($board, $idx, $piece) * ROOK_MOBILITY_BONUS;
      my $file = _file_of_idx($idx);
      my $friendly_file_pawns = $side_sign > 0 ? ($friendly_counts->[$file] // 0) : ($enemy_counts->[$file] // 0);
      my $enemy_file_pawns = $side_sign > 0 ? ($enemy_counts->[$file] // 0) : ($friendly_counts->[$file] // 0);
      if ($friendly_file_pawns == 0) {
        $delta += $enemy_file_pawns == 0 ? ROOK_OPEN_FILE_BONUS : ROOK_SEMIOPEN_FILE_BONUS;
      }
      my $rank = _rank_of_idx($idx);
      $delta += ROOK_SEVENTH_RANK_BONUS if ($side_sign > 0 && $rank == 7) || ($side_sign < 0 && $rank == 2);
    } elsif ($abs_piece == QUEEN) {
      $delta += _piece_mobility_count($board, $idx, $piece) * QUEEN_MOBILITY_BONUS;
    }

    $score += $side_sign > 0 ? $delta : -$delta;
  }

  $score += BISHOP_PAIR_BONUS if $friendly_bishops >= 2;
  $score -= BISHOP_PAIR_BONUS if $enemy_bishops >= 2;
  return $score;
}

sub _threat_score {
  my ($board, $attack_cache, $our_king_idx, $opp_king_idx) = @_;
  my $score = pressure_score_for_side($board, 1, -1, $attack_cache)
    - pressure_score_for_side($board, -1, 1, $attack_cache);
  my $summary = threatened_material_summary($board, $attack_cache);
  if (ref($summary) eq 'HASH') {
    my $delta = $summary->{threatened_delta} // 0;
    $score += int($delta / THREATENED_PAWN_PENALTY) if $delta;
  }

  if (defined $opp_king_idx && _is_square_attacked_by_side($board, $opp_king_idx, 1, $attack_cache)) {
    $score += THREAT_SAFE_CHECK_BONUS;
  }
  if (defined $our_king_idx && _is_square_attacked_by_side($board, $our_king_idx, -1, $attack_cache)) {
    $score -= THREAT_SAFE_CHECK_BONUS;
  }

  return $score;
}

sub _endgame_score {
  my ($board, $piece_count, $our_king_idx, $opp_king_idx) = @_;
  return 0 unless defined $piece_count && $piece_count <= MID_ENDGAME_PIECE_THRESHOLD;
  my $score = 0;

  $score += _centralization_bonus($our_king_idx) * ENDGAME_KING_CENTER_BONUS if defined $our_king_idx;
  $score -= _centralization_bonus($opp_king_idx) * ENDGAME_KING_CENTER_BONUS if defined $opp_king_idx;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece == PAWN || $piece == OPP_PAWN;
    my $side_sign = $piece > 0 ? 1 : -1;
    next unless _is_passed_pawn($board, $idx, $side_sign);
    my $friendly_king = $side_sign > 0 ? $our_king_idx : $opp_king_idx;
    my $enemy_king = $side_sign > 0 ? $opp_king_idx : $our_king_idx;
    next unless defined $friendly_king && defined $enemy_king;
    my $support_delta = _king_distance($enemy_king, $idx) - _king_distance($friendly_king, $idx);
    my $delta = $support_delta * ENDGAME_PASSED_PAWN_BONUS;
    $score += $side_sign > 0 ? $delta : -$delta;
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
    my $penalty = HANGING_PIECE_PENALTY->{$abs_piece} // 0;
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

sub _threatened_material_summary {
  my ($board, $attack_cache) = @_;
  return threatened_material_summary($board, $attack_cache);
}

sub _least_attacker_value {
  my ($board, $target_idx, $attacker_sign) = @_;
  return unless $attacker_sign == 1 || $attacker_sign == -1;

  my $pawn = $attacker_sign * PAWN;
  my $knight = $attacker_sign * KNIGHT;
  my $bishop = $attacker_sign * BISHOP;
  my $rook = $attacker_sign * ROOK;
  my $queen = $attacker_sign * QUEEN;
  my $king = $attacker_sign * KING;

  my $best;
  my $update_best = sub {
    my ($piece) = @_;
    return unless defined $piece;
    my $value = abs($piece_values{$piece} // 0);
    return unless $value > 0;
    $best = $value if !defined($best) || $value < $best;
  };

  if ($attacker_sign > 0) {
    $update_best->($pawn) if (($board->[$target_idx - 11] // OOB) == $pawn);
    $update_best->($pawn) if (($board->[$target_idx - 9] // OOB) == $pawn);
  } else {
    $update_best->($pawn) if (($board->[$target_idx + 11] // OOB) == $pawn);
    $update_best->($pawn) if (($board->[$target_idx + 9] // OOB) == $pawn);
  }

  for my $inc (-21, -19, -12, -8, 8, 12, 19, 21) {
    $update_best->($knight) if (($board->[$target_idx + $inc] // OOB) == $knight);
  }

  for my $inc (-11, -10, -9, -1, 1, 9, 10, 11) {
    $update_best->($king) if (($board->[$target_idx + $inc] // OOB) == $king);
  }

  for my $inc (-10, -1, 1, 10) {
    my $dest = $target_idx;
    while (1) {
      $dest += $inc;
      my $piece = $board->[$dest] // OOB;
      next if $piece == EMPTY;
      if ($piece == $rook || $piece == $queen) {
        $update_best->($piece);
      }
      last;
    }
  }

  for my $inc (-11, -9, 9, 11) {
    my $dest = $target_idx;
    while (1) {
      $dest += $inc;
      my $piece = $board->[$dest] // OOB;
      next if $piece == EMPTY;
      if ($piece == $bishop || $piece == $queen) {
        $update_best->($piece);
      }
      last;
    }
  }

  return $best;
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
  my $base = HANGING_PIECE_PENALTY->{$moved_piece} // 0;
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
  my %zone = map { $_ => 1 } ($king_idx, @ring);
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

  my $attack_units = 0;
  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    next unless ($piece * $enemy_sign) > 0;
    my $abs_piece = abs($piece);
    next if $abs_piece < KNIGHT || $abs_piece > QUEEN;
    for my $sq (keys %zone) {
      next unless _piece_attacks_square($board, $idx, $piece, $sq);
      $attack_units += 1 if $abs_piece == KNIGHT || $abs_piece == BISHOP;
      $attack_units += 2 if $abs_piece == ROOK;
      $attack_units += 3 if $abs_piece == QUEEN;
      last;
    }
  }
  $danger += $attack_units * KING_DANGER_ATTACK_UNIT_PENALTY if $attack_units;

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
  my $king_idx = _find_piece_idx($board, $king_piece);
  return 0 unless defined $king_idx;

  my $phase = (KING_AGGRESSION_ENEMY_PIECE_START - $enemy_piece_count) / KING_AGGRESSION_ENEMY_PIECE_START;
  my $rank = _rank_of_idx($king_idx);
  my $file = _file_of_idx($king_idx);
  my $advance = $king_piece > 0 ? max(0, $rank - 1) : max(0, 8 - $rank);
  my $center = max(0, 4 - int(abs(4.5 - $file) + abs(4.5 - $rank)));
  my $activity = $advance + $center;
  return 0 unless $activity > 0;
  return int(($activity * $phase * KING_AGGRESSION_RANK_BONUS / 2) + 0.5);
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
  my ($from_piece, $move, $new_state, $own_king_danger, $king_idx, $ring_ref) = @_;
  return 1 if $from_piece == KING;
  return 1 if $new_state->is_checked;

  return 1 if defined $own_king_danger && $own_king_danger >= LMR_KING_DANGER_THRESHOLD;
  return 0 unless defined $king_idx;

  my $king_file = _file_of_idx($king_idx);
  if ($from_piece == PAWN && abs(_file_of_idx($move->[0]) - $king_file) <= 1) {
    return 1;
  }

  if (ref($ring_ref) eq 'HASH') {
    return 1 if $ring_ref->{$move->[0]} || $ring_ref->{$move->[1]};
  }

  return 0;
}

sub _is_tactical_queen_move {
  my ($from_piece, $new_state, $is_capture) = @_;
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
    my @undo_stack;
    if (defined $state->do_move($move, \@undo_stack)) {
      my $new_board = $state->[Chess::State::BOARD];
      my $king_danger_after = _king_danger_for_piece($new_board, OPP_KING);
      my $delta = $king_danger_after - $king_danger_before;
      $penalty += $delta * UNSAFE_CAPTURE_KING_EXPOSURE_WEIGHT if $delta > 0;
      $state->undo_move(\@undo_stack);
    }
  }

  return $penalty;
}

sub _quiet_move_threat_flags {
  my ($parent_board, $threat_summary_before, $enemy_king_danger_before, $new_state);
  if (ref($_[0]) eq 'ARRAY') {
    ($parent_board, $threat_summary_before, $enemy_king_danger_before, $new_state) = @_;
  } else {
    ($threat_summary_before, $enemy_king_danger_before, $new_state) = @_;
  }
  return (0, 0)
    unless ref($threat_summary_before) eq 'HASH'
      && defined $new_state;

  my %post_attack_cache;
  my $new_board = $new_state->[Chess::State::BOARD];
  my $threat_summary_after = _threatened_material_summary($new_board, \%post_attack_cache);

  my $our_threatened_before = $threat_summary_before->{threatened_ours} // 0;
  my $their_threatened_before = $threat_summary_before->{threatened_theirs} // 0;
  my $our_threatened_after = $threat_summary_after->{threatened_theirs} // 0;
  my $their_threatened_after = $threat_summary_after->{threatened_ours} // 0;

  my $threat_relief = $our_threatened_before - $our_threatened_after;
  my $threat_pressure = $their_threatened_after - $their_threatened_before;
  if (ref($parent_board) eq 'ARRAY') {
    my $pressure_before = pressure_score_for_side($parent_board, 1, -1);
    my $pressure_after = pressure_score_for_side($new_board, -1, 1, \%post_attack_cache);
    my $pressure_relief_before = pressure_score_for_side($parent_board, -1, 1);
    my $pressure_relief_after = pressure_score_for_side($new_board, 1, -1, \%post_attack_cache);

    $threat_relief = max($threat_relief, $pressure_relief_before - $pressure_relief_after);
    $threat_pressure = max($threat_pressure, $pressure_after - $pressure_before);
  }
  my $enemy_king_danger_after = _king_danger_for_piece($new_board, KING, \%post_attack_cache);
  my $king_pressure = $enemy_king_danger_after - ($enemy_king_danger_before // 0);

  my $is_threat_response = $threat_relief >= THREAT_RESPONSE_DELTA_THRESHOLD ? 1 : 0;
  my $is_strategic_threat = (
    $threat_pressure >= STRATEGIC_THREAT_DELTA_THRESHOLD
      || $king_pressure >= STRATEGIC_THREAT_KING_DANGER_DELTA
  ) ? 1 : 0;

  return ($is_threat_response, $is_strategic_threat);
}

sub _capture_plan_order_bonus {
  my ($board, $move, $from_piece, $to_piece) = @_;
  return 0 unless $to_piece < 0;

  my $bonus = 0;
  my $dest_idx = $move->[1];
  my $defended = _is_square_attacked_by_side($board, $dest_idx, -1) ? 1 : 0;
  $bonus += UNGUARDED_CAPTURE_ORDER_BONUS if !$defended;

  my $attacker_value = abs($piece_values{$from_piece} // 0);
  my $victim_value = abs($piece_values{$to_piece} // 0);
  if ($attacker_value > 0
      && $victim_value > 0
      && $attacker_value <= ($victim_value + UNGUARDED_TARGET_VALUE_MARGIN)) {
    $bonus += UNGUARDED_CAPTURE_VIABLE_ORDER_BONUS;
  }

  return $bonus;
}

sub _root_plan_tags_apply_at_ply {
  my ($ply) = @_;
  return 0 unless defined $ply && $ply =~ /^\d+$/;
  return 0 if $ply > 2;
  return ($ply % 2) == 0 ? 1 : 0;
}

sub _quiet_plan_order_bonus {
  my ($state, $move, $from_piece, $ply, $opts) = @_;
  my $plan_tags = [];
  if (ref($root_plan_tags) eq 'ARRAY' && _root_plan_tags_apply_at_ply($ply)) {
    $plan_tags = $root_plan_tags;
  }
  return quiet_move_order_bonus($state, $move, {
    plan_tags => $plan_tags,
  });
}

sub _promotion_check_order_bonus {
  my ($state, $move) = @_;
  return 0 unless defined $move->[2];
  my @undo_stack;
  return 0 unless defined $state->do_move($move, \@undo_stack);
  my $is_check = $state->is_checked ? 1 : 0;
  $state->undo_move(\@undo_stack);
  return $is_check ? PROMOTION_CHECK_ORDER_BONUS : 0;
}

sub _ordered_moves {
  my ($state, $ply, $tt_move_key, $prev_move_key) = @_;
  my $picker = _new_move_picker($state, $ply, $tt_move_key, $prev_move_key);
  return $picker->all_moves;
}

sub _new_move_picker {
  my ($state, $ply, $tt_move_key, $prev_move_key, $tt_move, $prev_piece, $prev_to) = @_;
  my $killer_move_keys = $move_order->{killer_moves}[$ply] || [];
  my $countermove_key = defined $prev_move_key ? $move_order->{counter_moves}[$prev_move_key] : undef;
  my %exclude_move_keys;
  my @tt_moves;

  if (defined $tt_move && !defined $tt_move_key) {
    $tt_move_key = _move_key($tt_move);
  }
  if (defined $tt_move) {
    push @tt_moves, $tt_move;
    $exclude_move_keys{$tt_move_key} = 1 if defined $tt_move_key;
  } elsif (defined $tt_move_key) {
    my $resolved_tt_move = _find_move_by_key($state, $tt_move_key);
    if (defined $resolved_tt_move) {
      push @tt_moves, $resolved_tt_move;
      $exclude_move_keys{$tt_move_key} = 1;
    }
  }

  my $move_gen_opts = {
    move_key_cb => \&_move_key,
    exclude_move_keys => \%exclude_move_keys,
  };
  my $legal_moves = generate_moves($state, 'legal', $move_gen_opts);

  my $cont_opts = {};
  $cont_opts->{prev_piece} = $prev_piece if defined $prev_piece;
  $cont_opts->{prev_to} = $prev_to if defined $prev_to;

  return Chess::MovePicker->new(
    state => $state,
    moves => [ @tt_moves, @{$legal_moves} ],
    tt_move_key => $tt_move_key,
    killer_move_keys => $killer_move_keys,
    countermove_key => $countermove_key,
    see_order_weight => SEE_ORDER_WEIGHT,
    see_bad_capture_threshold => SEE_BAD_CAPTURE_THRESHOLD,
    # Do not prune captures by SEE at generation time; this can hide tactical sacs.
    see_prune_threshold => undef,
    move_key_cb => \&_move_key,
    is_capture_cb => sub {
      my ($move) = @_;
      return _is_capture_state($state, $move);
    },
    score_cb => sub {
      my ($move, $move_key, $is_capture) = @_;
      return _move_order_score($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key, $cont_opts);
    },
  );
}

sub _new_quiesce_capture_picker {
  my ($state) = @_;
  return Chess::MovePicker->new(
    state => $state,
    moves => $state->generate_moves_by_type('captures'),
    see_order_weight => SEE_ORDER_WEIGHT,
    see_bad_capture_threshold => SEE_BAD_CAPTURE_THRESHOLD,
    see_prune_threshold => QUIESCE_SEE_PRUNE_THRESHOLD,
    move_key_cb => \&_move_key,
    is_capture_cb => sub { return 1; },
    score_cb => sub {
      my ($move, $move_key, $is_capture) = @_;
      return _move_order_score($state, $move, $move_key, $is_capture, 0);
    },
  );
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
  my ($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key, $opts) = @_;
  return $move_order->score_move($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key, $opts);
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
  return $move_order->move_key($move);
}

sub _store_killer {
  my ($ply, $move_key) = @_;
  $move_order->store_killer($ply, $move_key);
}

sub _store_countermove {
  my ($prev_move_key, $move_key) = @_;
  $move_order->store_countermove($prev_move_key, $move_key);
}

sub _update_history {
  my ($move_key, $depth) = @_;
  $move_order->update_history($move_key, $depth);
}

sub _update_continuation_history {
  my ($prev_piece, $prev_to, $piece, $to, $depth) = @_;
  return unless defined $prev_piece && defined $prev_to;
  my $bonus = $depth * $depth;
  $move_order->update_continuation_history($prev_piece, $prev_to, $piece, $to, $bonus);
}

sub _decay_history {
  $move_order->decay_history();
}

sub _piece_count {
  my ($state) = @_;
  return piece_count($state);
}

sub _is_middlegame_piece_count {
  my ($piece_count) = @_;
  return is_middlegame_piece_count($piece_count);
}

sub _is_pawn_move_in_state {
  my ($state, $move) = @_;
  return is_pawn_move_in_state($state, $move);
}

sub _is_sac_candidate_move_in_state {
  my ($state, $move) = @_;
  return is_sac_candidate_move_in_state($state, $move);
}

sub _has_sac_candidate_with_score_drop {
  my ($state, $drop_cp) = @_;
  return has_sac_candidate_with_score_drop($state, $drop_cp, \&_is_sac_candidate_move_in_state);
}

sub _has_non_pawn_material {
  my ($state) = @_;
  return has_non_pawn_material($state);
}

sub _make_null_move_state {
  my ($state) = @_;
  return make_null_move_state($state);
}

sub _configure_time_limits {
  my ($state, $opts) = @_;
  $opts ||= {};

  $search_time_manager->reset();
  $search_quiesce_limit = QUIESCE_MAX_DEPTH;

  my $piece_count = _piece_count($state);
  my $out_of_book_middlegame = (
    ($opts->{out_of_book} ? 1 : 0)
      && $piece_count >= MIDDLEGAME_MIN_PIECE_COUNT
      && $piece_count <= MIDDLEGAME_MAX_PIECE_COUNT
  ) ? 1 : 0;
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
    my $hard_target = int($mt * TIME_MOVETIME_HARD_SCALE);
    my $hard_cap = $mt + TIME_MOVETIME_HARD_CAP_MS;
    $hard_ms = min($hard_target, $hard_cap);
    $hard_ms = max($budget_ms, $hard_ms);
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
      $horizon = max(8, $horizon + MID_ENDGAME_HORIZON_REDUCTION);
    }
    if ($piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD) {
      $horizon = max(6, $horizon + DEEP_ENDGAME_HORIZON_REDUCTION);
    }
    if ($out_of_book_middlegame) {
      my $post_book_horizon_reduction = int(MID_ENDGAME_HORIZON_REDUCTION / 2);
      $horizon = max(8, $horizon - $post_book_horizon_reduction);
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
    if ($piece_count <= MID_ENDGAME_PIECE_THRESHOLD) {
      $max_share = min($max_share, 0.52);
    }
    if ($piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD) {
      $max_share = min($max_share, 0.42);
    }
    if ($out_of_book_middlegame) {
      $max_share = min(0.75, $max_share + 0.10);
    }
    my $max_budget_ms = int($usable_ms * $max_share) + $inc_ms;
    $max_budget_ms = max(TIME_MIN_BUDGET_MS, $max_budget_ms);
    if ($out_of_book_middlegame) {
      $budget_ms = int($budget_ms * 1.18);
    } elsif ($piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD) {
      $budget_ms = int($budget_ms * 0.70);
    } elsif ($piece_count <= MID_ENDGAME_PIECE_THRESHOLD) {
      $budget_ms = int($budget_ms * 0.82);
    }
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
    $search_time_manager->start_budget_ms($budget_ms, $hard_ms);
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
  return $search_time_manager->soft_deadline_reached();
}

sub _extend_soft_deadline {
  my ($extra_ms) = @_;
  $search_time_manager->extend_soft_budget_ms($extra_ms);
}

sub _check_time_or_abort {
  die $search_time_abort if $search_time_manager->tick_node_and_hard_deadline_reached();
}

sub _volatility_pressure_score {
  my ($opts) = @_;
  $opts = {} unless ref($opts) eq 'HASH';

  my $pressure = 0;
  my $has_instability_signal = ($opts->{volatile} // 0)
    || ($opts->{near_tie_root} // 0)
    || (($opts->{aspiration_expansions} // 0) >= 1)
    || (($opts->{score_delta} // 0) > (SCORE_STABILITY_DELTA * 2));
  $pressure++ if $opts->{volatile};
  $pressure++ if $opts->{near_tie_root};
  $pressure++ if ($opts->{aspiration_expansions} // 0) >= 2;
  $pressure++ if $has_instability_signal
    && !($opts->{forced_or_easy_root} // 0)
    && ($opts->{stable_best_hits} // 0) < 1;
  $pressure++ if ($opts->{score_delta} // 0) > (SCORE_STABILITY_DELTA * 6);
  return $pressure;
}

sub _volatility_extension_ms {
  my ($time_policy, $volatility_pressure, $slack_ms) = @_;
  return 0 unless ref($time_policy) eq 'HASH' && $time_policy->{has_clock};
  return 0 if $time_policy->{panic_level};
  return 0 unless defined $volatility_pressure && $volatility_pressure >= 2;
  return 0 unless ($time_policy->{budget_ms} // 0) >= VOLATILITY_LONG_THINK_MIN_BUDGET_MS;

  $slack_ms = int($slack_ms // 0);
  return 0 if $slack_ms <= TIME_MOVE_OVERHEAD_MS;

  my $pressure_scale = $volatility_pressure / 2;
  my $extra_ms = int(($time_policy->{budget_ms} // 0) * VOLATILITY_LONG_THINK_EXTRA_SHARE * $pressure_scale);
  my $slack_cap = max(0, $slack_ms - TIME_MOVE_OVERHEAD_MS);
  $extra_ms = min($extra_ms, VOLATILITY_LONG_THINK_MAX_MS, $slack_cap);
  return $extra_ms > 0 ? $extra_ms : 0;
}

sub _is_mate_like_score {
  my ($score) = @_;
  return 0 unless defined $score;
  return abs(int($score)) >= (MATE_SCORE - 256) ? 1 : 0;
}

sub _mate_refinement_extension_ms {
  my ($time_policy, $score, $slack_ms) = @_;
  return 0 unless ref($time_policy) eq 'HASH' && $time_policy->{has_clock};
  return 0 if $time_policy->{panic_level};
  return 0 unless defined $score && int($score) > 0;
  return 0 unless _is_mate_like_score($score);
  return 0 unless ($time_policy->{budget_ms} // 0) >= MATE_REFINEMENT_MIN_BUDGET_MS;

  $slack_ms = int($slack_ms // 0);
  return 0 if $slack_ms <= TIME_MOVE_OVERHEAD_MS;

  my $extra_ms = int(($time_policy->{budget_ms} // 0) * MATE_REFINEMENT_EXTRA_TIME_SHARE);
  my $slack_cap = max(0, $slack_ms - TIME_MOVE_OVERHEAD_MS);
  $extra_ms = min($extra_ms, MATE_REFINEMENT_MAX_MS, $slack_cap);
  return $extra_ms > 0 ? $extra_ms : 0;
}

sub _can_stop_after_target_depth {
  my ($critical_position, $stability_hits, $stable_best_hits, $score) = @_;
  return 0 if $critical_position;
  return 0 if _is_mate_like_score($score);
  return 0 unless ($stability_hits // 0) >= 1;
  return 0 unless ($stable_best_hits // 0) >= 1;
  return 1;
}

sub _state_key {
  my ($state) = @_;
  my $cached = $state->[Chess::State::STATE_KEY];
  return $cached if defined $cached;
  return canonical_fen_key($state);
}

sub _search_is_draw {
  my ($state, $ply, $rep_counts) = @_;
  return 1 if ($state->[Chess::State::HALFMOVE] // 0) >= 100;
  return 0 unless $ply > 0;
  return 0 unless ref($rep_counts) eq 'HASH';
  my $key = _state_key($state);
  return (($rep_counts->{$key} // 0) >= 3) ? 1 : 0;
}

sub _rep_push_state {
  my ($rep_counts, $state) = @_;
  return unless ref($rep_counts) eq 'HASH';
  my $key = _state_key($state);
  $rep_counts->{$key} = ($rep_counts->{$key} // 0) + 1;
  return $key;
}

sub _rep_pop_key {
  my ($rep_counts, $key) = @_;
  return unless ref($rep_counts) eq 'HASH' && defined $key;
  return unless exists $rep_counts->{$key};
  $rep_counts->{$key}--;
  delete $rep_counts->{$key} if $rep_counts->{$key} <= 0;
}

sub _find_move_by_key {
  my ($state, $target_key) = @_;
  return unless defined $target_key;

  my $pseudo = $state->generate_pseudo_moves;
  my @undo_stack;
  for my $move (@{$pseudo}) {
    next unless _move_key($move) == $target_key;
    my @undo_stack;
    next unless defined $state->do_move($move, \@undo_stack);
    $state->undo_move(\@undo_stack);
    return $move;
  }

  return;
}

sub _collect_root_pv_lines {
  my ($state, $depth, $requested_multipv, $fallback_move, $fallback_score) = @_;
  return collect_root_pv_lines($state, $depth, $requested_multipv, $fallback_move, $fallback_score, {
    normalize_multipv_cb => \&_normalize_multipv,
    find_move_by_key_cb => \&_find_move_by_key,
    move_key_cb => \&_move_key,
    state_key_cb => \&_state_key,
    transposition_table => $transposition_table,
  });
}

sub _quiesce {
  my ($state, $alpha, $beta, $depth, $ply) = @_;
  $depth //= 0;
  $ply //= 0;
  _check_time_or_abort();

  my $in_check = $state->is_checked ? 1 : 0;
  if (!$in_check) {
    my $stand_pat = _evaluate_board($state);
    $alpha = max($alpha, $stand_pat);
    return $alpha if $alpha >= $beta || $depth >= $search_quiesce_limit;
  }

  my $legal_groups = collect_legal_moves($state);
  my $captures = $legal_groups->{captures};
  my $quiets = $legal_groups->{quiets};
  $captures = [] unless ref($captures) eq 'ARRAY';
  $quiets = [] unless ref($quiets) eq 'ARRAY';

  my @forcing;
  my @undo_stack;

  if ($in_check) {
    my $evasion_picker = _new_move_picker($state, 0, undef, undef);
    while (my $entry = $evasion_picker->next_move) {
      my ($move, $move_key, $is_capture) = @{$entry}[1, 2, 3];
      push @forcing, [
        _move_order_score($state, $move, $move_key, $is_capture, 0),
        $move,
      ];
    }
  } else {
    my $capture_picker = _new_quiesce_capture_picker($state);
    while (my $entry = $capture_picker->next_move) {
      my ($move, $move_key) = @{$entry}[1, 2];
      push @forcing, [ _move_order_score($state, $move, $move_key, 1, 0), $move ];
    }

    if ($depth < QUIESCE_CHECK_MAX_DEPTH) {
      my $quiet_moves = $state->generate_moves_by_type('quiets');
      for my $move (@{$quiet_moves}) {
        my $is_promo = defined $move->[2] ? 1 : 0;
        next unless $is_promo;
        my $move_key = _move_key($move);
        push @forcing, [ _move_order_score($state, $move, $move_key, 0, 0), $move ];
      }

      for my $move (@{$quiet_moves}) {
        next if defined $move->[2];
        my @undo_stack;
        next unless defined $state->do_move($move, \@undo_stack);
        my $is_check = $state->is_checked ? 1 : 0;
        $state->undo_move(\@undo_stack);
        next unless $is_check;
        my $move_key = _move_key($move);
        push @forcing, [
          _move_order_score($state, $move, $move_key, 0, 0) + QUIESCE_CHECK_BONUS,
          $move,
        ];
      }
    }
  }
  return $in_check ? (-MATE_SCORE + $ply) : $alpha unless @forcing;

  my @ordered = _sort_scored_desc(@forcing);

  foreach my $entry (@ordered) {
    my ($move) = @{$entry}[1];

    # More aggressive SEE pruning for captures in quiescence
    if (!$in_check && _is_capture_state($state, $move)) {
      my $see_value = Chess::See::evaluate_capture(state => $state, move => $move);
      if (defined $see_value && $see_value < QUIESCE_SEE_PRUNE_THRESHOLD) {
        next;  # Skip losing captures
      }
    }

    my @undo_stack;
    next unless defined $state->do_move($move, \@undo_stack);
    my $score = ($in_check && $depth >= $search_quiesce_limit)
      ? -_evaluate_board($state)
      : -_quiesce($state, -$beta, -$alpha, $depth + 1, $ply + 1);
    $state->undo_move(\@undo_stack);
    if ($score > $alpha) {
      $alpha = $score;
      last if $alpha >= $beta;
    }
  }

  return $alpha;
}

sub _evaluate_board {
  my ($state) = @_;
  my $key = _state_key($state);
  my $cache_key = defined $key ? $eval_cache_tag . '|' . $key : undef;
  if (defined $cache_key && exists $eval_cache{$cache_key}) {
    return $eval_cache{$cache_key};
  }

  my $score = evaluate_position($state, {
    board_indices => \@board_indices,
    piece_values => \%piece_values,
    square_of_idx_cb => \&_square_of_idx,
    location_bonus_cb => \&_location_bonus,
    strategic_cb => sub {
      my ($board, $ctx, $attack_cache) = @_;
      my $extra = 0;
      my $threat_summary = _threatened_material_summary($board, $attack_cache);
      $extra += _development_score($board, {
        piece_count => $ctx->{piece_count},
        king_idx => $ctx->{our_king_idx},
        rook_count => $ctx->{rook_count},
        rook_home_count => $ctx->{rook_home_count},
        queen_idx => $ctx->{queen_idx},
        opponent_has_queen => $ctx->{opponent_has_queen},
      });
      $extra += _passed_pawn_score($board);
      $extra += _pawn_structure_score($board);
      $extra += _piece_activity_score($board, $attack_cache);
      $extra += _hanging_piece_score($board, $attack_cache);
      $extra += int((($threat_summary->{threatened_delta} // 0) + (($threat_summary->{threatened_theirs_count} // 0) - ($threat_summary->{threatened_ours_count} // 0))) / 2);
      $extra += _king_danger_score($board, $attack_cache, $ctx->{our_king_idx}, $ctx->{opp_king_idx});
      $extra += _threat_score($board, $attack_cache, $ctx->{our_king_idx}, $ctx->{opp_king_idx});
      $extra += _king_aggression_score($board, $ctx->{friendly_non_king}, $ctx->{enemy_non_king});
      $extra += _endgame_score($board, $ctx->{piece_count}, $ctx->{our_king_idx}, $ctx->{opp_king_idx});
      return $extra;
    },
  });

  if (defined $cache_key) {
    %eval_cache = () if scalar(keys %eval_cache) >= EVAL_CACHE_MAX_ENTRIES;
    $eval_cache{$cache_key} = $score;
  }
  return $score;
}

sub _search {
  my ($state, $depth, $alpha, $beta, $ply, $prev_move_key, $prev_was_null, $rep_counts, $prev_piece, $prev_to) = @_;
  $ply //= 0;
  $prev_was_null = $prev_was_null ? 1 : 0;
  if (!defined $rep_counts || ref($rep_counts) ne 'HASH') {
    my $root_key = _state_key($state);
    $rep_counts = { $root_key => 1 };
  }
  if ($ply == 0) {
    _reset_root_search_stats();
  }
  _check_time_or_abort();

  if (_search_is_draw($state, $ply, $rep_counts)) {
    return (0, undef);
  }

  if ($depth <= 0) {
    return (_quiesce($state, $alpha, $beta, 0, $ply), undef);
  }

  my $key = _state_key($state);
  my $tt_entry = $transposition_table->probe($key, ply => $ply, mate_score => MATE_SCORE);
  my $tt_move_key = $tt_entry ? $tt_entry->{best_move_key} : undef;
  my $tt_move;

  if ($tt_entry && $tt_entry->{depth} >= $depth) {
    my $tt_score = $tt_entry->{score};
    if ($tt_entry->{flag} == TT_FLAG_EXACT) {
      return ($tt_score, ($ply == 0 ? _find_move_by_key($state, $tt_move_key) : undef));
    }
    if ($tt_entry->{flag} == TT_FLAG_LOWER) {
      $alpha = max($alpha, $tt_score);
    } elsif ($tt_entry->{flag} == TT_FLAG_UPPER) {
      $beta = min($beta, $tt_score);
    }
    if ($alpha >= $beta) {
      return ($tt_score, ($ply == 0 ? _find_move_by_key($state, $tt_move_key) : undef));
    }
  }

  my $alpha_orig = $alpha;
  my $beta_orig = $beta;
  my $is_pv = ($beta - $alpha) > 1 ? 1 : 0;
  my $best_value = -INF_SCORE;
  my $best_move;
  my $best_move_key;
  my $legal_moves = 0;
  my $move_index = 0;
  my $in_check = $state->is_checked ? 1 : 0;
  my $has_non_pawn_material = _has_non_pawn_material($state);
  my $static_eval = !$in_check ? _evaluate_board($state) : undef;
  my $own_king_danger = _king_danger_for_piece($state->[Chess::State::BOARD], KING);

  if (!$in_check
    && !$is_pv
    && !$prev_was_null
    && $ply > 0
    && $depth <= STATIC_NULL_PRUNE_MAX_DEPTH
    && defined $static_eval
    && abs($beta) < (MATE_SCORE - NULL_MOVE_MATE_GUARD)
    && $has_non_pawn_material)
  {
    my $margin = STATIC_NULL_PRUNE_MARGIN_BASE + ($depth * STATIC_NULL_PRUNE_MARGIN_PER_DEPTH);
    if ($static_eval >= ($beta + $margin)) {
      return ($static_eval, undef);
    }
  }

  if (!$in_check
    && !$is_pv
    && $ply > 0
    && $depth <= RFP_MAX_DEPTH
    && defined $static_eval
    && abs($beta) < (MATE_SCORE - NULL_MOVE_MATE_GUARD)
    && $has_non_pawn_material)
  {
    my $margin = RFP_MARGIN_BASE + ($depth * RFP_MARGIN_PER_DEPTH);
    if (($static_eval - $margin) >= $beta) {
      return ($static_eval - $margin, undef);
    }
  }

  # Razoring: skip search if eval is way below alpha at shallow depths
  if (!$in_check
    && !$is_pv
    && $depth <= RAZORING_MAX_DEPTH
    && defined $static_eval
    && $static_eval < $alpha - RAZORING_MARGIN_BASE - RAZORING_MARGIN_DEPTH * $depth * $depth)
  {
    return (_quiesce($state, $alpha, $beta, 0, $ply), undef);
  }

  if (!defined $tt_move_key
    && !$in_check
    && $ply > 0
    && $depth >= IID_MIN_DEPTH)
  {
    my $iid_reduction = IID_REDUCTION;
    my $iid_depth = $depth - $iid_reduction;
    if ($iid_depth > 0) {
      my (undef, $iid_move) = _search(
        $state, $iid_depth, $alpha, $beta, $ply, $prev_move_key, $prev_was_null, $rep_counts, $prev_piece, $prev_to
      );
      if (defined $iid_move) {
        $tt_move = $iid_move;
        $tt_move_key = _move_key($iid_move);
      }
      if (!defined $tt_move_key) {
        my $iid_tt_entry = $transposition_table->probe($key, ply => $ply, mate_score => MATE_SCORE);
        $tt_move_key = $iid_tt_entry->{best_move_key} if $iid_tt_entry;
      }
    }
  }

  if (! $in_check
    && ! $prev_was_null
    && $ply > 0
    && $depth >= NULL_MOVE_MIN_DEPTH
    && ($beta - $alpha) <= 1
    && abs($beta) < (MATE_SCORE - NULL_MOVE_MATE_GUARD)
    && $has_non_pawn_material)
  {
    my $null_state = _make_null_move_state($state);
    if (defined $null_state) {
      my $reduction = NULL_MOVE_REDUCTION;
      $reduction++ if $depth >= NULL_MOVE_DEEP_DEPTH;
      my $null_depth = $depth - 1 - $reduction;
      $null_depth = 0 if $null_depth < 0;
      my $null_rep_key = _rep_push_state($rep_counts, $null_state);
      my ($null_value) = _search($null_state, $null_depth, -$beta, -$beta + 1, $ply + 1, undef, 1, $rep_counts, undef, undef);
      _rep_pop_key($rep_counts, $null_rep_key);
      $null_value = -$null_value;
      if ($null_value >= $beta && abs($null_value) < (MATE_SCORE - NULL_MOVE_MATE_GUARD)) {
        # At shallow depths, trust the null move result
        if ($depth < NULL_MOVE_VERIFY_DEPTH) {
          return ($null_value, undef);
        }
        
        # At high depths, do verification search to avoid zugzwang errors
        my $verification_depth = $depth - $reduction - 1;
        $verification_depth = 1 if $verification_depth < 1;
        
        # Search with null move disabled (prev_was_null=1) for verification
        my ($verification_value) = _search(
          $state, $verification_depth, $beta - 1, $beta,
          $ply + 1, $prev_move_key, 1, $rep_counts, $prev_piece, $prev_to
        );
        
        if ($verification_value >= $beta) {
          return ($null_value, undef);
        }
      }
    }
  }

  # ProbCut: prune if shallow capture search beats beta by margin
  my $probcut_beta = $beta + PROBCUT_MARGIN;
  if (!$in_check
      && !$is_pv
      && $depth >= PROBCUT_MIN_DEPTH
      && abs($beta) < (MATE_SCORE - NULL_MOVE_MATE_GUARD)
      && $has_non_pawn_material)
  {
    # Generate captures with good SEE
    my $capture_moves = $state->generate_moves_by_type('captures');
    my $probcut_depth = $depth - PROBCUT_REDUCTION;

    for my $move (@{$capture_moves}) {
      # Skip captures with bad SEE
      my $see_value = Chess::See::evaluate_capture(state => $state, move => $move);
      next unless defined $see_value && $see_value >= $probcut_beta - $static_eval;

      my @undo_stack;
      my $pc_board = $state->[Chess::State::BOARD];
      my $pc_from_piece = abs($pc_board->[$move->[0]] // 0);
      next unless defined $state->do_move($move, \@undo_stack);

      # Do qsearch first to verify the capture holds
      my $qvalue = -_quiesce($state, -$probcut_beta, -$probcut_beta + 1, 0, $ply + 1);

      if ($qvalue >= $probcut_beta && $probcut_depth > 0) {
        # Verify with reduced search
        my ($value) = _search(
          $state, $probcut_depth, -$probcut_beta, -$probcut_beta + 1,
          $ply + 1, _move_key($move), 0, $rep_counts, $pc_from_piece, $move->[1]
        );
        $qvalue = -$value;
      }

      $state->undo_move(\@undo_stack);

      if ($qvalue >= $probcut_beta) {
        return ($qvalue, undef);
      }
    }
  }

  my $parent_board = $state->[Chess::State::BOARD];
  my $king_idx = $state->[Chess::State::KING_IDX];
  $king_idx = _find_piece_idx($parent_board, KING) unless defined $king_idx;
  my %king_ring = map { $_ => 1 } _king_ring_indices($parent_board, $king_idx);
  my %threat_attack_cache;
  my $threat_summary_before = _threatened_material_summary($parent_board, \%threat_attack_cache);
  my $enemy_king_danger_before = _king_danger_for_piece($parent_board, OPP_KING, \%threat_attack_cache);
  my @undo_stack;
  my $move_picker = _new_move_picker($state, $ply, $tt_move_key, $prev_move_key, $tt_move, $prev_piece, $prev_to);
  while (my $entry = $move_picker->next_move) {
    my ($move, $child_prev_move_key, $is_capture) = @{$entry}[1, 2, 3];

    # SEE-based capture pruning
    if ($is_capture && !$in_check && !$is_pv && $depth <= SEE_PRUNING_MAX_DEPTH) {
      my $see_value = Chess::See::evaluate_capture(state => $state, move => $move);
      if (defined $see_value) {
        # Calculate margin based on depth
        my $margin = SEE_PRUNING_MARGIN_BASE * $depth;
        # Prune clearly losing captures
        if ($see_value < -$margin) {
          next;  # Skip this move
        }
      }
    }
    my $board = $state->[Chess::State::BOARD];
    my $from_piece = abs($board->[$move->[0]] // 0);
    my $quiet_plan_bonus = 0;
    if (!$is_capture && !defined $move->[2]) {
      $quiet_plan_bonus = _quiet_plan_order_bonus($state, $move, undef, $ply);
    }
    my $king_safety_critical = 0;
    if ($from_piece == KING || (defined $own_king_danger && $own_king_danger >= LMR_KING_DANGER_THRESHOLD)) {
      $king_safety_critical = 1;
    } else {
      my $king_idx = $state->[Chess::State::KING_IDX];
      $king_idx = _find_piece_idx($board, KING) unless defined $king_idx;
      if (defined $king_idx) {
        my $king_file = _file_of_idx($king_idx);
        if ($from_piece == PAWN && abs(_file_of_idx($move->[0]) - $king_file) <= 1) {
          $king_safety_critical = 1;
        } else {
          my %ring = map { $_ => 1 } _king_ring_indices($board, $king_idx);
          $king_safety_critical = 1 if $ring{$move->[0]} || $ring{$move->[1]};
        }
      }
    }
    my $queen_move = $from_piece == QUEEN ? 1 : 0;
    my @undo_stack;
    next unless defined $state->do_move($move, \@undo_stack);
    my $gives_check = $state->is_checked ? 1 : 0;
    my $quiet_hanging_move = _is_quiet_hanging_move($state, $move, $is_capture);
    $king_safety_critical = 1 if $gives_check;
    my $threat_response_move = 0;
    my $strategic_threat_move = 0;
    if (!$is_capture && !defined $move->[2] && !defined $move->[3] && !$gives_check) {
      ($threat_response_move, $strategic_threat_move)
        = _quiet_move_threat_flags($parent_board, $threat_summary_before, $enemy_king_danger_before, $state);
    }
    $strategic_threat_move = 1 if $quiet_plan_bonus >= 70;
    my $tactical_queen_move = 0;
    if ($queen_move) {
      if ($is_capture || $gives_check) {
        $tactical_queen_move = 1;
      } else {
        my $new_board = $state->[Chess::State::BOARD];
        my $enemy_king_idx = $state->[Chess::State::KING_IDX];
        $enemy_king_idx = _find_piece_idx($new_board, KING) unless defined $enemy_king_idx;
        if (defined $enemy_king_idx) {
          my @ring = _king_ring_indices($new_board, $enemy_king_idx);
          for my $sq ($enemy_king_idx, @ring) {
            if (_is_square_attacked_by_side($new_board, $sq, -1)) {
              $tactical_queen_move = 1;
              last;
            }
          }
        }
      }
    }

    $legal_moves++;
    if (!$in_check
      && !$is_pv
      && $depth <= LMP_MAX_DEPTH
      && $move_index >= (LMP_BASE_MOVES + $depth * LMP_DEPTH_FACTOR)
      && !defined $move->[2]
      && !defined $move->[3]
      && !$is_capture
      && !$gives_check
      && !$quiet_hanging_move
      && !$threat_response_move
      && !$strategic_threat_move
      && !$king_safety_critical
      && !$tactical_queen_move)
    {
      $state->undo_move(\@undo_stack);
      $move_index++;
      next;
    }

    my $value;
    my $child_rep_key = _rep_push_state($rep_counts, $state);
    my $child_prev_piece = $from_piece;
    my $child_prev_to = $move->[1];
    if ($move_index == 0) {
      ($value) = _search($state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts, $child_prev_piece, $child_prev_to);
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
        && ! $threat_response_move
        && ! $strategic_threat_move
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
        ($value) = _search($state, $reduced_depth, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts, $child_prev_piece, $child_prev_to);
        $value = -$value;
        if ($value > $alpha) {
          ($value) = _search($state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts, $child_prev_piece, $child_prev_to);
          $value = -$value;
          if ($value > $alpha && $value < $beta) {
            ($value) = _search($state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts, $child_prev_piece, $child_prev_to);
            $value = -$value;
          }
        }
      } else {
        ($value) = _search($state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts, $child_prev_piece, $child_prev_to);
        $value = -$value;
        if ($value > $alpha && $value < $beta) {
          ($value) = _search($state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts, $child_prev_piece, $child_prev_to);
          $value = -$value;
        }
      }
    }
    _rep_pop_key($rep_counts, $child_rep_key);
    $move_index++;
    if ($quiet_hanging_move) {
      $value -= _hanging_move_penalty($state, $move);
    }

    my $raw_value = $value;
    if ($ply == 0 && defined $child_prev_move_key) {
      $root_regression_current_scores{$child_prev_move_key} = $raw_value;
      my $regression_penalty = _root_regression_penalty($child_prev_move_key, $raw_value, $depth);
      $value -= $regression_penalty if $regression_penalty > 0;
    }

    if ($ply == 0) {
      push @{$root_search_stats->{root_candidates}}, {
        score => $value,
        raw_score => $raw_value,
        move => $move,
        move_key => $child_prev_move_key,
      };
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
          # Update continuation history
          _update_continuation_history($prev_piece, $prev_to, $from_piece, $move->[1], $depth);
        }
        $state->undo_move(\@undo_stack);
        last;
      }
    }
    $state->undo_move(\@undo_stack);
  }

  if (! $legal_moves) {
    if ($ply == 0) {
      _reset_root_search_stats();
    }
    my $mate_or_draw = $state->is_checked ? (-MATE_SCORE + $ply) : 0;
    return ($mate_or_draw, undef);
  }

  _finalize_root_search_stats($legal_moves) if $ply == 0;

  my $flag = TT_FLAG_EXACT;
  if ($best_value <= $alpha_orig) {
    $flag = TT_FLAG_UPPER;
  } elsif ($best_value >= $beta_orig) {
    $flag = TT_FLAG_LOWER;
  }

  $transposition_table->store(
    key => $key,
    depth => $depth,
    score => $best_value,
    flag => $flag,
    best_move_key => $best_move_key,
    ply => $ply,
    mate_score => MATE_SCORE,
  );

  return ($best_value, $best_move);
}

sub _search_root_with_workers {
  my ($state, $depth, $alpha, $beta, $workers) = @_;

  _reset_root_search_stats();

  # Root parallelization currently races time control/cancellation across threads.
  # Keep single-thread root search for stable playing strength.
  return _search($state, $depth, $alpha, $beta, 0, undef);
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
  my $root_state = ${$self->{state}};
  my $piece_count = _piece_count($root_state);
  $root_plan_tags = [];

  if ($use_book && (my $book_move = Chess::Book::choose_move($root_state))) {
    return $book_move;
  }
  $think_opts{out_of_book} = 1 if $use_book;

  if (my $table_move = Chess::EndgameTable::choose_move($root_state)) {
    return $table_move;
  }
  my $state = $root_state->clone;
  my $plan_tags = state_plan_tags($root_state);
  $root_plan_tags = $plan_tags if ref($plan_tags) eq 'ARRAY' && @{$plan_tags};

  _decay_history();
  $move_order->reset_killers();
  $transposition_table->next_generation();
  my $workers = exists $think_opts{workers}
    ? _normalize_worker_count($think_opts{workers})
    : _normalize_worker_count($self->{workers});
  my $requested_multipv = _normalize_multipv($think_opts{multipv});
  my $strict_depth = $think_opts{strict_depth} ? 1 : 0;

  my $target_depth = max(1, $self->{depth});
  if (!$strict_depth) {
    $target_depth += MID_ENDGAME_DEPTH_BOOST if $piece_count <= MID_ENDGAME_PIECE_THRESHOLD;
    $target_depth += DEEP_ENDGAME_DEPTH_BOOST if $piece_count <= DEEP_ENDGAME_PIECE_THRESHOLD;
  }
  $target_depth = min(20, $target_depth);
  my $max_depth = $strict_depth
    ? $target_depth
    : min(20, $target_depth + EXTRA_DEPTH_ON_UNSTABLE);
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
  my $sac_candidate_extension_used = 0;
  my $volatility_extensions_used = 0;
  my $mate_refinement_extension_used = 0;
  _reset_root_regression_state();

  DEPTH_LOOP:
  for my $depth (1 .. $max_depth) {
    last DEPTH_LOOP if $last_completed_depth && _time_up_soft();
    _begin_root_regression_depth();
    my $iteration_score;
    my $iteration_move;
    my $aspiration_expansions = 0;

    # Aspiration window with iterative widening
    my $delta = ASPIRATION_WINDOW_INITIAL;
    my $avg = $prev_score // 0;
    my $alpha = ($depth >= 3) ? max(-INF_SCORE, $avg - $delta) : -INF_SCORE;
    my $beta = ($depth >= 3) ? min(INF_SCORE, $avg + $delta) : INF_SCORE;

    while (1) {
      my ($score, $move);
      my $ok = eval {
        ($score, $move) = _search_root_with_workers($state, $depth, $alpha, $beta, $workers);
        1;
      };
      if (! $ok) {
        my $err = $@;
        if (defined $err && $err =~ /\Q$search_time_abort\E/) {
          $state = $root_state->clone;
          last DEPTH_LOOP;
        }
        die $err;
      }
      $best_move = $move if defined $move;
      $iteration_score = $score;
      $iteration_move = $move if defined $move;

      if ($score <= $alpha) {
        # Fail low - widen window downward
        $aspiration_expansions++;
        $beta = $alpha;
        $alpha = max(-INF_SCORE, $score - $delta);
        $delta += int($delta / 3);
        last if !$strict_depth && $last_completed_depth && _time_up_soft();
        last if $aspiration_expansions >= ASPIRATION_WINDOW_MAX_WIDEN;
        last if $delta > INF_SCORE / 2;
        next;
      }
      if ($score >= $beta) {
        # Fail high - widen window upward
        $aspiration_expansions++;
        $alpha = max($beta - $delta, $alpha);
        $beta = min(INF_SCORE, $score + $delta);
        $delta += int($delta / 3);
        last if !$strict_depth && $last_completed_depth && _time_up_soft();
        last if $aspiration_expansions >= ASPIRATION_WINDOW_MAX_WIDEN;
        last if $delta > INF_SCORE / 2;
        next;
      }

      # Success - value within window
      last;
    }

    next unless defined $iteration_score;
    $last_completed_depth = $depth;
    $last_completed_score = $iteration_score;
    _commit_root_regression_depth();
    my $iteration_move_key = defined $iteration_move ? _move_key($iteration_move) : undef;
    my $pv_lines = _collect_root_pv_lines($state, $depth, $requested_multipv, $iteration_move, $iteration_score);
    if (ref($pv_lines) eq 'ARRAY' && @{$pv_lines}) {
      my $best_pv_move = $pv_lines->[0]{pv}[0];
      if (defined $best_pv_move) {
        $best_move = $best_pv_move;
        $iteration_move = $best_pv_move;
        $iteration_move_key = _move_key($best_pv_move);
      }
    }
    my $pv_changed = defined $iteration_move_key && defined $prev_best_move_key && $iteration_move_key != $prev_best_move_key;
    if (defined $iteration_move_key && defined $prev_best_move_key && $iteration_move_key == $prev_best_move_key) {
      $stable_best_hits++;
    } else {
      $stable_best_hits = 0;
    }

    my $score_delta = $had_prev_score ? abs($iteration_score - $prev_score) : 0;
    my $score_drop_from_prev = $had_prev_score ? ($iteration_score - $prev_score) : 0;
    my $volatile = $pv_changed || $score_delta > (SCORE_STABILITY_DELTA * 4) || $aspiration_expansions >= 2;
    my $root_legal_moves = $root_search_stats->{legal_moves} // 0;
    my $root_gap;
    if (defined $root_search_stats->{best_value} && defined $root_search_stats->{second_value}) {
      $root_gap = $root_search_stats->{best_value} - $root_search_stats->{second_value};
    }
    my $near_tie_root = defined $root_gap
      && $root_legal_moves >= 3
      && $root_gap <= ROOT_NEAR_TIE_DELTA;
    my $clear_best_root = defined $root_gap && $root_gap >= ROOT_CLEAR_BEST_DELTA;
    my $mate_score_found = _is_mate_like_score($iteration_score);
    my $forced_or_easy_root = $root_legal_moves == 1
      || ($root_legal_moves >= 2 && $root_legal_moves <= 3
        && $clear_best_root
        && !$mate_score_found
        && !$pv_changed
        && $aspiration_expansions == 0
        && $score_delta <= (SCORE_STABILITY_DELTA * 2));
    my $critical_position = $volatile || $near_tie_root;
    my $volatility_pressure = _volatility_pressure_score({
      volatile => $volatile,
      near_tie_root => $near_tie_root,
      aspiration_expansions => $aspiration_expansions,
      forced_or_easy_root => $forced_or_easy_root,
      stable_best_hits => $stable_best_hits,
      score_delta => $score_delta,
    });

    if ($had_prev_score && abs($iteration_score - $prev_score) <= SCORE_STABILITY_DELTA) {
      $stability_hits++;
    } else {
      $stability_hits = 0;
    }
    $prev_score = $iteration_score;
    $had_prev_score = 1;
    $prev_best_move_key = $iteration_move_key if defined $iteration_move_key;
    if ($on_update && defined $best_move) {
      my $update = {
        multipv => $requested_multipv,
        pv_lines => $pv_lines,
      };
      eval { $on_update->($depth, $iteration_score, $best_move, $update); };
    }

    if (!$strict_depth
      && $time_policy->{has_clock}
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

    if ($time_policy->{has_clock}
      && !$time_policy->{panic_level}
      && !$sac_candidate_extension_used
      && $depth >= 4
      && ($time_policy->{budget_ms} || 0) >= SAC_CANDIDATE_MIN_BUDGET_MS)
    {
      my $best_is_sac = defined $iteration_move && _is_sac_candidate_move_in_state($state, $iteration_move);
      my $sac_drop_risk = $score_drop_from_prev <= -SAC_SCORE_DROP_CP ? 1 : 0;
      my $sac_candidate_seen = _has_sac_candidate_with_score_drop($state, SAC_SCORE_DROP_CP);
      if ($best_is_sac || $sac_drop_risk || $sac_candidate_seen) {
        my $extra_ms = int(($time_policy->{budget_ms} || 0) * SAC_EXTRA_TIME_SHARE);
        $extra_ms = min(SAC_EXTRA_TIME_MAX_MS, $extra_ms);
        if ($extra_ms > 0) {
          _extend_soft_deadline($extra_ms);
          $sac_candidate_extension_used = 1;
        }
      }
    }

    if (!$strict_depth
      && $time_policy->{has_clock}
      && !$time_policy->{panic_level}
      && $volatility_extensions_used < VOLATILITY_LONG_THINK_MAX_EXTENSIONS
      && $depth >= VOLATILITY_LONG_THINK_MIN_DEPTH)
    {
      my $slack_ms = $search_time_manager->hard_time_left_ms - $search_time_manager->soft_time_left_ms;
      my $extra_ms = _volatility_extension_ms($time_policy, $volatility_pressure, $slack_ms);
      if ($extra_ms > 0) {
        _extend_soft_deadline($extra_ms);
        $volatility_extensions_used++;
      }
    }

    if ($time_policy->{has_clock} && !$mate_refinement_extension_used) {
      my $slack_ms = $search_time_manager->hard_time_left_ms - $search_time_manager->soft_time_left_ms;
      my $extra_ms = _mate_refinement_extension_ms($time_policy, $iteration_score, $slack_ms);
      if ($extra_ms > 0) {
        _extend_soft_deadline($extra_ms);
        $mate_refinement_extension_used = 1;
      }
    }

    if (!$strict_depth && $time_policy->{has_clock} && $depth >= $easy_move_depth) {
      my $easy_move = !$critical_position
        && !$mate_score_found
        && $stable_best_hits >= 2
        && $score_delta <= SCORE_STABILITY_DELTA
        && $aspiration_expansions == 0;
      last DEPTH_LOOP if $easy_move;
    }

    if ($depth >= $target_depth) {
      if ($strict_depth) {
        last;
      }
      last if _can_stop_after_target_depth($critical_position, $stability_hits, $stable_best_hits, $iteration_score);
      last if _time_up_soft();
    }
  }

  if (!defined $best_move) {
    my @legal = $state->generate_moves;
    $best_move = $legal[0] if @legal;
  }
  $best_move = _maybe_randomize_tied_root_move($state, $best_move, \%think_opts);

  $last_completed_score = _evaluate_board($state) unless defined $last_completed_score;
  $last_completed_depth = 1 unless $last_completed_depth;
  return wantarray
    ? ($best_move, $last_completed_score, $last_completed_depth)
    : $best_move;
}

1;
