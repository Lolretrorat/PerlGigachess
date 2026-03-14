#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::TranspositionTable;

my $tt = Chess::TranspositionTable->new(
  max_entries => 4,
  cluster_size => 2,
  age_weight => 2,
);

ok($tt->store(
  key => 'alpha',
  depth => 5,
  score => 42,
  flag => 1,
  best_move_key => 99,
  ply => 0,
  mate_score => 30_000,
), 'stores initial entry');

is($tt->entry_count, 1, 'entry count increments after initial store');

my $alpha = $tt->probe('alpha', ply => 0, mate_score => 30_000);
is($alpha->{depth}, 5, 'probe returns stored depth');
is($alpha->{score}, 42, 'probe returns stored score');
is($alpha->{best_move_key}, 99, 'probe returns stored move key');

ok(!$tt->store(
  key => 'alpha',
  depth => 4,
  score => 7,
  flag => 2,
  best_move_key => 88,
  ply => 0,
  mate_score => 30_000,
), 'same-generation shallower entry does not replace deeper one');

$alpha = $tt->probe('alpha', ply => 0, mate_score => 30_000);
is($alpha->{depth}, 5, 'depth is preserved after rejected replacement');
is($alpha->{best_move_key}, 99, 'best move is preserved after rejected replacement');

my $next_gen = $tt->next_generation;
is($next_gen, 1, 'generation increments');

ok($tt->store(
  key => 'alpha',
  depth => 4,
  score => 13,
  flag => 3,
  best_move_key => 77,
  ply => 0,
  mate_score => 30_000,
), 'newer generation can replace shallower same-key entry');

$alpha = $tt->probe('alpha', ply => 0, mate_score => 30_000);
is($alpha->{depth}, 4, 'newer generation replacement depth is visible');
is($alpha->{best_move_key}, 77, 'newer generation replacement move is visible');

ok($tt->store(
  key => 'mate',
  depth => 7,
  score => 29_995,
  flag => 1,
  best_move_key => 11,
  ply => 3,
  mate_score => 30_000,
), 'stores mate-like score with normalization');

my $mate = $tt->probe('mate', ply => 3, mate_score => 30_000);
is($mate->{score}, 29_995, 'mate-like score round-trips at same ply');

my $victim_tt = Chess::TranspositionTable->new(
  max_entries => 2,
  cluster_size => 2,
  age_weight => 2,
);

ok($victim_tt->store(key => 'old_shallow', depth => 1, score => 5, flag => 1), 'stores old shallow entry');
ok($victim_tt->store(key => 'old_deep', depth => 6, score => 8, flag => 1), 'stores old deep entry');
$victim_tt->next_generation;
$victim_tt->next_generation;

ok($victim_tt->store(key => 'fresh_mid', depth => 2, score => 9, flag => 1), 'stores fresh entry into full cluster');
ok(!defined $victim_tt->probe('old_shallow'), 'replacement policy evicts the weakest aged entry');
ok(defined $victim_tt->probe('old_deep'), 'deeper aged entry is retained');
ok(defined $victim_tt->probe('fresh_mid'), 'new entry is present after replacement');
is($victim_tt->entry_count, 2, 'entry count remains capped after replacement');

done_testing();
