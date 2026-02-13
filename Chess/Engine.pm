package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::LocationModifer qw(%location_modifiers);
use Chess::EndgameTable;

use Chess::Book;

use List::Util qw(max);

use constant DEBUG => 1;
use constant LOCATION_WEIGHT => 0.15;
use constant QUIESCE_MAX_DEPTH => 4;

my %history_scores;
my @killer_moves;

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 6; # bigger number more thinky

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

sub _ordered_moves {
  my ($state, $ply) = @_;
  my $turn = $state->[Chess::State::TURN];
  my $board = $state->[Chess::State::BOARD];
  my @scored = map {
    [ _move_order_score($board, $_, $turn, $ply), $_ ]
  } @{$state->generate_pseudo_moves};
  @scored = sort { $b->[0] <=> $a->[0] } @scored;
  return map { $_->[1] } @scored;
}

sub _move_order_score {
  my ($board, $move, $turn, $ply) = @_;
  my $from_piece = $board->[$move->[0]] || 0;
  my $to_piece = $board->[$move->[1]] || 0;
  my $score = 0;

  if ($to_piece < 0) {
    my $victim_value = abs($piece_values{$to_piece} || 0);
    my $attacker_value = abs($piece_values{$from_piece} || 0);
    $score += 1000 + 10 * $victim_value - $attacker_value;
  }

  if (defined $move->[2]) {
    my $promo = abs($piece_values{$move->[2]} || 0);
    my $pawn = abs($piece_values{PAWN} || 1);
    $score += 500 + ($promo - $pawn);
  }

  if (defined $move->[3]) {
    $score += 50;
  }

  if (my $square = _idx_to_square($move->[1], $turn)) {
    my $bonus = abs(_location_modifier_percent($from_piece, $square));
    $score += 25 * $bonus;
  }

  if (! _is_capture($board, $move)) {
    $score += _history_bonus($move);
    $score += _killer_bonus($move, $ply);
  }

  return $score;
}

sub _is_capture {
  my ($board, $move) = @_;
  return ($board->[$move->[1]] // 0) < 0;
}

sub _move_key {
  my ($move) = @_;
  return join(':', $move->[0], $move->[1], (defined $move->[2] ? $move->[2] : 0));
}

sub _history_bonus {
  my ($move) = @_;
  return ($history_scores{_move_key($move)} // 0);
}

sub _killer_bonus {
  my ($move, $ply) = @_;
  my $slot = $killer_moves[$ply] || [];
  my $key = _move_key($move);
  return 200 if defined $slot->[0] && $slot->[0] eq $key;
  return 150 if defined $slot->[1] && $slot->[1] eq $key;
  return 0;
}

sub _store_killer {
  my ($ply, $move) = @_;
  $killer_moves[$ply] ||= [];
  my $key = _move_key($move);
  return if defined $killer_moves[$ply][0] && $killer_moves[$ply][0] eq $key;
  $killer_moves[$ply][1] = $killer_moves[$ply][0] if defined $killer_moves[$ply][0];
  $killer_moves[$ply][0] = $key;
}

sub _update_history {
  my ($move, $depth) = @_;
  my $key = _move_key($move);
  $history_scores{$key} += $depth * $depth;
}

sub _quiesce {
  my ($state, $alpha, $beta, $depth) = @_;
  $depth //= 0;

  my $stand_pat = _evaluate_board($state);
  $alpha = max($alpha, $stand_pat);
  return $alpha if $alpha >= $beta || $depth >= QUIESCE_MAX_DEPTH;

  my $board = $state->[Chess::State::BOARD];
  my $turn = $state->[Chess::State::TURN];
  my @captures = grep { _is_capture($board, $_) } @{$state->generate_pseudo_moves};
  return $alpha unless @captures;

  my @ordered = map { $_->[1] }
    sort { $b->[0] <=> $a->[0] }
    map { [ _move_order_score($board, $_, $turn, 0), $_ ] } @captures;

  foreach my $move (@ordered) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $score = -_quiesce($new_state, -$beta, -$alpha, $depth + 1);
    if ($score > $alpha) {
      $alpha = $score;
      last if $alpha >= $beta;
    }
  }

  return $alpha;
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
    my ($state, $depth, $alpha, $beta, $ply) = @_;
    $ply //= 0;

  if ($depth <= 0) {
    my $static = _quiesce($state, $alpha, $beta, 0);
    return (-$static, undef);
  }

  my $best_value;
  my $best_move;
  foreach my $move (_ordered_moves($state, $ply))
  {
    my $is_capture = _is_capture($state->[Chess::State::BOARD], $move);
    my $new_state = $state->make_move($move);
    if (defined $new_state)
    {
      my ($value) = _rec_think($new_state, $depth - 1, -$beta, -$alpha, $ply + 1);
      if (! defined $best_value || $best_value < $value) {
        $best_value = $value;
	$best_move = $move;
        $alpha = max($alpha, $best_value);
        if ($alpha >= $beta) {
          unless ($is_capture) {
            _store_killer($ply, $move);
            _update_history($move, $depth);
          }
          last;
        }
      }
    }
  }

  $best_value = ($state->is_checked() ? -99999 : 0) unless defined $best_value;

  return (- $best_value, $best_move);
}

#  mainly a converience wrapper around rec_think.
sub think {
  my $self = shift;
  #my ($self, @move_list) = shift;

  my $state = ${$self->{state}};

  if (my $book_move = Chess::Book::choose_move($state)) {
    return $book_move;
  }

  if (my $table_move = Chess::EndgameTable::choose_move($state)) {
    return $table_move;
  }

  #my ($best_value, $best_move);
  #foreach $move (@move_list) {
  my ($score, $move) = _rec_think(${$self->{state}}, $self->{depth} - 1, -99999, 99999, 0);
  return $move;
  #}
}

1;
