#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use IPC::Open2;

my $play = File::Spec->catfile($RealBin, '..', 'play.pl');
my ($out, $in);
my $pid = open2($out, $in, $^X, '-I.', $play, '--uci');
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
    return (\@lines, $line) if $line =~ $pattern;
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
  read_until(qr/^uciok$/, $timeout_s, 'uciok');
  send_cmd('isready');
  read_until(qr/^readyok$/, $timeout_s, 'readyok');
  send_cmd('setoption name OwnBook value false');

  send_cmd('position startpos');
  send_cmd('go depth 1 searchmoves e2e4 zzzz');
  my ($forced_lines, $forced_best) = read_until(
    qr/^bestmove\s+(\S+)/,
    $timeout_s,
    'bestmove for single legal searchmove',
  );
  assert_any_line(
    $forced_lines,
    qr/^info string searchmoves narrowed root to a single legal move: e2e4$/,
    'single-legal searchmoves info',
  );
  $forced_best =~ /^bestmove\s+(\S+)/ or die "Malformed bestmove line: $forced_best\n";
  die "Expected forced bestmove e2e4, got $1\n" unless lc($1) eq 'e2e4';

  send_cmd('position startpos');
  send_cmd('go depth 1 searchmoves e2e4 d2d4');
  my (undef, $filtered_best) = read_until(
    qr/^bestmove\s+(\S+)/,
    $timeout_s,
    'bestmove for filtered searchmoves',
  );
  $filtered_best =~ /^bestmove\s+(\S+)/ or die "Malformed bestmove line: $filtered_best\n";
  my $best = lc($1);
  my %allowed = map { $_ => 1 } qw(e2e4 d2d4);
  die "searchmoves regression failed: got out-of-set bestmove $best\n" unless $allowed{$best};

  send_cmd('position startpos');
  send_cmd('go depth 1 searchmoves zzzz');
  my ($none_lines, $none_best) = read_until(
    qr/^bestmove\s+(\S+)/,
    $timeout_s,
    'bestmove for empty searchmoves filter',
  );
  assert_any_line(
    $none_lines,
    qr/^info string No legal moves from searchmoves filter; returning bestmove 0000$/,
    'empty searchmoves info',
  );
  $none_best =~ /^bestmove\s+(\S+)/ or die "Malformed bestmove line: $none_best\n";
  die "Expected bestmove 0000 when searchmoves has no legal moves, got $1\n" unless lc($1) eq '0000';

  send_cmd('quit');
  close $in;
  close $out;
  waitpid($pid, 0);
  print "UCI searchmoves regression OK: filter/narrow/empty cases validated\n";
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
