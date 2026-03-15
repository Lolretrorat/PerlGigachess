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
my %fen_book_meta;
my %relaxed_fen_book_meta;
my %overlay_fen_book;
my %overlay_relaxed_fen_book;
my %overlay_fen_book_meta;
my %overlay_relaxed_fen_book_meta;
my %legal_move_map_cache;
my %ranked_legal_entries_cache;
my $LEGAL_MOVE_MAP_CACHE_MAX = 20_000;
my $RANKED_LEGAL_CACHE_MAX = 20_000;
my $book_path_cache;
my $book_extra_paths_cache;
my $book_style_overlay_path_cache;
my $BOOK_MIN_PLAYED   = _env_int('CHESS_BOOK_MIN_PLAYED', 3, 1);
my $BOOK_MIN_RELATIVE = _env_num('CHESS_BOOK_MIN_RELATIVE', 0.12, 0.0, 1.0);
my $BOOK_VARIETY      = _env_num('CHESS_BOOK_VARIETY', 0.0, 0.0, 1.0);
my $BOOK_BAYES_GAMES  = _env_num('CHESS_BOOK_BAYES_GAMES', 8.0, 0.0, 1000.0);
my $BOOK_QUALITY_WEIGHT = _env_num('CHESS_BOOK_QUALITY_WEIGHT', 0.82, 0.0, 1.0);
my $BOOK_POLICY = _env_choice(
  'CHESS_BOOK_POLICY',
  'weighted_random',
  {
    best => 1,
    weighted_random => 1,
    uniform_random => 1,
  },
);
my $BOOK_TOP_N = _env_int('CHESS_BOOK_TOP_N', 3, 1);
my $BOOK_MAX_PLIES = _env_int('CHESS_BOOK_MAX_PLIES', 0, 0);
my $BOOK_MAX_FULLMOVE = _env_int('CHESS_BOOK_MAX_FULLMOVE', 0, 0);
my $BOOK_USE_STYLE_OVERLAY = _env_flag('CHESS_BOOK_USE_STYLE_OVERLAY', 0);

sub _book_path {
  return $ENV{CHESS_BOOK_PATH} if defined $ENV{CHESS_BOOK_PATH} && length $ENV{CHESS_BOOK_PATH};
  return $book_path_cache if defined $book_path_cache;
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  $book_path_cache = File::Spec->catfile($root, 'data', 'opening_book.json');
  return $book_path_cache;
}

sub _book_extra_paths {
  return $book_extra_paths_cache if defined $book_extra_paths_cache;
  my $raw = $ENV{CHESS_BOOK_EXTRA_PATHS};
  return $book_extra_paths_cache = [] unless defined $raw && length $raw;

  my $path_list_sep = _path_list_sep();
  my @paths = grep { defined $_ && length $_ } split /\Q$path_list_sep\E/, $raw;
  $book_extra_paths_cache = \@paths;
  return $book_extra_paths_cache;
}

sub _path_list_sep {
  return ($^O eq 'MSWin32') ? ';' : ':';
}

sub _book_paths {
  my @paths;
  my %seen;
  my $primary = _book_path();
  if (defined $primary && length $primary) {
    push @paths, $primary;
    $seen{$primary} = 1;
  }
  foreach my $extra (@{_book_extra_paths()}) {
    next unless defined $extra && length $extra;
    next if $seen{$extra};
    push @paths, $extra;
    $seen{$extra} = 1;
  }
  if ($BOOK_USE_STYLE_OVERLAY) {
    my $overlay = _book_style_overlay_path();
    if (defined $overlay && length $overlay && -e $overlay && !$seen{$overlay}) {
      push @paths, $overlay;
      $seen{$overlay} = 1;
    }
  }
  return @paths;
}

sub _book_style_overlay_path {
  return $ENV{CHESS_BOOK_STYLE_OVERLAY_PATH}
    if defined $ENV{CHESS_BOOK_STYLE_OVERLAY_PATH} && length $ENV{CHESS_BOOK_STYLE_OVERLAY_PATH};
  return $book_style_overlay_path_cache if defined $book_style_overlay_path_cache;
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  $book_style_overlay_path_cache = File::Spec->catfile($root, 'data', 'opening_style_overlay.json');
  return $book_style_overlay_path_cache;
}

sub reload {
  $book_path_cache = undef;
  $book_extra_paths_cache = undef;
  $book_style_overlay_path_cache = undef;
  _load_json_book();
  return scalar(keys %fen_book);
}

sub _load_json_book {
  %fen_book = ();
  %relaxed_fen_book = ();
  %fen_book_meta = ();
  %relaxed_fen_book_meta = ();
  %overlay_fen_book = ();
  %overlay_relaxed_fen_book = ();
  %overlay_fen_book_meta = ();
  %overlay_relaxed_fen_book_meta = ();
  %ranked_legal_entries_cache = ();

  my @paths = _book_paths();
  foreach my $path (@paths) {
    _merge_json_book_path($path);
  }
  if (!$BOOK_USE_STYLE_OVERLAY) {
    my $overlay = _book_style_overlay_path();
    if (defined $overlay && length $overlay && -e $overlay) {
      _merge_json_book_path(
        $overlay,
        \%overlay_fen_book,
        \%overlay_relaxed_fen_book,
        \%overlay_fen_book_meta,
        \%overlay_relaxed_fen_book_meta,
      );
    }
  }
}

sub _merge_json_book_path {
  my ($path, $fen_target, $relaxed_target, $fen_meta_target, $relaxed_meta_target) = @_;
  return unless defined $path && -e $path;
  $fen_target ||= \%fen_book;
  $relaxed_target ||= \%relaxed_fen_book;
  $fen_meta_target ||= \%fen_book_meta;
  $relaxed_meta_target ||= \%relaxed_fen_book_meta;

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
    my $meta = _parse_book_metadata($entry);
    my @parsed = _parse_book_moves($moves);
    next unless @parsed;

    push @{ $pending_fen{$key} }, @parsed;
    push @{ $pending_relaxed{$relaxed} }, @parsed if defined $relaxed;
    _merge_book_metadata_for_key($fen_meta_target, $key, $meta);
    _merge_book_metadata_for_key($relaxed_meta_target, $relaxed, $meta) if defined $relaxed;
  }

  foreach my $merge_key (keys %pending_fen) {
    _merge_book_entries($fen_target, $merge_key, $pending_fen{$merge_key});
  }
  foreach my $merge_key (keys %pending_relaxed) {
    _merge_book_entries($relaxed_target, $merge_key, $pending_relaxed{$merge_key});
  }
}

sub choose_move {
  my ($state) = @_;
  my $entry = choose_entry($state);
  return unless $entry;
  return $entry->{move} if ref($entry) eq 'HASH';
  return $entry;
}

sub choose_entry {
  my ($state) = @_;
  return unless _book_depth_allowed($state);
  return _lookup_fen_entry($state) || _legacy_lookup_entry($state);
}

sub lookup_plan {
  my ($state, $move_or_uci) = @_;
  return unless _book_depth_allowed($state);
  my $entry = _lookup_fen_entry($state, $move_or_uci);
  return unless ref($entry) eq 'HASH';

  my %plan;
  for my $field (qw(uci opening plan plan_id source source_key)) {
    $plan{$field} = $entry->{$field} if defined $entry->{$field};
  }
  for my $field (qw(plan_tags plans)) {
    next unless ref($entry->{$field}) eq 'ARRAY' && @{$entry->{$field}};
    $plan{$field} = [ @{$entry->{$field}} ];
  }
  return unless %plan;
  return \%plan;
}

sub plan_tags_for_state {
  my ($state, $opts) = @_;
  return [] unless _book_depth_allowed($state);
  $opts = {} unless ref($opts) eq 'HASH';

  my $limit = $opts->{top_n};
  $limit = 2 unless defined $limit && $limit =~ /^\d+$/ && $limit > 0;

  my %scores;
  my $ctx = _lookup_fen_context($state);
  _accumulate_plan_tags_from_context(\%scores, $ctx, $limit) if $ctx;

  if (!$BOOK_USE_STYLE_OVERLAY) {
    my $overlay_ctx = _lookup_fen_context_from(
      $state,
      \%overlay_fen_book,
      \%overlay_relaxed_fen_book,
      'overlay_fen',
      'overlay_relaxed',
    );
    _accumulate_plan_tags_from_context(\%scores, $overlay_ctx, $limit) if $overlay_ctx;
  }

  return [] unless %scores;
  return [
    sort {
      $scores{$b} <=> $scores{$a}
        || $a cmp $b
    } keys %scores
  ];
}

sub _book_depth_allowed {
  my ($state) = @_;
  return 1 unless defined $state && ref($state) eq 'Chess::State';

  if ($BOOK_MAX_PLIES > 0) {
    my $ply = _state_ply($state);
    return 0 if $ply > $BOOK_MAX_PLIES;
  }
  if ($BOOK_MAX_FULLMOVE > 0) {
    my $fullmove = $state->[Chess::State::MOVE];
    $fullmove = 1 unless defined $fullmove && $fullmove =~ /^\d+$/;
    return 0 if $fullmove > $BOOK_MAX_FULLMOVE;
  }
  return 1;
}

sub _state_ply {
  my ($state) = @_;
  my $fullmove = $state->[Chess::State::MOVE];
  $fullmove = 1 unless defined $fullmove && $fullmove =~ /^\d+$/;
  my $turn = $state->[Chess::State::TURN] ? 1 : 0;
  return (($fullmove - 1) * 2) + $turn;
}

sub _lookup_fen_entry {
  my ($state, $move_or_uci) = @_;
  my $ctx = _lookup_fen_context($state) or return;
  my $choice;
  my $requested_uci = _requested_book_uci($state, $move_or_uci);
  if (defined $requested_uci) {
    ($choice) = grep {
      defined($_->{uci}) && $_->{uci} eq $requested_uci
    } @{$ctx->{ranked}};
    return unless $choice;
  } else {
    $choice = _select_ranked_entry($ctx->{ranked});
    return unless $choice;
  }

  my $move = $ctx->{legal}{$choice->{uci}} or return;
  return _compose_book_choice($choice, $ctx, $move);
}

sub _lookup_fen_context {
  my ($state) = @_;
  return _lookup_fen_context_from($state, \%fen_book, \%relaxed_fen_book, 'fen', 'relaxed');
}

sub _lookup_fen_context_from {
  my ($state, $fen_ref, $relaxed_ref, $fen_source, $relaxed_source) = @_;
  $fen_ref ||= \%fen_book;
  $relaxed_ref ||= \%relaxed_fen_book;
  $fen_source ||= 'fen';
  $relaxed_source ||= 'relaxed';

  my $key = canonical_fen_key($state);
  my $entries = $fen_ref->{$key};
  my $source = $fen_source;
  my $source_key = $key;
  if (! $entries) {
    my $relaxed = relaxed_fen_key($key);
    if (defined $relaxed) {
      $entries = $relaxed_ref->{$relaxed};
      $source = $relaxed_source;
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

  return {
    key => $key,
    source => $source,
    source_key => $source_key,
    ranked => $ranked,
    legal => $legal,
  };
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

sub _legacy_lookup_entry {
  my ($state) = @_;
  my $pos = join('', map { $Chess::Constant::p2l{$_} }
    @{$state->[Chess::State::BOARD]}[21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98]);

  my $entry = $book{$pos} or return;
  my $index = int(rand(@$entry));
  my $move = $entry->[$index];
  return unless ref($move) eq 'ARRAY';
  my $uci = eval { $state->decode_move($move) };
  return {
    move => $move,
    uci => $uci,
    source => 'legacy',
  };
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
      _merge_book_metadata($by_uci{$uci}, _parse_book_metadata($move));
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
      _merge_book_metadata($slot, $entry);
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
    _merge_book_metadata($new_slot, $entry);
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

  return $entries->[0] if $BOOK_POLICY eq 'best';
  my @pool = _selection_pool($entries);
  return $entries->[0] unless @pool > 1;

  if ($BOOK_POLICY eq 'uniform_random') {
    return $pool[int(rand(@pool))];
  }

  return _pick_weighted(\@pool, sub {
    my ($entry) = @_;
    my $score = ($entry->{_book_score} // 0);
    my $played = ($entry->{_book_played} // 1);
    my $variety = $BOOK_VARIETY >= 0.05 ? $BOOK_VARIETY : 0.05;
    my $base = (1 + 20 * $score) * (1 + $played * $variety);
    return $base > 0 ? $base : 1;
  });
}

sub _selection_pool {
  my ($entries) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;
  my $top = $entries->[0];
  my $floor = ($top->{_book_score} // 0) - 0.02;
  my @near_top = grep { ($_->{_book_score} // 0) >= $floor } @$entries;

  # Keep a little diversity when one line is clearly best by still considering
  # a small top-N slice for weighted policies.
  if (@near_top < 2 && @$entries > 1) {
    my $fallback_take = $BOOK_TOP_N;
    $fallback_take = 2 if !defined $fallback_take || $fallback_take < 2;
    $fallback_take = @$entries if $fallback_take > @$entries;
    return @$entries[0 .. ($fallback_take - 1)];
  }

  my $take = $BOOK_TOP_N;
  $take = 1 if !defined $take || $take < 1;
  $take = @near_top if $take > @near_top;
  return @near_top[0 .. ($take - 1)];
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

sub _compose_book_choice {
  my ($choice, $ctx, $move) = @_;
  return unless ref($choice) eq 'HASH';
  return unless ref($ctx) eq 'HASH';

  my %entry = (
    move => $move,
    uci => $choice->{uci},
    source => $ctx->{source},
    source_key => $ctx->{source_key},
  );
  _merge_book_metadata(\%entry, _book_metadata_for_source($ctx->{source}, $ctx->{source_key}));
  _merge_book_metadata(\%entry, $choice);
  return \%entry;
}

sub _requested_book_uci {
  my ($state, $move_or_uci) = @_;
  return unless defined $move_or_uci;
  if (ref($move_or_uci) eq 'ARRAY') {
    return unless ref($state) eq 'Chess::State';
    my $uci = eval { $state->decode_move($move_or_uci) };
    return normalize_uci_move($uci);
  }
  return normalize_uci_move($move_or_uci);
}

sub _book_metadata_for_source {
  my ($source, $key) = @_;
  return unless defined $key;
  return $fen_book_meta{$key} if defined $source && $source eq 'fen';
  return $relaxed_fen_book_meta{$key} if defined $source && $source eq 'relaxed';
  return $overlay_fen_book_meta{$key} if defined $source && $source eq 'overlay_fen';
  return $overlay_relaxed_fen_book_meta{$key} if defined $source && $source eq 'overlay_relaxed';
  return;
}

sub _parse_book_metadata {
  my ($node) = @_;
  return unless ref($node) eq 'HASH';

  my %meta;
  for my $field (qw(opening plan plan_id)) {
    my $value = $node->{$field};
    next unless defined $value;
    $value =~ s/^\s+|\s+$//g;
    next unless length $value;
    $meta{$field} = $value;
  }

  for my $field (qw(plan_tags plans)) {
    my $value = _normalize_string_list($node->{$field});
    next unless $value && @{$value};
    $meta{$field} = $value;
  }

  return unless %meta;
  return \%meta;
}

sub _merge_book_metadata_for_key {
  my ($target, $key, $meta) = @_;
  return unless ref($target) eq 'HASH';
  return unless defined $key && length $key;
  return unless ref($meta) eq 'HASH' && %{$meta};
  $target->{$key} ||= {};
  _merge_book_metadata($target->{$key}, $meta);
}

sub _merge_book_metadata {
  my ($target, $meta) = @_;
  return unless ref($target) eq 'HASH';
  return unless ref($meta) eq 'HASH' && %{$meta};

  for my $field (qw(opening plan plan_id)) {
    next unless defined $meta->{$field} && length $meta->{$field};
    $target->{$field} = $meta->{$field};
  }

  for my $field (qw(plan_tags plans)) {
    next unless ref($meta->{$field}) eq 'ARRAY' && @{$meta->{$field}};
    my %seen = map { $_ => 1 } @{ $target->{$field} || [] };
    for my $value (@{$meta->{$field}}) {
      next unless defined $value && length $value;
      next if $seen{$value}++;
      push @{ $target->{$field} ||= [] }, $value;
    }
  }
}

sub _normalize_string_list {
  my ($value) = @_;
  return unless ref($value) eq 'ARRAY' && @{$value};
  my @values;
  my %seen;
  for my $item (@{$value}) {
    next unless defined $item;
    $item =~ s/^\s+|\s+$//g;
    next unless length $item;
    next if $seen{$item}++;
    push @values, $item;
  }
  return unless @values;
  return \@values;
}

sub _accumulate_plan_tags {
  my ($scores, $meta, $weight) = @_;
  return unless ref($scores) eq 'HASH';
  return unless ref($meta) eq 'HASH';
  $weight = 1.0 unless defined $weight;

  for my $field (qw(plan_tags plans)) {
    next unless ref($meta->{$field}) eq 'ARRAY';
    for my $value (@{$meta->{$field}}) {
      next unless defined $value && length $value;
      $scores->{$value} += $weight;
    }
  }
}

sub _accumulate_plan_tags_from_context {
  my ($scores, $ctx, $limit) = @_;
  return unless ref($scores) eq 'HASH';
  return unless ref($ctx) eq 'HASH';
  $limit = 2 unless defined $limit && $limit =~ /^\d+$/ && $limit > 0;

  _accumulate_plan_tags($scores, _book_metadata_for_source($ctx->{source}, $ctx->{source_key}), 1.0);

  my $taken = 0;
  foreach my $entry (@{$ctx->{ranked} || []}) {
    last if $taken >= $limit;
    my $weight = 1.0 + ($entry->{_book_score} // 0);
    _accumulate_plan_tags($scores, $entry, $weight);
    $taken++;
  }
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

sub _env_choice {
  my ($name, $default, $allowed) = @_;
  my $value = $ENV{$name};
  return $default unless defined $value;
  $value = lc($value);
  return $default unless ref($allowed) eq 'HASH' && $allowed->{$value};
  return $value;
}

sub _env_flag {
  my ($name, $default) = @_;
  my $value = $ENV{$name};
  return $default unless defined $value;
  $value = lc($value);
  return 1 if $value eq '1' || $value eq 'true' || $value eq 'yes' || $value eq 'on';
  return 0 if $value eq '0' || $value eq 'false' || $value eq 'no' || $value eq 'off';
  return $default;
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

_load_json_book();

1;
