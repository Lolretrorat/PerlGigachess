#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Chess::Eval qw(evaluate_position);
use Chess::EvalTerms qw(piece_values);
use Chess::TableUtil qw(board_indices idx_to_square);
use Chess::State;

my @indices = board_indices();
my $pv = piece_values();

# Material-only consistency and side-to-move sign symmetry.
my $white_to_move = Chess::State->new('4k3/8/8/8/8/8/4Q3/4K3 w - - 0 1');
my $black_to_move = Chess::State->new('4k3/8/8/8/8/8/4Q3/4K3 b - - 0 1');

my $score_white = evaluate_position($white_to_move, {
  board_indices => \@indices,
  piece_values => $pv,
});
my $score_black = evaluate_position($black_to_move, {
  board_indices => \@indices,
  piece_values => $pv,
});

die "Eval consistency failed: white-to-move score should be positive in queen-up material case (got $score_white)\n"
  unless $score_white > 0;
die "Eval consistency failed: expected sign symmetry across side-to-move flip ($score_white vs $score_black)\n"
  unless $score_white == -$score_black;

# Strategic callback should be deterministic and receive consistent context.
my $strategic_cb = sub {
  my ($board, $ctx, $attack_cache) = @_;
  my $derived = 0;
  $derived += ($ctx->{piece_count} // 0);
  $derived += ($ctx->{friendly_non_king} // 0) * 3;
  $derived -= ($ctx->{enemy_non_king} // 0) * 2;
  return $derived;
};

my $score_with_strat_a = evaluate_position($white_to_move, {
  board_indices => \@indices,
  piece_values => $pv,
  strategic_cb => $strategic_cb,
});
my $score_with_strat_b = evaluate_position($white_to_move, {
  board_indices => \@indices,
  piece_values => $pv,
  strategic_cb => $strategic_cb,
});

die "Eval consistency failed: strategic callback path is non-deterministic\n"
  unless $score_with_strat_a == $score_with_strat_b;

die "Eval consistency failed: strategic callback did not affect score as expected\n"
  unless $score_with_strat_a != $score_white;

# PST callback should be deterministic and sensitive to square callback output.
my $pst_score_a = evaluate_position($white_to_move, {
  board_indices => \@indices,
  piece_values => $pv,
  square_of_idx_cb => sub { idx_to_square($_[0], 0) },
  location_bonus_cb => sub {
    my ($piece, $square, $base) = @_;
    return 0 unless defined $square;
    return $square eq 'e2' ? 7 : 0;
  },
});
my $pst_score_b = evaluate_position($white_to_move, {
  board_indices => \@indices,
  piece_values => $pv,
  square_of_idx_cb => sub { idx_to_square($_[0], 0) },
  location_bonus_cb => sub {
    my ($piece, $square, $base) = @_;
    return 0 unless defined $square;
    return $square eq 'e2' ? 7 : 0;
  },
});

die "Eval consistency failed: PST callback path is non-deterministic\n"
  unless $pst_score_a == $pst_score_b;
die "Eval consistency failed: PST callback did not influence score\n"
  unless $pst_score_a != $score_white;

print "Eval consistency regression OK: deterministic scoring, side-to-move symmetry, and callback paths validated\n";
exit 0;
