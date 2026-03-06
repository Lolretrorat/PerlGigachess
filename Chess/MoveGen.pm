package Chess::MoveGen;
use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(generate_moves);

sub generate_moves {
  my ($state, $type, $opts) = @_;
  $type = lc($type // 'non_evasions');
  $opts = {} unless ref($opts) eq 'HASH';

  my $is_checked = $state->is_checked ? 1 : 0;

  if ($type eq 'legal' || $type eq 'all') {
    return _generate_filtered_legal($state, $opts, sub { 1 });
  }

  if ($type eq 'evasions') {
    return [] unless $is_checked;
    return _generate_filtered_legal($state, $opts, sub { 1 });
  }

  if ($type eq 'captures') {
    return _generate_filtered_legal($state, $opts, sub {
      my ($move) = @_;
      return _is_capture_like($state, $move);
    });
  }

  if ($type eq 'quiets') {
    return _generate_filtered_legal($state, $opts, sub {
      my ($move) = @_;
      return !_is_capture_like($state, $move);
    });
  }

  # NON_EVASIONS in this mailbox implementation is simply legal moves
  # when not in check; otherwise legal evasions.
  if ($type eq 'non_evasions') {
    return [] if $is_checked;
    return _generate_filtered_legal($state, $opts, sub { 1 });
  }

  return _generate_filtered_legal($state, $opts, sub { 1 });
}

sub _generate_filtered_legal {
  my ($state, $opts, $predicate) = @_;
  my $pseudo = $opts->{pseudo_moves};
  $pseudo = $state->generate_pseudo_moves unless ref($pseudo) eq 'ARRAY';
  my $move_filter_cb = $opts->{move_filter_cb};

  my $move_key_cb = $opts->{move_key_cb};
  my $exclude = $opts->{exclude_move_keys};
  my $has_exclude = ref($exclude) eq 'HASH' && keys %{$exclude};

  my @legal;
  for my $move (@{$pseudo}) {
    next unless ref($move) eq 'ARRAY';
    next if defined $predicate && !$predicate->($move);
    next if defined $move_filter_cb && !$move_filter_cb->($move);
    if ($has_exclude && defined $move_key_cb) {
      my $move_key = $move_key_cb->($move);
      next if defined $move_key && exists $exclude->{$move_key};
    }
    my $new_state = $state->make_move($move);
    next unless defined $new_state;
    push @legal, $move;
  }
  return \@legal;
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
