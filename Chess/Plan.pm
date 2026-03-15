package Chess::Plan;
use strict;
use warnings;

use Exporter qw(import);

use Chess::Book ();
use Chess::Constant;
use Chess::EvalTerms qw(
  file_of_idx
  find_piece_idx
  is_square_attacked_by_side
  king_danger_for_piece
  least_attacker_value
  piece_count
  piece_values
  rank_of_idx
  square_of_idx
);
use Chess::Heuristics qw(:engine);
use Chess::State;
use Chess::TableUtil qw(board_indices);

our @EXPORT_OK = qw(
  state_plan_tags
  pressure_score_for_side
  quiet_move_order_bonus
  is_quiet_plan_move
);

use constant PLAN_CASTLE_ORDER_BONUS            => 120;
use constant PLAN_MINOR_DEVELOP_ORDER_BONUS     => 72;
use constant PLAN_CENTER_BREAK_ORDER_BONUS      => 56;
use constant PLAN_FIANCHETTO_ORDER_BONUS        => 44;
use constant PLAN_KINGSIDE_SPACE_ORDER_BONUS    => 32;
use constant PLAN_CENTER_PRESSURE_ORDER_BONUS   => 24;
use constant PLAN_ROOK_FILE_ORDER_BONUS         => 28;
use constant PLAN_QUEENSIDE_PRESSURE_ORDER_BONUS => 20;
use constant PLAN_EARLY_QUEEN_ORDER_PENALTY     => 92;
use constant PLAN_QUIET_MOVE_THRESHOLD          => 70;
use constant PLAN_PRESSURE_DELTA_THRESHOLD      => 4;
use constant PLAN_KING_DANGER_DELTA_THRESHOLD   => 3;

my @board_indices = board_indices();
my %piece_values = %{piece_values()};

sub state_plan_tags {
  my ($state, $opts) = @_;
  $opts = {} unless ref($opts) eq 'HASH';
  return $opts->{plan_tags} if ref($opts->{plan_tags}) eq 'ARRAY';
  my $tags = Chess::Book::plan_tags_for_state($state);
  return ref($tags) eq 'ARRAY' ? $tags : [];
}

sub pressure_score_for_side {
  my ($board, $attacker_sign, $defender_sign, $attack_cache) = @_;
  return 0 unless ref($board) eq 'ARRAY';
  return 0 unless $attacker_sign == 1 || $attacker_sign == -1;
  return 0 unless $defender_sign == 1 || $defender_sign == -1;

  my $score = 0;
  for my $idx (@board_indices) {
    my $piece = $board->[$idx] // EMPTY;
    next unless $piece;
    next unless ($piece * $defender_sign) > 0;

    my $abs_piece = abs($piece);
    next if $abs_piece == KING;

    my $base = _piece_pressure_weight($abs_piece);
    next unless $base;
    next unless is_square_attacked_by_side($board, $idx, $attacker_sign, $attack_cache);

    my $attacker_count = _attacker_count_for_side($board, $idx, $attacker_sign);
    my $defender_count = _attacker_count_for_side($board, $idx, $defender_sign);
    my $least_attacker = least_attacker_value($board, $idx, $attacker_sign);
    my $least_defender = least_attacker_value($board, $idx, $defender_sign);
    my $victim_value = abs($piece_values{$piece} // 0);

    my $delta = $base;
    $delta += int($base / 2) if !$defender_count;
    $delta += int($base / 2) if $attacker_count > $defender_count;
    if (defined $least_attacker && (!defined($least_defender) || $least_attacker < $least_defender)) {
      $delta += int($base / 2);
    }
    if (defined $least_attacker && $least_attacker <= ($victim_value + UNGUARDED_TARGET_VALUE_MARGIN)) {
      $delta += int($base / 3);
    }
    $score += $delta;
  }

  return $score;
}

sub quiet_move_order_bonus {
  my ($state, $move, $opts) = @_;
  return 0 unless defined $state && ref($move) eq 'ARRAY';
  $opts = {} unless ref($opts) eq 'HASH';

  my $board = $state->[Chess::State::BOARD];
  return 0 unless ref($board) eq 'ARRAY';

  my $to_piece = $board->[$move->[1]] // EMPTY;
  return 0 if $to_piece < 0;
  return 0 if defined $move->[2];

  my $from_piece = $board->[$move->[0]] // EMPTY;
  my $abs_piece = abs($from_piece);
  return 0 unless $abs_piece >= PAWN && $abs_piece <= KING;

  my $piece_count = piece_count($state);
  my $middlegame = $piece_count >= KING_SHUFFLE_MIDGAME_MIN_PIECES ? 1 : 0;
  my $opening = $piece_count >= OPENING_PIECE_COUNT_THRESHOLD ? 1 : 0;
  return 0 unless $middlegame;

  my %plan = map { $_ => 1 } @{state_plan_tags($state, $opts)};
  my $bonus = 0;

  if (defined $move->[3]) {
    $bonus += PLAN_CASTLE_ORDER_BONUS;
    $bonus += int(PLAN_CASTLE_ORDER_BONUS / 2) if $plan{castle_kingside};
  }

  if ($abs_piece == KNIGHT || $abs_piece == BISHOP) {
    if (_is_home_minor_square($move->[0], $abs_piece)) {
      $bonus += PLAN_MINOR_DEVELOP_ORDER_BONUS;
      $bonus += int(PLAN_MINOR_DEVELOP_ORDER_BONUS / 2) if $plan{develop_minors};
    }
    $bonus += PLAN_CENTER_PRESSURE_ORDER_BONUS if $plan{pressure_center} && _is_central_destination($move->[1]);
    $bonus += 18 if $plan{dark_square_control} && _is_dark_square($move->[1]);
  }

  if ($abs_piece == PAWN) {
    $bonus += PLAN_CENTER_BREAK_ORDER_BONUS
      if _is_center_break_pawn_move($move->[0], $move->[1], $from_piece);
    $bonus += int(PLAN_CENTER_BREAK_ORDER_BONUS / 2)
      if $plan{center_break} && _is_center_break_pawn_move($move->[0], $move->[1], $from_piece);
    $bonus += PLAN_KINGSIDE_SPACE_ORDER_BONUS
      if $plan{kingside_space} && _is_kingside_space_pawn_move($move->[0], $move->[1]);
    $bonus += PLAN_FIANCHETTO_ORDER_BONUS
      if $plan{fianchetto_king} && _is_fianchetto_pawn_move($move->[0], $move->[1]);
    $bonus += PLAN_QUEENSIDE_PRESSURE_ORDER_BONUS
      if $plan{queenside_pressure} && _is_queenside_space_pawn_move($move->[0], $move->[1]);
  }

  if ($abs_piece == BISHOP && $plan{fianchetto_king} && _is_fianchetto_bishop_move($move->[1])) {
    $bonus += PLAN_FIANCHETTO_ORDER_BONUS;
  }

  if ($abs_piece == ROOK) {
    $bonus += _rook_file_bonus($board, $move->[1], $from_piece > 0 ? 1 : -1);
  }

  if ($abs_piece == QUEEN && $opening && _friendly_king_uncastled($board) && _undeveloped_minor_count($board) >= 2) {
    $bonus -= PLAN_EARLY_QUEEN_ORDER_PENALTY;
  }

  return $bonus;
}

sub is_quiet_plan_move {
  my ($state, $move, $new_state, $opts) = @_;
  return 0 unless defined $state && defined $new_state && ref($move) eq 'ARRAY';
  $opts = {} unless ref($opts) eq 'HASH';

  my $board = $state->[Chess::State::BOARD];
  my $to_piece = ref($board) eq 'ARRAY' ? ($board->[$move->[1]] // EMPTY) : EMPTY;
  return 0 if $to_piece < 0;
  return 0 if defined $move->[2];
  return 1 if quiet_move_order_bonus($state, $move, $opts) >= PLAN_QUIET_MOVE_THRESHOLD;

  my $before_board = $state->[Chess::State::BOARD];
  my $after_board = $new_state->[Chess::State::BOARD];
  return 0 unless ref($before_board) eq 'ARRAY' && ref($after_board) eq 'ARRAY';

  my $pressure_gain =
      pressure_score_for_side($after_board, -1, 1) - pressure_score_for_side($before_board, 1, -1);
  return 1 if $pressure_gain >= PLAN_PRESSURE_DELTA_THRESHOLD;

  my $pressure_relief =
      pressure_score_for_side($before_board, -1, 1) - pressure_score_for_side($after_board, 1, -1);
  return 1 if $pressure_relief >= PLAN_PRESSURE_DELTA_THRESHOLD;

  my $opp_king_before = $state->[Chess::State::OPP_KING_IDX];
  my $opp_king_after = $new_state->[Chess::State::KING_IDX];
  my $king_danger_gain =
      king_danger_for_piece($after_board, KING, undef, $opp_king_after)
      - king_danger_for_piece($before_board, OPP_KING, undef, $opp_king_before);
  return 1 if $king_danger_gain >= PLAN_KING_DANGER_DELTA_THRESHOLD;

  return 0;
}

sub _piece_pressure_weight {
  my ($abs_piece) = @_;
  return 0 if !defined $abs_piece || $abs_piece <= PAWN || $abs_piece == KING;
  my $base = HANGING_PIECE_PENALTY->{$abs_piece} // 0;
  return $base > 0 ? THREAT_ATTACK_BONUS + int($base / 2) : 0;
}

sub _attacker_count_for_side {
  my ($board, $target_idx, $attacker_sign) = @_;
  return 0 unless ref($board) eq 'ARRAY';
  return 0 unless $attacker_sign == 1 || $attacker_sign == -1;

  my $pawn = $attacker_sign * PAWN;
  my $knight = $attacker_sign * KNIGHT;
  my $bishop = $attacker_sign * BISHOP;
  my $rook = $attacker_sign * ROOK;
  my $queen = $attacker_sign * QUEEN;
  my $king = $attacker_sign * KING;
  my $count = 0;

  if ($attacker_sign > 0) {
    $count++ if (($board->[$target_idx - 11] // OOB) == $pawn);
    $count++ if (($board->[$target_idx - 9] // OOB) == $pawn);
  } else {
    $count++ if (($board->[$target_idx + 11] // OOB) == $pawn);
    $count++ if (($board->[$target_idx + 9] // OOB) == $pawn);
  }

  for my $inc (-21, -19, -12, -8, 8, 12, 19, 21) {
    $count++ if (($board->[$target_idx + $inc] // OOB) == $knight);
  }

  for my $inc (-11, -10, -9, -1, 1, 9, 10, 11) {
    $count++ if (($board->[$target_idx + $inc] // OOB) == $king);
  }

  for my $inc (-10, -1, 1, 10) {
    my $dest = $target_idx;
    while (1) {
      $dest += $inc;
      my $piece = $board->[$dest] // OOB;
      next if $piece == EMPTY;
      $count++ if $piece == $rook || $piece == $queen;
      last;
    }
  }

  for my $inc (-11, -9, 9, 11) {
    my $dest = $target_idx;
    while (1) {
      $dest += $inc;
      my $piece = $board->[$dest] // OOB;
      next if $piece == EMPTY;
      $count++ if $piece == $bishop || $piece == $queen;
      last;
    }
  }

  return $count;
}

sub _friendly_king_uncastled {
  my ($board) = @_;
  my $king_idx = find_piece_idx($board, KING);
  return 0 unless defined $king_idx;
  return ($king_idx == 23 || $king_idx == 27) ? 0 : 1;
}

sub _undeveloped_minor_count {
  my ($board) = @_;
  return 0 unless ref($board) eq 'ARRAY';
  my $count = 0;
  $count++ if ($board->[22] // EMPTY) == KNIGHT;
  $count++ if ($board->[27] // EMPTY) == KNIGHT;
  $count++ if ($board->[23] // EMPTY) == BISHOP;
  $count++ if ($board->[26] // EMPTY) == BISHOP;
  return $count;
}

sub _is_home_minor_square {
  my ($idx, $abs_piece) = @_;
  return 1 if $abs_piece == KNIGHT && ($idx == 22 || $idx == 27);
  return 1 if $abs_piece == BISHOP && ($idx == 23 || $idx == 26);
  return 0;
}

sub _is_center_break_pawn_move {
  my ($from_idx, $to_idx, $piece) = @_;
  return 0 unless abs($piece // 0) == PAWN;
  my $from_file = file_of_idx($from_idx);
  return 0 unless $from_file >= 3 && $from_file <= 6;
  my $from_rank = rank_of_idx($from_idx);
  my $to_rank = rank_of_idx($to_idx);
  return 0 unless $from_rank == 2;
  return ($to_rank == 3 || $to_rank == 4) ? 1 : 0;
}

sub _is_kingside_space_pawn_move {
  my ($from_idx, $to_idx) = @_;
  my $from_file = file_of_idx($from_idx);
  return 0 unless $from_file >= 6;
  my $from_rank = rank_of_idx($from_idx);
  my $to_rank = rank_of_idx($to_idx);
  return 0 unless $from_rank == 2;
  return ($to_rank == 3 || $to_rank == 4) ? 1 : 0;
}

sub _is_queenside_space_pawn_move {
  my ($from_idx, $to_idx) = @_;
  my $from_file = file_of_idx($from_idx);
  return 0 unless $from_file <= 3;
  my $from_rank = rank_of_idx($from_idx);
  my $to_rank = rank_of_idx($to_idx);
  return 0 unless $from_rank == 2;
  return ($to_rank == 3 || $to_rank == 4) ? 1 : 0;
}

sub _is_fianchetto_pawn_move {
  my ($from_idx, $to_idx) = @_;
  return square_of_idx($from_idx) eq 'g2' && square_of_idx($to_idx) eq 'g3' ? 1 : 0;
}

sub _is_fianchetto_bishop_move {
  my ($to_idx) = @_;
  my $sq = square_of_idx($to_idx);
  return ($sq eq 'g2' || $sq eq 'b2') ? 1 : 0;
}

sub _is_central_destination {
  my ($idx) = @_;
  my $file = file_of_idx($idx);
  my $rank = rank_of_idx($idx);
  return ($file >= 3 && $file <= 6 && $rank >= 3 && $rank <= 6) ? 1 : 0;
}

sub _is_dark_square {
  my ($idx) = @_;
  return ((file_of_idx($idx) + rank_of_idx($idx)) % 2) == 0 ? 1 : 0;
}

sub _rook_file_bonus {
  my ($board, $to_idx, $side_sign) = @_;
  return 0 unless ref($board) eq 'ARRAY';
  return 0 unless $side_sign == 1 || $side_sign == -1;

  my $file = file_of_idx($to_idx);
  my $friendly_pawn = $side_sign * PAWN;
  my $enemy_pawn = -$friendly_pawn;
  my ($friendly, $enemy) = (0, 0);
  for my $idx (@board_indices) {
    next unless file_of_idx($idx) == $file;
    my $piece = $board->[$idx] // EMPTY;
    $friendly++ if $piece == $friendly_pawn;
    $enemy++ if $piece == $enemy_pawn;
  }

  return PLAN_ROOK_FILE_ORDER_BONUS if !$friendly && !$enemy;
  return int(PLAN_ROOK_FILE_ORDER_BONUS / 2) if !$friendly;
  return 0;
}

1;
