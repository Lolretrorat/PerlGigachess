package Chess::MoveGen;
use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(generate_moves);

sub generate_moves {
  my ($state, $type) = @_;
  $type = lc($type // 'non_evasions');

  my @pseudo = @{$state->generate_pseudo_moves};
  my @legal = grep { defined $state->make_move($_) } @pseudo;

  if ($type eq 'legal' || $type eq 'all') {
    return \@legal;
  }

  if ($type eq 'evasions') {
    return [] unless $state->is_checked;
    return \@legal;
  }

  if ($type eq 'captures') {
    my @captures = grep { _is_capture_like($state, $_) } @legal;
    return \@captures;
  }

  if ($type eq 'quiets') {
    my @quiets = grep { !_is_capture_like($state, $_) } @legal;
    return \@quiets;
  }

  # NON_EVASIONS in this mailbox implementation is simply legal moves
  # when not in check; otherwise legal evasions.
  if ($type eq 'non_evasions') {
    return $state->is_checked ? [] : \@legal;
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
