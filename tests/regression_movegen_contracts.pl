#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Chess::State;

sub sorted_uci {
  my ($state, $moves) = @_;
  return sort map { $state->decode_move($_) } @{$moves};
}

sub is_capture_like {
  my ($state, $move) = @_;
  my $board = $state->[Chess::State::BOARD];
  my $to_piece = $board->[$move->[1]] // 0;
  return 1 if $to_piece < 0;

  my $from_piece = $board->[$move->[0]] // 0;
  return 0 unless abs($from_piece) == 1;
  return 0 unless defined $state->[Chess::State::EP];
  return 0 unless $move->[1] == $state->[Chess::State::EP];
  my $delta = $move->[1] - $move->[0];
  return ($delta == 9 || $delta == 11) ? 1 : 0;
}

# In-check contract: legal == evasions, non_evasions empty.
my $checked = Chess::State->new('4k3/8/8/8/8/8/4r3/4K3 w - - 0 1');
my $checked_legal = $checked->generate_moves_by_type('legal');
my $checked_evasions = $checked->generate_moves_by_type('evasions');
my $checked_non = $checked->generate_moves_by_type('non_evasions');

my @legal_uci = sorted_uci($checked, $checked_legal);
my @evasion_uci = sorted_uci($checked, $checked_evasions);

die "Movegen contract failed: checked legal list unexpectedly empty\n" unless @legal_uci;
die "Movegen contract failed: non_evasions must be empty while checked\n" if @{$checked_non};
die "Movegen contract failed: evasions differ from legal moves while checked\n"
  unless "@legal_uci" eq "@evasion_uci";

# Not-in-check contract: evasions empty, non_evasions == legal.
my $quiet = Chess::State->new();
my $quiet_legal = $quiet->generate_moves_by_type('legal');
my $quiet_evasions = $quiet->generate_moves_by_type('evasions');
my $quiet_non = $quiet->generate_moves_by_type('non_evasions');

my @quiet_legal_uci = sorted_uci($quiet, $quiet_legal);
my @quiet_non_uci = sorted_uci($quiet, $quiet_non);

die "Movegen contract failed: evasions must be empty when not in check\n" if @{$quiet_evasions};
die "Movegen contract failed: non_evasions differ from legal while not checked\n"
  unless "@quiet_legal_uci" eq "@quiet_non_uci";

# Capture/quiets partition, including en-passant capture classification.
my $ep_state = Chess::State->new('4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1');
my $ep_legal = $ep_state->generate_moves_by_type('legal');
my $ep_caps = $ep_state->generate_moves_by_type('captures');
my $ep_quiets = $ep_state->generate_moves_by_type('quiets');

my %seen;
for my $m (@{$ep_caps}) {
  my $uci = $ep_state->decode_move($m);
  $seen{$uci}++;
  die "Movegen contract failed: capture list contains non-capture $uci\n"
    unless is_capture_like($ep_state, $m);
}
for my $m (@{$ep_quiets}) {
  my $uci = $ep_state->decode_move($m);
  die "Movegen contract failed: quiet list contains capture $uci\n"
    if is_capture_like($ep_state, $m);
  $seen{$uci}++;
}

for my $m (@{$ep_legal}) {
  my $uci = $ep_state->decode_move($m);
  die "Movegen contract failed: legal move $uci missing from captures/quiets partition\n"
    unless $seen{$uci};
}

die "Movegen contract failed: en-passant capture e5d6 missing from captures list\n"
  unless grep { $_ eq 'e5d6' } map { $ep_state->decode_move($_) } @{$ep_caps};

print "Movegen contract regression OK: legal/evasion/non-evasion and captures/quiets behavior is consistent\n";
exit 0;
