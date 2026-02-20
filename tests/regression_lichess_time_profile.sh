#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

grep -Eq 'bullet\s*=>\s*11\b' "$ROOT_DIR/lichess.pl"
grep -Eq 'blitz\s*=>\s*13\b' "$ROOT_DIR/lichess.pl"
grep -Eq 'rapid\s*=>\s*5\b' "$ROOT_DIR/lichess.pl"
grep -Eq 'classical\s*=>\s*17\b' "$ROOT_DIR/lichess.pl"
grep -Eq 'unlimited\s*=>\s*18\b' "$ROOT_DIR/lichess.pl"

perl -I"$ROOT_DIR" - "$ROOT_DIR" <<'PERL'
use strict;
use warnings;

use Chess::State;

my ($root) = @ARGV;

delete $ENV{LICHESS_MOVETIME_MS};
delete $ENV{LICHESS_BOOK_MOVETIME_MS};
delete $ENV{LICHESS_DEPTH_OVERRIDE};

my $loaded = do "$root/lichess.pl";
if (!defined $loaded) {
  die "Failed to load lichess.pl: $@ $!\n";
}

my $state = Chess::State->new('rnbqkbnr/ppp2ppp/3pp3/8/3P4/3Q4/PPP1PPPP/RNB1KBNR w KQkq - 0 5');
my @moves = qw(d2d4 d7d6 d1d3 g8f6 c2c4 e7e6 g1f3 f8e7 b1c3 e8g8);

sub check_budget {
  my ($speed, $remaining_ms, $inc_ms, $min_expected, $max_expected) = @_;
  my %game = (
    speed    => $speed,
    my_color => 'white',
    wtime    => $remaining_ms,
    btime    => $remaining_ms,
    winc     => $inc_ms,
    binc     => $inc_ms,
    moves    => [@moves],
  );
  my $budget = _movetime_for_game_ms(\%game, $state);
  die "No budget computed for $speed\n" unless defined $budget;
  die "Budget too low for $speed: got $budget expected >= $min_expected\n"
    if $budget < $min_expected;
  die "Budget too high for $speed: got $budget expected <= $max_expected\n"
    if $budget > $max_expected;
  return $budget;
}

my $blitz = check_budget('blitz', 300_000, 3_000, 2_500, 8_000);
my $rapid = check_budget('rapid', 600_000, 0, 4_500, 12_000);
my $classical = check_budget('classical', 1_800_000, 0, 7_000, 15_000);
my $rapid_panic_30 = check_budget('rapid', 30_000, 0, 150, 2_200);
my $rapid_panic_10 = check_budget('rapid', 10_000, 0, 80, 900);

print "Lichess time-profile regression OK: blitz=$blitz rapid=$rapid classical=$classical rapid_panic_30=$rapid_panic_30 rapid_panic_10=$rapid_panic_10\n";
PERL
