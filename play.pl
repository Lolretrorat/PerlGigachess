#!/usr/bin/env perl
use v5.10;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use IO::Handle;
$| = 1;
STDOUT->autoflush(1);
STDERR->autoflush(1);

## LOCAL MODULES
# make local dir accessible for use statements
use FindBin qw( $RealBin );
use lib $RealBin;

use Chess::Constant;
use Chess::State;
use Chess::Engine;
use Chess::TableUtil qw(canonical_fen_key);

my $uci_mode = 0;
my $depth = 15;
my $fen;
my %GO_NUMERIC_TOKEN = map { $_ => 1 } qw(
  wtime btime winc binc movestogo movetime depth
);
my %GO_FLAG_TOKEN = map { $_ => 1 } qw(ponder infinite);

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
  my $cached_moves_key;
  my @cached_moves;
  _record_position($state, \%history);

  while ($state->is_playable) {
    print_board($state);

    my $state_key = canonical_fen_key($state);
    if (!defined $cached_moves_key || $cached_moves_key ne $state_key) {
      @cached_moves = $state->get_moves;
      $cached_moves_key = $state_key;
    }

    print "\nAvailable moves:\n";
    foreach my $possible_move (@cached_moves) {
      print " $possible_move\n";
    }

    my $move;
    if (! $state->[Chess::State::TURN]) {
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
  my $move_overhead_ms = 100;
  my $own_book = 1;
  my %history;
  _record_position($state, \%history);

  while (my $input = <STDIN>) {
    $input =~ s/[\r\n]+$//;

    if ($input eq 'uci') {
      print "id name PerlGigachess\n";
      print "id author Lolretrorat\n";
      print "option name Depth type spin default $depth min 1 max 20\n";
      print "option name MoveOverhead type spin default $move_overhead_ms min 0 max 1000\n";
      print "option name OwnBook type check default true\n";
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
      } elsif ($name eq 'moveoverhead') {
        my $new_overhead = $value =~ /(-?\d+)/ ? $1 : $move_overhead_ms;
        $new_overhead = int($new_overhead);
        $new_overhead = 0 if $new_overhead < 0;
        $new_overhead = 1000 if $new_overhead > 1000;
        $move_overhead_ms = $new_overhead;
      } elsif ($name eq 'ownbook') {
        my $normalized = lc $value;
        $normalized =~ s/^\s+//;
        $normalized =~ s/\s+$//;
        $own_book = ($normalized eq 'true' || $normalized eq '1') ? 1 : 0;
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
      elsif ($position =~ /^fen\s+(.+)/) {
        $position = $1;
      }

      $state->set_fen($position);
      %history = ();
      _record_position($state, \%history);

      foreach my $temp (split / /, $moves) {
        my $encoded = eval { $state->encode_move($temp) };
        if (! $encoded || $@) {
          print "info string ignored invalid move token '$temp' in position command\n";
          last;
        }
        my $next_state = eval { $state->make_move($encoded) };
        if (! defined $next_state || $@) {
          print "info string ignored illegal move token '$temp' in position command\n";
          last;
        }
        $state = $next_state;
        _record_position($state, \%history);
      }
    } elsif ($input =~ m/^go/) {
      my %go = _parse_go_command($input);
      my ($depth_from_cmd) = $input =~ /\bdepth\s+(-?\d+)/;
      $go{depth} = int($depth_from_cmd) if defined $depth_from_cmd;
      my $status = _current_draw_status($state, \%history);
      if ($status->{force}) {
        print "info string Forced draw: $status->{force}\n";
        print "bestmove 0000\n";
        next;
      } elsif ($status->{claim}) {
        print "info string Draw available: $status->{claim}\n";
      }
      my $go_depth = defined $go{depth} ? _normalize_depth($go{depth}) : $depth;
      my $engine = Chess::Engine->new(\$state, $go_depth);
      my %time_args = (move_overhead_ms => $move_overhead_ms);
      if (defined $go{movetime}) {
        $time_args{movetime_ms} = $go{movetime};
      } else {
        my $remaining_ms = $state->[Chess::State::TURN] ? $go{btime} : $go{wtime};
        my $increment_ms = $state->[Chess::State::TURN] ? $go{binc} : $go{winc};
        $time_args{remaining_ms} = $remaining_ms if defined $remaining_ms;
        $time_args{increment_ms} = $increment_ms if defined $increment_ms;
        $time_args{movestogo} = $go{movestogo} if defined $go{movestogo};
      }
      if (defined $go{depth}) {
        $time_args{strict_depth} = 1;
      }
      $time_args{use_book} = $own_book;
      my ($move, $score, $searched_depth) = $engine->think(sub {
        my ($cur_depth, $cur_score, $candidate_move) = @_;
        return unless defined $candidate_move;
        my $candidate_uci = eval { $state->decode_move($candidate_move) };
        $candidate_uci = '0000' unless defined $candidate_uci && length $candidate_uci;
        my $cp = int($cur_score // 0);
        print "info depth $cur_depth score cp $cp pv $candidate_uci\n";
        print "info string Thinking... depth $cur_depth candidate $candidate_uci eval $cp\n";
      }, \%time_args);
      if (!defined $move) {
        print "bestmove 0000\n";
        next;
      }
      if (defined $score && defined $searched_depth) {
        print "info depth $searched_depth score cp " . int($score) . "\n";
      }
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

sub _record_position {
  my ($state, $history) = @_;
  my $key = canonical_fen_key($state);
  my $count = ++$history->{$key};
  return _current_draw_status($state, $history, $count, $key);
}

sub _current_draw_status {
  my ($state, $history, $count_override, $key_override) = @_;
  my $key = defined $key_override ? $key_override : canonical_fen_key($state);
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

sub _parse_go_command {
  my ($input) = @_;
  my %go;
  my @tokens = split /\s+/, $input;
  shift @tokens; # consume 'go'

  while (@tokens) {
    my $token = shift @tokens;
    if ($GO_NUMERIC_TOKEN{$token}) {
      last unless @tokens;
      my $value = shift @tokens;
      next unless defined $value && $value =~ /^-?\d+$/;
      $go{$token} = int($value);
    } elsif ($GO_FLAG_TOKEN{$token}) {
      $go{$token} = 1;
    } elsif ($token eq 'searchmoves') {
      last;
    }
  }

  return %go;
}
