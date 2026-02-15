#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Getopt::Long qw(GetOptions);
use IPC::Open2;

my $depth = 3;
my $movetime_ms = 10000;
GetOptions(
  'depth=i' => \$depth,
  'movetime=i' => \$movetime_ms,
) or die "Usage: perl tests/regression_hyhMjQD2_kg8.pl [--depth N] [--movetime MS]\n";

$depth = 1 if $depth < 1;
$depth = 20 if $depth > 20;
$movetime_ms = 100 if !defined $movetime_ms || $movetime_ms < 100;

my $fen = 'rn1q1r1k/ppb2ppp/2p5/3p1b2/3PnNP1/3BP2P/PP3P2/R1BQ1RK1 b - - 0 13';
my $expected_bad = 'h8g8';
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

die "Did not receive bestmove from engine\n" unless defined $bestmove;

if ($bestmove eq $expected_bad) {
  die "Regression failed: engine chose $bestmove for hyhMjQD2 guard position at depth $depth movetime=$movetime_ms\n";
}

print "Regression OK: bestmove=$bestmove (not $expected_bad) at depth $depth movetime=$movetime_ms\n";
exit 0;
