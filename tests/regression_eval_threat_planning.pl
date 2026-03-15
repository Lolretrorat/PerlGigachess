#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;
use List::Util qw(max);

use Chess::Constant;
use Chess::Engine ();
use Chess::EvalTerms qw(
  king_aggression_for_piece
  threatened_material_summary
  unsafe_capture_penalty
  king_danger_for_piece
  piece_values
);
use Chess::Heuristics qw(:engine);
use Chess::State;

my $pawn_tension = Chess::State->new('4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1');
my $pawn_summary = threatened_material_summary($pawn_tension->[Chess::State::BOARD], {});
ok(
  ($pawn_summary->{threatened_ours} // 0) > 0
    && ($pawn_summary->{threatened_theirs} // 0) > 0,
  'threat summary counts attacked pawns for both sides'
);

my $defense_state = Chess::State->new('6k1/7p/8/4b3/8/8/8/R5K1 w - - 0 1');
my $defense_move = $defense_state->encode_move('a1a2');
my %defense_cache;
my $defense_pre = threatened_material_summary($defense_state->[Chess::State::BOARD], \%defense_cache);
my $defense_king_danger = Chess::Engine::_king_danger_for_piece(
  $defense_state->[Chess::State::BOARD],
  OPP_KING,
  \%defense_cache,
);
my ($is_response, $is_strategic) = Chess::Engine::_quiet_move_threat_flags(
  $defense_state->[Chess::State::BOARD],
  $defense_pre,
  $defense_king_danger,
  $defense_state->make_move($defense_move),
);
ok($is_response, 'quiet rook lift is recognized as a threat-response move');
ok(!$is_strategic, 'quiet defensive move is not mislabeled as a strategic threat');

my $pressure_state = Chess::State->new('rnbq1rk1/pppp1ppp/5n2/4p2Q/2B1P3/5N2/PPPP1PPP/RNB2RK1 w - - 0 1');
my %pressure_cache;
my $pressure_pre = threatened_material_summary($pressure_state->[Chess::State::BOARD], \%pressure_cache);
my $pressure_king_danger = Chess::Engine::_king_danger_for_piece(
  $pressure_state->[Chess::State::BOARD],
  OPP_KING,
  \%pressure_cache,
);
my (undef, $ng5_is_strategic) = Chess::Engine::_quiet_move_threat_flags(
  $pressure_state->[Chess::State::BOARD],
  $pressure_pre,
  $pressure_king_danger,
  $pressure_state->make_move($pressure_state->encode_move('f3g5')),
);
my (undef, $kh1_is_strategic) = Chess::Engine::_quiet_move_threat_flags(
  $pressure_state->[Chess::State::BOARD],
  $pressure_pre,
  $pressure_king_danger,
  $pressure_state->make_move($pressure_state->encode_move('g1h1')),
);
ok($ng5_is_strategic, 'quiet attacking move is preserved as a strategic threat');
ok(!$kh1_is_strategic, 'king shuffle is not treated as a strategic threat');

my $white_ahead = Chess::State->new('rnbqkbnr/pppp1ppp/8/4p3/2B1P3/5N2/PPPP1PPP/RNBQ1RK1 w kq - 0 1');
my $black_ahead = Chess::State->new('rnbq1rk1/pppp1ppp/5n2/2b1p3/4P3/8/PPPP1PPP/RNBQKBNR w KQ - 0 1');
cmp_ok(
  Chess::Engine::_evaluate_board($white_ahead),
  '>',
  0,
  'balanced development score rewards our lead in development'
);
cmp_ok(
  Chess::Engine::_evaluate_board($black_ahead),
  '<',
  0,
  'balanced development score penalizes the same lag when the opponent has the lead'
);

my $central_king = Chess::State->new('4k3/8/8/3K4/8/8/8/8 w - - 0 1');
my $corner_king = Chess::State->new('4k3/8/8/8/8/8/8/3K4 w - - 0 1');
cmp_ok(
  king_aggression_for_piece($central_king->[Chess::State::BOARD], KING, 2),
  '>',
  king_aggression_for_piece($corner_king->[Chess::State::BOARD], KING, 2),
  'endgame king activity depends on king square instead of only material count'
);

my $unsafe_capture_state = Chess::State->new('rnbqkbnr/ppp2ppp/3pp3/8/3P4/3Q4/PPP1PPPP/RNB1KBNR w KQkq - 0 5');
my $unsafe_capture_move = $unsafe_capture_state->encode_move('d3h7');
my $unsafe_from_piece = $unsafe_capture_state->[Chess::State::BOARD]->[$unsafe_capture_move->[0]];
my $unsafe_to_piece = $unsafe_capture_state->[Chess::State::BOARD]->[$unsafe_capture_move->[1]];
my $unsafe_after = $unsafe_capture_state->make_move($unsafe_capture_move);
my $own_king_before = king_danger_for_piece($unsafe_capture_state->[Chess::State::BOARD], KING);
my $own_king_after = king_danger_for_piece($unsafe_after->[Chess::State::BOARD], OPP_KING);
my $enemy_king_after = king_danger_for_piece($unsafe_after->[Chess::State::BOARD], KING);
my $expected_capture_penalty = int(
  max(0, abs(piece_values()->{$unsafe_from_piece}) - abs(piece_values()->{$unsafe_to_piece}))
    * UNSAFE_CAPTURE_DEFENDED_SCALE
);
is($own_king_before, $own_king_after, 'post-capture king danger is measured on OPP_KING after the side-to-move flip');
cmp_ok($enemy_king_after, '>', $own_king_after, 'capture increases enemy king danger without inflating our own');
is(
  unsafe_capture_penalty($unsafe_capture_state, $unsafe_capture_move, $unsafe_from_piece, $unsafe_to_piece),
  $expected_capture_penalty,
  'unsafe capture penalty ignores enemy king pressure when our own king exposure is unchanged',
);

ok(Chess::Engine::_root_plan_tags_apply_at_ply(0), 'root plan tags apply on the root side to move');
ok(!Chess::Engine::_root_plan_tags_apply_at_ply(1), 'root plan tags are not reused on the opponent reply ply');
ok(Chess::Engine::_root_plan_tags_apply_at_ply(2), 'root plan tags can still guide the root side follow-up ply');
ok(!Chess::Engine::_root_plan_tags_apply_at_ply(3), 'root plan tags are not carried deeper into the tree');

my $volatility_pressure = Chess::Engine::_volatility_pressure_score({
  volatile => 1,
  near_tie_root => 1,
  aspiration_expansions => 2,
  forced_or_easy_root => 0,
  stable_best_hits => 0,
  score_delta => SCORE_STABILITY_DELTA * 7,
});
cmp_ok($volatility_pressure, '>=', 2, 'volatile roots accumulate enough pressure to claim extra think time');
is(
  Chess::Engine::_volatility_extension_ms(
    {
      has_clock => 1,
      panic_level => 0,
      budget_ms => 500,
    },
    $volatility_pressure,
    600,
  ),
  int(500 * VOLATILITY_LONG_THINK_EXTRA_SHARE * ($volatility_pressure / 2)),
  'volatile roots receive an extra soft-budget grant when hard-budget slack exists',
);
is(
  Chess::Engine::_volatility_extension_ms(
    {
      has_clock => 1,
      panic_level => 1,
      budget_ms => 500,
    },
    $volatility_pressure,
    600,
  ),
  0,
  'panic time controls suppress volatility-driven long-think extensions',
);
ok(
  !Chess::Engine::_can_stop_after_target_depth(1, 3, 3),
  'critical positions do not stop immediately at target depth even when prior iterations were stable'
);
ok(
  Chess::Engine::_can_stop_after_target_depth(0, 1, 1),
  'stable non-critical positions can stop at target depth'
);

done_testing();
