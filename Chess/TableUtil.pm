package Chess::TableUtil;
use strict;
use warnings;
use Chess::State ();

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
  canonical_fen_key
  relaxed_fen_key
  normalize_uci_move
  merge_weighted_moves
  idx_to_square
  board_indices
);

my @BOARD_INDICES = _build_board_indices();

sub canonical_fen_key {
  my ($state) = @_;
  if (ref($state) eq 'Chess::State') {
    my $cached = $state->[Chess::State::FEN_KEY];
    return $cached if defined $cached;
    my $legacy = $state->[Chess::State::STATE_KEY];
    return $legacy if _looks_like_fen_key($legacy);
  }
  my $fen = $state->get_fen;
  my $pos = -1;
  for (1 .. 4) {
    $pos = index($fen, ' ', $pos + 1);
    last if $pos < 0;
  }
  my $key = $pos > 0 ? substr($fen, 0, $pos) : $fen;
  if (ref($state) eq 'Chess::State') {
    $state->[Chess::State::FEN_KEY] = $key;
  }
  return $key;
}

sub _looks_like_fen_key {
  my ($value) = @_;
  return unless defined $value && !ref($value);
  return if $value !~ /^[\x20-\x7e]+$/;
  my $spaces = ($value =~ tr/ //);
  return $spaces >= 3 ? 1 : 0;
}

sub relaxed_fen_key {
  my ($key) = @_;
  return unless defined $key;
  my $pos = index($key, ' ');
  return unless $pos > 0;
  my $next = index($key, ' ', $pos + 1);
  return substr($key, 0, $next > 0 ? $next : length($key));
}

sub normalize_uci_move {
  my ($uci) = @_;
  return unless defined $uci;
  $uci =~ s/\s+//g;
  return unless length $uci;

  if ($uci =~ /^([a-h][1-8])[x-]?([a-h][1-8])(?:=?([nbrqNBRQ]))?[+#]?$/) {
    return lc($1 . $2 . ($3 // ''));
  }
  return;
}

sub merge_weighted_moves {
  my ($target, $key, $entries, $opts) = @_;
  return unless defined $key && ref $entries eq 'ARRAY' && @$entries;
  $opts ||= {};
  my $with_rank = $opts->{with_rank} ? 1 : 0;
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

  if ($with_rank) {
    foreach my $entry (@$entries) {
      next unless ref $entry eq 'HASH';
      my $uci = $entry->{uci} // next;
      my $delta_weight = ($entry->{weight} // 0);
      if (exists $index_by_uci{$uci}) {
        my $slot = $current->[$index_by_uci{$uci}];
        $slot->{weight} = 0 unless defined $slot->{weight};
        $slot->{rank} = 0 unless defined $slot->{rank};
        my $changed = 0;
        if ($delta_weight != 0) {
          $slot->{weight} += $delta_weight;
          $changed = 1;
        }
        my $rank = $entry->{rank} // 0;
        if ($rank > ($slot->{rank} // 0)) {
          $slot->{rank} = $rank;
          $changed = 1;
        }
        $touched{$uci} = 1 if $changed;
      } else {
        if (! $has_current) {
          $current = [];
          $target->{$key} = $current;
          $has_current = 1;
        }
        my $new_slot = {
          uci    => $uci,
          weight => ($entry->{weight} // 1),
          rank   => ($entry->{rank} // ($entry->{weight} // 1)),
        };
        push @$current, $new_slot;
        $index_by_uci{$uci} = $#$current;
        $touched{$uci} = 1;
      }
    }
    _reorder_touched($current, \%index_by_uci, \%touched, \&_cmp_rank_weight)
      if %touched;
    return;
  }

  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    my $delta_weight = ($entry->{weight} // 0);
    if (exists $index_by_uci{$uci}) {
      $current->[$index_by_uci{$uci}]{weight} = 0
        unless defined $current->[$index_by_uci{$uci}]{weight};
      if ($delta_weight != 0) {
        $current->[$index_by_uci{$uci}]{weight} += $delta_weight;
        $touched{$uci} = 1;
      }
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
    };
    $new_slot->{weight} += $delta_weight;
    push @$current, $new_slot;
    $index_by_uci{$uci} = $#$current;
    $touched{$uci} = 1;
  }

  _reorder_touched($current, \%index_by_uci, \%touched, \&_cmp_weight_only)
    if %touched;
}

sub idx_to_square {
  my ($idx, $turn) = @_;
  my $file = ($idx % 10) - 1;
  return unless $file >= 0 && $file < 8;
  my $rank = $turn ? 10 - int($idx / 10) : int($idx / 10) - 1;
  return unless $rank >= 1 && $rank <= 8;
  return chr(ord('a') + $file) . $rank;
}

sub board_indices {
  return @BOARD_INDICES;
}

sub _build_board_indices {
  my @indices;
  for my $rank (1 .. 8) {
    my $base = ($rank + 1) * 10;
    push @indices, map { $base + $_ } (1 .. 8);
  }
  return @indices;
}

sub _reorder_touched {
  my ($entries, $index_by_uci, $touched, $cmp_cb) = @_;
  return unless ref $entries eq 'ARRAY' && @$entries;
  return unless ref $cmp_cb eq 'CODE';

  my @reorder = sort {
    ($index_by_uci->{$a} // 0) <=> ($index_by_uci->{$b} // 0)
  } grep { exists $index_by_uci->{$_} } keys %$touched;

  foreach my $uci (@reorder) {
    my $idx = $index_by_uci->{$uci};
    next unless defined $idx;
    while ($idx > 0 && $cmp_cb->($entries->[$idx], $entries->[$idx - 1]) < 0) {
      @$entries[$idx, $idx - 1] = @$entries[$idx - 1, $idx];
      $index_by_uci->{$entries->[$idx]{uci}} = $idx if defined $entries->[$idx]{uci};
      $index_by_uci->{$entries->[$idx - 1]{uci}} = $idx - 1 if defined $entries->[$idx - 1]{uci};
      $idx--;
    }
  }
}

sub _cmp_rank_weight {
  my ($left, $right) = @_;
  return ($right->{rank} // 0) <=> ($left->{rank} // 0)
    || ($right->{weight} // 0) <=> ($left->{weight} // 0);
}

sub _cmp_weight_only {
  my ($left, $right) = @_;
  return ($right->{weight} // 0) <=> ($left->{weight} // 0);
}

1;
