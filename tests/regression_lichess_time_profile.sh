#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

perl -I"$ROOT_DIR" - "$ROOT_DIR" <<'PERL'
use strict;
use warnings;

use Chess::State;

my ($root) = @ARGV;

delete $ENV{LICHESS_MOVETIME_MS};
delete $ENV{LICHESS_BOOK_MOVETIME_MS};
delete $ENV{LICHESS_DEPTH_OVERRIDE};
delete $ENV{LICHESS_ALLOW_FORCED_MOVETIME};
delete $ENV{LICHESS_DEPTH_TARGET_BULLET};
delete $ENV{LICHESS_DEPTH_TARGET_BLITZ};
delete $ENV{LICHESS_DEPTH_TARGET_CLASSICAL};
delete $ENV{LICHESS_DEPTH_TARGET_UNLIMITED};
$ENV{LICHESS_DEPTH_TARGET_RAPID} = 15;

my $loaded = do "$root/lichess.pl";
if (!defined $loaded) {
  die "Failed to load lichess.pl: $@ $!\n";
}

my $state = Chess::State->new('rnbqkbnr/ppp2ppp/3pp3/8/3P4/3Q4/PPP1PPPP/RNB1KBNR w KQkq - 0 5');
my @moves = qw(d2d4 d7d6 d1d3 g8f6 c2c4 e7e6 g1f3 f8e7 b1c3 e8g8);

sub mock_analysis {
  my (%game) = @_;
  my $engine_out_text = "bestmove d3g3\n";
  my $engine_in_text = '';
  open my $engine_out, '<', \$engine_out_text or die "open engine_out scalar: $!\n";
  open my $engine_in,  '>', \$engine_in_text  or die "open engine_in scalar: $!\n";
  my $analysis = compute_bestmove(\%game, $engine_out, $engine_in, $state);
  die "No analysis returned\n" unless ref $analysis eq 'HASH';
  return ($analysis, $engine_in_text);
}

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

my %base_game = (
  id                    => 'time-profile',
  speed                 => 'rapid',
  my_color              => 'white',
  wtime                 => 600_000,
  btime                 => 600_000,
  winc                  => 0,
  binc                  => 0,
  moves                 => [@moves],
  engine_supports_depth => 1,
  engine_depth_min      => 1,
  engine_depth_max      => 20,
  engine_depth_default  => 6,
  engine_depth          => undef,
);

my ($rapid_analysis) = mock_analysis(%base_game);
die "Rapid default search should use a clock-managed go command, got '$rapid_analysis->{go_cmd}'\n"
  unless ($rapid_analysis->{go_cmd} // '') =~ /^go wtime \d+ btime \d+ winc \d+ binc \d+(?: movestogo \d+)?$/;
die "Rapid default search should not inject an implicit depth cap, got '$rapid_analysis->{go_cmd}'\n"
  if ($rapid_analysis->{go_cmd} // '') =~ /\bdepth\b/;
my $rapid_depth_target = _speed_target_depth_for_game(\%base_game);
die "Rapid depth target should honor env-backed config, got '$rapid_depth_target'\n"
  unless defined $rapid_depth_target && $rapid_depth_target == 15;

my $clock_go = _clock_go_command_for_game(\%base_game, $state);
die "Clock go command should carry time fields, got '$clock_go'\n"
  unless defined $clock_go && $clock_go =~ /^go wtime \d+ btime \d+ winc \d+ binc \d+(?: movestogo \d+)?$/;

print "Lichess time-profile regression OK: blitz=$blitz rapid=$rapid classical=$classical rapid_panic_30=$rapid_panic_30 rapid_panic_10=$rapid_panic_10 go='$rapid_analysis->{go_cmd}'\n";
PERL
