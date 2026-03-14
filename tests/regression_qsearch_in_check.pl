#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);

use lib "$RealBin/..";
use Chess::Engine ();
use Chess::State;

my $mate_state = Chess::State->new('7k/6Q1/6K1/8/8/8/8/8 b - - 0 1');
my $score = Chess::Engine::_quiesce($mate_state, -Chess::Engine::INF_SCORE(), Chess::Engine::INF_SCORE(), 0);
my $mate_floor = Chess::Engine::MATE_SCORE() - 128;

die "Qsearch in-check regression failed: expected mate-like score <= -$mate_floor, got $score\n"
  unless defined $score && $score <= -$mate_floor;

print "Qsearch in-check regression OK: checkmated node returned mate-like score $score\n";
exit 0;
