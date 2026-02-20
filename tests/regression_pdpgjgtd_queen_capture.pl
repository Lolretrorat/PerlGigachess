#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Getopt::Long qw(GetOptions);
use IPC::Open2;

my $depth = 3;
my $movetime_ms = 2500;
GetOptions(
  'depth=i' => \$depth,
  'movetime=i' => \$movetime_ms,
) or die "Usage: perl tests/regression_pdpgjgtd_queen_capture.pl [--depth N] [--movetime MS]\n";

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

# Position before White's move 13 in Lichess game PDPgjgTd (URL secret form: PDPgjgTdyUwU).
my $position_cmd = join ' ',
  'position startpos moves',
  qw(
    e2e4 e7e5
    g1f3 b8c6
    d2d4 f8b4
    c2c3 g8f6
    f3e5 b4d6
    e5c6 d7c6
    e4e5 d8e7
    c1e3 c8f5
    f1d3 e7e6
    e5f6 g7f6
    d3f5 e6f5
    d1b3 b7b5
  );
send_cmd($position_cmd);
send_cmd("go depth $depth movetime $movetime_ms");

my $bestmove;
while (my $line = <$out>) {
  $line =~ s/[\r\n]+$//;
  if ($line =~ /^bestmove\s+(\S+)/) {
    $bestmove = $1;
    last;
  }
}

die "Did not receive bestmove for PDPgjgTd regression position\n"
  unless defined $bestmove;

if ($bestmove eq 'd1f7') {
  die "Regression failed: selected random queen capture d1f7 from PDPgjgTd position\n";
}

send_cmd('quit');
close $in;
close $out;
waitpid($pid, 0);

print "PDPgjgTd regression OK: avoided random queen capture d1f7 (bestmove=$bestmove depth=$depth movetime=$movetime_ms)\n";
exit 0;
