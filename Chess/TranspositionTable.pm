package Chess::TranspositionTable;
use strict;
use warnings;

use constant DEFAULT_MAX_ENTRIES => 200_000;
use constant DEFAULT_CLUSTER_SIZE => 4;
use constant DEFAULT_AGE_WEIGHT => 2;
use constant MATE_NORMALIZE_MARGIN => 10_000;

sub new {
  my ($class, %opts) = @_;

  my $max_entries = $opts{max_entries};
  $max_entries = DEFAULT_MAX_ENTRIES unless defined $max_entries && $max_entries =~ /^\d+$/ && $max_entries > 0;

  my $cluster_size = $opts{cluster_size};
  $cluster_size = DEFAULT_CLUSTER_SIZE unless defined $cluster_size && $cluster_size =~ /^\d+$/ && $cluster_size > 0;

  my $age_weight = $opts{age_weight};
  $age_weight = DEFAULT_AGE_WEIGHT unless defined $age_weight && $age_weight =~ /^\d+$/ && $age_weight > 0;

  my $shared = $opts{shared} ? 1 : 0;
  my $has_threads_shared = 0;
  if ($shared && $INC{'threads.pm'}) {
    $has_threads_shared = eval {
      require threads::shared;
      threads::shared->import(qw(lock));
      1;
    } ? 1 : 0;
  }
  $shared = 0 unless $has_threads_shared;

  if ($shared) {
    my $generation = 0;
    my $entry_count = 0;
    my %entries;
    my $entries_ref = threads::shared::share(\%entries);
    threads::shared::share(\$generation);
    threads::shared::share(\$entry_count);

    my %self = (
      shared => 1,
      entries => $entries_ref,
      generation_ref => \$generation,
      entry_count_ref => \$entry_count,
      max_entries => $max_entries,
      age_weight => $age_weight,
    );

    return bless \%self, $class;
  }

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
  my ($self, $key, %opts) = @_;
  return undef unless defined $key && length $key;

  my $entry;
  if ($self->{shared}) {
    lock(%{$self->{entries}});
    my $packed = $self->{entries}{$key};
    return undef unless defined $packed;
    $entry = _decode_entry($key, $packed);
  } else {
    my $cluster = _cluster_for_key($self, $key);
    for my $candidate (@{$cluster}) {
      next unless defined $candidate;
      if ($candidate->{key} eq $key) {
        $entry = { %{$candidate} };
        last;
      }
    }
    return undef unless defined $entry;
  }

  my $ply = int($opts{ply} // 0);
  my $mate_score = int($opts{mate_score} // 0);
  $entry->{score} = _score_from_tt($entry->{score}, $ply, $mate_score);
  return $entry;
}

sub store {
  my ($self, %args) = @_;

  my $key = $args{key};
  return 0 unless defined $key && length $key;

  my $ply = int($args{ply} // 0);
  my $mate_score = int($args{mate_score} // 0);
  my $score = _score_to_tt(int($args{score} // 0), $ply, $mate_score);

  my $entry = {
    key => $key,
    depth => int($args{depth} // 0),
    score => $score,
    flag => $args{flag},
    best_move_key => $args{best_move_key},
    gen => defined $args{gen} ? int($args{gen}) : $self->generation(),
  };

  if ($self->{shared}) {
    lock(%{$self->{entries}});
    my $entries = $self->{entries};
    if (exists $entries->{$key}) {
      my $existing = _decode_entry($key, $entries->{$key});
      if (_should_replace_for_same_key($existing, $entry)) {
        $entries->{$key} = _encode_entry($entry);
        return 1;
      }
      return 0;
    }

    if ((${$self->{entry_count_ref}} // 0) >= $self->{max_entries}) {
      my $victim_key = _select_shared_victim_key($self);
      if (defined $victim_key && exists $entries->{$victim_key}) {
        delete $entries->{$victim_key};
        ${$self->{entry_count_ref}}-- if ${$self->{entry_count_ref}} > 0;
      }
    }

    if ((${$self->{entry_count_ref}} // 0) < $self->{max_entries}) {
      $entries->{$key} = _encode_entry($entry);
      ${$self->{entry_count_ref}}++;
      return 1;
    }

    my $victim_key = _select_shared_victim_key($self);
    if (defined $victim_key && exists $entries->{$victim_key}) {
      delete $entries->{$victim_key};
    }
    $entries->{$key} = _encode_entry($entry);
    return 1;
  }

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
  if ($self->{shared}) {
    lock(${$self->{generation_ref}});
    ${$self->{generation_ref}}++;
    return ${$self->{generation_ref}};
  }
  $self->{generation}++;
  return $self->{generation};
}

sub generation {
  my ($self) = @_;
  if ($self->{shared}) {
    lock(${$self->{generation_ref}});
    return ${$self->{generation_ref}};
  }
  return $self->{generation};
}

sub entry_count {
  my ($self) = @_;
  if ($self->{shared}) {
    lock(${$self->{entry_count_ref}});
    return ${$self->{entry_count_ref}};
  }
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

sub _select_shared_victim_key {
  my ($self) = @_;
  my $entries = $self->{entries};
  my $generation = $self->generation();
  my $age_weight = $self->{age_weight} // DEFAULT_AGE_WEIGHT;

  my $worst_key;
  my $worst_score;
  my $checked = 0;
  for my $key (keys %{$entries}) {
    my $entry = _decode_entry($key, $entries->{$key});
    my $depth = $entry->{depth} // 0;
    my $entry_gen = $entry->{gen} // 0;
    my $age = $generation - $entry_gen;
    $age = 0 if $age < 0;
    my $score = $depth - ($age * $age_weight);
    if (!defined $worst_score || $score < $worst_score) {
      $worst_score = $score;
      $worst_key = $key;
    }
    last if ++$checked >= 64;
  }
  return $worst_key;
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

sub _encode_entry {
  my ($entry) = @_;
  return join("\t",
    int($entry->{depth} // 0),
    int($entry->{score} // 0),
    defined $entry->{flag} ? int($entry->{flag}) : '',
    defined $entry->{best_move_key} ? int($entry->{best_move_key}) : '',
    int($entry->{gen} // 0),
  );
}

sub _decode_entry {
  my ($key, $packed) = @_;
  my ($depth, $score, $flag, $best_move_key, $gen) = split(/\t/, ($packed // ''), 5);
  return {
    key => $key,
    depth => int($depth // 0),
    score => int($score // 0),
    flag => ($flag eq '' ? undef : int($flag)),
    best_move_key => ($best_move_key eq '' ? undef : int($best_move_key)),
    gen => int($gen // 0),
  };
}

sub _score_to_tt {
  my ($score, $ply, $mate_score) = @_;
  return $score unless $mate_score > 0;
  my $bound = $mate_score - MATE_NORMALIZE_MARGIN;
  return $score unless abs($score) >= $bound;
  return $score > 0 ? ($score + $ply) : ($score - $ply);
}

sub _score_from_tt {
  my ($score, $ply, $mate_score) = @_;
  return $score unless $mate_score > 0;
  my $bound = $mate_score - MATE_NORMALIZE_MARGIN;
  return $score unless abs($score) >= $bound;
  return $score > 0 ? ($score - $ply) : ($score + $ply);
}

1;
