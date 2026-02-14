package Chess::Book;
use strict;
use warnings;

use Chess::Constant;
use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;
use List::Util qw(sum);

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
        $by_uci{$uci} += $weight;
      } elsif (! ref $move) {
        my $uci = _normalize_uci($move);
        next unless defined $uci;
        $by_uci{$uci} += 1;
      }
    }
    next unless %by_uci;

    my @parsed = map {
      { uci => $_, weight => $by_uci{$_} }
    } sort { $by_uci{$b} <=> $by_uci{$a} } keys %by_uci;

    _merge_entries(\%fen_book, $key, \@parsed);
    _merge_entries(\%relaxed_fen_book, $relaxed, \@parsed) if defined $relaxed;
  }
}

sub choose_move {
  my ($state) = @_;
  return _lookup_fen_move($state) || _legacy_lookup($state);
}

sub _canonical_key {
  my ($state) = @_;
  my $fen = $state->get_fen;
  my ($placement, $turn, $castle, $ep) = split / /, $fen;
  return join(' ', $placement, $turn, $castle, $ep);
}

sub _lookup_fen_move {
  my ($state) = @_;
  my $key = _canonical_key($state);
  my $entries = $fen_book{$key};
  if (! $entries) {
    my $relaxed = _relaxed_key_from_canonical($key);
    $entries = $relaxed_fen_book{$relaxed} if defined $relaxed;
  }
  return unless $entries && @$entries;

  my $legal = _legal_move_map($state);
  return unless keys %$legal;

  my @legal_entries = grep { exists $legal->{$_->{uci}} } @$entries;
  return unless @legal_entries;

  my $choice = _pick_weighted(\@legal_entries) or return;
  return $legal->{$choice->{uci}};
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

sub _legal_move_map {
  my ($state) = @_;
  my %legal;
  foreach my $move (@{$state->generate_pseudo_moves}) {
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    my $uci = $state->decode_move($move);
    $uci = _normalize_uci($uci);
    next unless defined $uci;
    $legal{$uci} = $move;
  }
  return \%legal;
}

sub _legacy_lookup {
  my ($state) = @_;
  my $pos = join('', map { $Chess::Constant::p2l{$_} }
    @{$state->[0]}[21 .. 28, 31 .. 38, 41 .. 48, 51 .. 58, 61 .. 68, 71 .. 78, 81 .. 88, 91 .. 98]);

  my $entry = $book{$pos} or return;
  my $index = int(rand(@$entry));
  return $entry->[$index];
}

sub _encode_uci {
  my ($state, $uci) = @_;
  return unless defined $uci && length $uci;
  my $move = eval { $state->encode_move($uci) };
  return $move if $move;
  return;
}

sub _pick_weighted {
  my ($entries) = @_;
  my $total = sum(map { $_->{weight} } @$entries);
  return $entries->[rand @$entries] unless $total;

  my $roll = rand($total);
  my $accum = 0;
  foreach my $entry (@$entries) {
    $accum += $entry->{weight};
    return $entry if $roll <= $accum;
  }
  return $entries->[-1];
}

BEGIN {
  _load_json_book();
}

1;
