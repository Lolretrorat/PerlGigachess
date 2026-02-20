#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";
use Chess::State;
use Chess::Engine;

my @cases = (
  {
    name => 'white checking promotion is prioritized',
    fen => '7k/6P1/6K1/8/8/8/8/8 w - - 0 1',
    higher => 'g7g8q',
    lower  => 'g7g8n',
  },
  {
    name => 'black checking promotion is prioritized',
    fen => '8/8/8/8/8/6k1/6p1/7K b - - 0 1',
    higher => 'g2g1q',
    lower  => 'g2g1n',
  },
);

for my $case (@cases) {
  my $state = Chess::State->new($case->{fen});
  my @ordered = Chess::Engine::_ordered_moves($state, 0, undef, undef);
  my @moves = map { $state->decode_move($_->[1]) } @ordered;

  my %index_by_move;
  for my $idx (0 .. $#moves) {
    $index_by_move{$moves[$idx]} //= $idx;
  }

  die "Promotion-check regression failed for '$case->{name}': missing $case->{higher} in ordered moves\n"
    unless exists $index_by_move{$case->{higher}};
  die "Promotion-check regression failed for '$case->{name}': missing $case->{lower} in ordered moves\n"
    unless exists $index_by_move{$case->{lower}};

  if ($index_by_move{$case->{higher}} >= $index_by_move{$case->{lower}}) {
    die "Promotion-check regression failed for '$case->{name}': $case->{higher} ranked after $case->{lower}\n";
  }
}

print "Promotion-check regression OK: checking promotions rank above non-check promotions\n";
exit 0;
