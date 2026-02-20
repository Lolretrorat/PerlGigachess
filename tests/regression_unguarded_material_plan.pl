#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Getopt::Long qw(GetOptions);
use IPC::Open2;

my $depth = 3;
my $movetime_ms = 1500;
GetOptions(
  'depth=i' => \$depth,
  'movetime=i' => \$movetime_ms,
) or die "Usage: perl tests/regression_unguarded_material_plan.pl [--depth N] [--movetime MS]\n";

$depth = 1 if $depth < 1;
$depth = 20 if $depth > 20;
$movetime_ms = 100 if !defined $movetime_ms || $movetime_ms < 100;

my $play = File::Spec->catfile($RealBin, '..', 'play.pl');
my ($out, $in);
my $pid = open2($out, $in, $^X, $play, '--uci');

sub send_cmd {
  my ($cmd) = @_;
  print {$in} "$cmd\n";
}

sub read_until {
  my ($pattern) = @_;
  while (my $line = <$out>) {
    $line =~ s/[\r\n]+$//;
    return $line if $line =~ $pattern;
  }
  return;
}

send_cmd('uci');
read_until(qr/^uciok$/) or die "UCI handshake failed (missing uciok)\n";
send_cmd('isready');
read_until(qr/^readyok$/) or die "UCI handshake failed (missing readyok)\n";
send_cmd('setoption name OwnBook value false');

# White to move with a loose black queen on d5. Engine should choose a capture,
# not a quiet king shuffle.
my $fen = 'r5k1/pp3ppp/2n5/3q4/3P4/2N2Q2/PPP2PPP/R5K1 w - - 0 1';
send_cmd("position fen $fen");
send_cmd("go depth $depth movetime $movetime_ms");

my $bestmove;
while (my $line = <$out>) {
  $line =~ s/[\r\n]+$//;
  if ($line =~ /^bestmove\s+(\S+)/) {
    $bestmove = $1;
    last;
  }
}

send_cmd('quit');
close $in;
close $out;
waitpid($pid, 0);

die "Did not receive bestmove for unguarded-material regression\n"
  unless defined $bestmove;

my %expected_capture = map { $_ => 1 } qw(c3d5 f3d5);
if (!$expected_capture{$bestmove}) {
  die "Unguarded-material regression failed: expected one of c3d5/f3d5, got $bestmove\n";
}

print "Unguarded-material regression OK: captured loose queen ($bestmove) at depth=$depth movetime=$movetime_ms\n";
exit 0;
