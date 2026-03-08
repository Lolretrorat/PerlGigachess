#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Chess::TranspositionTable;

# Same-key replacement: shallower same-generation entry should not replace deeper one.
my $tt = Chess::TranspositionTable->new(max_entries => 8, cluster_size => 2, age_weight => 2);

my $ok = $tt->store(
  key => 'k',
  depth => 4,
  score => 33,
  flag => 1,
  best_move_key => 111,
);
die "TT contract failed: initial store rejected\n" unless $ok;

$ok = $tt->store(
  key => 'k',
  depth => 2,
  score => 99,
  flag => 2,
  best_move_key => 222,
);
die "TT contract failed: shallower same-generation replacement should be rejected\n"
  if $ok;

my $entry = $tt->probe('k');
die "TT contract failed: probe missing stored key\n" unless $entry;
die "TT contract failed: rejected replacement changed depth/score\n"
  unless ($entry->{depth} == 4 && $entry->{score} == 33 && ($entry->{flag} // -1) == 1);

# New generation may replace even if shallower.
$tt->next_generation();
$ok = $tt->store(
  key => 'k',
  depth => 2,
  score => 77,
  flag => 3,
  best_move_key => 333,
);
die "TT contract failed: newer-generation replacement rejected\n" unless $ok;
$entry = $tt->probe('k');
die "TT contract failed: newer-generation replacement not visible\n"
  unless ($entry->{depth} == 2 && $entry->{score} == 77 && ($entry->{flag} // -1) == 3);

# Mate score normalization should round-trip when probing with matching ply.
my $tt_mate = Chess::TranspositionTable->new(max_entries => 8, cluster_size => 2);
$ok = $tt_mate->store(
  key => 'mate+',
  depth => 1,
  score => 29995,
  ply => 3,
  mate_score => 30000,
);
die "TT contract failed: positive mate store rejected\n" unless $ok;
my $mate_same_ply = $tt_mate->probe('mate+', ply => 3, mate_score => 30000);
my $mate_root_ply = $tt_mate->probe('mate+', ply => 0, mate_score => 30000);
die "TT contract failed: positive mate score did not round-trip at same ply\n"
  unless $mate_same_ply && $mate_same_ply->{score} == 29995;
die "TT contract failed: positive mate score did not keep ply-distance when probing from root\n"
  unless $mate_root_ply && $mate_root_ply->{score} == 29998;

$ok = $tt_mate->store(
  key => 'mate-',
  depth => 1,
  score => -29995,
  ply => 2,
  mate_score => 30000,
);
die "TT contract failed: negative mate store rejected\n" unless $ok;
my $neg_same_ply = $tt_mate->probe('mate-', ply => 2, mate_score => 30000);
my $neg_root_ply = $tt_mate->probe('mate-', ply => 0, mate_score => 30000);
die "TT contract failed: negative mate score did not round-trip at same ply\n"
  unless $neg_same_ply && $neg_same_ply->{score} == -29995;
die "TT contract failed: negative mate score did not keep ply-distance when probing from root\n"
  unless $neg_root_ply && $neg_root_ply->{score} == -29997;

# Capacity contract: with max_entries=1, entry_count remains bounded and only one key survives.
my $tt_cap = Chess::TranspositionTable->new(max_entries => 1, cluster_size => 1, age_weight => 2);
$tt_cap->store(key => 'a', depth => 1, score => 10);
$tt_cap->store(key => 'b', depth => 1, score => 20);
my $count = $tt_cap->entry_count();
die "TT contract failed: entry_count exceeded max_entries (got $count)\n"
  unless $count == 1;
my $has_a = $tt_cap->probe('a') ? 1 : 0;
my $has_b = $tt_cap->probe('b') ? 1 : 0;
die "TT contract failed: expected exactly one key to survive capacity eviction\n"
  unless ($has_a + $has_b) == 1;

print "Transposition table regression OK: replacement, mate normalization, and capacity bounds hold\n";
exit 0;
