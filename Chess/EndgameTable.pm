package Chess::EndgameTable;
use strict;
use warnings;

use Chess::Constant;
use Chess::State ();
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;
use Chess::TableUtil qw(
  canonical_fen_key
  relaxed_fen_key
  normalize_uci_move
  merge_weighted_moves
  board_indices
);

my %table;
my %relaxed_table;
my %syzygy_cache;
my %syzygy_failure_backoff_until;

my %syzygy_wdl_rank = (
  2  => 5_000_000,  # win
  1  => 4_000_000,  # cursed win
  0  => 3_000_000,  # draw
  -1 => 2_000_000,  # blessed loss
  -2 => 1_000_000,  # loss
);

sub _table_path {
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  return File::Spec->catfile($root, 'data', 'endgame_table.json');
}

sub _load_tables {
  %table = ();
  %relaxed_table = ();

  my $path = _table_path();
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
    my %by_uci;
    foreach my $move (@$moves) {
      if (ref $move eq 'HASH') {
        my $uci = normalize_uci_move($move->{uci});
        next unless defined $uci;
        my $weight = $move->{weight};
        $weight = 1 unless defined $weight && $weight =~ /-?\d+(?:\.\d+)?/;
        $weight += 0;
        $weight = 1 if $weight <= 0;

        my $rank = $move->{rank};
        $rank = $weight unless defined $rank && $rank =~ /-?\d+(?:\.\d+)?/;
        $rank += 0;

        if (exists $by_uci{$uci}) {
          $by_uci{$uci}{weight} += $weight;
          $by_uci{$uci}{rank} = $rank if $rank > $by_uci{$uci}{rank};
        } else {
          $by_uci{$uci} = { uci => $uci, weight => $weight, rank => $rank };
        }
      } elsif (! ref $move) {
        my $uci = normalize_uci_move($move);
        next unless defined $uci;
        if (exists $by_uci{$uci}) {
          $by_uci{$uci}{weight} += 1;
        } else {
          $by_uci{$uci} = { uci => $uci, weight => 1, rank => 1 };
        }
      }
    }
    next unless %by_uci;

    my @parsed = sort {
      $b->{rank} <=> $a->{rank} || $b->{weight} <=> $a->{weight}
    } values %by_uci;

    merge_weighted_moves(\%table, $key, \@parsed, { with_rank => 1 });
    merge_weighted_moves(\%relaxed_table, $relaxed, \@parsed, { with_rank => 1 }) if defined $relaxed;
  }
}

sub choose_move {
  my ($state) = @_;
  my $syzygy_entries = tablebase_entries($state);
  if ($syzygy_entries && @$syzygy_entries) {
    my $syzygy_move = _choose_ranked_table_move($state, $syzygy_entries);
    return $syzygy_move if $syzygy_move;
  }

  my $key = canonical_fen_key($state);
  my $entries = $table{$key};
  if (! $entries) {
    my $relaxed = relaxed_fen_key($key);
    $entries = $relaxed_table{$relaxed} if defined $relaxed;
  }

  if ($entries && @$entries) {
    my $move = _choose_ranked_table_move($state, $entries);
    return $move if $move;
  }

  my $fallback = _choose_simple_mating_move($state);
  return $fallback if $fallback;
  return;
}

sub tablebase_entries {
  my ($state) = @_;
  return unless _env_bool('CHESS_SYZYGY_ENABLED', 1);
  return unless _piece_count($state) <= _env_int('CHESS_SYZYGY_MAX_PIECES', 7, 2, 16);

  my @tb_paths = _syzygy_paths();
  return unless @tb_paths;

  my $key = canonical_fen_key($state);
  return if _in_syzygy_failure_backoff($key);

  my $ttl = _env_int('CHESS_SYZYGY_CACHE_TTL', 30 * 24 * 3600, 0);
  if ($ttl > 0) {
    my $entry = $syzygy_cache{$key};
    if (ref $entry eq 'HASH') {
      my $age = time() - ($entry->{ts} // 0);
      if ($age <= $ttl && ref $entry->{data} eq 'ARRAY') {
        return $entry->{data};
      }
    }
  }

  my $fen = $state->get_fen;
  my $payload = _probe_syzygy($fen, \@tb_paths);
  if (! $payload || ref $payload ne 'HASH' || ref $payload->{moves} ne 'ARRAY') {
    _mark_syzygy_failure($key);
    return;
  }

  my @entries;
  foreach my $move (@{$payload->{moves}}) {
    next unless ref $move eq 'HASH';
    my $uci = normalize_uci_move($move->{uci});
    next unless defined $uci;

    my $wdl = _numeric_or($move->{wdl}, -3);
    my $rank = $syzygy_wdl_rank{$wdl} // 0;
    my $dtz = _maybe_numeric($move->{dtz});
    my $dtm = _maybe_numeric($move->{dtm});

    if (defined $dtz) {
      my $clamped = $dtz > 400 ? 400 : $dtz;
      if ($wdl > 0) {
        $rank += (400 - $clamped) * 10;
      } elsif ($wdl < 0) {
        $rank += $clamped * 10;
      } else {
        $rank += (400 - $clamped);
      }
    }
    if (defined $dtm) {
      my $clamped = $dtm > 600 ? 600 : $dtm;
      $rank += ($wdl > 0) ? (600 - $clamped) : $clamped;
    }

    my $weight = _numeric_or($move->{weight}, 1);
    $weight = 1 if $weight < 1;

    push @entries, {
      uci    => $uci,
      rank   => $rank,
      weight => $weight,
    };
  }

  @entries = sort {
    $b->{rank} <=> $a->{rank} || $b->{weight} <=> $a->{weight}
  } @entries;

  $syzygy_cache{$key} = {
    ts   => time(),
    data => \@entries,
  };
  return \@entries;
}

sub _choose_ranked_table_move {
  my ($state, $entries) = @_;
  my $legal = _legal_move_details($state);
  return unless keys %{$legal};

  my $best_move;
  my $best_score;
  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    my $detail = $legal->{$uci} or next;
    my $rank = $entry->{rank} // $entry->{weight} // 0;

    # Tablebase preference:
    # first use table rank, then tie-break by restricting the opponent.
    my $score = 1_000_000 * $rank;
    $score += 500_000 if $detail->{mate};
    $score += 5_000 if $detail->{gives_check};
    $score -= 25 * $detail->{opp_moves};
    $score -= 100 * $detail->{opp_captures};
    $score += $entry->{weight} // 0;

    if (!defined $best_score || $score > $best_score) {
      $best_score = $score;
      $best_move = $detail->{move};
    }
  }

  return $best_move;
}

sub _choose_simple_mating_move {
  my ($state) = @_;
  return unless _is_basic_mating_material($state);

  my $legal = _legal_move_details($state);
  return unless keys %{$legal};

  my $best_move;
  my $best_score;
  foreach my $detail (values %{$legal}) {
    my $score = 0;
    $score += 500_000 if $detail->{mate};
    $score += 5_000 if $detail->{gives_check};
    $score -= 30 * $detail->{opp_moves};
    $score -= 120 * $detail->{opp_captures};
    if (!defined $best_score || $score > $best_score) {
      $best_score = $score;
      $best_move = $detail->{move};
    }
  }

  return $best_move;
}

sub _is_basic_mating_material {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];

  my ($friendly_king, $enemy_king, $friendly_queen, $friendly_rook, $other_friendly, $enemy_other) = (0, 0, 0, 0, 0, 0);
  foreach my $idx (board_indices()) {
    my $piece = $board->[$idx] // 0;
    next unless $piece;
    if ($piece > 0) {
      if ($piece == KING) {
        $friendly_king++;
      } elsif ($piece == QUEEN) {
        $friendly_queen++;
      } elsif ($piece == ROOK) {
        $friendly_rook++;
      } else {
        $other_friendly++;
      }
    } else {
      if ($piece == OPP_KING) {
        $enemy_king++;
      } else {
        $enemy_other++;
      }
    }
  }

  return 0 unless $friendly_king == 1 && $enemy_king == 1;
  return 0 unless $enemy_other == 0;
  return 1 if $friendly_queen == 1 && $friendly_rook == 0 && $other_friendly == 0;
  return 1 if $friendly_rook == 1 && $friendly_queen == 0 && $other_friendly == 0;
  return 0;
}

sub _legal_move_details {
  my ($state) = @_;
  my %details;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;

    my $uci = normalize_uci_move($state->decode_move($move));
    next unless defined $uci;

    my @opp_legal = grep {
      defined $new_state->make_move($_)
    } @{$new_state->generate_pseudo_moves};

    my $opp_captures = scalar grep {
      my $target = $new_state->[Chess::State::BOARD][$_->[1]] // 0;
      $target < 0;
    } @opp_legal;

    $details{$uci} = {
      move => $move,
      opp_moves => scalar @opp_legal,
      opp_captures => $opp_captures,
      gives_check => ($new_state->is_checked ? 1 : 0),
      mate => ((@opp_legal == 0 && $new_state->is_checked) ? 1 : 0),
    };
  }
  return \%details;
}

sub _probe_syzygy {
  my ($fen, $tb_paths) = @_;
  my $script = _probe_script_path();
  return unless -e $script;

  my @cmd = ($script, '--fen', $fen);
  foreach my $path (@$tb_paths) {
    push @cmd, ('--tb-path', $path);
  }

  my $output = '';
  my $ok = eval {
    open my $fh, '-|', @cmd or die "spawn failed";
    local $/;
    $output = <$fh>;
    close $fh or die "probe failed";
    1;
  };
  return unless $ok;
  return unless defined $output && length $output;

  my $data = eval { JSON::PP->new->decode($output) };
  return if $@;
  return $data;
}

sub _probe_script_path {
  if (defined $ENV{CHESS_SYZYGY_PROBE_SCRIPT} && length $ENV{CHESS_SYZYGY_PROBE_SCRIPT}) {
    return $ENV{CHESS_SYZYGY_PROBE_SCRIPT};
  }
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  return File::Spec->catfile($root, 'scripts', 'probe_syzygy.pl');
}

sub _syzygy_paths {
  my $raw = $ENV{CHESS_SYZYGY_PATH} // '';
  return unless length $raw;

  my $sep = ($^O eq 'MSWin32') ? ';' : ':';
  my %seen;
  my @paths = grep {
    !$seen{$_}++
  } grep {
    defined $_ && length $_ && -d $_
  } map {
    my $path = $_;
    $path =~ s/^\s+//;
    $path =~ s/\s+$//;
    $path;
  } split /\Q$sep\E/, $raw;

  return @paths;
}

sub _piece_count {
  my ($state) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $count = 0;

  for my $rank (2 .. 9) {
    my $base = $rank * 10;
    for my $file (1 .. 8) {
      my $piece = $board->[$base + $file] // 0;
      my $abs_piece = abs($piece);
      $count++ if $abs_piece >= PAWN && $abs_piece <= KING;
    }
  }

  return $count;
}

sub _env_bool {
  my ($name, $default) = @_;
  return $default unless exists $ENV{$name};
  my $value = lc($ENV{$name} // '');
  return 1 if $value =~ /^(?:1|true|on|yes)$/;
  return 0 if $value =~ /^(?:0|false|off|no)$/;
  return $default ? 1 : 0;
}

sub _env_int {
  my ($name, $default, $min, $max) = @_;
  my $value = exists $ENV{$name} ? $ENV{$name} : $default;
  $value = $default unless defined $value && $value =~ /^-?\d+$/;
  $value = int($value);
  $value = $min if defined $min && $value < $min;
  $value = $max if defined $max && $value > $max;
  return $value;
}

sub _numeric_or {
  my ($value, $default) = @_;
  return $default unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
  return $value + 0;
}

sub _maybe_numeric {
  my ($value) = @_;
  return unless defined $value && $value =~ /^-?\d+(?:\.\d+)?$/;
  my $num = abs($value + 0);
  return $num;
}

sub _in_syzygy_failure_backoff {
  my ($key) = @_;
  my $until = $syzygy_failure_backoff_until{$key} // 0;
  return $until > time();
}

sub _mark_syzygy_failure {
  my ($key) = @_;
  my $seconds = _env_int('CHESS_SYZYGY_FAILURE_BACKOFF_SECS', 120, 1, 3600);
  $syzygy_failure_backoff_until{$key} = time() + $seconds;
}

_load_tables();

1;
