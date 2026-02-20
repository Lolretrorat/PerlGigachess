#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use Config;
use lib "$RealBin/..";
use Chess::State;

my $root = "$RealBin/..";
my $local_perl = "$root/.perl5/lib/perl5";
if (-d $local_perl) {
  unshift @INC, $local_perl;
  my $arch_perl = "$local_perl/" . $Config::Config{archname};
  unshift @INC, $arch_perl if -d $arch_perl;
}
my $loaded = do "$root/lichess.pl";
die "Failed to load lichess.pl: $@ $!\n" unless defined $loaded;

my @moves = qw(
  e2e4 e7e5
  g1f3 b8c6
  d2d4 e5d4
  f1c4 d8f6
  e1g1 d7d6
);

my $state = Chess::State->new();
for my $uci (@moves) {
  my $encoded = eval { $state->encode_move($uci) };
  die "Could not encode $uci: $@\n" if !$encoded || $@;
  my $next = eval { $state->make_move($encoded) };
  die "Failed to apply $uci: $@\n" unless defined $next;
  $state = $next;
}

my $game = {
  id => 'jlPas6bb-repro',
  initial_fen => 'startpos',
  moves => [@moves],
};

my @candidates = _candidate_moves($state, 'c1g5');
my @ordered = _reorder_candidates_for_repetition($game, $state, \@candidates, {
  cp => 38,
  move => 'c1g5',
});

die "jlPas6bb regression failed: missing ordered candidates\n" unless @ordered;
die "jlPas6bb regression failed: expected c1g5 to remain top, got $ordered[0]\n"
  unless $ordered[0] eq 'c1g5';

print "Repetition guard jlPas6bb regression OK: kept engine top move c1g5\n";
exit 0;
