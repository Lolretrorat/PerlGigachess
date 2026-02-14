package Chess::Book;
use strict;
use warnings;

use Chess::Constant;
use Chess::State ();
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;
use List::Util qw(max sum);
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
my $BOOK_MIN_PLAYED   = _env_int('CHESS_BOOK_MIN_PLAYED', 3, 1);
my $BOOK_MIN_RELATIVE = _env_num('CHESS_BOOK_MIN_RELATIVE', 0.12, 0.0, 1.0);
my $BOOK_VARIETY      = _env_num('CHESS_BOOK_VARIETY', 0.0, 0.0, 1.0);
my $BOOK_BAYES_GAMES  = _env_num('CHESS_BOOK_BAYES_GAMES', 8.0, 0.0, 1000.0);
my $BOOK_QUALITY_WEIGHT = _env_num('CHESS_BOOK_QUALITY_WEIGHT', 0.82, 0.0, 1.0);

sub _book_path {
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  return File::Spec->catfile($root, 'data', 'opening_book.json');
}

sub _load_json_book {
  %fen_book = ();
  %relaxed_fen_book = ();

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

  foreach my $entry (@$data) {
    next unless ref $entry eq 'HASH';
    my $key = $entry->{key} || next;
    my $relaxed = relaxed_fen_key($key);
    my $moves = $entry->{moves} || [];
    my @parsed = _parse_book_moves($moves);
    next unless @parsed;

    _merge_book_entries(\%fen_book, $key, \@parsed);
    _merge_book_entries(\%relaxed_fen_book, $relaxed, \@parsed) if defined $relaxed;
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
  if (! $entries) {
    my $relaxed = relaxed_fen_key($key);
    $entries = $relaxed_fen_book{$relaxed} if defined $relaxed;
  }
  return unless $entries && @$entries;

  my $legal = _legal_move_map($state);
  return unless keys %$legal;

  my @legal_entries = grep { exists $legal->{$_->{uci}} } @$entries;
  return unless @legal_entries;

  my $side = _side_to_move($key);
  my @ranked = _rank_legal_entries(\@legal_entries, $side);
  return unless @ranked;

  my $choice = _select_ranked_entry(\@ranked);
  return unless $choice;
  return $legal->{$choice->{uci}};
}

sub _legal_move_map {
  my ($state) = @_;
  my %legal;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $uci = $state->decode_move($move);
    $uci = normalize_uci_move($uci);
    next unless defined $uci;
    $legal{$uci} = $move;
  }
  return \%legal;
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

  my %merged = map {
    $_->{uci} => {
      uci    => $_->{uci},
      weight => _positive_num($_->{weight}, 1),
      played => _positive_num($_->{played}, _positive_num($_->{weight}, 1)),
      white  => _nonneg_num($_->{white}, 0),
      draw   => _nonneg_num($_->{draw}, 0),
      black  => _nonneg_num($_->{black}, 0),
    }
  } @{ $target->{$key} || [] };

  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    if (!exists $merged{$uci}) {
      $merged{$uci} = {
        uci    => $uci,
        weight => 0,
        played => 0,
        white  => 0,
        draw   => 0,
        black  => 0,
      };
    }
    $merged{$uci}{weight} += _positive_num($entry->{weight}, 1);
    $merged{$uci}{played} += _positive_num($entry->{played}, _positive_num($entry->{weight}, 1));
    $merged{$uci}{white}  += _nonneg_num($entry->{white}, 0);
    $merged{$uci}{draw}   += _nonneg_num($entry->{draw}, 0);
    $merged{$uci}{black}  += _nonneg_num($entry->{black}, 0);
  }

  my @sorted = sort { _entry_rank($b) <=> _entry_rank($a) } values %merged;
  $target->{$key} = \@sorted if @sorted;
}

sub _rank_legal_entries {
  my ($entries, $side) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;
  $side //= 'white';

  my $top_played = max(map { _entry_played($_) } @$entries) || 1;
  my ($quality_weight, $popularity_weight) = _book_rank_weights($top_played);
  my @scored = ();
  foreach my $entry (@$entries) {
    my $played = _entry_played($entry);
    next if _is_sparse_move($played, $top_played);

    my $quality = _entry_quality_for_side($entry, $side);
    my $popularity = sqrt($played / $top_played);
    my $score = $quality_weight * $quality + $popularity_weight * $popularity;
    push @scored, { %$entry, _book_score => $score };
  }

  # If filtering removed everything, fall back to all legal entries.
  if (!@scored) {
    foreach my $entry (@$entries) {
      my $quality = _entry_quality_for_side($entry, $side);
      my $played = _entry_played($entry);
      my $popularity = sqrt($played / $top_played);
      my $score = $quality_weight * $quality + $popularity_weight * $popularity;
      push @scored, { %$entry, _book_score => $score };
    }
  }

  return sort {
    $b->{_book_score} <=> $a->{_book_score}
      || _entry_played($b) <=> _entry_played($a)
      || _positive_num($b->{weight}, 1) <=> _positive_num($a->{weight}, 1)
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
    my $played = _entry_played($entry);
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
