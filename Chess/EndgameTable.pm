package Chess::EndgameTable;
use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use JSON::PP;
use List::Util qw(sum);

my %table;

sub _table_path {
  my $module_dir = dirname(__FILE__);
  my $root = File::Spec->catdir($module_dir, '..');
  return File::Spec->catfile($root, 'data', 'endgame_table.json');
}

sub _load_tables {
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
    my $moves = $entry->{moves} || [];
    my @parsed;
    foreach my $move (@$moves) {
      if (ref $move eq 'HASH') {
        my $uci = $move->{uci};
        next unless defined $uci && length $uci;
        my $weight = $move->{weight};
        $weight = 1 unless defined $weight && $weight =~ /\d/;
        push @parsed, { uci => $uci, weight => $weight + 0 };
      } elsif (! ref $move) {
        push @parsed, { uci => $move, weight => 1 };
      }
    }
    $table{$key} = \@parsed if @parsed;
  }
}

BEGIN {
  _load_tables();
}

sub choose_move {
  my ($state) = @_;
  my $key = _canonical_key($state);
  my $entries = $table{$key} or return;
  my $choice = _pick_weighted($entries) or return;
  my $move = eval { $state->encode_move($choice->{uci}) };
  return $move if $move;
  return;
}

sub _canonical_key {
  my ($state) = @_;
  my $fen = $state->get_fen;
  my ($placement, $turn, $castle, $ep) = split / /, $fen;
  return join(' ', $placement, $turn, $castle, $ep);
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

1;
