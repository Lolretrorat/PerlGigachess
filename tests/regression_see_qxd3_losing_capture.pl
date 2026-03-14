#!/usr/bin/env perl
# Regression test for SEE bug fix from Lichess game qrlijiqK.
# Position after 9. b4 where Black should NOT play Qd6 (loses bishop to bxc5).
# The bug was in Chess/See.pm: gain calculation used attacker value instead
# of captured piece value, making Qxd3 appear profitable when it loses the queen.

use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use lib File::Spec->catdir($RealBin, '..');

use Chess::State;
use Chess::See;
use Chess::TableUtil qw(idx_to_square);

my $errors = 0;

# Position after 9. b4 (Black to move, bishop on c5 attacked)
my $fen_before_qd6 = 'r1bqk2r/p4ppp/2p2n2/2b1p3/1P6/3B4/P1P2PPP/RNBQ1RK1 b kq - 0 9';

# Position after 9...Qd6 10. bxc5 (Black to move, White won the bishop)
my $fen_after_bxc5 = 'r1b1k2r/p4ppp/2pq1n2/2P1p3/8/3B4/P1P2PPP/RNBQ1RK1 b kq - 0 10';

# Test 1: SEE for Qxd3 should be negative (losing capture)
{
  my $s = Chess::State->new($fen_after_bxc5);
  
  # Find d6xd3 move
  my $qxd3_move;
  for my $m (@{$s->generate_pseudo_moves}) {
    my $from_sq = idx_to_square($m->[0], $s->[1]) // '';
    my $to_sq = idx_to_square($m->[1], $s->[1]) // '';
    if ("$from_sq$to_sq" eq 'd6d3') {
      $qxd3_move = $m;
      last;
    }
  }
  
  if (!$qxd3_move) {
    print STDERR "FAIL: Could not find Qxd3 move in position\n";
    $errors++;
  } else {
    my $see = Chess::See::evaluate_capture(state => $s, move => $qxd3_move);
    if (!defined $see) {
      print STDERR "FAIL: SEE returned undef for Qxd3\n";
      $errors++;
    } elsif ($see >= 0) {
      print STDERR "FAIL: SEE for Qxd3 should be negative (losing queen to recapture) but got $see\n";
      $errors++;
    } else {
      print "OK: SEE(Qxd3) = $see (correctly negative)\n";
    }
  }
}

# Test 2: SEE for Qxc5 should be positive (winning back pawn)
{
  my $s = Chess::State->new($fen_after_bxc5);
  
  # Find d6xc5 move
  my $qxc5_move;
  for my $m (@{$s->generate_pseudo_moves}) {
    my $from_sq = idx_to_square($m->[0], $s->[1]) // '';
    my $to_sq = idx_to_square($m->[1], $s->[1]) // '';
    if ("$from_sq$to_sq" eq 'd6c5') {
      $qxc5_move = $m;
      last;
    }
  }
  
  if (!$qxc5_move) {
    print STDERR "FAIL: Could not find Qxc5 move in position\n";
    $errors++;
  } else {
    my $see = Chess::See::evaluate_capture(state => $s, move => $qxc5_move);
    if (!defined $see) {
      print STDERR "FAIL: SEE returned undef for Qxc5\n";
      $errors++;
    } elsif ($see <= 0) {
      print STDERR "FAIL: SEE for Qxc5 should be positive (winning pawn back) but got $see\n";
      $errors++;
    } else {
      print "OK: SEE(Qxc5) = $see (correctly positive)\n";
    }
  }
}

if ($errors > 0) {
  die "SEE regression FAILED with $errors error(s)\n";
}

print "SEE regression OK for qrlijiqK position (Qxd3 correctly evaluated as losing)\n";
exit 0;
