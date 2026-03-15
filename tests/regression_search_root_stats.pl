#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::Heuristics qw(MATE_SCORE);
use Chess::Search qw(
  finalize_root_search_stats
  has_sac_candidate_with_score_drop
  maybe_randomize_tied_root_move
  reset_root_search_stats
  root_search_stats
);
use Chess::State;

my $state = Chess::State->new();
my $move_a = [ 31, 41 ];
my $move_b = [ 32, 42 ];
my $move_c = [ 33, 43 ];

reset_root_search_stats();
my $stats = root_search_stats();
is($stats->{legal_moves}, 0, 'root stats reset legal move count');
is_deeply($stats->{root_candidates}, [], 'root stats reset root candidates');

$stats->{root_candidates} = [
  { score => 15, move => $move_b, move_key => 2 },
  { score => 40, move => $move_a, move_key => 1 },
  { score => -25, move_key => 3 },
];
finalize_root_search_stats();
$stats = root_search_stats();
is($stats->{legal_moves}, 3, 'finalize_root_search_stats infers legal move count');
is($stats->{best_value}, 40, 'best_value tracks the top score');
is($stats->{second_value}, 15, 'second_value tracks the runner-up score');
is($stats->{best_move_key}, 1, 'best_move_key tracks the top move key');
is_deeply(
  [ map { $_->{move_key} } @{$stats->{root_candidates}} ],
  [ 1, 2, 3 ],
  'root candidates are sorted by score descending'
);

my $resolved = maybe_randomize_tied_root_move(
  $state,
  $move_a,
  { randomize_ties => 1, tie_random_cp => 30 },
  sub {
    my ($current_state, $move_key) = @_;
    return $move_c if $move_key == 3;
    return;
  },
);
ok(
  (ref($resolved) eq 'ARRAY')
    && (
      ($resolved->[0] == $move_a->[0] && $resolved->[1] == $move_a->[1])
      || ($resolved->[0] == $move_b->[0] && $resolved->[1] == $move_b->[1])
    ),
  'tie randomization only selects near-tied resolved moves'
);

ok(
  has_sac_candidate_with_score_drop(
    $state,
    20,
    sub {
      my ($current_state, $move) = @_;
      return defined($move) && $move eq $move_b ? 1 : 0;
    }
  ),
  'sac candidate detection fires when score drop exceeds the threshold'
);

ok(
  !has_sac_candidate_with_score_drop(
    $state,
    30,
    sub {
      my ($current_state, $move) = @_;
      return defined($move) && $move eq $move_b ? 1 : 0;
    }
  ),
  'sac candidate detection respects larger thresholds'
);

reset_root_search_stats();
is(
  maybe_randomize_tied_root_move($state, $move_a, { randomize_ties => 0 }, undef),
  $move_a,
  'tie randomization returns the best move unchanged when disabled'
);

reset_root_search_stats();
$stats = root_search_stats();
$stats->{root_candidates} = [
  { score => MATE_SCORE - 1, move => $move_a, move_key => 1 },
  { score => MATE_SCORE - 3, move => $move_b, move_key => 2 },
];
finalize_root_search_stats();
is(
  maybe_randomize_tied_root_move($state, $move_a, { randomize_ties => 1, tie_random_cp => 10 }, undef),
  $move_a,
  'mate-like root scores are not randomized away from the shortest mate'
);

done_testing();
