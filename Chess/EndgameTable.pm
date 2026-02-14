package Chess::EndgameTable;
use strict;
use warnings;

use Chess::Constant;
use Chess::State ();
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;

my %table;
my %relaxed_table;

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
    <$fh>;
  };

  my $data = eval { JSON::PP->new->relaxed->decode($json_text) };
  return if $@ || ref $data ne 'ARRAY';

  foreach my $entry (@$data) {
    next unless ref $entry eq 'HASH';
    my $key = $entry->{key} || next;
    my $relaxed = _relaxed_key_from_canonical($key);
    my $moves = $entry->{moves} || [];
    my %by_uci;
    foreach my $move (@$moves) {
      if (ref $move eq 'HASH') {
        my $uci = _normalize_uci($move->{uci});
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
        my $uci = _normalize_uci($move);
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

    _merge_entries(\%table, $key, \@parsed);
    _merge_entries(\%relaxed_table, $relaxed, \@parsed) if defined $relaxed;
  }
}

sub choose_move {
  my ($state) = @_;
  my $key = _canonical_key($state);
  my $entries = $table{$key};
  if (! $entries) {
    my $relaxed = _relaxed_key_from_canonical($key);
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

sub _canonical_key {
  my ($state) = @_;
  my $fen = $state->get_fen;
  my ($placement, $turn, $castle, $ep) = split / /, $fen;
  return join(' ', $placement, $turn, $castle, $ep);
}

sub _relaxed_key_from_canonical {
  my ($key) = @_;
  return unless defined $key;
  my ($placement, $turn) = split / /, $key;
  return unless defined $placement && defined $turn;
  return join(' ', $placement, $turn);
}

sub _merge_entries {
  my ($target, $key, $entries) = @_;
  return unless defined $key && ref $entries eq 'ARRAY' && @$entries;

  my %merged = map {
    $_->{uci} => {
      uci => $_->{uci},
      weight => ($_->{weight} // 0),
      rank => ($_->{rank} // 0),
    }
  } @{ $target->{$key} || [] };

  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    if (exists $merged{$uci}) {
      $merged{$uci}{weight} += ($entry->{weight} // 0);
      my $rank = $entry->{rank} // 0;
      $merged{$uci}{rank} = $rank if $rank > $merged{$uci}{rank};
    } else {
      $merged{$uci} = {
        uci => $uci,
        weight => ($entry->{weight} // 1),
        rank => ($entry->{rank} // ($entry->{weight} // 1)),
      };
    }
  }

  my @sorted = sort {
    $b->{rank} <=> $a->{rank} || $b->{weight} <=> $a->{weight}
  } values %merged;
  $target->{$key} = \@sorted if @sorted;
}

sub _normalize_uci {
  my ($uci) = @_;
  return unless defined $uci;
  $uci =~ s/\s+//g;
  return unless length $uci;

  if ($uci =~ /^([a-h][1-8])[x-]?([a-h][1-8])(?:=?([nbrqNBRQ]))?[+#]?$/) {
    return lc($1 . $2 . ($3 // ''));
  }
  return;
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
  foreach my $idx (_board_indices()) {
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

sub _board_indices {
  my @indices;
  for my $rank (1 .. 8) {
    my $base = ($rank + 1) * 10;
    push @indices, map { $base + $_ } (1 .. 8);
  }
  return @indices;
}

sub _legal_move_details {
  my ($state) = @_;
  my %details;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;

    my $uci = _normalize_uci($state->decode_move($move));
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

_load_tables();

1;
