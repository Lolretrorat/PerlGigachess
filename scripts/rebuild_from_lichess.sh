#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

URL=""
TMP_DIR="/tmp"
KEEP_DOWNLOAD=0

BOOK_OUTPUT="$ROOT_DIR/data/opening_book.json"
BOOK_MAX_PLIES=18
BOOK_MAX_GAMES=200000
BOOK_MIN_POSITION_GAMES=5
BOOK_MIN_MOVE_GAMES=2
RUN_BOOK=1

LOCATION_OUTPUT="$ROOT_DIR/data/location_modifiers.json"
LOCATION_GAMES=5000
LOCATION_SCALE=""
RUN_LOCATION=1

APPEND_MODE=0
MANIFEST_PATH="$ROOT_DIR/data/lichess_ingest_manifest.json"
CONFIRM_SOURCE=""
ALLOW_DUPLICATE_SOURCE=0

usage() {
  cat <<USAGE
Usage:
  scripts/rebuild_from_lichess.sh --url <lichess .pgn.zst url> [options]

Options:
  --tmp-dir <dir>                  Download directory (default: /tmp)
  --keep-download                  Keep downloaded archive instead of deleting

  --append                         Append month data to existing outputs
  --manifest <path>                Ingest manifest JSON (default: data/lichess_ingest_manifest.json)
  --confirm-source <source_id>     Required in --append mode; must match URL basename
  --allow-duplicate-source         Allow re-ingesting a source already listed in manifest

  --skip-book                      Skip opening book rebuild
  --book-output <path>             Output JSON (default: data/opening_book.json)
  --book-max-plies <n>             Max plies per game (default: 18)
  --book-max-games <n>             Max games for book (default: 200000)
  --book-min-position-games <n>    Min games per position (default: 5)
  --book-min-move-games <n>        Min games per move (default: 2)

  --skip-location                  Skip location modifier training
  --location-output <path>         Output JSON (default: data/location_modifiers.json)
  --location-games <n>             Max games for location training (default: 5000)
  --location-scale <n>             Scale passed to ./init train-location

Examples:
  scripts/rebuild_from_lichess.sh \
    --url https://database.lichess.org/standard/lichess_db_standard_rated_2025-01.pgn.zst

  scripts/rebuild_from_lichess.sh \
    --append \
    --confirm-source lichess_db_standard_rated_2025-01.pgn.zst \
    --url https://database.lichess.org/standard/lichess_db_standard_rated_2025-01.pgn.zst
USAGE
}

source_id_from_url() {
  local raw="$1"
  local trimmed="${raw%%\?*}"
  basename "$trimmed"
}

manifest_contains_source() {
  local manifest="$1"
  local source_id="$2"

  perl -e '
    use strict;
    use warnings;
    use JSON::PP;

    my ($manifest, $source_id) = @ARGV;
    exit 1 unless -e $manifest;

    open my $fh, q{<}, $manifest or exit 1;
    local $/;
    my $raw = <$fh>;
    close $fh;

    my $data = eval { JSON::PP->new->decode($raw) };
    exit 1 if $@ || ref $data ne q{ARRAY};

    for my $entry (@$data) {
      next unless ref $entry eq q{HASH};
      my $s = $entry->{source_id};
      next unless defined $s;
      if ($s eq $source_id) {
        exit 0;
      }
    }

    exit 1;
  ' "$manifest" "$source_id"
}

append_manifest_entry() {
  local manifest="$1"
  local source_id="$2"
  local url="$3"
  local append_mode="$4"

  MANIFEST_PATH="$manifest" \
  SOURCE_ID="$source_id" \
  SOURCE_URL="$url" \
  APPEND_MODE="$append_mode" \
  BOOK_OUTPUT="$BOOK_OUTPUT" \
  LOCATION_OUTPUT="$LOCATION_OUTPUT" \
  BOOK_MAX_GAMES="$BOOK_MAX_GAMES" \
  LOCATION_GAMES="$LOCATION_GAMES" \
  perl <<'PERL'
use strict;
use warnings;
use JSON::PP;

my $manifest = $ENV{MANIFEST_PATH} // die "Missing MANIFEST_PATH\n";
my $source_id = $ENV{SOURCE_ID} // die "Missing SOURCE_ID\n";
my $url = $ENV{SOURCE_URL} // die "Missing SOURCE_URL\n";
my $append_mode = $ENV{APPEND_MODE} // 0;

my $entries = [];
if (-e $manifest) {
  open my $fh, '<', $manifest or die "Cannot read $manifest: $!\n";
  local $/;
  my $raw = <$fh>;
  close $fh;

  my $decoded = eval { JSON::PP->new->decode($raw) };
  die "Invalid manifest JSON: $manifest\n" if $@ || ref $decoded ne 'ARRAY';
  $entries = $decoded;
}

for my $entry (@$entries) {
  next unless ref $entry eq 'HASH';
  next unless defined $entry->{source_id};
  if ($entry->{source_id} eq $source_id) {
    print "manifest_exists=1\n";
    exit 0;
  }
}

my $stamp = scalar gmtime();
push @$entries, {
  source_id      => $source_id,
  url            => $url,
  ingested_at_utc => $stamp,
  mode           => ($append_mode ? 'append' : 'replace'),
  book_output    => $ENV{BOOK_OUTPUT},
  location_output => $ENV{LOCATION_OUTPUT},
  book_max_games => 0 + ($ENV{BOOK_MAX_GAMES} // 0),
  location_games => 0 + ($ENV{LOCATION_GAMES} // 0),
};

my ($dir) = $manifest =~ m{^(.*)/[^/]+$};
if (defined $dir && length $dir && !-d $dir) {
  require File::Path;
  File::Path::make_path($dir);
}

open my $out, '>', $manifest or die "Cannot write $manifest: $!\n";
print {$out} JSON::PP->new->canonical->pretty->encode($entries);
close $out;

print "manifest_exists=0\n";
PERL
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      URL="${2:-}"
      shift 2
      ;;
    --tmp-dir)
      TMP_DIR="${2:-}"
      shift 2
      ;;
    --keep-download)
      KEEP_DOWNLOAD=1
      shift
      ;;
    --append)
      APPEND_MODE=1
      shift
      ;;
    --manifest)
      MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    --confirm-source)
      CONFIRM_SOURCE="${2:-}"
      shift 2
      ;;
    --allow-duplicate-source)
      ALLOW_DUPLICATE_SOURCE=1
      shift
      ;;
    --skip-book)
      RUN_BOOK=0
      shift
      ;;
    --book-output)
      BOOK_OUTPUT="${2:-}"
      shift 2
      ;;
    --book-max-plies)
      BOOK_MAX_PLIES="${2:-}"
      shift 2
      ;;
    --book-max-games)
      BOOK_MAX_GAMES="${2:-}"
      shift 2
      ;;
    --book-min-position-games)
      BOOK_MIN_POSITION_GAMES="${2:-}"
      shift 2
      ;;
    --book-min-move-games)
      BOOK_MIN_MOVE_GAMES="${2:-}"
      shift 2
      ;;
    --skip-location)
      RUN_LOCATION=0
      shift
      ;;
    --location-output)
      LOCATION_OUTPUT="${2:-}"
      shift 2
      ;;
    --location-games)
      LOCATION_GAMES="${2:-}"
      shift 2
      ;;
    --location-scale)
      LOCATION_SCALE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac

done

if [[ -z "$URL" ]]; then
  echo "--url is required" >&2
  usage
  exit 1
fi

if [[ "$RUN_BOOK" -eq 0 && "$RUN_LOCATION" -eq 0 ]]; then
  echo "Nothing to do: both --skip-book and --skip-location are set" >&2
  exit 1
fi

SOURCE_ID="$(source_id_from_url "$URL")"
if [[ "$APPEND_MODE" -eq 1 ]]; then
  if [[ -z "$CONFIRM_SOURCE" ]]; then
    echo "--confirm-source is required in --append mode (expected: $SOURCE_ID)" >&2
    exit 1
  fi
  if [[ "$CONFIRM_SOURCE" != "$SOURCE_ID" ]]; then
    echo "--confirm-source mismatch: expected '$SOURCE_ID', got '$CONFIRM_SOURCE'" >&2
    exit 1
  fi

  if manifest_contains_source "$MANIFEST_PATH" "$SOURCE_ID"; then
    if [[ "$ALLOW_DUPLICATE_SOURCE" -eq 1 ]]; then
      echo "==> Source already in manifest, continuing due to --allow-duplicate-source"
    else
      echo "==> Source already ingested, skipping: $SOURCE_ID"
      exit 0
    fi
  fi
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

decompress_cmd=()
if command -v zstdcat >/dev/null 2>&1; then
  decompress_cmd=(zstdcat --)
elif command -v zstd >/dev/null 2>&1; then
  decompress_cmd=(zstd -dc --)
else
  echo "zstdcat or zstd is required to read .pgn.zst" >&2
  exit 1
fi

mkdir -p "$TMP_DIR"
ARCHIVE_PATH="$(mktemp "$TMP_DIR/lichess_standard_XXXXXX.pgn.zst")"
DELTA_BOOK_PATH=""

cleanup() {
  if [[ -n "$DELTA_BOOK_PATH" && -f "$DELTA_BOOK_PATH" ]]; then
    rm -f "$DELTA_BOOK_PATH"
  fi
  if [[ "$KEEP_DOWNLOAD" -eq 0 && -f "$ARCHIVE_PATH" ]]; then
    rm -f "$ARCHIVE_PATH"
  fi
}
trap cleanup EXIT

echo "==> Downloading Lichess PGN archive"
echo "    URL: $URL"
echo "    Source ID: $SOURCE_ID"
echo "    Temp file: $ARCHIVE_PATH"
curl -fL --retry 3 --retry-delay 2 "$URL" -o "$ARCHIVE_PATH"

if [[ "$RUN_BOOK" -eq 1 ]]; then
  if [[ "$APPEND_MODE" -eq 1 ]]; then
    DELTA_BOOK_PATH="$(mktemp "$TMP_DIR/opening_book_delta_XXXXXX.json")"
    echo "==> Building monthly opening delta at $DELTA_BOOK_PATH"
    perl "$ROOT_DIR/scripts/build_opening_book.pl" \
      --output "$DELTA_BOOK_PATH" \
      --max-plies "$BOOK_MAX_PLIES" \
      --max-games "$BOOK_MAX_GAMES" \
      --min-position-games "$BOOK_MIN_POSITION_GAMES" \
      --min-move-games "$BOOK_MIN_MOVE_GAMES" \
      "$ARCHIVE_PATH"

    echo "==> Merging opening delta into $BOOK_OUTPUT"
    perl "$ROOT_DIR/scripts/merge_opening_book.pl" \
      --base "$BOOK_OUTPUT" \
      --delta "$DELTA_BOOK_PATH" \
      --output "$BOOK_OUTPUT"
  else
    echo "==> Rebuilding opening book at $BOOK_OUTPUT"
    perl "$ROOT_DIR/scripts/build_opening_book.pl" \
      --output "$BOOK_OUTPUT" \
      --max-plies "$BOOK_MAX_PLIES" \
      --max-games "$BOOK_MAX_GAMES" \
      --min-position-games "$BOOK_MIN_POSITION_GAMES" \
      --min-move-games "$BOOK_MIN_MOVE_GAMES" \
      "$ARCHIVE_PATH"
  fi
fi

if [[ "$RUN_LOCATION" -eq 1 ]]; then
  echo "==> Training location modifiers at $LOCATION_OUTPUT"
  train_cmd=("$ROOT_DIR/init" train-location --output "$LOCATION_OUTPUT" --games "$LOCATION_GAMES")
  if [[ -n "$LOCATION_SCALE" ]]; then
    train_cmd+=(--scale "$LOCATION_SCALE")
  fi
  if [[ "$APPEND_MODE" -eq 1 ]]; then
    train_cmd+=(--accumulate)
  fi

  "${decompress_cmd[@]}" "$ARCHIVE_PATH" | "${train_cmd[@]}"
fi

if [[ "$APPEND_MODE" -eq 1 ]]; then
  echo "==> Recording source in manifest: $MANIFEST_PATH"
  append_manifest_entry "$MANIFEST_PATH" "$SOURCE_ID" "$URL" "$APPEND_MODE" >/dev/null
fi

echo "==> Completed"
if [[ "$KEEP_DOWNLOAD" -eq 1 ]]; then
  echo "    Kept archive: $ARCHIVE_PATH"
else
  echo "    Removed temp archive"
fi
