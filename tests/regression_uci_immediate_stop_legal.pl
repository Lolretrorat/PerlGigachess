#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use IPC::Open2;
use IO::Handle;

use lib "$RealBin/..";
use Chess::State;

my $play = File::Spec->catfile($RealBin, '..', 'play.pl');
my ($out, $in);
my $pid = open2($out, $in, $^X, $play, '--uci');
$in->autoflush(1);

my $timeout_s = 10;

sub send_cmd {
  my ($cmd) = @_;
  print {$in} "$cmd\n" or die "Failed to send '$cmd' to engine\n";
}

sub read_line_with_timeout {
  my ($timeout) = @_;
  my $line;
  my $timed_out = 0;

  local $SIG{ALRM} = sub {
    $timed_out = 1;
    die "__READ_TIMEOUT__\n";
  };
  alarm $timeout;
  my $ok = eval {
    $line = <$out>;
    return 1;
  };
  alarm 0;

  if (!$ok) {
    die $@ if !$timed_out;
    return;
  }

  die "Engine stream closed\n" unless defined $line;
  $line =~ s/[\r\n]+$//;
  return $line;
}

sub read_until {
  my ($pattern, $timeout, $label) = @_;
  my @lines;

  while (1) {
    my $line = read_line_with_timeout($timeout);
    if (!defined $line) {
      my $seen = @lines ? join("\n", @lines) : '<no output>';
      die "Timed out waiting for $label. Seen:\n$seen\n";
    }
    push @lines, $line;
    return (\@lines, $line) if $line =~ $pattern;
  }
}

my $ok = eval {
  send_cmd('uci');
  read_until(qr/^uciok$/, $timeout_s, 'uciok');
  send_cmd('isready');
  read_until(qr/^readyok$/, $timeout_s, 'readyok');

  send_cmd('setoption name OwnBook value false');
  send_cmd('position startpos');
  send_cmd('go depth 8');
  send_cmd('stop');

  my (undef, $best_line) = read_until(qr/^bestmove\s+(\S+)/, $timeout_s, 'bestmove after immediate stop');
  $best_line =~ /^bestmove\s+(\S+)/ or die "Malformed bestmove line: $best_line\n";
  my $bestmove = lc $1;

  die "Immediate-stop regression failed: returned bestmove 0000 in a playable position\n"
    if $bestmove eq '0000';

  my $state = Chess::State->new();
  my %legal = map { lc($_) => 1 } $state->get_moves;
  die "Immediate-stop regression failed: bestmove '$bestmove' is not legal in startpos\n"
    unless $legal{$bestmove};

  send_cmd('quit');
  close $in;
  close $out;
  waitpid($pid, 0);

  print "UCI immediate-stop regression OK: returned legal bestmove '$bestmove' (not 0000)\n";
  return 1;
};

my $err = $@;
if (!$ok) {
  eval { send_cmd('quit') };
  close $in if defined fileno($in);
  close $out if defined fileno($out);
  waitpid($pid, 0);
  die $err;
}

exit 0;
