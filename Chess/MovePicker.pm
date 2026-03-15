package Chess::MovePicker;
use strict;
use warnings;

use Chess::Constant;
use Chess::See ();
use Chess::Heuristics qw(:engine);

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(generate_moves collect_legal_moves);


sub generate_moves {
  my ($state, $type, $opts) = @_;
  $type = lc($type // 'non_evasions');
  $opts = {} unless ref($opts) eq 'HASH';

  my $is_checked = $state->is_checked ? 1 : 0;
  my $groups;

  if ($type eq 'legal' || $type eq 'all') {
    $groups = collect_legal_moves($state, $opts);
    return $groups->{legal};
  }

  if ($type eq 'evasions') {
    return [] unless $is_checked;
    $groups = collect_legal_moves($state, $opts);
    return $groups->{legal};
  }

  if ($type eq 'captures') {
    $groups = collect_legal_moves($state, $opts);
    return $groups->{captures};
  }

  if ($type eq 'quiets') {
    $groups = collect_legal_moves($state, $opts);
    return $groups->{quiets};
  }

  # NON_EVASIONS in this mailbox implementation is simply legal moves
  # when not in check; otherwise legal evasions.
  if ($type eq 'non_evasions') {
    return [] if $is_checked;
    $groups = collect_legal_moves($state, $opts);
    return $groups->{legal};
  }

  $groups = collect_legal_moves($state, $opts);
  return $groups->{legal};
}

sub collect_legal_moves {
  my ($state, $opts) = @_;
  $opts = {} unless ref($opts) eq 'HASH';

  my $pseudo = $opts->{pseudo_moves};
  $pseudo = $state->generate_pseudo_moves unless ref($pseudo) eq 'ARRAY';
  my $move_filter_cb = $opts->{move_filter_cb};

  my $move_key_cb = $opts->{move_key_cb};
  my $exclude = $opts->{exclude_move_keys};
  my $has_exclude = ref($exclude) eq 'HASH' && keys %{$exclude};

  my @legal;
  my @captures;
  my @quiets;
  my @undo_stack;
  for my $move (@{$pseudo}) {
    next unless ref($move) eq 'ARRAY';
    next if defined $move_filter_cb && !$move_filter_cb->($move);
    if ($has_exclude && defined $move_key_cb) {
      my $move_key = $move_key_cb->($move);
      next if defined $move_key && exists $exclude->{$move_key};
    }
    my $is_capture = _is_capture_like($state, $move) ? 1 : 0;
    next unless defined $state->do_move($move, \@undo_stack);
    push @legal, $move;
    if ($is_capture) {
      push @captures, $move;
    } else {
      push @quiets, $move;
    }
    $state->undo_move(\@undo_stack);
  }
  return {
    legal    => \@legal,
    captures => \@captures,
    quiets   => \@quiets,
  };
}

sub _is_capture_like {
  my ($state, $move) = @_;
  my $board = $state->[0];
  my $to_piece = $board->[$move->[1]] // 0;
  return 1 if $to_piece < 0;

  # En-passant capture: pawn moves diagonally into EP square.
  my $from_piece = $board->[$move->[0]] // 0;
  return 0 unless abs($from_piece) == 1;
  return 0 unless defined $state->[3];
  return 0 unless $move->[1] == $state->[3];
  my $delta = $move->[1] - $move->[0];
  return ($delta == 9 || $delta == 11) ? 1 : 0;
}

sub new {
  my ($class, %args) = @_;

  my $stage_generators = ref($args{stage_generators}) eq 'HASH' ? $args{stage_generators} : {};

  my $moves = $args{moves};
  if (!defined $moves
      && !keys(%{$stage_generators})
      && defined $args{state}
      && ref($args{state})) {
    $moves = $args{state}->generate_pseudo_moves;
  }
  $moves = [] unless ref($moves) eq 'ARRAY';

  my %killer_keys;
  if (ref($args{killer_move_keys}) eq 'ARRAY') {
    for my $move_key (@{$args{killer_move_keys}}) {
      next unless defined $move_key;
      $killer_keys{$move_key} = 1;
    }
  }

  my $self = bless {
    score_cb                 => $args{score_cb},
    move_key_cb              => $args{move_key_cb},
    is_capture_cb            => $args{is_capture_cb},
    see_cb                   => $args{see_cb},
    state                    => $args{state},
    see_order_weight         => defined $args{see_order_weight} ? $args{see_order_weight} : 1,
    see_bad_capture_threshold => defined $args{see_bad_capture_threshold} ? $args{see_bad_capture_threshold} : 0,
    see_prune_threshold      => $args{see_prune_threshold},
    tt_move_key              => $args{tt_move_key},
    countermove_key          => $args{countermove_key},
    killer_keys              => \%killer_keys,
    pruned_capture_count     => 0,
    buckets => {
      tt          => [],
      tactical    => [],
      killer      => [],
      counter     => [],
      quiet       => [],
      bad_capture => [],
    },
    bucket_sorted => {
      tt          => 0,
      tactical    => 0,
      killer      => 0,
      counter     => 0,
      quiet       => 0,
      bad_capture => 0,
    },
    stage_generators => $stage_generators,
    stage_loaded     => {},
    stage_order      => [qw(tt tactical killer counter quiet bad_capture)],
    stage_index      => 0,
  }, $class;

  $self->_seed_moves($moves);
  return $self;
}

sub next_move {
  my ($self) = @_;

  while ($self->{stage_index} < @{$self->{stage_order}}) {
    my $stage = $self->{stage_order}[$self->{stage_index}];
    $self->_load_stage($stage);
    my $entry = $self->_pop_best_from_bucket($stage);
    return $entry if defined $entry;
    $self->{stage_index}++;
  }

  return;
}

sub all_moves {
  my ($self) = @_;
  my @ordered;
  while (my $entry = $self->next_move) {
    push @ordered, $entry;
  }
  return @ordered;
}

sub _seed_moves {
  my ($self, $moves) = @_;

  for my $move (@{$moves}) {
    next unless ref($move) eq 'ARRAY';
    my $move_key = $self->_move_key($move);
    my $is_capture = $self->_is_capture($move) ? 1 : 0;
    my $see_score = $is_capture ? $self->_see_score($move, $move_key, $is_capture) : undef;
    my $entry = [undef, $move, $move_key, $is_capture, $see_score];
    if ($self->_should_prune_entry($entry)) {
      $self->{pruned_capture_count}++;
      next;
    }
    my $bucket = $self->_bucket_for_entry($entry);
    $self->_push_entry_to_bucket($bucket, $entry) if defined $bucket;
  }
}

sub _load_stage {
  my ($self, $stage) = @_;
  return if $self->{stage_loaded}{$stage};
  $self->{stage_loaded}{$stage} = 1;

  my $generator = $self->{stage_generators}{$stage};
  return unless defined $generator && ref($generator) eq 'CODE';

  my $moves = $generator->($self, $stage);
  return unless ref($moves) eq 'ARRAY' && @{$moves};
  $self->_seed_moves($moves);
}

sub _bucket_for_entry {
  my ($self, $entry) = @_;
  my ($move, $move_key, $is_capture, $see_score) = @{$entry}[1, 2, 3, 4];

  if (defined $self->{tt_move_key} && defined $move_key && $move_key == $self->{tt_move_key}) {
    return 'tt';
  }

  if ($is_capture) {
    if (defined $see_score) {
      return $see_score >= $self->{see_bad_capture_threshold} ? 'tactical' : 'bad_capture';
    }
    my $score = $self->_score_entry($entry);
    return $score >= 0 ? 'tactical' : 'bad_capture';
  }

  if (defined $move->[2]) {
    return 'tactical';
  }

  if (defined $move_key && $self->{killer_keys}{$move_key}) {
    return 'killer';
  }

  if (defined $self->{countermove_key} && defined $move_key && $move_key == $self->{countermove_key}) {
    return 'counter';
  }

  return 'quiet';
}

sub _score_entry {
  my ($self, $entry) = @_;
  return $entry->[0] if defined $entry->[0];

  my $score = 0;
  if (defined $self->{score_cb}) {
    $score = $self->{score_cb}->(@{$entry}[1, 2, 3]);
  }
  if ($entry->[3] && defined $entry->[4] && $self->{see_order_weight}) {
    $score += $entry->[4] * $self->{see_order_weight};
  }
  $entry->[0] = $score;
  return $score;
}

sub _pop_best_from_bucket {
  my ($self, $stage) = @_;
  my $bucket = $self->{buckets}{$stage};
  return unless ref($bucket) eq 'ARRAY' && @{$bucket};

  if (! $self->{bucket_sorted}{$stage}) {
    @{$bucket} = sort {
      $self->_score_entry($a) <=> $self->_score_entry($b)
    } @{$bucket};
    $self->{bucket_sorted}{$stage} = 1;
  }

  return pop @{$bucket};
}

sub _push_entry_to_bucket {
  my ($self, $bucket, $entry) = @_;
  return unless defined $bucket;
  return unless exists $self->{buckets}{$bucket};
  push @{$self->{buckets}{$bucket}}, $entry;
  $self->{bucket_sorted}{$bucket} = 0;
}

sub _move_key {
  my ($self, $move) = @_;
  return 0 unless defined $self->{move_key_cb};
  return $self->{move_key_cb}->($move);
}

sub _is_capture {
  my ($self, $move) = @_;
  return 0 unless defined $self->{is_capture_cb};
  return $self->{is_capture_cb}->($move) ? 1 : 0;
}

sub _see_score {
  my ($self, $move, $move_key, $is_capture) = @_;
  return undef unless $is_capture;

  if (defined $self->{see_cb}) {
    return $self->{see_cb}->($move, $move_key, $is_capture);
  }

  return undef unless defined $self->{state};
  return Chess::See::evaluate_capture(
    state => $self->{state},
    move  => $move,
  );
}

sub _should_prune_entry {
  my ($self, $entry) = @_;
  return 0 unless $entry->[3];
  return 0 unless defined $self->{see_prune_threshold};
  return 0 unless defined $entry->[4];
  return $entry->[4] < $self->{see_prune_threshold} ? 1 : 0;
}

sub pruned_capture_count {
  my ($self) = @_;
  return $self->{pruned_capture_count} || 0;
}

#-----------------------------------------------------------------------------
# MoveOrder - move scoring and history heuristics
#-----------------------------------------------------------------------------

package Chess::MovePicker::MoveOrder;
use strict;
use warnings;

use Chess::Constant;
use Chess::Heuristics qw(:engine);

use constant MOVE_KEY_SIZE => 1 << 18;    # 7 bits from, 7 bits to, 4 bits promo.

sub new {
  my ($class, %opts) = @_;
  my @history_scores = (undef) x MOVE_KEY_SIZE;
  my @counter_moves = (undef) x MOVE_KEY_SIZE;
  my $self = {
    history_scores               => \@history_scores,
    history_scale                => 1.0,
    killer_moves                 => [],
    counter_moves                => \@counter_moves,
    continuation_history         => {},
    piece_values                 => $opts{piece_values} || {},
    location_modifier_percent_cb => $opts{location_modifier_percent_cb},
    square_of_idx_cb             => $opts{square_of_idx_cb},
    unsafe_capture_penalty_cb    => $opts{unsafe_capture_penalty_cb},
    capture_plan_order_bonus_cb  => $opts{capture_plan_order_bonus_cb},
    quiet_plan_order_bonus_cb    => $opts{quiet_plan_order_bonus_cb},
    promotion_check_order_bonus_cb => $opts{promotion_check_order_bonus_cb},
    is_sac_candidate_move_cb     => $opts{is_sac_candidate_move_cb},
    piece_count_cb               => $opts{piece_count_cb},
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

sub get_continuation_bonus {
  my ($self, $prev_piece, $prev_to, $piece, $to) = @_;
  return 0 unless defined $prev_piece && defined $prev_to;
  my $key = "$prev_piece:$prev_to:$piece:$to";
  return $self->{continuation_history}{$key} // 0;
}

sub update_continuation_history {
  my ($self, $prev_piece, $prev_to, $piece, $to, $bonus) = @_;
  return unless defined $prev_piece && defined $prev_to;
  my $key = "$prev_piece:$prev_to:$piece:$to";
  my $current = $self->{continuation_history}{$key} // 0;
  # Gravity update: new = old + bonus - old * |bonus| / D
  my $D = CONTINUATION_HISTORY_LIMIT;
  my $clamped = $bonus > $D ? $D : ($bonus < -$D ? -$D : $bonus);
  $self->{continuation_history}{$key} = $current + $clamped - int($current * abs($clamped) / $D);
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
  my ($self, $state, $move, $move_key, $is_capture, $ply, $tt_move_key, $prev_move_key, $opts) = @_;
  $opts = {} unless ref($opts) eq 'HASH';
  my $board = $state->[0];  # BOARD index
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
    if (ref($self->{quiet_plan_order_bonus_cb}) eq 'CODE') {
      $score += $self->{quiet_plan_order_bonus_cb}->($state, $move, $from_piece, $ply, $opts);
    }
    $score += $self->history_bonus($move_key);
    $score += $self->killer_bonus($move_key, $ply);
    $score += $self->countermove_bonus($move_key, $prev_move_key);
    # Continuation history bonus
    if (defined $opts->{prev_piece} && defined $opts->{prev_to}) {
      my $cont_bonus = $self->get_continuation_bonus(
        $opts->{prev_piece}, $opts->{prev_to}, $from_piece, $move->[1]
      );
      $score += int($cont_bonus / CONTINUATION_HISTORY_WEIGHT);
    }
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
