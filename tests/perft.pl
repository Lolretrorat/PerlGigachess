#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;

## tests/perft.pl
# Calculates node depths for positions up to specified depth.
# Used for testing move-generation routines.
use Time::HiRes qw/ clock /;

## LOCAL MODULES
# make local dir accessible for use statements
use FindBin qw( $RealBin );
use lib "$RealBin/..";

use Chess::State;

# Some sample perft tests
my @positions = (
  'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1',
  '8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1',
  'r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1',
  'rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8',
  'r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10'
);
my @position_names = (
  'kiwipete',
  'endgame-rook-pawn',
  'mirror-castle-tactics',
  'minor-piece-tension',
  'middlegame-piece-pressure',
);

my %expected_nodes = (
  startpos => {
    1 => 20,
    2 => 400,
    3 => 8902,
    4 => 197281,
    5 => 4865609,
  },
  0 => {
    1 => 48,
    2 => 2039,
    3 => 97862,
    4 => 4085603,
    5 => 193690690,
  },
  1 => {
    1 => 14,
    2 => 191,
    3 => 2812,
    4 => 43238,
    5 => 674624,
  },
  2 => {
    1 => 6,
    2 => 264,
    3 => 9467,
    4 => 422333,
    5 => 15833292,
  },
  3 => {
    1 => 44,
    2 => 1486,
    3 => 62379,
    4 => 2103487,
    5 => 89941194,
  },
  4 => {
    1 => 46,
    2 => 2079,
    3 => 89890,
    4 => 3894594,
    5 => 164075551,
  },
);

sub usage {
  die "Usage: perl tests/perft.pl <depth> [position_index 0-4]\n";
}


##############################################################################
## COUNTERS
my @count;
## Recursive move-and-count routine
sub rec_perft {
  my $state = shift;
  my $max_depth = shift;
  my $depth = 1 + (shift || 0);

  # check moves, increment counters
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);

    if (defined $new_state)
    {
      $count[$depth]{nodes} ++;
      #if (defined $move->[TO_PIECE]) {
        #$count[$depth]{captures} ++
      #}

      if ($max_depth > $depth) {
        # still room for more, make the move and count the results.
        rec_perft($new_state, $max_depth, $depth);
      }
    }
  }
}

##############################################################################
## Global max depth
my $max_depth = shift @ARGV;
usage() unless defined $max_depth && $max_depth =~ /^\d+$/;
$max_depth = int($max_depth);
die "Depth must be between 1 and 5 for asserted regression coverage\n"
  if $max_depth < 1 || $max_depth > 5;

my $position_arg = shift @ARGV;
usage() if @ARGV;

# setup board
my $state;
my $position_key = 'startpos';
my $position_name = 'startpos';
if (defined $position_arg) {
  usage() unless $position_arg =~ /^\d+$/;
  my $position_index = int($position_arg);
  die "Position index must be between 0 and $#positions\n"
    if $position_index < 0 || $position_index > $#positions;
  $state = Chess::State->new($positions[$position_index]);
  $position_key = $position_index;
  $position_name = "position[$position_index] $position_names[$position_index]";
} else {
  $state = Chess::State->new;
}

# call perft routine
my $start_time = clock;
rec_perft($state,$max_depth);
my $end_time = clock;

# print results
say "Results (Elapsed " . ($end_time - $start_time) . " seconds)";
for (my $i = 0; $i < scalar @count; $i ++)
{
  say "======================================================================";
  say "	Depth $i:";
  say "		nodes: " . ($count[$i]{nodes} || 0);
  say "		captures: " . ($count[$i]{captures} || 0);
  say "		ep: " . ($count[$i]{ep} || 0);
  say "		castles: " . ($count[$i]{castles} || 0);
  say "		promotions: " . ($count[$i]{promotions} || 0);
  say "		checks: " . ($count[$i]{checks} || 0);
  say "		checkmates: " . ($count[$i]{checkmates} || 0);
}

my $expected = $expected_nodes{$position_key}
  or die "No expected-node table found for $position_name\n";

my @mismatches;
for my $depth (1 .. $max_depth) {
  die "Missing expected-node baseline for $position_name depth $depth\n"
    unless exists $expected->{$depth};
  my $actual = $count[$depth]{nodes} || 0;
  my $want = $expected->{$depth};
  push @mismatches, "depth $depth expected $want got $actual"
    if $actual != $want;
}

if (@mismatches) {
  die "Perft regression failed for $position_name:\n" . join("\n", @mismatches) . "\n";
}

say "Perft regression OK for $position_name through depth $max_depth";
