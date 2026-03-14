#!/usr/bin/env perl
use v5.16;
use strict;
use warnings;

use FindBin qw($RealBin);
use lib "$RealBin/..";

use Test::More;

use Chess::State;

my $start_fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
my $start = Chess::State->new($start_fen);
is($start->get_fen, $start_fen, 'start position round-trips through FEN');

my $encoded_e2e4 = $start->encode_move('e2e4');
ok($encoded_e2e4, 'encodes a basic opening move');
is($start->decode_move($encoded_e2e4), 'e2e4', 'decode_move round-trips encoded move');

my $castle_fen = 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1';
my $castle_state = Chess::State->new($castle_fen);
my $castle_move = $castle_state->encode_move('e1g1');
ok(defined $castle_move->[3], 'castling move is marked as special');
is($castle_state->decode_move($castle_move), 'e1g1', 'decode_move preserves castling notation');

my @undo_stack;
my $before_fen = $start->get_fen;
ok($start->do_move($encoded_e2e4, \@undo_stack), 'do_move applies a legal move in place');
is($start->get_fen, 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1', 'do_move updates board and en-passant state');
ok($start->undo_move(\@undo_stack), 'undo_move restores prior position');
is($start->get_fen, $before_fen, 'undo_move restores original FEN');

my $ep_fen = '4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1';
my $ep_state = Chess::State->new($ep_fen);
my $ep_move = $ep_state->encode_move('e5d6');
my @ep_stack;
ok($ep_state->do_move($ep_move, \@ep_stack), 'en-passant capture is legal with do_move');
ok($ep_state->undo_move(\@ep_stack), 'en-passant move can be undone');
is($ep_state->get_fen, $ep_fen, 'undo_move restores en-passant position exactly');

my $clone_source = Chess::State->new($castle_fen);
my $clone = $clone_source->clone;
is($clone->get_fen, $clone_source->get_fen, 'clone starts from identical state');
my @clone_stack;
ok($clone->do_move($castle_move, \@clone_stack), 'clone can be mutated independently');
is($clone_source->get_fen, $castle_fen, 'mutating clone leaves original state untouched');
ok($clone->undo_move(\@clone_stack), 'clone undo succeeds');
is($clone->get_fen, $castle_fen, 'clone undo returns clone to original FEN');

my $black_fen = 'r3k2r/ppp2ppp/8/3pP3/8/8/PPP2PPP/R3K2R b KQkq e3 4 12';
my $black_state = Chess::State->new($black_fen);
is($black_state->get_fen, $black_fen, 'black-to-move FEN with en-passant round-trips');
my $encoded_black = $black_state->encode_move('d5e4');
ok($encoded_black, 'black-side move encodes correctly');
is($black_state->decode_move($encoded_black), 'd5e4', 'black-side move decodes correctly');

done_testing();
