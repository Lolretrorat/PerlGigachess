#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use Config;
use lib "$RealBin/..";

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
  d2d4 f8b4
  c2c3 g8f6
  f3e5 b4d6
  e5c6 d7c6
  e4e5 d8e7
  c1f4 c8f5
  d1b3 e8c8
  b1d2 f6d5
  f4g3 b7b5
  f1b5 c8b7
  b5c6 b7c6
  b3d5 c6d5
  c3c4 d5d4
);

my $game = {
  id                => 'xXgzD7zW',
  initial_fen       => 'startpos',
  moves             => [@moves],
  state_obj         => undef,
  state_move_count  => 0,
  state_initial_fen => undef,
};

my $state = _sync_state_from_game($game);
die "State rebuild failed for xXgzD7zW sequence\n" unless $state;

my $expected_count = scalar(@moves);
if (($game->{state_move_count} // 0) != $expected_count) {
  die "State rebuild count mismatch: got $game->{state_move_count}, expected $expected_count\n";
}

my $expected_fen = '3r3r/p1p1qppp/3b4/4Pb2/2Pk4/6B1/PP1N1PPP/R3K2R w KQ - 0 16';
my $actual_fen = $state->get_fen;
if ($actual_fen ne $expected_fen) {
  die "Unexpected final FEN after rebuild: got '$actual_fen', expected '$expected_fen'\n";
}

print "xXgzD7zW rebuild regression OK: historical line (including d5d4) is legal and state sync succeeds\n";
exit 0;
