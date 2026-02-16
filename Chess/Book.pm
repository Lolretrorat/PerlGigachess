package Chess::Book;
use strict;
use warnings;

use Chess::Constant;
use Chess::State ();
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;
use List::Util qw(sum);
use Chess::TableUtil qw(
  canonical_fen_key
  relaxed_fen_key
  normalize_uci_move
);

our %book = (
  # moves from opening
  'RNBQKBNRPPPPPPPP________________________________pppppppprnbqkbnr' => [
    [ 35, 55 ], # e4
    [ 34, 54 ], # d4
    [ 27, 46 ], # Nf3
    [ 33, 53 ], # c4
  ],
  # 1. e4
  'RNBQKBNRPPPPPPPP____________________p___________pppp_ppprnbqkbnr' => [
    [ 33, 53 ], # ... c5
    [ 35, 55 ], # ... e5
  ],
);

my %fen_book;
my %relaxed_fen_book;
my %legal_move_map_cache;
my %ranked_legal_entries_cache;
my $LEGAL_MOVE_MAP_CACHE_MAX = 20_000;
my $RANKED_LEGAL_CACHE_MAX = 20_000;
my $book_path_cache;
my $BOOK_MIN_PLAYED   = _env_int('CHESS_BOOK_MIN_PLAYED', 3, 1);
my $BOOK_MIN_RELATIVE = _env_num('CHESS_BOOK_MIN_RELATIVE', 0.12, 0.0, 1.0);
my $BOOK_VARIETY      = _env_num('CHESS_BOOK_VARIETY', 0.0, 0.0, 1.0);
my $BOOK_BAYES_GAMES  = _env_num('CHESS_BOOK_BAYES_GAMES', 8.0, 0.0, 1000.0);
my $BOOK_QUALITY_WEIGHT = _env_num('CHESS_BOOK_QUALITY_WEIGHT', 0.82, 0.0, 1.0);

sub _book_path {
  return $book_path_cache if defined $book_path_cache;
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  $book_path_cache = File::Spec->catfile($root, 'data', 'opening_book.json');
  return $book_path_cache;
}

sub _load_json_book {
  %fen_book = ();
  %relaxed_fen_book = ();
  %ranked_legal_entries_cache = ();

  my $path = _book_path();
  return unless defined $path && -e $path;

  my $json_text = do {
    open my $fh, '<', $path or return;
    local $/;
    my $raw = <$fh>;
    close $fh;
    $raw;
  };

  my $data = eval { JSON::PP->new->relaxed->decode($json_text) };
  return if $@ || ref $data ne 'ARRAY';

  my %pending_fen;
  my %pending_relaxed;
  foreach my $entry (@$data) {
    next unless ref $entry eq 'HASH';
    my $key = $entry->{key} || next;
    my $relaxed = relaxed_fen_key($key);
    my $moves = $entry->{moves} || [];
    my @parsed = _parse_book_moves($moves);
    next unless @parsed;

    push @{ $pending_fen{$key} }, @parsed;
    push @{ $pending_relaxed{$relaxed} }, @parsed if defined $relaxed;
  }

  foreach my $merge_key (keys %pending_fen) {
    _merge_book_entries(\%fen_book, $merge_key, $pending_fen{$merge_key});
  }
  foreach my $merge_key (keys %pending_relaxed) {
    _merge_book_entries(\%relaxed_fen_book, $merge_key, $pending_relaxed{$merge_key});
  }
}

sub choose_move {
  my ($state) = @_;
  return _lookup_fen_move($state) || _legacy_lookup($state);
}

sub _lookup_fen_move {
  my ($state) = @_;
  my $key = canonical_fen_key($state);
  my $entries = $fen_book{$key};
  my $source = 'fen';
  my $source_key = $key;
  if (! $entries) {
    my $relaxed = relaxed_fen_key($key);
    if (defined $relaxed) {
      $entries = $relaxed_fen_book{$relaxed};
      $source = 'relaxed';
      $source_key = $relaxed;
    }
  }
  return unless $entries && @$entries;

  my $legal = _legal_move_map($state, $key);
  return unless keys %$legal;

  my $side = _side_to_move($key);
  my $ranked = _ranked_legal_entries_for_state(
    $key,
    $source_key,
    $source,
    $entries,
    $legal,
    $side,
  );
  return unless $ranked && @$ranked;

  my $choice = _select_ranked_entry($ranked);
  return unless $choice;
  return $legal->{$choice->{uci}};
}

sub _ranked_legal_entries_for_state {
  my ($state_key, $source_key, $source, $entries, $legal, $side) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;
  return unless ref $legal eq 'HASH';

  my $cache_key = join("\x1e",
    (defined $source ? $source : ''),
    (defined $state_key ? $state_key : ''),
    (defined $source_key ? $source_key : ''),
  );

  if (exists $ranked_legal_entries_cache{$cache_key}) {
    return $ranked_legal_entries_cache{$cache_key};
  }

  my @ranked = _rank_legal_entries($entries, $side, $legal);
  return unless @ranked;

  my $ranked_ref = \@ranked;
  if (scalar(keys %ranked_legal_entries_cache) >= $RANKED_LEGAL_CACHE_MAX) {
    %ranked_legal_entries_cache = ();
  }
  $ranked_legal_entries_cache{$cache_key} = $ranked_ref;
  return $ranked_ref;
}

sub _legal_move_map {
  my ($state, $state_key) = @_;
  $state_key = canonical_fen_key($state) unless defined $state_key;
  if (defined $state_key && exists $legal_move_map_cache{$state_key}) {
    return $legal_move_map_cache{$state_key};
  }

  my %legal;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $uci = $state->decode_move($move);
    $uci = normalize_uci_move($uci);
    next unless defined $uci;
    $legal{$uci} = $move;
  }
  my $result = \%legal;
  if (defined $state_key) {
    if (scalar(keys %legal_move_map_cache) >= $LEGAL_MOVE_MAP_CACHE_MAX) {
      %legal_move_map_cache = ();
    }
    $legal_move_map_cache{$state_key} = $result;
  }
  return $result;
}

sub _legacy_lookup {
  my ($state) = @_;
  my $pos = join('', map { $Chess::Constant::p2l{$_} }
    @{$state->[Chess::State::BOARD]}[21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98]);

  my $entry = $book{$pos} or return;
  my $index = int(rand(@$entry));
  return $entry->[$index];
}

sub _parse_book_moves {
  my ($moves) = @_;
  return unless ref $moves eq 'ARRAY' && @$moves;

  my %by_uci;
  foreach my $move (@$moves) {
    if (ref $move eq 'HASH') {
      my $uci = normalize_uci_move($move->{uci});
      next unless defined $uci;

      my $weight = _positive_num($move->{weight}, 1);
      my $played = _positive_num(
        (defined $move->{played} ? $move->{played} : $move->{games}),
        $weight,
      );

      my $white = _nonneg_num($move->{white}, 0);
      my $draw  = _nonneg_num($move->{draw}, 0);
      my $black = _nonneg_num($move->{black}, 0);
      my $total = $white + $draw + $black;
      $played = $total if $total > $played;

      $by_uci{$uci}{uci}    = $uci;
      $by_uci{$uci}{weight} += $weight;
      $by_uci{$uci}{played} += $played;
      $by_uci{$uci}{white}  += $white;
      $by_uci{$uci}{draw}   += $draw;
      $by_uci{$uci}{black}  += $black;
    } elsif (!ref $move) {
      my $uci = normalize_uci_move($move);
      next unless defined $uci;
      $by_uci{$uci}{uci}    = $uci;
      $by_uci{$uci}{weight} += 1;
      $by_uci{$uci}{played} += 1;
    }
  }
  return unless %by_uci;
  return sort { _entry_rank($b) <=> _entry_rank($a) } values %by_uci;
}

sub _merge_book_entries {
  my ($target, $key, $entries) = @_;
  return unless defined $key && ref $entries eq 'ARRAY' && @$entries;
  my $current = $target->{$key};
  my $has_current = (ref($current) eq 'ARRAY') ? 1 : 0;
  my %index_by_uci;
  if ($has_current) {
    for (my $i = 0; $i < @$current; $i++) {
      my $uci = $current->[$i]{uci};
      next unless defined $uci;
      $index_by_uci{$uci} = $i;
    }
  }
  my %touched;

  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    my $weight = _positive_num($entry->{weight}, 1);
    my $played = _positive_num($entry->{played}, $weight);
    my $white  = _nonneg_num($entry->{white}, 0);
    my $draw   = _nonneg_num($entry->{draw}, 0);
    my $black  = _nonneg_num($entry->{black}, 0);

    if (exists $index_by_uci{$uci}) {
      my $slot = $current->[$index_by_uci{$uci}];
      $slot->{weight} = 0 unless defined $slot->{weight};
      $slot->{played} = 0 unless defined $slot->{played};
      $slot->{white} = 0 unless defined $slot->{white};
      $slot->{draw} = 0 unless defined $slot->{draw};
      $slot->{black} = 0 unless defined $slot->{black};
      $slot->{weight} += $weight;
      $slot->{played} += $played;
      $slot->{white}  += $white;
      $slot->{draw}   += $draw;
      $slot->{black}  += $black;
      $touched{$uci} = 1;
      next;
    }

    if (! $has_current) {
      $current = [];
      $target->{$key} = $current;
      $has_current = 1;
    }
    my $new_slot = {
      uci    => $uci,
      weight => 0,
      played => 0,
      white  => 0,
      draw   => 0,
      black  => 0,
    };
    $new_slot->{weight} += $weight;
    $new_slot->{played} += $played;
    $new_slot->{white}  += $white;
    $new_slot->{draw}   += $draw;
    $new_slot->{black}  += $black;
    push @$current, $new_slot;
    $index_by_uci{$uci} = $#$current;
    $touched{$uci} = 1;
  }

  _reorder_book_touched($current, \%index_by_uci, \%touched) if %touched;
}

sub _reorder_book_touched {
  my ($entries, $index_by_uci, $touched) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;

  my @reorder = sort {
    ($index_by_uci->{$a} // 0) <=> ($index_by_uci->{$b} // 0)
  } grep { exists $index_by_uci->{$_} } keys %$touched;

  foreach my $uci (@reorder) {
    my $idx = $index_by_uci->{$uci};
    next unless defined $idx;
    while ($idx > 0 && _cmp_entry_rank($entries->[$idx], $entries->[$idx - 1]) < 0) {
      @$entries[$idx, $idx - 1] = @$entries[$idx - 1, $idx];
      $index_by_uci->{$entries->[$idx]{uci}} = $idx if defined $entries->[$idx]{uci};
      $index_by_uci->{$entries->[$idx - 1]{uci}} = $idx - 1 if defined $entries->[$idx - 1]{uci};
      $idx--;
    }
  }
}

sub _cmp_entry_rank {
  my ($left, $right) = @_;
  return _entry_rank($right) <=> _entry_rank($left);
}

sub _rank_legal_entries {
  my ($entries, $side, $legal_map) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;
  $side //= 'white';

  my @candidates;
  my $top_played = 0;
  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    next if ref($legal_map) eq 'HASH' && !exists $legal_map->{$uci};

    my $played = _entry_played($entry);
    my $weight = _positive_num($entry->{weight}, 1);
    push @candidates, {
      entry  => $entry,
      played => $played,
      weight => $weight,
    };
    $top_played = $played if $played > $top_played;
  }
  return unless @candidates;
  $top_played ||= 1;

  my ($quality_weight, $popularity_weight) = _book_rank_weights($top_played);
  my @scored = ();
  foreach my $candidate (@candidates) {
    my $played = $candidate->{played};
    next if _is_sparse_move($played, $top_played);

    my $entry = $candidate->{entry};
    my $quality = _entry_quality_for_side($entry, $side);
    my $popularity = sqrt($played / $top_played);
    my $score = $quality_weight * $quality + $popularity_weight * $popularity;
    push @scored, {
      %$entry,
      _book_score  => $score,
      _book_played => $played,
      _book_weight => $candidate->{weight},
    };
  }

  # If filtering removed everything, fall back to all legal entries.
  if (!@scored) {
    foreach my $candidate (@candidates) {
      my $entry = $candidate->{entry};
      my $played = $candidate->{played};
      my $quality = _entry_quality_for_side($entry, $side);
      my $popularity = sqrt($played / $top_played);
      my $score = $quality_weight * $quality + $popularity_weight * $popularity;
      push @scored, {
        %$entry,
        _book_score  => $score,
        _book_played => $played,
        _book_weight => $candidate->{weight},
      };
    }
  }

  return sort {
    $b->{_book_score} <=> $a->{_book_score}
      || $b->{_book_played} <=> $a->{_book_played}
      || $b->{_book_weight} <=> $a->{_book_weight}
      || ($a->{uci} // '') cmp ($b->{uci} // '')
  } @scored;
}

sub _select_ranked_entry {
  my ($entries) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;

  my $top = $entries->[0];
  return $top unless $BOOK_VARIETY > 0 && @$entries > 1;

  my $floor = $top->{_book_score} - 0.02;
  my @pool = grep { ($_->{_book_score} // 0) >= $floor } @$entries;
  return $top unless @pool > 1;
  return _pick_weighted(\@pool, sub {
    my ($entry) = @_;
    my $score = ($entry->{_book_score} // 0);
    my $played = ($entry->{_book_played} // 1);
    return (1 + 20 * $score) * (1 + $played * $BOOK_VARIETY);
  });
}

sub _entry_played {
  my ($entry) = @_;
  return _positive_num(
    (defined $entry->{played} ? $entry->{played} : $entry->{weight}),
    1,
  );
}

sub _entry_quality_for_side {
  my ($entry, $side) = @_;
  my $white = _nonneg_num($entry->{white}, 0);
  my $draw  = _nonneg_num($entry->{draw}, 0);
  my $black = _nonneg_num($entry->{black}, 0);
  my $total = $white + $draw + $black;
  return 0.5 unless $total > 0;

  my $white_score = ($white + 0.5 * $draw) / $total;
  my $side_score = ($side eq 'black') ? (1 - $white_score) : $white_score;
  return ($side_score * $total + 0.5 * $BOOK_BAYES_GAMES) / ($total + $BOOK_BAYES_GAMES);
}

sub _entry_rank {
  my ($entry) = @_;
  my $played = _entry_played($entry);
  my $weight = _positive_num($entry->{weight}, 1);
  return $played * 1000 + $weight;
}

sub _is_sparse_move {
  my ($played, $top_played) = @_;
  return 0 if $played >= $BOOK_MIN_PLAYED;
  return 0 if $played >= $top_played;
  return 1 if $top_played < 10;
  return ($played / $top_played) < $BOOK_MIN_RELATIVE ? 1 : 0;
}

sub _book_rank_weights {
  my ($top_played) = @_;
  $top_played = int($top_played // 0);
  if ($top_played > 0 && $top_played < 8) {
    return (0.93, 0.07);
  }
  if ($top_played > 0 && $top_played < 20) {
    return (0.88, 0.12);
  }
  my $quality = $BOOK_QUALITY_WEIGHT;
  my $popularity = 1 - $quality;
  return ($quality, $popularity);
}

sub _side_to_move {
  my ($key) = @_;
  return 'white' unless defined $key;
  my (undef, $turn) = split / /, $key;
  return 'black' if defined $turn && $turn eq 'b';
  return 'white';
}

sub _positive_num {
  my ($value, $fallback) = @_;
  $fallback = 1 unless defined $fallback;
  if (defined $value && $value =~ /-?\d+(?:\.\d+)?/) {
    $value += 0;
    return $value if $value > 0;
  }
  return $fallback;
}

sub _nonneg_num {
  my ($value, $fallback) = @_;
  $fallback = 0 unless defined $fallback;
  if (defined $value && $value =~ /-?\d+(?:\.\d+)?/) {
    $value += 0;
    return $value if $value >= 0;
  }
  return $fallback;
}

sub _env_int {
  my ($name, $default, $min) = @_;
  my $value = $ENV{$name};
  return $default unless defined $value && $value =~ /^\d+$/;
  $value = int($value);
  $value = $min if defined $min && $value < $min;
  return $value;
}

sub _env_num {
  my ($name, $default, $min, $max) = @_;
  my $value = $ENV{$name};
  return $default unless defined $value && $value =~ /-?\d+(?:\.\d+)?/;
  $value += 0;
  $value = $min if defined $min && $value < $min;
  $value = $max if defined $max && $value > $max;
  return $value;
}

sub _pick_weighted {
  my ($entries, $weight_cb) = @_;
  $weight_cb ||= sub { $_[0]{weight} };
  my $total = sum(map { $weight_cb->($_) } @$entries);
  return $entries->[rand @$entries] unless $total;

  my $roll = rand($total);
  my $accum = 0;
  foreach my $entry (@$entries) {
    $accum += $weight_cb->($entry);
    return $entry if $roll <= $accum;
  }
  return $entries->[-1];
}

BEGIN {
  _load_json_book();
}

1;
