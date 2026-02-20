#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use IPC::Open2;

my $play = File::Spec->catfile($RealBin, '..', 'play.pl');
my ($out, $in);
my $pid = open2($out, $in, $^X, $play, '--uci');
my $timeout_s = 8;

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

    if ($line =~ $pattern) {
      return (\@lines, $line);
    }
  }
}

sub assert_any_line {
  my ($lines, $pattern, $label) = @_;
  for my $line (@{$lines}) {
    return if $line =~ $pattern;
  }
  my $seen = @{$lines} ? join("\n", @{$lines}) : '<no output>';
  die "Missing $label. Seen:\n$seen\n";
}

my $ok = eval {
  send_cmd('uci');
  my ($uci_lines) = read_until(qr/^uciok$/, $timeout_s, 'uciok');
  assert_any_line($uci_lines, qr/^id name\s+\S+/, 'id name');
  assert_any_line($uci_lines, qr/^id author\s+\S+/, 'id author');
  for my $option (qw(Depth Workers MoveOverhead MultiPV OwnBook)) {
    assert_any_line($uci_lines, qr/^option name \Q$option\E\b/, "option $option");
  }

  send_cmd('isready');
  read_until(qr/^readyok$/, $timeout_s, 'readyok');

  send_cmd('setoption name Depth value 999');
  send_cmd('setoption name Workers value -5');
  send_cmd('setoption name MoveOverhead value 5000');
  send_cmd('setoption name MultiPV value 99');
  send_cmd('setoption name OwnBook value false');

  send_cmd('debug on');
  send_cmd('bogus_command_for_protocol_regression');
  read_until(
    qr/^unknown command 'bogus_command_for_protocol_regression'$/,
    $timeout_s,
    'debug unknown-command echo',
  );

  send_cmd('position startpos moves e2e4 e7e5');
  send_cmd('isready');
  read_until(qr/^readyok$/, $timeout_s, 'readyok after position startpos moves');

  send_cmd('position fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 moves zzzz');
  read_until(
    qr/^info string Ignored invalid move token 'zzzz' while applying position moves; remaining tokens were skipped$/,
    $timeout_s,
    'invalid move-token info string',
  );

  send_cmd('ucinewgame');
  send_cmd('isready');
  read_until(qr/^readyok$/, $timeout_s, 'readyok after ucinewgame');

  send_cmd('quit');
  close $in;
  close $out;
  waitpid($pid, 0);

  print "UCI protocol regression OK: handshake/options/debug/position contract validated\n";
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
