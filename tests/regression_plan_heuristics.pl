#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$RealBin/..";

use Test::More;

use Chess::Book ();
use Chess::Plan qw(
  is_quiet_plan_move
  pressure_score_for_side
  quiet_move_order_bonus
  state_plan_tags
);
use Chess::State;

my $italian = Chess::State->new();
for my $uci (qw(e2e4 e7e5 g1f3 b8c6 f1c4 f8c5)) {
  $italian = $italian->make_move($italian->encode_move($uci));
}

my $castle_bonus = quiet_move_order_bonus($italian, $italian->encode_move('e1g1'), {
  plan_tags => [qw(castle_kingside develop_minors pressure_center)],
});
my $shuffle_bonus = quiet_move_order_bonus($italian, $italian->encode_move('h2h3'), {
  plan_tags => [qw(castle_kingside develop_minors pressure_center)],
});
cmp_ok($castle_bonus, '>', $shuffle_bonus, 'castling outranks a waiting move in an open-game setup');

my $center_break_bonus = quiet_move_order_bonus($italian, $italian->encode_move('d2d4'), {
  plan_tags => [qw(center_break pressure_center develop_minors)],
});
cmp_ok($center_break_bonus, '>', $shuffle_bonus, 'center break outranks a waiting move when plan tags call for it');

my $after_d4 = $italian->make_move($italian->encode_move('d2d4'));
ok(
  is_quiet_plan_move($italian, $italian->encode_move('d2d4'), $after_d4, {
    plan_tags => [qw(center_break pressure_center develop_minors)],
  }),
  'd4 is recognized as a plan-building quiet move in the Scotch shell',
);

my $after_h3 = $italian->make_move($italian->encode_move('h2h3'));
ok(
  !is_quiet_plan_move($italian, $italian->encode_move('h2h3'), $after_h3, {
    plan_tags => [qw(center_break pressure_center develop_minors)],
  }),
  'h3 is not misclassified as a plan-building quiet move',
);

my $loose_queen = Chess::State->new('r5k1/pp3ppp/2n5/3q4/3P4/2N2Q2/PPP2PPP/R5K1 w - - 0 1');
my $pressure_us = pressure_score_for_side($loose_queen->[Chess::State::BOARD], 1, -1);
my $pressure_them = pressure_score_for_side($loose_queen->[Chess::State::BOARD], -1, 1);
cmp_ok($pressure_us, '>', 0, 'pressure score notices the loose enemy queen');
cmp_ok($pressure_us, '>', $pressure_them, 'pressure score is asymmetric in the expected tactical direction');

{
  my $tmp_dir = tempdir(CLEANUP => 1);
  my $base_book = File::Spec->catfile($tmp_dir, 'base_book.json');
  my $style_overlay = File::Spec->catfile($tmp_dir, 'style_overlay.json');

  open my $base_fh, '>', $base_book or die "Cannot write $base_book: $!\n";
  print {$base_fh} <<'JSON';
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3",
    "moves": [
      { "uci": "d7d5", "played": 25, "weight": 25, "white": 10, "draw": 5, "black": 10 }
    ]
  }
]
JSON
  close $base_fh;

  open my $overlay_fh, '>', $style_overlay or die "Cannot write $style_overlay: $!\n";
  print {$overlay_fh} <<'JSON';
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3",
    "opening": "Dutch Defense",
    "plan": "Fight for e4 and dark squares with ...f5.",
    "plan_tags": ["dark_square_control", "kingside_space"],
    "moves": [
      {
        "uci": "f7f5",
        "played": 240,
        "weight": 240,
        "white": 10,
        "draw": 20,
        "black": 210,
        "plan_tags": ["dark_square_control", "kingside_space", "pressure_center"]
      }
    ]
  }
]
JSON
  close $overlay_fh;

  local $ENV{CHESS_BOOK_PATH} = $base_book;
  local $ENV{CHESS_BOOK_STYLE_OVERLAY_PATH} = $style_overlay;
  local $ENV{CHESS_BOOK_USE_STYLE_OVERLAY} = 1;
  Chess::Book::reload();

  my $d4_state = Chess::State->new();
  $d4_state = $d4_state->make_move($d4_state->encode_move('d2d4'));
  my $tags = state_plan_tags($d4_state);
  my %tag = map { $_ => 1 } @{$tags || []};
  ok($tag{dark_square_control}, 'state_plan_tags picks up overlay plan tags through Chess::Book');
  ok($tag{kingside_space}, 'state_plan_tags retains shared plan tags from the overlay entry');
  ok($tag{pressure_center}, 'state_plan_tags retains move-specific plan tags from the chosen overlay move');
}

Chess::Book::reload();

done_testing();
