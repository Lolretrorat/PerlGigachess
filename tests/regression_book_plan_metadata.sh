#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_book_plan_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PLAN_BOOK="$TMP_ROOT/plan_book.json"

cat > "$PLAN_BOOK" <<'JSON'
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -",
    "opening": "Preferred White Repertoire",
    "plan": "Claim the center first and steer toward structured queenside play.",
    "plans": [
      "occupy the center",
      "develop smoothly",
      "keep multiple move-order transpositions available"
    ],
    "moves": [
      {
        "uci": "d2d4",
        "played": 40,
        "weight": 40,
        "white": 26,
        "draw": 8,
        "black": 6,
        "plan_id": "queen_pawn_shell",
        "plan_tags": ["queen-pawn", "structure-first"]
      },
      {
        "uci": "e2e4",
        "played": 18,
        "weight": 18,
        "white": 10,
        "draw": 4,
        "black": 4,
        "plan_id": "open_game_shell",
        "plan_tags": ["open-game", "scotch_preferred"]
      }
    ]
  }
]
JSON

CHESS_BOOK_PATH="$PLAN_BOOK" CHESS_BOOK_POLICY=best perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
  use strict;
  use warnings;

  my $state = Chess::State->new();

  my $move = Chess::Book::choose_move($state);
  die "book move missing\n" unless $move;
  my $uci = $state->decode_move($move);
  die "Expected choose_move to remain d2d4 with metadata present, got $uci\n"
    unless $uci eq "d2d4";

  my $entry = Chess::Book::choose_entry($state);
  die "book entry missing\n" unless ref($entry) eq "HASH";
  die "Expected choose_entry move d2d4, got " . ($entry->{uci} // "undef") . "\n"
    unless ($entry->{uci} // "") eq "d2d4";
  die "Expected opening metadata to survive loading\n"
    unless ($entry->{opening} // "") eq "Preferred White Repertoire";
  die "Expected top-level plan metadata to survive loading\n"
    unless ($entry->{plan} // "") eq "Claim the center first and steer toward structured queenside play.";
  my %chosen_tags = map { $_ => 1 } @{ $entry->{plan_tags} || [] };
  die "Expected chosen move tags to include queen-pawn and structure-first\n"
    unless $chosen_tags{"queen-pawn"} && $chosen_tags{"structure-first"};

  my $lookup = Chess::Book::lookup_plan($state, "e2e4");
  die "lookup_plan for e2e4 missing\n" unless ref($lookup) eq "HASH";
  die "Expected lookup_plan to preserve move-specific plan_id, got "
    . ($lookup->{plan_id} // "undef") . "\n"
    unless ($lookup->{plan_id} // "") eq "open_game_shell";
  my %lookup_tags = map { $_ => 1 } @{ $lookup->{plan_tags} || [] };
  die "Expected lookup tags to include scotch_preferred\n"
    unless $lookup_tags{"scotch_preferred"};
  die "Expected lookup_plan to preserve shared opening metadata\n"
    unless ($lookup->{opening} // "") eq "Preferred White Repertoire";

  print "Book plan metadata regression OK: choose_move is stable and plan metadata is retrievable\n";
'
