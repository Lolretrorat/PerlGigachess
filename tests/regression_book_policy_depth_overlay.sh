#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_book_policy_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_BOOK="$TMP_ROOT/base_book.json"
OVERLAY_BOOK="$TMP_ROOT/overlay_book.json"
DEPTH_BOOK="$TMP_ROOT/depth_book.json"

cat > "$BASE_BOOK" <<'JSON'
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -",
    "moves": [
      { "uci": "e2e4", "played": 10, "weight": 10, "white": 5, "draw": 2, "black": 3 },
      { "uci": "d2d4", "played": 30, "weight": 30, "white": 20, "draw": 5, "black": 5 }
    ]
  }
]
JSON

cat > "$OVERLAY_BOOK" <<'JSON'
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -",
    "moves": [
      { "uci": "d2d4", "played": 60, "weight": 60, "white": 42, "draw": 10, "black": 8 }
    ]
  }
]
JSON

cat > "$DEPTH_BOOK" <<'JSON'
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -",
    "moves": [
      { "uci": "d2d4", "played": 25, "weight": 25, "white": 15, "draw": 5, "black": 5 }
    ]
  },
  {
    "key": "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6",
    "moves": [
      { "uci": "g1f3", "played": 20, "weight": 20, "white": 12, "draw": 4, "black": 4 }
    ]
  }
]
JSON

best_move="$(
  CHESS_BOOK_PATH="$BASE_BOOK" CHESS_BOOK_POLICY=best perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    my $move = Chess::Book::choose_move($state);
    die "book move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$best_move" == "d2d4" ]] || {
  echo "Expected best policy move d2d4, got: $best_move" >&2
  exit 1
}

overlay_move="$(
  CHESS_BOOK_PATH="$BASE_BOOK" CHESS_BOOK_EXTRA_PATHS="$OVERLAY_BOOK" CHESS_BOOK_POLICY=best perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    my $move = Chess::Book::choose_move($state);
    die "overlay move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$overlay_move" == "d2d4" ]] || {
  echo "Expected overlay move d2d4, got: $overlay_move" >&2
  exit 1
}

depth_move="$(
  CHESS_BOOK_PATH="$DEPTH_BOOK" CHESS_BOOK_POLICY=best CHESS_BOOK_MAX_PLIES=1 perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    $state = $state->make_move($state->encode_move("e2e4"));
    $state = $state->make_move($state->encode_move("e7e5"));
    my $move = Chess::Book::choose_move($state);
    print((defined($move) ? $state->decode_move($move) : "none"), "\n");
  '
)"
[[ "$depth_move" == "none" ]] || {
  echo "Expected depth gate to suppress book move, got: $depth_move" >&2
  exit 1
}

echo "Book regression OK: policy, depth gating, and overlay loading behave as expected"
