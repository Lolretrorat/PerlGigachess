#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use Getopt::Long qw(GetOptions);
use IPC::Open2;

my $depth = 4;
my $movetime_ms = 1500;
GetOptions(
  'depth=i' => \$depth,
  'movetime=i' => \$movetime_ms,
) or die "Usage: perl tests/regression_promotion_mate.pl [--depth N] [--movetime MS]\n";

$depth = 1 if $depth < 1;
$depth = 20 if $depth > 20;
$movetime_ms = 100 if !defined $movetime_ms || $movetime_ms < 100;

my @cases = (
  {
    name => 'white promotes from 7th rank',
    fen => '7k/5P2/6K1/8/8/8/8/8 w - - 0 1',
    expected => 'f7f8q',
  },
  {
    name => 'black promotes from 2nd rank',
    fen => '8/8/8/8/8/6k1/5p2/7K b - - 0 1',
    expected => 'f2f1q',
  },
);

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

for my $case (@cases) {
  send_cmd("position fen $case->{fen}");
  send_cmd("go depth $depth movetime $movetime_ms");

  my $bestmove;
  my $saw_mate_line = 0;
  while (my $line = <$out>) {
    $line =~ s/[\r\n]+$//;
    $saw_mate_line = 1 if $line =~ /\bscore\s+mate\s+-?\d+/;
    if ($line =~ /^bestmove\s+(\S+)/) {
      $bestmove = $1;
      last;
    }
  }

  die "Did not receive bestmove for case '$case->{name}'\n" unless defined $bestmove;
  if ($bestmove ne $case->{expected}) {
    die "Promotion regression failed for '$case->{name}': expected $case->{expected}, got $bestmove\n";
  }
  if (!$saw_mate_line) {
    die "Promotion regression failed for '$case->{name}': engine did not report a mating score\n";
  }
}

send_cmd('quit');
close $in;
close $out;
waitpid($pid, 0);

print "Promotion regression OK: queen promotions selected with mating lines (depth=$depth movetime=$movetime_ms)\n";
exit 0;
