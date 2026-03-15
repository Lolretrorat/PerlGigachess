#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::Engine;
use Chess::State;

my $state = Chess::State->new();
my @legal = $state->generate_moves;
my $move_a = $legal[0];
my $move_b = $legal[1];

{
  no warnings 'redefine';

  local *Chess::Engine::_configure_time_limits = sub {
    return {
      has_clock => 1,
      panic_level => 0,
      budget_ms => 500,
      hard_ms => 700,
    };
  };
  local *Chess::Engine::_time_up_soft = sub { return 0; };
  local *Chess::Engine::_search_root_with_workers = sub {
    my ($current_state, $depth) = @_;
    return (12, $move_a) if $depth == 1;
    return (15, $move_b) if $depth == 2;
    die "__SOFTTIME__" if $depth >= 3;
    die "unexpected depth $depth\n";
  };
  local *Chess::Engine::_collect_root_pv_lines = sub {
    my ($current_state, $depth, $requested_multipv, $fallback_move, $fallback_score) = @_;
    return [
      {
        multipv => 1,
        score => $fallback_score,
        move => $fallback_move,
        pv => [ $fallback_move ],
      }
    ];
  };

  my $engine = Chess::Engine->new(\$state, 4);
  my ($best_move, $score, $depth) = $engine->think({ use_book => 0, movetime_ms => 400 });

  is($depth, 2, 'unfinished soft-aborted iteration does not count as a completed depth');
  is($score, 15, 'score comes from the last completed iteration before soft abort');
  is_deeply($best_move, $move_b, 'best move remains the move from the last completed iteration');
}

done_testing();
