#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);

## LOCAL MODULES
# make local dir accessible for use statements
use FindBin qw( $RealBin );
use lib $RealBin;

use Chess::Constant;
use Chess::State;
use Chess::Engine;

my $uci_mode = 0;
my $depth = 4;
my $fen;

GetOptions(
  'uci'    => \$uci_mode,
  'depth=i' => \$depth,
  'fen=s'   => \$fen,
) or die "Usage: $0 [--depth N] [--fen FEN] [--uci]\n";

$depth = _normalize_depth($depth);

my $state = Chess::State->new($fen);

if ($uci_mode) {
  run_uci($state, $depth);
  exit 0;
}

run_interactive($state, $depth);
exit 0;

sub run_interactive {
  my ($state, $depth) = @_;

  my $engine = Chess::Engine->new(\$state, $depth);
  my %history;
  _record_position($state, \%history);

  while ($state->is_playable) {
    print_board($state);

    print "\nAvailable moves:\n";
    foreach my $possible_move ($state->get_moves) {
      print " $possible_move\n";
    }

    my $move;
    if (! $state->[1]) {
      print "> ";
      my $input = <STDIN>;
      last unless defined $input;
      chomp $input;
      last if lc($input) eq 'quit';
      $move = eval { $state->encode_move($input) };
      unless ($move) {
        warn "Could not parse move '$input'.\n";
        next;
      }
    } else {
      $move = $engine->think;
      print "> " . $state->decode_move($move) . "\n";
    }

    my $new_state = eval { $state->make_move($move) };
    if (! defined $new_state) {
      warn "Illegal move, try again.\n";
      next;
    }

    $state = $new_state;
    my $status = _record_position($state, \%history);
    if ($status->{force}) {
      print "Forced draw detected ($status->{force}).\n";
      last;
    } elsif ($status->{claim}) {
      print "Draw available ($status->{claim}). Continuing...\n";
    }
  }

  print "Game over. Final FEN: " . $state->get_fen . "\n";
}

sub run_uci {
  my ($state, $depth) = @_;
  my $debug = 0;
  my %history;
  _record_position($state, \%history);

  while (my $input = <STDIN>) {
    $input =~ s/[\r\n]+$//;

    if ($input eq 'uci') {
      print "id name PerlGigachess\n";
      print "id author Greg Kennedy\n";
      print "option name Depth type spin default $depth min 1 max 20\n";
      print "option name OwnBook type check default false\n";
      print "uciok\n";
    } elsif ($input =~ m/^debug (on|off)$/) {
      $debug = ($1 eq 'on') ? 1 : 0;
    } elsif ($input =~ m/^setoption name\s+(.+?)(?:\s+value\s+(.+))?$/i) {
      my $name = lc $1;
      $name =~ s/\s+$//;
      my $value = defined $2 ? $2 : '';
      if ($name eq 'depth') {
        my $new_depth = $value =~ /(\d+)/ ? $1 : $depth;
        $depth = _normalize_depth($new_depth);
      }
    } elsif ($input eq 'isready') {
      print "readyok\n";
    } elsif ($input eq 'ucinewgame') {
      $state = Chess::State->new();
      %history = ();
      _record_position($state, \%history);
    } elsif ($input =~ m/^position (.+?)(?: moves (.+))?$/) {
      my $position = $1;
      my $moves = $2 || '';

      if ($position eq 'startpos') {
        $position = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      }

      $state->set_fen($position);
      %history = ();
      _record_position($state, \%history);

      foreach my $temp (split / /, $moves) {
        my $encoded = $state->encode_move($temp);
        $state = $state->make_move($encoded);
        _record_position($state, \%history);
      }
    } elsif ($input =~ m/^go/) {
      my $status = _current_draw_status($state, \%history);
      if ($status->{force}) {
        print "info string Forced draw: $status->{force}\n";
        print "bestmove 0000\n";
        next;
      } elsif ($status->{claim}) {
        print "info string Draw available: $status->{claim}\n";
      }
      my $engine = Chess::Engine->new(\$state, $depth);
      my $move = $engine->think();
      print "bestmove " . $state->decode_move($move) . "\n";
    } elsif ($input eq 'quit') {
      exit 0;
    } else {
      print "unknown command '$input'\n" if $debug;
    }
  }
}

sub print_board {
  my ($state) = @_;

  print "FEN: " . $state->get_fen . "\n";

  my @board = $state->get_board;
  print "+-+-+-+-+-+-+-+-+\n";
  for my $rank (0 .. 7) {
    for my $file (0 .. 7) {
      my $piece = $board[7 - $rank][$file];
      printf("|%1s", $piece ? $p2l{$piece} : ' ');
    }
    printf("|%d\n", 8 - $rank);
    print "+-+-+-+-+-+-+-+-+\n";
  }
  print " a b c d e f g h\n";
}

sub _repetition_key {
  my ($state) = @_;
  my $fen = $state->get_fen;
  my ($placement, $turn, $castle, $ep) = split / /, $fen;
  return join(' ', $placement, $turn, $castle, $ep);
}

sub _record_position {
  my ($state, $history) = @_;
  my $key = _repetition_key($state);
  my $count = ++$history->{$key};
  return _current_draw_status($state, $history, $count);
}

sub _current_draw_status {
  my ($state, $history, $count_override) = @_;
  my $key = _repetition_key($state);
  my $count = defined $count_override ? $count_override : ($history->{$key} // 0);
  my $halfmove = $state->[Chess::State::HALFMOVE] // 0;

  my @claim;
  push @claim, 'threefold repetition' if $count >= 3;
  push @claim, '50-move rule' if $halfmove >= 100;

  my @force;
  push @force, 'fourfold repetition' if $count >= 4;
  push @force, '60-move rule' if $halfmove >= 120;

  return {
    claim => @claim ? join(' and ', @claim) : undef,
    force => @force ? join(' and ', @force) : undef,
  };
}

sub _normalize_depth {
  my ($value) = @_;
  $value = 1 unless defined $value && $value =~ /\d/;
  $value = int($value);
  $value = 1 if $value < 1;
  $value = 20 if $value > 20;
  return $value;
}
