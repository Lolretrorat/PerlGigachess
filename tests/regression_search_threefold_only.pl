#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);

use lib "$RealBin/..";
use Chess::Engine ();
use Chess::State;

my $state = Chess::State->new();
my $key = Chess::Engine::_state_key($state);

my $twofold_is_draw = Chess::Engine::_search_is_draw($state, 1, { $key => 2 });
die "Search repetition regression failed: second occurrence was treated as draw\n"
  if $twofold_is_draw;

my $threefold_is_draw = Chess::Engine::_search_is_draw($state, 1, { $key => 3 });
die "Search repetition regression failed: third occurrence was not treated as draw\n"
  unless $threefold_is_draw;

print "Search repetition regression OK: draw starts at threefold, not twofold\n";
exit 0;
