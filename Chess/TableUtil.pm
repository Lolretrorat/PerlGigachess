package Chess::TableUtil;
use strict;
use warnings;

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
  my $fen = $state->get_fen;
  my ($placement, $turn, $castle, $ep) = split / /, $fen;
  return join(' ', $placement, $turn, $castle, $ep);
}

sub relaxed_fen_key {
  my ($key) = @_;
  return unless defined $key;
  my ($placement, $turn) = split / /, $key;
  return unless defined $placement && defined $turn;
  return join(' ', $placement, $turn);
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

  if ($with_rank) {
    my %merged = map {
      $_->{uci} => {
        uci    => $_->{uci},
        weight => ($_->{weight} // 0),
        rank   => ($_->{rank} // 0),
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
          uci    => $uci,
          weight => ($entry->{weight} // 1),
          rank   => ($entry->{rank} // ($entry->{weight} // 1)),
        };
      }
    }

    my @sorted = sort {
      $b->{rank} <=> $a->{rank} || $b->{weight} <=> $a->{weight}
    } values %merged;
    $target->{$key} = \@sorted if @sorted;
    return;
  }

  my %weights = map { $_->{uci} => ($_->{weight} || 0) } @{ $target->{$key} || [] };
  foreach my $entry (@$entries) {
    next unless ref $entry eq 'HASH';
    my $uci = $entry->{uci} // next;
    my $weight = $entry->{weight} // 0;
    $weights{$uci} += $weight;
  }

  my @merged = map {
    { uci => $_, weight => $weights{$_} }
  } sort { $weights{$b} <=> $weights{$a} } keys %weights;
  $target->{$key} = \@merged if @merged;
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

1;
