#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Chess::State;

sub move_list_uci {
  my ($state) = @_;
  return sort map { $state->decode_move($_) } @{$state->generate_moves_by_type('legal')};
}

my @fens = (
  'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  'r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1',
  '4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1',
);

for my $fen (@fens) {
  my $state = Chess::State->new($fen);
  my $base_fen = $state->get_fen;
  my $base_key = $state->[Chess::State::STATE_KEY];
  my @base_moves = move_list_uci($state);

  my $legal = $state->generate_moves_by_type('legal');
  for my $move (@{$legal}) {
    my @undo_stack;
    my $uci = $state->decode_move($move);

    my $did = $state->do_move($move, \@undo_stack);
    die "Do/undo integrity failed: do_move rejected legal move $uci in $fen\n"
      unless defined $did;
    die "Do/undo integrity failed: undo stack not populated for $uci in $fen\n"
      unless @undo_stack == 1;

    my $undid = $state->undo_move(\@undo_stack);
    die "Do/undo integrity failed: undo_move failed for $uci in $fen\n"
      unless defined $undid;
    die "Do/undo integrity failed: undo stack not drained for $uci in $fen\n"
      if @undo_stack;

    die "Do/undo integrity failed: FEN mismatch after undo for $uci in $fen\n"
      unless $state->get_fen eq $base_fen;
    die "Do/undo integrity failed: STATE_KEY mismatch after undo for $uci in $fen\n"
      unless $state->[Chess::State::STATE_KEY] eq $base_key;
  }

  my @after_moves = move_list_uci($state);
  die "Do/undo integrity failed: legal move list changed after do/undo cycle for $fen\n"
    unless "@after_moves" eq "@base_moves";
}

# make_move should be immutable for the original object.
my $immut = Chess::State->new();
my $immut_fen = $immut->get_fen;
my ($first_move) = @{$immut->generate_moves_by_type('legal')};
my $next = $immut->make_move($first_move);
die "Do/undo integrity failed: make_move returned undef for legal move\n"
  unless defined $next;
die "Do/undo integrity failed: make_move mutated original state\n"
  unless $immut->get_fen eq $immut_fen;
die "Do/undo integrity failed: make_move returned unchanged next state\n"
  if $next->get_fen eq $immut_fen;

print "State do/undo regression OK: legal do/undo fully restores FEN, key, and move list; make_move remains immutable\n";
exit 0;
