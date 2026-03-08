package Chess::MoveOrder;
use strict;
use warnings;

use Chess::Constant;
use Chess::State;
use Chess::Heuristics qw(:engine);

use constant MOVE_KEY_SIZE => 1 << 18; # 7 bits from, 7 bits to, 4 bits promo.

sub new {
  my ($class, %opts) = @_;
  my @history_scores = (undef) x MOVE_KEY_SIZE;
  my @counter_moves = (undef) x MOVE_KEY_SIZE;
  my $self = {
    history_scores => \@history_scores,
    history_scale => 1.0,
    killer_moves => [],
    counter_moves => \@counter_moves,
    piece_values => $opts{piece_values} || {},
    location_modifier_percent_cb => $opts{location_modifier_percent_cb},
    square_of_idx_cb => $opts{square_of_idx_cb},
    unsafe_capture_penalty_cb => $opts{unsafe_capture_penalty_cb},
    capture_plan_order_bonus_cb => $opts{capture_plan_order_bonus_cb},
    promotion_check_order_bonus_cb => $opts{promotion_check_order_bonus_cb},
    is_sac_candidate_move_cb => $opts{is_sac_candidate_move_cb},
    piece_count_cb => $opts{piece_count_cb},
  };
  return bless $self, $class;
}

sub reset_killers {
  my ($self) = @_;
  $self->{killer_moves} = [];
}

sub move_key {
  my ($self, $move) = @_;
  my $from = $move->[0] // 0;
  my $to = $move->[1] // 0;
  my $promo = defined $move->[2] ? (($move->[2] + 8) & 0x0f) : 0;
  return (($from & 0x7f) << 11) | (($to & 0x7f) << 4) | $promo;
}

sub _valid_move_key {
  my ($self, $move_key) = @_;
  return defined $move_key && $move_key >= 0 && $move_key < MOVE_KEY_SIZE;
}

sub history_bonus {
  my ($self, $move_key) = @_;
  return 0 unless $self->_valid_move_key($move_key);
  my $raw = $self->{history_scores}[$move_key];
  return 0 unless defined $raw;
  my $scaled = int($raw * $self->{history_scale});
  if ($scaled <= 0) {
    $self->{history_scores}[$move_key] = undef;
    return 0;
  }
  return $scaled;
}

sub killer_bonus {
  my ($self, $move_key, $ply) = @_;
  my $slot = $self->{killer_moves}[$ply] || [];
  return 200 if defined $slot->[0] && $slot->[0] == $move_key;
  return 150 if defined $slot->[1] && $slot->[1] == $move_key;
  return 0;
}

sub countermove_bonus {
  my ($self, $move_key, $prev_move_key) = @_;
  return 0 unless $self->_valid_move_key($move_key) && $self->_valid_move_key($prev_move_key);
  my $counter = $self->{counter_moves}[$prev_move_key];
  return 0 unless defined $counter;
  return $move_key == $counter ? COUNTERMOVE_BONUS : 0;
}

sub store_killer {
  my ($self, $ply, $move_key) = @_;
  $self->{killer_moves}[$ply] ||= [];
  return if defined $self->{killer_moves}[$ply][0] && $self->{killer_moves}[$ply][0] == $move_key;
  $self->{killer_moves}[$ply][1] = $self->{killer_moves}[$ply][0] if defined $self->{killer_moves}[$ply][0];
  $self->{killer_moves}[$ply][0] = $move_key;
}

sub store_countermove {
  my ($self, $prev_move_key, $move_key) = @_;
  return unless $self->_valid_move_key($prev_move_key) && $self->_valid_move_key($move_key);
  $self->{counter_moves}[$prev_move_key] = $move_key;
}

sub update_history {
  my ($self, $move_key, $depth) = @_;
  return unless $self->_valid_move_key($move_key);
  my $bonus = $depth * $depth;
  my $scale = $self->{history_scale} > 0 ? $self->{history_scale} : 1;
  my $unscaled_bonus = int($bonus / $scale);
  $unscaled_bonus = 1 if $unscaled_bonus < 1;
  $self->{history_scores}[$move_key] = ($self->{history_scores}[$move_key] // 0) + $unscaled_bonus;
}

sub decay_history {
  my ($self) = @_;
  $self->{history_scale} *= HISTORY_DECAY_FACTOR;
  return if $self->{history_scale} >= HISTORY_RENORM_MIN_SCALE;

  for my $key (0 .. MOVE_KEY_SIZE - 1) {
    next unless defined $self->{history_scores}[$key];
    my $scaled = int(($self->{history_scores}[$key] // 0) * $self->{history_scale});
    if ($scaled > 0) {
      $self->{history_scores}[$key] = $scaled;
    } else {
      $self->{history_scores}[$key] = undef;
    }
  }
  $self->{history_scale} = 1.0;
}

sub score_move {
  my ($self, $state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $from_piece = $board->[$move->[0]] || 0;
  my $to_piece = $board->[$move->[1]] || 0;
  my $score = 0;

  if (defined $tt_move_key && $move_key == $tt_move_key) {
    $score += 5000;
  }

  if ($to_piece < 0) {
    my $victim_value = abs($self->{piece_values}{$to_piece} || 0);
    my $attacker_value = abs($self->{piece_values}{$from_piece} || 0);
    $score += 1000 + 10 * $victim_value - $attacker_value;
    if (ref($self->{unsafe_capture_penalty_cb}) eq 'CODE') {
      $score -= $self->{unsafe_capture_penalty_cb}->($state, $move, $from_piece, $to_piece);
    }
    if (ref($self->{capture_plan_order_bonus_cb}) eq 'CODE') {
      $score += $self->{capture_plan_order_bonus_cb}->($board, $move, $from_piece, $to_piece);
    }
  }

  if (defined $move->[2]) {
    my $promo = abs($self->{piece_values}{$move->[2]} || 0);
    my $pawn = abs($self->{piece_values}{PAWN} || 1);
    $score += 500 + ($promo - $pawn);
    if (ref($self->{promotion_check_order_bonus_cb}) eq 'CODE') {
      $score += $self->{promotion_check_order_bonus_cb}->($state, $move);
    }
  }

  if (defined $move->[3]) {
    $score += 50;
  }

  if (ref($self->{square_of_idx_cb}) eq 'CODE' && ref($self->{location_modifier_percent_cb}) eq 'CODE') {
    my $from_square = $self->{square_of_idx_cb}->($move->[0]);
    my $to_square = $self->{square_of_idx_cb}->($move->[1]);
    if (defined $to_square) {
      my $from_bonus = defined $from_square ? $self->{location_modifier_percent_cb}->($from_piece, $from_square) : 0;
      my $to_bonus = $self->{location_modifier_percent_cb}->($from_piece, $to_square);
      $score += 30 * ($to_bonus - $from_bonus);
    }
  }

  if (!$is_capture) {
    $score += $self->history_bonus($move_key);
    $score += $self->killer_bonus($move_key, $ply);
    $score += $self->countermove_bonus($move_key, $prev_move_key);
  } elsif (ref($self->{is_sac_candidate_move_cb}) eq 'CODE' && $self->{is_sac_candidate_move_cb}->($state, $move)) {
    $score -= SAC_MOVE_ORDER_PENALTY;
  }

  if (abs($from_piece) == KING
      && !$is_capture
      && !defined $move->[3]
      && !$state->is_checked
      && ref($self->{piece_count_cb}) eq 'CODE'
      && $self->{piece_count_cb}->($state) >= KING_SHUFFLE_MIDGAME_MIN_PIECES) {
    $score -= KING_SHUFFLE_ORDER_PENALTY;
  }

  return $score;
}

1;
