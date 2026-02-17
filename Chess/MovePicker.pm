package Chess::MovePicker;
use strict;
use warnings;

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
    tt_move_key => $args{tt_move_key},
    countermove_key => $args{countermove_key},
    killer_keys => \%killer_keys,
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
    my $entry = [undef, $move, $move_key, $is_capture];
    my $bucket = $self->_bucket_for_entry($entry);
    push @{$self->{buckets}{$bucket}}, $entry if defined $bucket;
  }
}

sub _bucket_for_entry {
  my ($self, $entry) = @_;
  my ($move, $move_key, $is_capture) = @{$entry}[1, 2, 3];

  if (defined $self->{tt_move_key} && defined $move_key && $move_key == $self->{tt_move_key}) {
    return 'tt';
  }

  if ($is_capture) {
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

1;
