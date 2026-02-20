package Chess::See;
use strict;
use warnings;

use Chess::Constant;
use Chess::State ();

my @knight_steps = (-21, -19, -12, -8, 8, 12, 19, 21);
my @king_steps = (-11, -10, -9, -1, 1, 9, 10, 11);
my @bishop_steps = (-11, -9, 9, 11);
my @rook_steps = (-10, -1, 1, 10);

my %piece_value = (
  PAWN() => 10,
  KNIGHT() => 30,
  BISHOP() => 30,
  ROOK() => 50,
  QUEEN() => 90,
  KING() => 200,
);

sub evaluate_capture {
  my (%args) = @_;
  my $state = $args{state};
  my $move = $args{move};
  return undef unless defined $state && ref($state) && ref($move) eq 'ARRAY';

  my $board = $state->[Chess::State::BOARD];
  return undef unless ref($board) eq 'ARRAY';

  my $from = $move->[0];
  my $to = $move->[1];
  my $from_piece = $board->[$from] // EMPTY;
  return undef unless $from_piece > 0;

  my @occ = @{$board};
  my $captured_piece = $occ[$to] // EMPTY;
  my $captured_idx = $to;

  my $ep = $state->[Chess::State::EP];
  if ($captured_piece == EMPTY
      && $from_piece == PAWN
      && defined $ep
      && $to == $ep
      && ($to - $from == 9 || $to - $from == 11)) {
    $captured_idx = $to - 10;
    $captured_piece = $occ[$captured_idx] // EMPTY;
  }

  return undef unless $captured_piece < 0;

  my @gain;
  $gain[0] = _piece_abs_value($captured_piece);

  $occ[$from] = EMPTY;
  $occ[$captured_idx] = EMPTY if $captured_idx != $to;
  $occ[$to] = defined($move->[2]) ? $move->[2] : $from_piece;

  my $depth = 0;
  my $side = -1;
  while (1) {
    my ($attacker_idx, $attacker_piece) = _least_valuable_attacker(\@occ, $to, $side);
    last unless defined $attacker_idx;
    $depth++;
    $gain[$depth] = _piece_abs_value($attacker_piece) - $gain[$depth - 1];
    $occ[$attacker_idx] = EMPTY;
    $occ[$to] = $attacker_piece;
    $side = -$side;
  }

  while ($depth > 0) {
    $gain[$depth - 1] = -_max(-$gain[$depth - 1], $gain[$depth]);
    $depth--;
  }

  return $gain[0];
}

sub _least_valuable_attacker {
  my ($occ, $target, $side) = @_;
  my $best_idx;
  my $best_piece;
  my $best_value = 1_000_000;

  my @candidates = _attackers_of_square($occ, $target, $side);
  for my $idx (@candidates) {
    my $piece = $occ->[$idx] // EMPTY;
    next unless _piece_matches_side($piece, $side);
    my $value = _piece_abs_value($piece);
    next if $value >= $best_value;
    $best_value = $value;
    $best_idx = $idx;
    $best_piece = $piece;
  }

  return ($best_idx, $best_piece);
}

sub _attackers_of_square {
  my ($occ, $target, $side) = @_;
  my @attackers;

  if ($side > 0) {
    push @attackers, grep { ($occ->[$_] // EMPTY) == PAWN } ($target - 9, $target - 11);
  } else {
    push @attackers, grep { ($occ->[$_] // EMPTY) == OPP_PAWN } ($target + 9, $target + 11);
  }

  for my $step (@knight_steps) {
    my $piece = $occ->[$target + $step] // OOB;
    if (($side > 0 && $piece == KNIGHT) || ($side < 0 && $piece == OPP_KNIGHT)) {
      push @attackers, $target + $step;
    }
  }

  for my $step (@king_steps) {
    my $piece = $occ->[$target + $step] // OOB;
    if (($side > 0 && $piece == KING) || ($side < 0 && $piece == OPP_KING)) {
      push @attackers, $target + $step;
    }
  }

  for my $step (@bishop_steps) {
    my $idx = $target;
    while (1) {
      $idx += $step;
      my $piece = $occ->[$idx] // OOB;
      last if $piece == OOB;
      next if $piece == EMPTY;
      if (($side > 0 && ($piece == BISHOP || $piece == QUEEN))
          || ($side < 0 && ($piece == OPP_BISHOP || $piece == OPP_QUEEN))) {
        push @attackers, $idx;
      }
      last;
    }
  }

  for my $step (@rook_steps) {
    my $idx = $target;
    while (1) {
      $idx += $step;
      my $piece = $occ->[$idx] // OOB;
      last if $piece == OOB;
      next if $piece == EMPTY;
      if (($side > 0 && ($piece == ROOK || $piece == QUEEN))
          || ($side < 0 && ($piece == OPP_ROOK || $piece == OPP_QUEEN))) {
        push @attackers, $idx;
      }
      last;
    }
  }

  return @attackers;
}

sub _piece_matches_side {
  my ($piece, $side) = @_;
  return 0 unless defined $piece && $piece != EMPTY && $piece != OOB;
  return $side > 0 ? ($piece > 0 ? 1 : 0) : ($piece < 0 ? 1 : 0);
}

sub _piece_abs_value {
  my ($piece) = @_;
  my $abs = abs($piece // 0);
  return $piece_value{$abs} // 0;
}

sub _max {
  my ($a, $b) = @_;
  return $a > $b ? $a : $b;
}

1;
