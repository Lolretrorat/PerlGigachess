#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::State;
use Chess::TableUtil qw(
  board_indices
  canonical_fen_key
  idx_to_square
  merge_weighted_moves
  normalize_uci_move
  relaxed_fen_key
);

my $state = Chess::State->new('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 7 12');
is(
  canonical_fen_key($state),
  'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -',
  'canonical_fen_key strips halfmove and fullmove counters'
);
is(
  relaxed_fen_key(canonical_fen_key($state)),
  'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w',
  'relaxed_fen_key strips castling and ep data'
);

is(normalize_uci_move('e2-e4+'), 'e2e4', 'normalize_uci_move normalizes SAN-ish separators');
is(normalize_uci_move('a7a8=Q#'), 'a7a8q', 'normalize_uci_move preserves promotion piece');
ok(!defined normalize_uci_move('bad move'), 'normalize_uci_move rejects invalid input');

my %book;
merge_weighted_moves(\%book, 'startpos', [
  { uci => 'e2e4', weight => 4 },
  { uci => 'd2d4', weight => 6 },
]);
is_deeply(
  $book{startpos},
  [
    { uci => 'd2d4', weight => 6 },
    { uci => 'e2e4', weight => 4 },
  ],
  'merge_weighted_moves orders entries by descending weight'
);

merge_weighted_moves(\%book, 'startpos', [
  { uci => 'e2e4', weight => 5 },
  { uci => 'c2c4', weight => 3 },
]);
is_deeply(
  $book{startpos},
  [
    { uci => 'e2e4', weight => 9 },
    { uci => 'd2d4', weight => 6 },
    { uci => 'c2c4', weight => 3 },
  ],
  'merge_weighted_moves accumulates weights and reorders touched entries'
);

my %ranked_book;
merge_weighted_moves(\%ranked_book, 'ranked', [
  { uci => 'g1f3', weight => 2, rank => 2 },
  { uci => 'c2c4', weight => 6, rank => 1 },
], { with_rank => 1 });
merge_weighted_moves(\%ranked_book, 'ranked', [
  { uci => 'g1f3', weight => 1, rank => 4 },
], { with_rank => 1 });
is_deeply(
  $ranked_book{ranked},
  [
    { uci => 'g1f3', weight => 3, rank => 4 },
    { uci => 'c2c4', weight => 6, rank => 1 },
  ],
  'merge_weighted_moves with rank prefers higher rank before raw weight'
);

my @indices = board_indices();
is(scalar @indices, 64, 'board_indices returns 64 playable squares');
is(idx_to_square($indices[0], 0), 'a1', 'idx_to_square maps first white-oriented board index');
is(idx_to_square($indices[-1], 0), 'h8', 'idx_to_square maps last white-oriented board index');

done_testing();
