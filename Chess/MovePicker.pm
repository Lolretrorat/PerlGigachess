package Chess::MovePicker;
use strict;
use warnings;

use Chess::See ();

sub new {
  my ($class, %args) = @_;

  my $moves = $args{moves};
  if (!defined $moves && defined $args{state} && ref($args{state})) {
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
    score_cb => $args{score_cb},
    move_key_cb => $args{move_key_cb},
    is_capture_cb => $args{is_capture_cb},
    see_cb => $args{see_cb},
    state => $args{state},
    see_order_weight => defined $args{see_order_weight} ? $args{see_order_weight} : 1,
    see_bad_capture_threshold => defined $args{see_bad_capture_threshold} ? $args{see_bad_capture_threshold} : 0,
    see_prune_threshold => $args{see_prune_threshold},
    tt_move_key => $args{tt_move_key},
    countermove_key => $args{countermove_key},
    killer_keys => \%killer_keys,
    pruned_capture_count => 0,
    buckets => {
      tt => [],
      tactical => [],
      killer => [],
      counter => [],
      quiet => [],
      bad_capture => [],
    },
    stage_order => [qw(tt tactical killer counter quiet bad_capture)],
    stage_index => 0,
  }, $class;

  $self->_seed_moves($moves);
  return $self;
}

sub next_move {
  my ($self) = @_;

  while ($self->{stage_index} < @{$self->{stage_order}}) {
    my $stage = $self->{stage_order}[$self->{stage_index}];
    my $entry = $self->_pop_best_from_bucket($self->{buckets}{$stage});
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
    push @{$self->{buckets}{$bucket}}, $entry if defined $bucket;
  }
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
  my ($self, $bucket) = @_;
  return unless ref($bucket) eq 'ARRAY' && @{$bucket};

  my $best_idx = 0;
  my $best_score = $self->_score_entry($bucket->[0]);
  for my $idx (1 .. $#{$bucket}) {
    my $score = $self->_score_entry($bucket->[$idx]);
    if ($score > $best_score) {
      $best_score = $score;
      $best_idx = $idx;
    }
  }

  return splice(@{$bucket}, $best_idx, 1);
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
    move => $move,
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

1;
