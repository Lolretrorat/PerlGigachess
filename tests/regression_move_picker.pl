#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::MovePicker;

my @moves = (
  [11, 12],      # tt
  [21, 22],      # good capture
  [31, 32],      # bad capture
  [41, 42, 5],   # promotion
  [51, 52],      # killer
  [61, 62],      # counter
  [71, 72],      # quiet
);

my %score_for = (
  11 => 5,
  21 => 30,
  31 => 2,
  41 => 20,
  51 => 15,
  61 => 10,
  71 => 1,
);

my %see_for = (
  21 => 5,
  31 => -5,
);

my $picker = Chess::MovePicker->new(
  moves => \@moves,
  tt_move_key => 11,
  killer_move_keys => [51],
  countermove_key => 61,
  see_bad_capture_threshold => 0,
  see_order_weight => 1,
  move_key_cb => sub {
    my ($move) = @_;
    return $move->[0];
  },
  is_capture_cb => sub {
    my ($move) = @_;
    return ($move->[0] == 21 || $move->[0] == 31) ? 1 : 0;
  },
  see_cb => sub {
    my ($move) = @_;
    return $see_for{$move->[0]};
  },
  score_cb => sub {
    my ($move) = @_;
    return $score_for{$move->[0]};
  },
);

my @ordered_keys = map { $_->[2] } $picker->all_moves;
is_deeply(
  \@ordered_keys,
  [11, 21, 41, 51, 61, 71, 31],
  'picker yields tt, tactical, killer, counter, quiet, then bad captures in bucket order',
);

my $pruning_picker = Chess::MovePicker->new(
  moves => [ [21, 22], [31, 32] ],
  see_bad_capture_threshold => 0,
  see_prune_threshold => 0,
  move_key_cb => sub {
    my ($move) = @_;
    return $move->[0];
  },
  is_capture_cb => sub { return 1; },
  see_cb => sub {
    my ($move) = @_;
    return $see_for{$move->[0]};
  },
  score_cb => sub {
    my ($move) = @_;
    return $score_for{$move->[0]};
  },
);

my @pruned_keys = map { $_->[2] } $pruning_picker->all_moves;
is_deeply(\@pruned_keys, [21], 'SEE pruning removes losing captures below threshold');
is($pruning_picker->pruned_capture_count, 1, 'pruned capture count tracks discarded captures');

my $staged_picker = Chess::MovePicker->new(
  moves => [ [81, 82] ],
  move_key_cb => sub {
    my ($move) = @_;
    return $move->[0];
  },
  score_cb => sub {
    my ($move) = @_;
    return $move->[0];
  },
  stage_generators => {
    tactical => sub {
      return [ [91, 92, 5] ];
    },
  },
);

my @staged_keys = map { $_->[2] } $staged_picker->all_moves;
is_deeply(\@staged_keys, [91, 81], 'stage generators feed later buckets without dropping seeded quiets');

done_testing();
