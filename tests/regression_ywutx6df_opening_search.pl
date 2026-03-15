#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::EvalTerms qw(is_tactical_queen_move);
use Chess::State;

sub replay_moves {
  my (@moves) = @_;
  my $state = Chess::State->new();
  for my $uci (@moves) {
    my $move = $state->encode_move($uci);
    my $next = $state->make_move($move);
    die "Failed to play $uci\n" unless defined $next;
    $state = $next;
  }
  return $state;
}

my $after_nxd5 = replay_moves(qw(
  e2e4 e7e5
  g1f3 b8c6
  f1c4 g8f6
  f3g5 d8e7
  g5f7 h8g8
  f7g5 d7d5
  c4d5 c6d5
));

my $qh5 = $after_nxd5->encode_move('d1h5');
my $qe2 = $after_nxd5->encode_move('d1e2');
my $qh5_state = $after_nxd5->make_move($qh5);
my $qe2_state = $after_nxd5->make_move($qe2);

ok(defined $qh5_state, 'YWUtX6DF forcing queen check can be replayed');
ok(defined $qe2_state, 'YWUtX6DF quiet queen regroup can be replayed');
ok(
  is_tactical_queen_move($after_nxd5, $qh5, $qh5_state, 0),
  'YWUtX6DF Qh5+ stays classified as a tactical queen move',
);
ok(
  !is_tactical_queen_move($after_nxd5, $qe2, $qe2_state, 0),
  'YWUtX6DF Qe2 is not misclassified as tactical just because other pieces already attack the king shell',
);

done_testing();
