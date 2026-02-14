package Chess::Engine;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::LocationModifer qw(%location_modifiers);
use Chess::EndgameTable;

use Chess::Book;

use List::Util qw(max min);

use constant DEBUG => 1;
use constant LOCATION_WEIGHT => 0.15;
use constant QUIESCE_MAX_DEPTH => 4;
use constant INF_SCORE => 1_000_000;
use constant MATE_SCORE => 900_000;
use constant ASPIRATION_WINDOW => 24;

use constant TT_FLAG_EXACT => 0;
use constant TT_FLAG_LOWER => 1;
use constant TT_FLAG_UPPER => 2;

my %history_scores;
my @killer_moves;
my %transposition_table;

sub new {
  my $class = shift;

  my %self;
  $self{state} = shift || die "Cannot instantiate Chess::Engine without a Chess::State";
  $self{depth} = shift || 14; # bigger number more thinky

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
  my ($state, $ply, $tt_move_key) = @_;
  my $turn = $state->[Chess::State::TURN];
  my $board = $state->[Chess::State::BOARD];
  my @scored = map {
    [ _move_order_score($board, $_, $turn, $ply, $tt_move_key), $_ ]
  } @{$state->generate_pseudo_moves};
  @scored = sort { $b->[0] <=> $a->[0] } @scored;
  return map { $_->[1] } @scored;
}

sub _move_order_score {
  my ($board, $move, $turn, $ply, $tt_move_key) = @_;
  my $from_piece = $board->[$move->[0]] || 0;
  my $to_piece = $board->[$move->[1]] || 0;
  my $score = 0;
  my $move_key = _move_key($move);

  if (defined $tt_move_key && $move_key eq $tt_move_key) {
    $score += 5000;
  }

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

sub _decay_history {
  for my $key (keys %history_scores) {
    $history_scores{$key} = int($history_scores{$key} * 0.85);
    delete $history_scores{$key} if $history_scores{$key} <= 0;
  }
}

sub _state_key {
  my ($state) = @_;
  return $state->get_fen;
}

sub _find_move_by_key {
  my ($state, $target_key) = @_;
  return unless defined $target_key;

  for my $move (@{$state->generate_pseudo_moves}) {
    next unless _move_key($move) eq $target_key;
    my $new_state = $state->make_move($move);
    return $move if defined $new_state;
  }

  return;
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

sub _search {
  my ($state, $depth, $alpha, $beta, $ply) = @_;
  $ply //= 0;

  if ($depth <= 0) {
    return (_quiesce($state, $alpha, $beta, 0), undef);
  }

  my $key = _state_key($state);
  my $tt_entry = $transposition_table{$key};

  if ($tt_entry && $tt_entry->{depth} >= $depth) {
    my $tt_score = $tt_entry->{score};
    if ($tt_entry->{flag} == TT_FLAG_EXACT) {
      return ($tt_score, _find_move_by_key($state, $tt_entry->{best_move_key}));
    }
    if ($tt_entry->{flag} == TT_FLAG_LOWER) {
      $alpha = max($alpha, $tt_score);
    } elsif ($tt_entry->{flag} == TT_FLAG_UPPER) {
      $beta = min($beta, $tt_score);
    }
    if ($alpha >= $beta) {
      return ($tt_score, _find_move_by_key($state, $tt_entry->{best_move_key}));
    }
  }

  my $alpha_orig = $alpha;
  my $beta_orig = $beta;
  my $tt_move_key = $tt_entry ? $tt_entry->{best_move_key} : undef;
  my $board = $state->[Chess::State::BOARD];
  my $best_value = -INF_SCORE;
  my $best_move;
  my $legal_moves = 0;
  my $move_index = 0;

  foreach my $move (_ordered_moves($state, $ply, $tt_move_key)) {
    my $is_capture = _is_capture($board, $move);
    my $new_state = $state->make_move($move);
    next unless defined $new_state;

    $legal_moves++;

    my $value;
    if ($move_index == 0) {
      ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1);
      $value = -$value;
    } else {
      ($value) = _search($new_state, $depth - 1, -$alpha - 1, -$alpha, $ply + 1);
      $value = -$value;
      if ($value > $alpha && $value < $beta) {
        ($value) = _search($new_state, $depth - 1, -$beta, -$alpha, $ply + 1);
        $value = -$value;
      }
    }
    $move_index++;

    if ($value > $best_value) {
      $best_value = $value;
      $best_move = $move;
    }

    if ($value > $alpha) {
      $alpha = $value;
      if ($alpha >= $beta) {
        unless ($is_capture) {
          _store_killer($ply, $move);
          _update_history($move, $depth);
        }
        last;
      }
    }
  }

  if (! $legal_moves) {
    my $mate_or_draw = $state->is_checked ? (-MATE_SCORE + $ply) : 0;
    return ($mate_or_draw, undef);
  }

  my $flag = TT_FLAG_EXACT;
  if ($best_value <= $alpha_orig) {
    $flag = TT_FLAG_UPPER;
  } elsif ($best_value >= $beta_orig) {
    $flag = TT_FLAG_LOWER;
  }

  $transposition_table{$key} = {
    depth => $depth,
    score => $best_value,
    flag => $flag,
    best_move_key => (defined $best_move ? _move_key($best_move) : undef),
  };

  return ($best_value, $best_move);
}

#  mainly a converience wrapper around rec_think.
sub think {
  my $self = shift;
  my $state = ${$self->{state}};

  if (my $book_move = Chess::Book::choose_move($state)) {
    return $book_move;
  }

  if (my $table_move = Chess::EndgameTable::choose_move($state)) {
    return $table_move;
  }

  _decay_history();
  @killer_moves = ();
  %transposition_table = ();

  my $target_depth = max(1, $self->{depth} - 1);
  my $best_move;
  my $prev_score = 0;

  for my $depth (1 .. $target_depth) {
    my $alpha = -INF_SCORE;
    my $beta = INF_SCORE;
    my $window = ASPIRATION_WINDOW;

    if ($depth >= 3) {
      $alpha = max(-INF_SCORE, $prev_score - $window);
      $beta = min(INF_SCORE, $prev_score + $window);
    }

    while (1) {
      my ($score, $move) = _search($state, $depth, $alpha, $beta, 0);
      $best_move = $move if defined $move;

      if ($score <= $alpha) {
        $alpha = max(-INF_SCORE, $alpha - $window);
        $window *= 2;
        next;
      }
      if ($score >= $beta) {
        $beta = min(INF_SCORE, $beta + $window);
        $window *= 2;
        next;
      }

      $prev_score = $score;
      last;
    }
  }

  return $best_move;
}

1;
