package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::EndgameTable;
use Chess::TableUtil qw(canonical_fen_key);
use Chess::TranspositionTable;
use Chess::TimeManager;
use Chess::Eval qw(evaluate_position);
use Chess::Heuristics qw(:engine);
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
use Chess::MoveOrder;
use Chess::Search qw(
  reset_root_search_stats
  finalize_root_search_stats
  root_search_stats
  maybe_randomize_tied_root_move
  has_sac_candidate_with_score_drop
  collect_root_pv_lines
);

use Chess::Book;
use Chess::MoveGen ();
use Chess::MovePicker;

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
my $move_order = Chess::MoveOrder->new(
  piece_values => \%piece_values,
  location_modifier_percent_cb => \&location_modifier_percent,
  square_of_idx_cb => \&square_of_idx,
  unsafe_capture_penalty_cb => \&unsafe_capture_penalty,
  capture_plan_order_bonus_cb => \&capture_plan_order_bonus,
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

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 6; # bigger number more thinky
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
  my $king_walk_phase = 0;
  if ($piece_count > MID_ENDGAME_PIECE_THRESHOLD) {
    my $phase_span = max(1, OPENING_PIECE_COUNT_THRESHOLD - MID_ENDGAME_PIECE_THRESHOLD);
    $king_walk_phase = _clamp(($piece_count - MID_ENDGAME_PIECE_THRESHOLD) / $phase_span, 0, 1);
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

  if ($uncastled && $king_idx != 25 && $king_walk_phase > 0) {
    my $file = _file_of_idx($king_idx);
    my $rank = _rank_of_idx($king_idx);
    my $walk_penalty = EARLY_KING_WALK_HOME_PENALTY;
    $walk_penalty += EARLY_KING_WALK_EXPOSED_FILE_PENALTY if $file >= 3 && $file <= 6;
    $walk_penalty += EARLY_KING_WALK_CENTRAL_FILE_PENALTY if $file >= 4 && $file <= 6;
    $walk_penalty += EARLY_KING_WALK_ADVANCED_RANK_PENALTY if $rank >= 2;
    $score -= int($walk_penalty * $king_walk_phase + 0.5);
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
  my ($state, $ply, $tt_move_key, $prev_move_key, $tt_move) = @_;
  my $killer_move_keys = $move_order->{killer_moves}[$ply] || [];
  my $countermove_key = defined $prev_move_key ? $move_order->{counter_moves}{$prev_move_key} : undef;

  if (defined $tt_move && !defined $tt_move_key) {
    $tt_move_key = _move_key($tt_move);
  }

  my $legal_groups = Chess::MoveGen::collect_legal_moves($state);
  my $legal_moves = $legal_groups->{legal};
  $legal_moves = [] unless ref($legal_moves) eq 'ARRAY';

  return Chess::MovePicker->new(
    state => $state,
    moves => $legal_moves,
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
      return _move_order_score($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key);
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
  my ($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key) = @_;
  return $move_order->score_move($state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key);
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
  return (($rep_counts->{$key} // 0) >= 2) ? 1 : 0;
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
  my ($state, $alpha, $beta, $depth) = @_;
  $depth //= 0;
  _check_time_or_abort();

  my $stand_pat = _evaluate_board($state);
  $alpha = max($alpha, $stand_pat);
  return $alpha if $alpha >= $beta || $depth >= $search_quiesce_limit;

  my $legal_groups = Chess::MoveGen::collect_legal_moves($state);
  my $captures = $legal_groups->{captures};
  my $quiets = $legal_groups->{quiets};
  $captures = [] unless ref($captures) eq 'ARRAY';
  $quiets = [] unless ref($quiets) eq 'ARRAY';

  my @forcing;
  my @undo_stack;

  my $capture_picker = Chess::MovePicker->new(
    state => $state,
    moves => $captures,
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
  while (my $entry = $capture_picker->next_move) {
    my ($move, $move_key) = @{$entry}[1, 2];
    next unless defined $state->do_move($move, \@undo_stack);
    my $is_check = $state->is_checked ? 1 : 0;
    $state->undo_move(\@undo_stack);
    my $score = _move_order_score($state, $move, $move_key, 1, 0) + ($is_check ? QUIESCE_CHECK_BONUS : 0);
    push @forcing, [ $score, $move ];
  }

  if ($depth < QUIESCE_CHECK_MAX_DEPTH) {
    for my $move (@{$quiets}) {
      my $is_promo = defined $move->[2] ? 1 : 0;
      my $move_key = _move_key($move);
      my $base_score = _move_order_score($state, $move, $move_key, 0, 0);
      next unless defined $state->do_move($move, \@undo_stack);
      my $is_check = $state->is_checked ? 1 : 0;
      $state->undo_move(\@undo_stack);
      next unless $is_promo || $is_check;
      my $score = $base_score + ($is_check ? QUIESCE_CHECK_BONUS : 0);
      push @forcing, [ $score, $move ];
    }
  }
  return $alpha unless @forcing;

  my @ordered = _sort_scored_desc(@forcing);

  foreach my $entry (@ordered) {
    my $move = $entry->[1];
    next unless defined $state->do_move($move, \@undo_stack);
    my $score;
    my $ok = eval {
      $score = -_quiesce($state, -$beta, -$alpha, $depth + 1);
      1;
    };
    $state->undo_move(\@undo_stack);
    die $@ unless $ok;
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
      $extra += _development_score($board, {
        piece_count => $ctx->{piece_count},
        king_idx => $ctx->{our_king_idx},
        rook_count => $ctx->{rook_count},
        rook_home_count => $ctx->{rook_home_count},
        queen_idx => $ctx->{queen_idx},
        opponent_has_queen => $ctx->{opponent_has_queen},
      });
      $extra += _passed_pawn_score($board);
      $extra += _hanging_piece_score($board, $attack_cache);
      $extra += _king_danger_score($board, $attack_cache, $ctx->{our_king_idx}, $ctx->{opp_king_idx});
      $extra += _king_aggression_score($board, $ctx->{friendly_non_king}, $ctx->{enemy_non_king});
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
  my ($state, $depth, $alpha, $beta, $ply, $prev_move_key, $prev_was_null, $rep_counts) = @_;
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
    return (_quiesce($state, $alpha, $beta, 0), undef);
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

  if (!defined $tt_move_key
    && !$in_check
    && $ply > 0
    && $depth >= IID_MIN_DEPTH)
  {
    my $iid_reduction = IID_REDUCTION;
    my $iid_depth = $depth - $iid_reduction;
    if ($iid_depth > 0) {
      my (undef, $iid_move) = _search(
        $state, $iid_depth, $alpha, $beta, $ply, $prev_move_key, $prev_was_null, $rep_counts
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
      my ($null_value) = _search($null_state, $null_depth, -$beta, -$beta + 1, $ply + 1, undef, 1, $rep_counts);
      _rep_pop_key($rep_counts, $null_rep_key);
      $null_value = -$null_value;
      if ($null_value >= $beta) {
        return ($null_value, undef);
      }
    }
  }

  my $parent_board = $state->[Chess::State::BOARD];
  my $king_idx = $state->[Chess::State::KING_IDX];
  $king_idx = _find_piece_idx($parent_board, KING) unless defined $king_idx;
  my %king_ring = map { $_ => 1 } _king_ring_indices($parent_board, $king_idx);
  my @undo_stack;
  my $move_picker = _new_move_picker($state, $ply, $tt_move_key, $prev_move_key, $tt_move);
  while (my $entry = $move_picker->next_move) {
    my ($move, $child_prev_move_key, $is_capture) = @{$entry}[1, 2, 3];
    my $from_piece = abs($parent_board->[$move->[0]] // 0);
    next unless defined $state->do_move($move, \@undo_stack);
    my $gives_check = $state->is_checked ? 1 : 0;
    my $quiet_hanging_move = _is_quiet_hanging_move($state, $move, $is_capture);
    my $king_safety_critical = _is_king_safety_critical_move(
      $from_piece, $move, $state, $own_king_danger, $king_idx, \%king_ring
    );
    my $tactical_queen_move = _is_tactical_queen_move($from_piece, $state, $is_capture);

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
      && !$king_safety_critical
      && !$tactical_queen_move)
    {
      $state->undo_move(\@undo_stack);
      $move_index++;
      next;
    }

    my $value;
    my $hanging_penalty = $quiet_hanging_move ? _hanging_move_penalty($state, $move) : 0;
    my $child_rep_key = _rep_push_state($rep_counts, $state);
    my $ok = eval {
      if ($move_index == 0) {
        ($value) = _search($state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts);
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
          ($value) = _search($state, $reduced_depth, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts);
          $value = -$value;

          if ($value > $alpha) {
            ($value) = _search($state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts);
            $value = -$value;
            if ($value > $alpha && $value < $beta) {
              ($value) = _search($state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts);
              $value = -$value;
            }
          }
        } else {
          ($value) = _search($state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts);
          $value = -$value;
          if ($value > $alpha && $value < $beta) {
            ($value) = _search($state, $depth - 1, -$beta, -$alpha, $ply + 1, $child_prev_move_key, 0, $rep_counts);
            $value = -$value;
          }
        }
      }
      1;
    };
    _rep_pop_key($rep_counts, $child_rep_key);
    $state->undo_move(\@undo_stack);
    die $@ unless $ok;
    $move_index++;
    if ($hanging_penalty) {
      $value -= $hanging_penalty;
    }

    if ($ply == 0) {
      push @{$root_search_stats->{root_candidates}}, {
        score => $value,
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
        }
        last;
      }
    }
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
  my $state = ${$self->{state}};
  my $piece_count = _piece_count($state);

  if ($use_book && (my $book_move = Chess::Book::choose_move($state))) {
    return $book_move;
  }
  $think_opts{out_of_book} = 1 if $use_book;

  if (my $table_move = Chess::EndgameTable::choose_move($state)) {
    return $table_move;
  }

  _decay_history();
  $move_order->reset_killers();
  $transposition_table->next_generation();
  my $workers = exists $think_opts{workers}
    ? _normalize_worker_count($think_opts{workers})
    : _normalize_worker_count($self->{workers});
  my $requested_multipv = _normalize_multipv($think_opts{multipv});

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
  my $sac_candidate_extension_used = 0;

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
        ($score, $move) = _search_root_with_workers($state, $depth, $alpha, $beta, $workers);
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
      my $update = {
        multipv => $requested_multipv,
        pv_lines => $pv_lines,
      };
      eval { $on_update->($depth, $iteration_score, $best_move, $update); };
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
  $best_move = _maybe_randomize_tied_root_move($state, $best_move, \%think_opts);

  $last_completed_score = _evaluate_board($state) unless defined $last_completed_score;
  $last_completed_depth = 1 unless $last_completed_depth;
  return wantarray
    ? ($best_move, $last_completed_score, $last_completed_depth)
    : $best_move;
}

1;
