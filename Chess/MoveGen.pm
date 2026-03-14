package Chess::MoveGen;
use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(generate_moves collect_legal_moves);

sub generate_moves {
  my ($state, $type, $opts) = @_;
  $type = lc($type // 'non_evasions');
  $opts = {} unless ref($opts) eq 'HASH';

  my $is_checked = $state->is_checked ? 1 : 0;
  my $groups;

  if ($type eq 'legal' || $type eq 'all') {
    $groups = collect_legal_moves($state, $opts);
    return $groups->{legal};
  }

  if ($type eq 'evasions') {
    return [] unless $is_checked;
    $groups = collect_legal_moves($state, $opts);
    return $groups->{legal};
  }

  if ($type eq 'captures') {
    $groups = collect_legal_moves($state, $opts);
    return $groups->{captures};
  }

  if ($type eq 'quiets') {
    $groups = collect_legal_moves($state, $opts);
    return $groups->{quiets};
  }

  # NON_EVASIONS in this mailbox implementation is simply legal moves
  # when not in check; otherwise legal evasions.
  if ($type eq 'non_evasions') {
    return [] if $is_checked;
    $groups = collect_legal_moves($state, $opts);
    return $groups->{legal};
  }

  $groups = collect_legal_moves($state, $opts);
  return $groups->{legal};
}

sub collect_legal_moves {
  my ($state, $opts) = @_;
  $opts = {} unless ref($opts) eq 'HASH';

  my $pseudo = $opts->{pseudo_moves};
  $pseudo = $state->generate_pseudo_moves unless ref($pseudo) eq 'ARRAY';
  my $move_filter_cb = $opts->{move_filter_cb};

  my $move_key_cb = $opts->{move_key_cb};
  my $exclude = $opts->{exclude_move_keys};
  my $has_exclude = ref($exclude) eq 'HASH' && keys %{$exclude};

  my @legal;
  my @captures;
  my @quiets;
  my @undo_stack;
  for my $move (@{$pseudo}) {
    next unless ref($move) eq 'ARRAY';
    next if defined $move_filter_cb && !$move_filter_cb->($move);
    if ($has_exclude && defined $move_key_cb) {
      my $move_key = $move_key_cb->($move);
      next if defined $move_key && exists $exclude->{$move_key};
    }
    my $is_capture = _is_capture_like($state, $move) ? 1 : 0;
    next unless defined $state->do_move($move, \@undo_stack);
    push @legal, $move;
    if ($is_capture) {
      push @captures, $move;
    } else {
      push @quiets, $move;
    }
    $state->undo_move(\@undo_stack);
  }
  return {
    legal => \@legal,
    captures => \@captures,
    quiets => \@quiets,
  };
}

sub _is_capture_like {
  my ($state, $move) = @_;
  my $board = $state->[0];
  my $to_piece = $board->[$move->[1]] // 0;
  return 1 if $to_piece < 0;

  # En-passant capture: pawn moves diagonally into EP square.
  my $from_piece = $board->[$move->[0]] // 0;
  return 0 unless abs($from_piece) == 1;
  return 0 unless defined $state->[3];
  return 0 unless $move->[1] == $state->[3];
  my $delta = $move->[1] - $move->[0];
  return ($delta == 9 || $delta == 11) ? 1 : 0;
}

1;
