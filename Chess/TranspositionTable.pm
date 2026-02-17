package Chess::TranspositionTable;
use strict;
use warnings;

use constant DEFAULT_MAX_ENTRIES => 200_000;
use constant DEFAULT_CLUSTER_SIZE => 4;
use constant DEFAULT_AGE_WEIGHT => 2;

sub new {
  my ($class, %opts) = @_;

  my $max_entries = $opts{max_entries};
  $max_entries = DEFAULT_MAX_ENTRIES unless defined $max_entries && $max_entries =~ /^\d+$/ && $max_entries > 0;

  my $cluster_size = $opts{cluster_size};
  $cluster_size = DEFAULT_CLUSTER_SIZE unless defined $cluster_size && $cluster_size =~ /^\d+$/ && $cluster_size > 0;

  my $age_weight = $opts{age_weight};
  $age_weight = DEFAULT_AGE_WEIGHT unless defined $age_weight && $age_weight =~ /^\d+$/ && $age_weight > 0;

  my $cluster_count = int(($max_entries + $cluster_size - 1) / $cluster_size);
  $cluster_count = 1 if $cluster_count < 1;

  my @clusters;
  for (1 .. $cluster_count) {
    push @clusters, [ (undef) x $cluster_size ];
  }

  my %self = (
    clusters => \@clusters,
    cluster_count => $cluster_count,
    cluster_size => $cluster_size,
    age_weight => $age_weight,
    generation => 0,
    entry_count => 0,
  );

  return bless \%self, $class;
}

sub probe {
  my ($self, $key) = @_;
  return undef unless defined $key && length $key;

  my $cluster = _cluster_for_key($self, $key);
  for my $entry (@{$cluster}) {
    next unless defined $entry;
    return $entry if $entry->{key} eq $key;
  }

  return undef;
}

sub store {
  my ($self, %args) = @_;

  my $key = $args{key};
  return 0 unless defined $key && length $key;

  my $entry = {
    key => $key,
    depth => int($args{depth} // 0),
    score => int($args{score} // 0),
    flag => $args{flag},
    best_move_key => $args{best_move_key},
    gen => defined $args{gen} ? int($args{gen}) : $self->{generation},
  };

  my $cluster = _cluster_for_key($self, $key);

  for my $slot (0 .. $#{$cluster}) {
    my $existing = $cluster->[$slot];
    next unless defined $existing && $existing->{key} eq $key;
    if (_should_replace_for_same_key($existing, $entry)) {
      $cluster->[$slot] = $entry;
      return 1;
    }
    return 0;
  }

  for my $slot (0 .. $#{$cluster}) {
    next if defined $cluster->[$slot];
    $cluster->[$slot] = $entry;
    $self->{entry_count}++;
    return 1;
  }

  my $victim_slot = _select_victim_slot($self, $cluster);
  $cluster->[$victim_slot] = $entry;
  return 1;
}

sub next_generation {
  my ($self) = @_;
  $self->{generation}++;
  return $self->{generation};
}

sub generation {
  my ($self) = @_;
  return $self->{generation};
}

sub entry_count {
  my ($self) = @_;
  return $self->{entry_count};
}

sub _should_replace_for_same_key {
  my ($existing, $new_entry) = @_;

  my $existing_depth = $existing->{depth} // 0;
  my $new_depth = $new_entry->{depth} // 0;
  return 1 if $new_depth > $existing_depth;

  my $existing_gen = $existing->{gen} // 0;
  my $new_gen = $new_entry->{gen} // 0;
  return 1 if $new_gen > $existing_gen;

  return $new_depth >= $existing_depth;
}

sub _select_victim_slot {
  my ($self, $cluster) = @_;

  my $worst_slot = 0;
  my $worst_score;
  my $generation = $self->{generation} // 0;
  my $age_weight = $self->{age_weight} // DEFAULT_AGE_WEIGHT;

  for my $slot (0 .. $#{$cluster}) {
    my $entry = $cluster->[$slot];
    next unless defined $entry;

    my $depth = $entry->{depth} // 0;
    my $entry_gen = $entry->{gen} // 0;
    my $age = $generation - $entry_gen;
    $age = 0 if $age < 0;

    my $score = $depth - ($age * $age_weight);
    if (!defined $worst_score || $score < $worst_score) {
      $worst_score = $score;
      $worst_slot = $slot;
    }
  }

  return $worst_slot;
}

sub _cluster_for_key {
  my ($self, $key) = @_;

  my $hash = _hash_key($key);
  my $index = $hash % $self->{cluster_count};
  return $self->{clusters}[$index];
}

sub _hash_key {
  my ($key) = @_;
  my $hash = 5381;
  for my $byte (unpack('C*', $key)) {
    $hash = (($hash << 5) + $hash + $byte) & 0x7fffffff;
  }
  return $hash;
}

1;
