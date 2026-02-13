package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::LocationModifer qw(%location_modifiers);

use Chess::Book;

use List::Util qw(max);

use constant DEBUG => 1;
use constant LOCATION_WEIGHT => 0.15;

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 5; # bigger number more thinky

  # hi ken
  return bless \%self, $class;
}

my %piece_values = (
  KING, 5590,
  PAWN, 10,
  BISHOP, 30,
  KNIGHT, 30,
  ROOK, 50,
  QUEEN, 90,
  OPP_KING, -5590,
  OPP_PAWN, -10,
  OPP_BISHOP, -30,
  OPP_KNIGHT, -30,
  OPP_ROOK, -50,
  OPP_QUEEN, -90,
  EMPTY, 0,
  OOB, 0,
);

my %piece_alias = map { $_ => $_ } qw(
  KING QUEEN ROOK BISHOP KNIGHT PAWN
  OPP_KING OPP_QUEEN OPP_ROOK OPP_BISHOP OPP_KNIGHT OPP_PAWN
);

$piece_alias{KING()}       = 'KING';
$piece_alias{QUEEN()}      = 'QUEEN';
$piece_alias{ROOK()}       = 'ROOK';
$piece_alias{BISHOP()}     = 'BISHOP';
$piece_alias{KNIGHT()}     = 'KNIGHT';
$piece_alias{PAWN()}       = 'PAWN';
$piece_alias{OPP_KING()}   = 'OPP_KING';
$piece_alias{OPP_QUEEN()}  = 'OPP_QUEEN';
$piece_alias{OPP_ROOK()}   = 'OPP_ROOK';
$piece_alias{OPP_BISHOP()} = 'OPP_BISHOP';
$piece_alias{OPP_KNIGHT()} = 'OPP_KNIGHT';
$piece_alias{OPP_PAWN()}   = 'OPP_PAWN';

my @board_indices = _build_board_indices();
my %normalized_location_tables = _normalize_location_modifiers();

sub _build_board_indices {
  my @indices;
  for my $rank (1 .. 8) {
    my $base = ($rank + 1) * 10;
    push @indices, map { $base + $_ } (1 .. 8);
  }
  return @indices;
}

sub _normalize_location_modifiers {
  my %normalized;
  for my $raw_key (keys %location_modifiers) {
    my $table = $location_modifiers{$raw_key};
    next unless ref $table eq 'HASH' && keys %{$table};
    my $canonical = $piece_alias{$raw_key} or next;
    my $max_abs = max(map { abs($_ // 0) } values %{$table}) || 0;
    my %relative = map {
      my $value = $table->{$_} // 0;
      my $ratio = $max_abs ? _clamp($value / $max_abs, -1, 1) : 0;
      $_ => $ratio;
    } keys %{$table};
    $normalized{$canonical} = \%relative;
  }
  return %normalized;
}

sub _clamp {
  my ($value, $min, $max) = @_;
  $value = $min if $value < $min;
  $value = $max if $value > $max;
  return $value;
}

sub _idx_to_square {
  my ($idx, $turn) = @_;
  my $file_idx = ($idx % 10) - 1;
  return unless $file_idx >= 0 && $file_idx < 8;
  my $file = chr(ord('a') + $file_idx);
  my $rank = $turn ? 10 - int($idx / 10) : int($idx / 10) - 1;
  return unless $rank >= 1 && $rank <= 8;
  return $file . $rank;
}

sub _location_modifier_percent {
  my ($piece, $square) = @_;
  my $canonical = $piece_alias{$piece} or return 0;
  my $table = $normalized_location_tables{$canonical} or return 0;
  return $table->{$square} // 0;
}

sub _location_bonus {
  my ($piece, $square, $base_value) = @_;
  my $percent = _location_modifier_percent($piece, $square);
  return 0 unless $percent;
  return $base_value * LOCATION_WEIGHT * $percent;
}

sub _evaluate_board {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $turn = $state->[Chess::State::TURN];
  my $score = 0;

  for my $idx (@board_indices) {
    my $piece = $board->[$idx];
    next unless $piece;

    my $base_value = $piece_values{$piece} // 0;
    next unless $base_value;

    my $square = _idx_to_square($idx, $turn) or next;
    my $bonus = _location_bonus($piece, $square, $base_value);
    $score += $base_value + $bonus;
  }

  return $score;
}

sub _rec_think {
    my ($state, $depth, $alpha, $beta) = @_;

  #printf("%s> _rec_think($depth, $alpha, $beta):", "===" x (3 - $depth));
  # STATIC EVALUATOR
  # bail if at the bottom
  #printf("%d\n", -sum( map { $piece_values{$_} } @{$state->[0]})) unless $depth;
  #return (-sum( map { $piece_values{$_} } @{$state->[0]}), undef) unless $depth;
  #print "\n";
  my $best_value;
  my $best_move;
  foreach my $move (@{$state->generate_pseudo_moves})
  {
    my $new_state = $state->make_move($move);
    if (defined $new_state)
    {
      #printf("%s> Consider move: %s\n", "===" x (3 - $depth), $state->decode_move($move));
      # Move was successful.  Recurse.
      my ($value) = $depth ?
        _rec_think($new_state, $depth - 1, -$beta, -$alpha) :
        (_evaluate_board($state));
      #printf("%s> Value of move %s was %d\n", "===" x (3 - $depth), $state->decode_move($move), $value);
      # Value of this move depends on whether we are at max depth or not.
      if (! defined $best_value || $best_value < $value) {
        #printf("%s> Better than best_value (%s), updating\n", "===" x (3 - $depth), defined $best_value ? $best_value : 'undef');
        $best_value = $value;
	$best_move = $move;
        # update the alpha cutoff
        $alpha = max($alpha, $best_value);
        #printf("%s> Alpha now %d\n", "===" x (3 - $depth), $alpha);
        # test against Beta
        #printf("%s> Alpha >= beta %d, SKIPPING\n", "===" x (3 - $depth), $beta) if $alpha >= $beta;
        last if $alpha >= $beta;
      }
    }
  }

  $best_value = ($state->is_checked() ? -99999 : 0) unless defined $best_value;

  #printf("%s> AT FINAL: return best value %d, move %s\n", "===" x (3 - $depth), $best_value, $state->decode_move($best_move));

  return (- $best_value, $best_move);
}

#  mainly a converience wrapper around rec_think.
sub think {
  my $self = shift;
  #my ($self, @move_list) = shift;

  my $state = ${$self->{state}};

  # see if we can make a book move
  my $pos = join('', map { $p2l{$_} }
    @{$state->[0]}[21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98]);
  #print "THINK: " . $pos . "\n";

  my $entry = $Chess::Book::book{$pos};
  if ($entry) {
    #print "BOOK HIT\n";
    return $entry->[rand(@$entry)];
  }

  #my ($best_value, $best_move);
  #foreach $move (@move_list) {
  my ($score, $move) = _rec_think(${$self->{state}}, $self->{depth} - 1, -99999, 99999);
  return $move;
  #}
}

1;
