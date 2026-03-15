package Chess::EvalTerms;
use strict;
use warnings;

use Exporter qw(import);

use Chess::Constant;
use Chess::State;
use Chess::TableUtil qw(idx_to_square board_indices);
use Chess::LocationModifer qw(%location_modifiers);
use Chess::Heuristics qw(:engine);

use List::Util qw(max);

our @EXPORT_OK = qw(
  piece_values
  flip_idx
  rank_of_idx
  file_of_idx
  square_of_idx
  clamp
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

sub piece_values {
  return \%piece_values;
}

sub _normalize_location_modifiers {
  my %normalized;
  for my $raw_key (keys %location_modifiers) {
    my $table = $location_modifiers{$raw_key};
    next unless ref $table eq 'HASH' && keys %{$table};
    my $canonical = $piece_alias{$raw_key} or next;
    my $max_abs = max(map { abs($_ // 0) } values %{$table}) || 0;
    my %relative = map {
      my $value = $table->{$_} // 0;
      my $ratio = $max_abs ? clamp($value / $max_abs, -1, 1) : 0;
      $_ => $ratio;
    } keys %{$table};
    $normalized{$canonical} = \%relative;
  }
  return %normalized;
}

sub clamp {
  my ($value, $min, $max) = @_;
  $value = $min if $value < $min;
  $value = $max if $value > $max;
  return $value;
}

sub location_modifier_percent {
  my ($piece, $square) = @_;
  my $canonical = $piece_alias{$piece} or return 0;
  my $table = $normalized_location_tables{$canonical} or return 0;
  return $table->{$square} // 0;
}

sub location_bonus {
  my ($piece, $square, $base_value) = @_;
  my $percent = location_modifier_percent($piece, $square);
  return 0 unless $percent;
  return $base_value * LOCATION_WEIGHT * $percent;
}

sub flip_idx {
  my ($idx) = @_;
  my $rank_base = int($idx / 10) * 10;
  my $file = $idx % 10;
  return 110 - $rank_base + $file;
}

sub rank_of_idx {
  my ($idx) = @_;
  my $cached = $rank_by_idx[$idx];
  return $cached if defined $cached;
  return int($idx / 10) - 1;
}

sub file_of_idx {
  my ($idx) = @_;
  my $cached = $file_by_idx[$idx];
  return $cached if defined $cached;
  return $idx % 10;
}

sub square_of_idx {
  my ($idx) = @_;
  return $square_by_idx[$idx] // idx_to_square($idx, 0);
}

sub is_square_attacked_by_side {
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

sub _queen_attacks_square_from {
  my ($board, $from_idx, $target_idx, $queen_piece) = @_;
  return 0 unless ref($board) eq 'ARRAY';
  return 0 unless defined $from_idx && defined $target_idx;
  return 0 unless defined $queen_piece && abs($queen_piece) == QUEEN;
  return 0 if $from_idx == $target_idx;

  my $delta = $target_idx - $from_idx;
  my $step;
  if ($delta % 10 == 0) {
    $step = $delta > 0 ? 10 : -10;
  } elsif (int($target_idx / 10) == int($from_idx / 10)) {
    $step = $delta > 0 ? 1 : -1;
  } elsif ($delta % 11 == 0) {
    $step = $delta > 0 ? 11 : -11;
  } elsif ($delta % 9 == 0) {
    $step = $delta > 0 ? 9 : -9;
  } else {
    return 0;
  }

  for (my $idx = $from_idx + $step; $idx != $target_idx; $idx += $step) {
    my $piece = $board->[$idx] // OOB;
    return 0 if $piece == OOB;
    next unless $piece;
    return 0;
  }

  return 1;
}

sub find_piece_idx {
  my ($board, $target_piece) = @_;
  for my $idx (@board_indices) {
    return $idx if ($board->[$idx] // 0) == $target_piece;
  }
  return;
}

sub _is_passed_pawn {
  my ($board, $idx, $side_sign) = @_;
  return 0 unless $side_sign == 1 || $side_sign == -1;

  my $file = file_of_idx($idx);
  my $rank = rank_of_idx($idx);
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

sub development_score {
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
    $king_walk_phase = clamp(($piece_count - MID_ENDGAME_PIECE_THRESHOLD) / $phase_span, 0, 1);
  }

  my $king_idx = exists $opts->{king_idx} ? $opts->{king_idx} : find_piece_idx($board, KING);
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

    my $queen_idx = exists $opts->{queen_idx} ? $opts->{queen_idx} : find_piece_idx($board, QUEEN);
    if (defined $queen_idx && $queen_idx != 24 && $undeveloped_minors >= 2) {
      $score -= EARLY_QUEEN_MOVE_PENALTY;
    }
  }

  if ($uncastled && $king_idx != 25 && $king_walk_phase > 0) {
    my $file = file_of_idx($king_idx);
    my $rank = rank_of_idx($king_idx);
    my $walk_penalty = EARLY_KING_WALK_HOME_PENALTY;
    $walk_penalty += EARLY_KING_WALK_EXPOSED_FILE_PENALTY if $file >= 3 && $file <= 6;
    $walk_penalty += EARLY_KING_WALK_CENTRAL_FILE_PENALTY if $file >= 4 && $file <= 6;
    $walk_penalty += EARLY_KING_WALK_ADVANCED_RANK_PENALTY if $rank >= 2;
    $score -= int($walk_penalty * $king_walk_phase + 0.5);
  }

  my $opponent_has_queen = exists $opts->{opponent_has_queen}
    ? ($opts->{opponent_has_queen} ? 1 : 0)
    : (defined find_piece_idx($board, OPP_QUEEN) ? 1 : 0);
  if ($uncastled && $opponent_has_queen) {
    $score -= UNCASTLED_KING_PENALTY;
    my $file = file_of_idx($king_idx);
    $score -= CENTRAL_KING_PENALTY if $file >= 4 && $file <= 6;
  }

  return $score;
}

sub passed_pawn_score {
  my ($board) = @_;
  my $score = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    if ($piece == PAWN && _is_passed_pawn($board, $idx, 1)) {
      my $rank = rank_of_idx($idx);
      $score += PASSED_PAWN_BONUS_BY_RANK->[$rank] // 0;
      if ($rank >= 6 && ($board->[$idx + 10] // OOB) == EMPTY) {
        $score += 2;
      }
    } elsif ($piece == OPP_PAWN && _is_passed_pawn($board, $idx, -1)) {
      my $rank = rank_of_idx($idx);
      $score -= ENEMY_PASSED_PAWN_PENALTY_BY_RANK->[$rank] // 0;
      if ($rank <= 3 && ($board->[$idx - 10] // OOB) == EMPTY) {
        $score -= 2;
      }
    }
  }

  return $score;
}

sub hanging_piece_score {
  my ($board, $attack_cache) = @_;
  my $score = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    my $abs_piece = abs($piece);
    my $penalty = HANGING_PIECE_PENALTY->{$abs_piece} // 0;
    next unless $penalty;

    if ($piece > 0) {
      next unless is_square_attacked_by_side($board, $idx, -1, $attack_cache);
      my $defended = is_square_attacked_by_side($board, $idx, 1, $attack_cache) ? 1 : 0;
      my $delta = $defended ? int($penalty * HANGING_DEFENDED_SCALE) : $penalty;
      $score -= $delta;
    } else {
      next unless is_square_attacked_by_side($board, $idx, 1, $attack_cache);
      my $defended = is_square_attacked_by_side($board, $idx, -1, $attack_cache) ? 1 : 0;
      my $delta = $defended ? int($penalty * HANGING_DEFENDED_SCALE) : $penalty;
      $score += $delta;
    }
  }

  return $score;
}

sub threatened_material_summary {
  my ($board, $attack_cache) = @_;
  my %summary = (
    threatened_ours        => 0,
    threatened_theirs      => 0,
    threatened_ours_count  => 0,
    threatened_theirs_count => 0,
    threatened_delta       => 0,
  );

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;

    my $abs_piece = abs($piece);
    next if $abs_piece == KING;

    my $penalty = HANGING_PIECE_PENALTY->{$abs_piece};
    $penalty = THREATENED_PAWN_PENALTY if !defined $penalty && $abs_piece == PAWN;
    next unless defined $penalty && $penalty > 0;

    my $enemy_sign = $piece > 0 ? -1 : 1;
    my $friendly_sign = -$enemy_sign;
    next unless is_square_attacked_by_side($board, $idx, $enemy_sign, $attack_cache);

    my $defended = is_square_attacked_by_side($board, $idx, $friendly_sign, $attack_cache) ? 1 : 0;
    my $least_attacker = least_attacker_value($board, $idx, $enemy_sign);
    my $victim_value = abs($piece_values{$piece} // 0);
    my $pressure = defined $least_attacker && $least_attacker <= ($victim_value + UNGUARDED_TARGET_VALUE_MARGIN)
      ? 1
      : 0;

    my $delta = $defended ? int($penalty * HANGING_DEFENDED_SCALE) : $penalty;
    $delta += THREAT_ATTACK_BONUS if !$defended || $pressure;
    next unless $delta > 0;

    if ($piece > 0) {
      $summary{threatened_ours} += $delta;
      $summary{threatened_ours_count}++;
    } else {
      $summary{threatened_theirs} += $delta;
      $summary{threatened_theirs_count}++;
    }
  }

  $summary{threatened_delta} = $summary{threatened_theirs} - $summary{threatened_ours};
  return \%summary;
}

sub least_attacker_value {
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

sub is_quiet_hanging_move {
  my ($new_state, $move, $is_capture) = @_;
  return 0 if $is_capture;
  return 0 if defined $move->[2] || defined $move->[3];
  return 0 if $new_state->is_checked;

  my $new_board = $new_state->[Chess::State::BOARD];
  my $dest_idx = flip_idx($move->[1]);
  my $moved_piece = $new_board->[$dest_idx] // 0;
  return 0 unless $moved_piece < 0;
  my $abs_piece = abs($moved_piece);
  return 0 if $abs_piece < KNIGHT;

  return 0 unless is_square_attacked_by_side($new_board, $dest_idx, 1);
  return 0 if is_square_attacked_by_side($new_board, $dest_idx, -1);
  return 1;
}

sub hanging_move_penalty {
  my ($new_state, $move) = @_;
  my $new_board = $new_state->[Chess::State::BOARD];
  my $dest_idx = flip_idx($move->[1]);
  my $moved_piece = abs($new_board->[$dest_idx] // 0);
  my $base = HANGING_PIECE_PENALTY->{$moved_piece} // 0;
  return 0 unless $base;
  return $base + HANGING_MOVE_GUARD_BONUS;
}

sub king_ring_indices {
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

sub king_danger_for_piece {
  my ($board, $king_piece, $attack_cache, $king_idx_hint) = @_;
  my $king_idx = defined $king_idx_hint ? $king_idx_hint : find_piece_idx($board, $king_piece);
  return 0 unless defined $king_idx;

  my $friendly_sign = $king_piece > 0 ? 1 : -1;
  my $enemy_sign = -$friendly_sign;
  my $friendly_pawn = $friendly_sign * PAWN;
  my $danger = 0;

  my @ring = king_ring_indices($board, $king_idx);
  my $ring_attacked = 0;
  my $ring_undefended = 0;
  for my $idx (@ring) {
    next unless is_square_attacked_by_side($board, $idx, $enemy_sign, $attack_cache);
    $ring_attacked++;
    $ring_undefended++ unless is_square_attacked_by_side($board, $idx, $friendly_sign, $attack_cache);
  }

  $danger += $ring_attacked * KING_DANGER_RING_ATTACK_PENALTY;
  $danger += $ring_undefended * KING_DANGER_RING_UNDEFENDED_PENALTY;
  $danger += KING_DANGER_CHECK_PENALTY if is_square_attacked_by_side($board, $king_idx, $enemy_sign, $attack_cache);

  my @shield_offsets = $friendly_sign > 0 ? (9, 10, 11) : (-9, -10, -11);
  for my $inc (@shield_offsets) {
    my $shield_idx = $king_idx + $inc;
    next if ($board->[$shield_idx] // OOB) == OOB;
    my $piece = $board->[$shield_idx] // OOB;
    $danger += KING_DANGER_SHIELD_MISSING_PENALTY if $piece != $friendly_pawn;
  }

  my $king_file = file_of_idx($king_idx);
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

sub king_danger_score {
  my ($board, $attack_cache, $our_king_idx, $opp_king_idx) = @_;
  my $our_danger = king_danger_for_piece($board, KING, $attack_cache, $our_king_idx);
  my $opp_danger = king_danger_for_piece($board, OPP_KING, $attack_cache, $opp_king_idx);
  return $opp_danger - $our_danger;
}

sub non_king_piece_count {
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

sub king_aggression_for_piece {
  my ($board, $king_piece, $enemy_piece_count) = @_;
  return 0 unless defined $enemy_piece_count;
  return 0 if $enemy_piece_count >= KING_AGGRESSION_ENEMY_PIECE_START;
  my $king_idx = find_piece_idx($board, $king_piece);
  return 0 unless defined $king_idx;

  my $phase = (KING_AGGRESSION_ENEMY_PIECE_START - $enemy_piece_count) / KING_AGGRESSION_ENEMY_PIECE_START;
  my $rank = rank_of_idx($king_idx);
  my $file = file_of_idx($king_idx);
  my $advance = $king_piece > 0 ? max(0, $rank - 1) : max(0, 8 - $rank);
  my $center = max(0, 4 - int(abs(4.5 - $file) + abs(4.5 - $rank)));
  my $activity = $advance + $center;
  return 0 unless $activity > 0;
  return int(($activity * $phase * KING_AGGRESSION_RANK_BONUS / 2) + 0.5);
}

sub king_aggression_score {
  my ($board, $friendly_piece_count, $enemy_piece_count) = @_;
  $enemy_piece_count = non_king_piece_count($board, -1) unless defined $enemy_piece_count;
  $friendly_piece_count = non_king_piece_count($board, 1) unless defined $friendly_piece_count;
  my $our_bonus = king_aggression_for_piece($board, KING, $enemy_piece_count);
  my $opp_bonus = king_aggression_for_piece($board, OPP_KING, $friendly_piece_count);
  return $our_bonus - $opp_bonus;
}

sub is_king_safety_critical_move {
  my ($state, $move, $new_state, $own_king_danger) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = abs($board->[$move->[0]] // 0);
  return 1 if $from_piece == KING;
  return 1 if $new_state->is_checked;

  my $king_idx = $state->[Chess::State::KING_IDX];
  $king_idx = find_piece_idx($board, KING) unless defined $king_idx;
  return 1 if defined $own_king_danger && $own_king_danger >= LMR_KING_DANGER_THRESHOLD;
  return 0 unless defined $king_idx;

  my $king_file = file_of_idx($king_idx);
  if ($from_piece == PAWN && abs(file_of_idx($move->[0]) - $king_file) <= 1) {
    return 1;
  }

  my @ring = king_ring_indices($board, $king_idx);
  my %ring = map { $_ => 1 } @ring;
  return 1 if $ring{$move->[0]} || $ring{$move->[1]};

  return 0;
}

sub is_tactical_queen_move {
  my ($state, $move, $new_state, $is_capture) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = abs($board->[$move->[0]] // 0);
  return 0 unless $from_piece == QUEEN;

  return 1 if $is_capture;
  return 1 if $new_state->is_checked;

  my $new_board = $new_state->[Chess::State::BOARD];
  my $enemy_king_idx = $new_state->[Chess::State::KING_IDX];
  $enemy_king_idx = find_piece_idx($new_board, KING) unless defined $enemy_king_idx;
  return 0 unless defined $enemy_king_idx;

  my $queen_idx = flip_idx($move->[1]);
  my $queen_piece = $new_board->[$queen_idx] // 0;
  return 0 unless abs($queen_piece) == QUEEN;
  return 1 if _queen_attacks_square_from($new_board, $queen_idx, $enemy_king_idx, $queen_piece);

  my @ring = king_ring_indices($new_board, $enemy_king_idx);
  for my $sq ($enemy_king_idx, @ring) {
    next unless _queen_attacks_square_from($new_board, $queen_idx, $sq, $queen_piece);
    return 1;
  }

  return 0;
}

sub unsafe_capture_penalty {
  my ($state, $move, $from_piece, $to_piece) = @_;
  return 0 unless $to_piece < 0;

  my $board = $state->[Chess::State::BOARD];
  my $dest_idx = $move->[1];
  my $king_danger_before = king_danger_for_piece($board, KING);

  my $attacker_value = abs($piece_values{$from_piece} || 0);
  my $victim_value = abs($piece_values{$to_piece} || 0);
  my $exchange_loss = max(0, $attacker_value - $victim_value);
  my $enemy_attacks = is_square_attacked_by_side($board, $dest_idx, -1) ? 1 : 0;
  my $defended = is_square_attacked_by_side($board, $dest_idx, 1) ? 1 : 0;

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
      my $king_danger_after = king_danger_for_piece($new_board, OPP_KING);
      my $delta = $king_danger_after - $king_danger_before;
      $penalty += $delta * UNSAFE_CAPTURE_KING_EXPOSURE_WEIGHT if $delta > 0;
    }
  }

  return $penalty;
}

sub capture_plan_order_bonus {
  my ($board, $move, $from_piece, $to_piece) = @_;
  return 0 unless $to_piece < 0;

  my $bonus = 0;
  my $dest_idx = $move->[1];
  my $defended = is_square_attacked_by_side($board, $dest_idx, -1) ? 1 : 0;
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

sub promotion_check_order_bonus {
  my ($state, $move) = @_;
  return 0 unless defined $move->[2];
  my $new_state = $state->make_move($move);
  return 0 unless defined $new_state;
  return $new_state->is_checked ? PROMOTION_CHECK_ORDER_BONUS : 0;
}

sub piece_count {
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
  $state->[Chess::State::PIECE_COUNT] = $count;
  return $count;
}

sub is_middlegame_piece_count {
  my ($piece_count) = @_;
  return 0 unless defined $piece_count;
  return $piece_count >= MIDDLEGAME_MIN_PIECE_COUNT
    && $piece_count <= MIDDLEGAME_MAX_PIECE_COUNT;
}

sub is_pawn_move_in_state {
  my ($state, $move) = @_;
  return 0 unless $state && ref($move) eq 'ARRAY';
  my $board = $state->[Chess::State::BOARD];
  return 0 unless ref($board) eq 'ARRAY';
  my $from_piece = $board->[$move->[0]] // 0;
  return abs($from_piece) == PAWN ? 1 : 0;
}

sub is_sac_candidate_move_in_state {
  my ($state, $move) = @_;
  return 0 unless $state && ref($move) eq 'ARRAY';
  return 0 if defined $move->[2];
  my $board = $state->[Chess::State::BOARD];
  return 0 unless ref($board) eq 'ARRAY';
  my $from_piece = $board->[$move->[0]] // 0;
  my $to_piece = $board->[$move->[1]] // 0;
  return 0 unless $to_piece == OPP_PAWN;
  my $attacker = abs($from_piece);
  return 0 if $attacker <= PAWN;
  return 0 if $attacker == KING;
  return 1;
}

sub has_non_pawn_material {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];
  return 0 unless ref($board) eq 'ARRAY';

  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // 0;
    next unless $piece > 0;
    my $abs_piece = abs($piece);
    return 1 if $abs_piece == KNIGHT
      || $abs_piece == BISHOP
      || $abs_piece == ROOK
      || $abs_piece == QUEEN;
  }

  return 0;
}

sub make_null_move_state {
  my ($state) = @_;
  my $board_ref = $state->[Chess::State::BOARD];
  return undef unless ref($board_ref) eq 'ARRAY';
  my @board = @{$board_ref};

  for my $rank (20, 30, 40, 50) {
    ($board[$rank + $_], $board[110 - $rank + $_]) = (-$board[110 - $rank + $_], -$board[$rank + $_]) for (1 .. 8);
  }

  my $castle = $state->[Chess::State::CASTLE];
  my @next_to_move_castle = (
    (($castle->[1][CASTLE_KING] // 0) ? 1 : 0),
    (($castle->[1][CASTLE_QUEEN] // 0) ? 1 : 0),
  );
  my @next_opponent_castle = (
    (($castle->[0][CASTLE_KING] // 0) ? 1 : 0),
    (($castle->[0][CASTLE_QUEEN] // 0) ? 1 : 0),
  );

  my $own_king_idx = $state->[Chess::State::KING_IDX];
  my $opp_king_idx = $state->[Chess::State::OPP_KING_IDX];
  my $move_number = $state->[Chess::State::MOVE] // 1;
  $move_number++ if $state->[Chess::State::TURN];

  return bless [
    \@board,
    !$state->[Chess::State::TURN],
    [ \@next_to_move_castle, \@next_opponent_castle ],
    undef,
    ($state->[Chess::State::HALFMOVE] // 0) + 1,
    $move_number,
    (defined $opp_king_idx ? flip_idx($opp_king_idx) : undef),
    (defined $own_king_idx ? flip_idx($own_king_idx) : undef),
    piece_count($state),
    undef,
  ], ref($state);
}

1;
