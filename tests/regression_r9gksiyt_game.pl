#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";
use File::Spec;
use IPC::Open2;
use Test::More;

use Chess::State;

my $promotion_fen_before = '6k1/5ppp/1p1p1P2/7P/8/4b3/2p1K3/6r1 b - - 2 51';
my $promotion_fen_after = '6k1/5ppp/1p1p1P2/7P/8/4b3/4K3/2q3r1 w - - 0 52';

my $promotion_state = Chess::State->new($promotion_fen_before);
my $promotion_move = $promotion_state->encode_move('c2c1q');
ok(defined $promotion_move, 'game promotion move c2c1q is encodable from the pre-promotion FEN');

my $promotion_next = $promotion_state->make_move($promotion_move);
ok(defined $promotion_next, 'game promotion move c2c1q is legal');
is($promotion_next->get_fen, $promotion_fen_after, 'black promotion from the game rebuilds the correct post-promotion FEN');

my @promotion_square_targets = grep { /c1(?:[nbrq])?$/ } map { $promotion_next->decode_move($_) } $promotion_next->generate_moves;
is_deeply(\@promotion_square_targets, [], 'no legal move illegally lands on the promoted queen square in the game position');

my $mate_fen = '6k1/5p1p/1K3p2/7P/6r1/2q5/8/2b5 b - - 0 59';
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
send_cmd("position fen $mate_fen");
send_cmd('go depth 6 movetime 1500');

my $bestmove;
my $saw_mate_two = 0;
my $saw_false_mate_one_log = 0;
my $final_decision;
while (my $line = <$out>) {
  $line =~ s/[\r\n]+$//;
  $saw_mate_two = 1 if $line =~ /\bscore\s+mate\s+2\b/;
  $saw_false_mate_one_log = 1
    if $line =~ /Critical position: forcing line detected \(mate in 1\)/;
  $final_decision = $line if $line =~ /^info string Critical position decision:/;
  if ($line =~ /^bestmove\s+(\S+)/) {
    $bestmove = $1;
    last;
  }
}

send_cmd('quit');
close $in;
close $out;
waitpid($pid, 0);

is($bestmove, 'g4b4', 'engine chooses the game\'s shortest mating move from the pre-mate net');
ok($saw_mate_two, 'engine reports the position as mate in two rather than a shorter phantom mate');
ok(!$saw_false_mate_one_log, 'critical-position logging no longer announces a false mate in one');
like(
  ($final_decision // ''),
  qr/\bmate in 2\b/,
  'final mate decision log reflects the actual mate distance from the game position'
);

done_testing();
