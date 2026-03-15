#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_book_policy_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_BOOK="$TMP_ROOT/base_book.json"
OVERLAY_BOOK="$TMP_ROOT/overlay_book.json"
DEPTH_BOOK="$TMP_ROOT/depth_book.json"
STYLE_BASE_BOOK="$TMP_ROOT/style_base_book.json"
STYLE_PLAN_OVERLAY="$TMP_ROOT/style_plan_overlay.json"

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

cat > "$STYLE_BASE_BOOK" <<'JSON'
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3",
    "moves": [
      { "uci": "d7d5", "played": 300, "weight": 300, "white": 130, "draw": 40, "black": 130 }
    ]
  }
]
JSON

cat > "$STYLE_PLAN_OVERLAY" <<'JSON'
[
  {
    "key": "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3",
    "opening": "Dutch Defense",
    "plan": "Fight for dark squares immediately and develop behind the f-pawn.",
    "plan_tags": ["dark_square_control", "kingside_space", "castle_kingside"],
    "moves": [
      {
        "uci": "f7f5",
        "played": 240000,
        "weight": 240000,
        "white": 10000,
        "draw": 24000,
        "black": 206000,
        "plan_tags": ["dark_square_control", "kingside_space", "castle_kingside"]
      }
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

style_default_move="$(
  CHESS_BOOK_PATH="$STYLE_BASE_BOOK" CHESS_BOOK_STYLE_OVERLAY_PATH="$STYLE_PLAN_OVERLAY" CHESS_BOOK_POLICY=best perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    $state = $state->make_move($state->encode_move("d2d4"));
    my $move = Chess::Book::choose_move($state);
    die "style default move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$style_default_move" == "d7d5" ]] || {
  echo "Expected default style-overlay-off move d7d5, got: $style_default_move" >&2
  exit 1
}

style_opt_in_move="$(
  CHESS_BOOK_PATH="$STYLE_BASE_BOOK" CHESS_BOOK_STYLE_OVERLAY_PATH="$STYLE_PLAN_OVERLAY" CHESS_BOOK_POLICY=best CHESS_BOOK_USE_STYLE_OVERLAY=1 perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    $state = $state->make_move($state->encode_move("d2d4"));
    my $move = Chess::Book::choose_move($state);
    die "style opt-in move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$style_opt_in_move" == "f7f5" ]] || {
  echo "Expected opt-in style overlay move f7f5, got: $style_opt_in_move" >&2
  exit 1
}

style_plan_tags="$(
  CHESS_BOOK_PATH="$STYLE_BASE_BOOK" CHESS_BOOK_STYLE_OVERLAY_PATH="$STYLE_PLAN_OVERLAY" CHESS_BOOK_POLICY=best perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    $state = $state->make_move($state->encode_move("d2d4"));
    my $tags = Chess::Book::plan_tags_for_state($state);
    print join(",", @{$tags || []}), "\n";
  '
)"
[[ "$style_plan_tags" == *"dark_square_control"* && "$style_plan_tags" == *"kingside_space"* ]] || {
  echo "Expected overlay plan tags to remain visible for search guidance, got: $style_plan_tags" >&2
  exit 1
}

dutch_followup_move="$(
  CHESS_BOOK_POLICY=best CHESS_BOOK_USE_STYLE_OVERLAY=1 perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    $state = $state->make_move($state->encode_move("d2d4"));
    $state = $state->make_move($state->encode_move("f7f5"));
    $state = $state->make_move($state->encode_move("c2c4"));
    my $move = Chess::Book::choose_move($state);
    die "Dutch follow-up move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$dutch_followup_move" == "g8f6" ]] || {
  echo "Expected Dutch follow-up move g8f6, got: $dutch_followup_move" >&2
  exit 1
}

scotch_entry_move="$(
  CHESS_BOOK_POLICY=best CHESS_BOOK_USE_STYLE_OVERLAY=1 perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    $state = $state->make_move($state->encode_move("e2e4"));
    $state = $state->make_move($state->encode_move("e7e5"));
    $state = $state->make_move($state->encode_move("g1f3"));
    $state = $state->make_move($state->encode_move("b8c6"));
    my $move = Chess::Book::choose_move($state);
    die "Scotch entry move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$scotch_entry_move" == "d2d4" ]] || {
  echo "Expected Scotch entry move d2d4, got: $scotch_entry_move" >&2
  exit 1
}

scotch_followup_move="$(
  CHESS_BOOK_POLICY=best CHESS_BOOK_USE_STYLE_OVERLAY=1 perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    for my $uci (qw(e2e4 e7e5 g1f3 b8c6 d2d4 e5d4 f3d4 g8f6 b1c3)) {
      $state = $state->make_move($state->encode_move($uci));
    }
    my $move = Chess::Book::choose_move($state);
    die "Scotch follow-up move missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$scotch_followup_move" == "f8b4" ]] || {
  echo "Expected Scotch follow-up move f8b4, got: $scotch_followup_move" >&2
  exit 1
}

scotch_bc5_reply="$(
  CHESS_BOOK_POLICY=best CHESS_BOOK_USE_STYLE_OVERLAY=1 perl -I"$ROOT_DIR" -MChess::Book -MChess::State -e '
    use strict;
    use warnings;
    my $state = Chess::State->new();
    for my $uci (qw(e2e4 e7e5 g1f3 b8c6 d2d4 e5d4 f3d4 f8c5)) {
      $state = $state->make_move($state->encode_move($uci));
    }
    my $move = Chess::Book::choose_move($state);
    die "Scotch Bc5 reply missing\n" unless $move;
    print $state->decode_move($move), "\n";
  '
)"
[[ "$scotch_bc5_reply" == "c2c3" ]] || {
  echo "Expected Scotch Bc5 reply c2c3, got: $scotch_bc5_reply" >&2
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

echo "Book regression OK: policy, depth gating, metadata-preserving overlay loading, and deeper Dutch/Scotch preferences behave as expected"
