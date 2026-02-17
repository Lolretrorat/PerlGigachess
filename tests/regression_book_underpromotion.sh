#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_book_underpromo_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PGN_INPUT="$TMP_ROOT/underpromotion_check.pgn"
BOOK_OUTPUT="$TMP_ROOT/opening_book.json"

cat > "$PGN_INPUT" <<'PGN'
[Event "Underpromotion SAN Regression"]
[Site "https://example.invalid/underpromotion"]
[Date "2026.02.17"]
[Round "-"]
[White "RegressionWhite"]
[Black "RegressionBlack"]
[Result "1/2-1/2"]
[SetUp "1"]
[FEN "8/1P6/6K1/4k3/8/8/8/8 w - - 0 1"]

1. b8=B+ 1/2-1/2
PGN

build_output="$(
  perl "$ROOT_DIR/scripts/build_opening_book.pl" \
    --output "$BOOK_OUTPUT" \
    --max-plies 1 \
    --max-games 1 \
    --min-position-games 1 \
    --min-move-games 1 \
    "$PGN_INPUT"
)"

printf '%s\n' "$build_output" | grep -q '^games_parsed=1$'
printf '%s\n' "$build_output" | grep -q '^games_processed=1$'

perl -MJSON::PP -e '
  use strict;
  use warnings;
  my ($path) = @ARGV;
  open my $fh, q{<}, $path or die "Cannot read $path: $!\n";
  local $/;
  my $data = JSON::PP->new->decode(<$fh>);
  close $fh;
  my $found = 0;
  for my $entry (@{$data}) {
    next unless ref $entry eq q{HASH};
    my $moves = $entry->{moves};
    next unless ref $moves eq q{ARRAY};
    for my $move (@{$moves}) {
      next unless ref $move eq q{HASH};
      if (($move->{uci} // q{}) eq q{b7b8b}) {
        $found = 1;
        last;
      }
    }
    last if $found;
  }
  exit($found ? 0 : 1);
' "$BOOK_OUTPUT"

echo "Book regression OK: SAN underpromotion with check (b8=B+) is parsed and stored as b7b8b"
