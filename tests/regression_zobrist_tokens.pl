#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::Zobrist qw(
  zobrist_castle_token
  zobrist_empty_key
  zobrist_ep_token
  zobrist_is_key
  zobrist_key_hex
  zobrist_piece_token
  zobrist_turn_token
);

my $empty = zobrist_empty_key();
ok(zobrist_is_key($empty), 'empty zobrist key is recognized as a key');
is(length($empty), 8, 'zobrist keys are eight bytes');
is(zobrist_key_hex($empty), '0000000000000000', 'empty key hex rendering is stable');

my $turn_a = zobrist_turn_token();
my $turn_b = zobrist_turn_token();
is($turn_a, $turn_b, 'turn token is deterministic');
ok(zobrist_is_key($turn_a), 'turn token is a valid zobrist key');

my $piece_a = zobrist_piece_token(0, 0);
my $piece_b = zobrist_piece_token(0, 0);
my $piece_c = zobrist_piece_token(0, 1);
is($piece_a, $piece_b, 'piece token is deterministic for the same piece and square');
ok($piece_a ne $piece_c, 'piece token varies across squares');

my $castle_ks = zobrist_castle_token(0, 0);
my $castle_qs = zobrist_castle_token(0, 1);
ok($castle_ks ne $castle_qs, 'castle tokens differ across sides');

my $ep_a = zobrist_ep_token(12);
my $ep_b = zobrist_ep_token(12);
ok(zobrist_is_key($ep_a), 'ep token is a valid zobrist key');
is($ep_a, $ep_b, 'ep token is deterministic');

ok(!defined zobrist_piece_token(-1, 0), 'invalid piece index returns undef');
ok(!defined zobrist_piece_token(0, 64), 'invalid square returns undef for piece token');
ok(!defined zobrist_castle_token(2, 0), 'invalid castle color returns undef');
ok(!defined zobrist_ep_token(64), 'invalid ep square returns undef');
ok(!zobrist_is_key('short'), 'non-eight-byte string is not a zobrist key');

done_testing();
