#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

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

MANIFEST_PATH="$ROOT_DIR/data/lichess_ingest_manifest.json"
ALLOW_DUPLICATE_SOURCE=0

OWN_URL_LOG="$ROOT_DIR/data/lichess_game_urls.log"
OWN_PGN_OUTPUT="$ROOT_DIR/data/lichess_games_export.pgn"
OWN_APPEND=0
CLEAR_OWN_URL_LOG=0

TMP_DIR="/tmp"
KEEP_DOWNLOAD=0

RUN_LICHESS_DB=0
LICHESS_MONTH=""
RUN_OWN_URLS=0

tmp_files=()

usage() {
  cat <<'USAGE'
Usage:
  scripts/data_ingress.sh [options] (LICHESS-DB-PGNS <YYYY-MM> | OWN-URLS) [more flags]

Required source flags (at least one):
  LICHESS-DB-PGNS <YYYY-MM>      Download Lichess monthly dump and run ingest pipeline
  OWN-URLS                        Read data/lichess_game_urls.log and run ingest pipeline

Options:
  --tmp-dir <dir>                 Temp directory (default: /tmp)
  --keep-download                 Keep downloaded monthly archive
  --manifest <path>               Ingest manifest path (default: data/lichess_ingest_manifest.json)
  --allow-duplicate-source        Allow ingesting an already-tracked monthly source

  --own-url-log <path>            URL log path for OWN-URLS (default: data/lichess_game_urls.log)
  --own-pgn-output <path>         PGN output path for OWN-URLS (default: data/lichess_games_export.pgn)
  --own-append                    Append OWN-URLS fetched games to existing own PGN output
  --clear-own-url-log             Truncate own URL log after successful OWN-URLS ingest

  --skip-book                     Skip opening book updates
  --book-output <path>            Opening book output (default: data/opening_book.json)
  --book-max-plies <n>            Max plies per game (default: 18)
  --book-max-games <n>            Max games for book (default: 200000)
  --book-min-position-games <n>   Min games per position (default: 5)
  --book-min-move-games <n>       Min games per move (default: 2)

  --skip-location                 Skip location modifier training
  --location-output <path>        Location table output (default: data/location_modifiers.json)
  --location-games <n>            Max games for location training (default: 5000)
  --location-scale <n>            Scale passed to ./init train-location

Examples:
  scripts/data_ingress.sh LICHESS-DB-PGNS 2025-01
  scripts/data_ingress.sh OWN-URLS
  scripts/data_ingress.sh LICHESS-DB-PGNS 2025-01 OWN-URLS
USAGE
}

cleanup() {
  local path
  for path in "${tmp_files[@]:-}"; do
    if [[ -n "$path" && -f "$path" ]]; then
      rm -f "$path"
    fi
  done
}
trap cleanup EXIT

validate_year_month() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]
}

require_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    echo "$flag requires a value" >&2
    exit 1
  fi
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

  MANIFEST_PATH="$manifest" \
  SOURCE_ID="$source_id" \
  SOURCE_URL="$url" \
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
  source_id       => $source_id,
  url             => $url,
  ingested_at_utc => $stamp,
  mode            => 'append',
  book_output     => $ENV{BOOK_OUTPUT},
  location_output => $ENV{LOCATION_OUTPUT},
  book_max_games  => 0 + ($ENV{BOOK_MAX_GAMES} // 0),
  location_games  => 0 + ($ENV{LOCATION_GAMES} // 0),
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

extract_game_id() {
  local raw="$1"
  local line="${raw#"${raw%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"

  [[ -z "$line" ]] && return 1
  [[ "$line" =~ ^# ]] && return 1

  if [[ "$line" =~ ^([A-Za-z0-9]{8})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$line" =~ ^https?://lichess\.org/([A-Za-z0-9]{8})([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$line" =~ ^/?([A-Za-z0-9]{8})([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

fetch_own_urls_to_pgn() {
  local delta_pgn_output="${1:-}"
  local failed_url_output="${2:-}"

  if [[ ! -f "$OWN_URL_LOG" ]]; then
    echo "List file not found: $OWN_URL_LOG" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$OWN_PGN_OUTPUT")"
  if [[ "$OWN_APPEND" -ne 1 ]]; then
    : > "$OWN_PGN_OUTPUT"
  fi
  if [[ -n "$delta_pgn_output" ]]; then
    mkdir -p "$(dirname "$delta_pgn_output")"
    : > "$delta_pgn_output"
  fi
  if [[ -n "$failed_url_output" ]]; then
    mkdir -p "$(dirname "$failed_url_output")"
    : > "$failed_url_output"
  fi

  declare -A seen=()
  local total=0
  local fetched=0
  local skipped=0
  local failed=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    total=$((total + 1))
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ -z "$trimmed" || "$trimmed" =~ ^# ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    local game_id=""
    if ! game_id="$(extract_game_id "$line")"; then
      skipped=$((skipped + 1))
      echo "Skipping unrecognized line: $line" >&2
      continue
    fi

    if [[ -n "${seen[$game_id]:-}" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    seen[$game_id]=1

    local url="https://lichess.org/game/export/$game_id"
    if [[ -n "$delta_pgn_output" ]]; then
      if curl -fsSL "$url" | tee -a "$OWN_PGN_OUTPUT" >> "$delta_pgn_output"; then
        printf '\n\n' >> "$OWN_PGN_OUTPUT"
        printf '\n\n' >> "$delta_pgn_output"
        fetched=$((fetched + 1))
        echo "Fetched $game_id" >&2
      else
        failed=$((failed + 1))
        if [[ -n "$failed_url_output" ]]; then
          printf '%s\n' "$game_id" >> "$failed_url_output"
        fi
        echo "Failed $game_id ($url)" >&2
      fi
    elif curl -fsSL "$url" >> "$OWN_PGN_OUTPUT"; then
      printf '\n\n' >> "$OWN_PGN_OUTPUT"
      fetched=$((fetched + 1))
      echo "Fetched $game_id" >&2
    else
      failed=$((failed + 1))
      if [[ -n "$failed_url_output" ]]; then
        printf '%s\n' "$game_id" >> "$failed_url_output"
      fi
      echo "Failed $game_id ($url)" >&2
    fi
  done < "$OWN_URL_LOG"

  echo "Done: total=$total fetched=$fetched skipped=$skipped failed=$failed out=$OWN_PGN_OUTPUT" >&2
}

train_location_from_pgn() {
  local pgn_file="$1"
  local -a train_cmd

  train_cmd=(
    "$ROOT_DIR/init"
    train-location
    --output "$LOCATION_OUTPUT"
    --games "$LOCATION_GAMES"
    --accumulate
  )
  if [[ -n "$LOCATION_SCALE" ]]; then
    train_cmd+=(--scale "$LOCATION_SCALE")
  fi

  "${train_cmd[@]}" < "$pgn_file"
}

build_book_delta_and_merge() {
  local pgn_input="$1"
  local delta_book

  delta_book="$(mktemp "$TMP_DIR/opening_book_delta_XXXXXX.json")"
  tmp_files+=("$delta_book")

  perl "$ROOT_DIR/scripts/build_opening_book.pl" \
    --output "$delta_book" \
    --max-plies "$BOOK_MAX_PLIES" \
    --max-games "$BOOK_MAX_GAMES" \
    --min-position-games "$BOOK_MIN_POSITION_GAMES" \
    --min-move-games "$BOOK_MIN_MOVE_GAMES" \
    "$pgn_input"

  perl "$ROOT_DIR/scripts/merge_opening_book.pl" \
    --base "$BOOK_OUTPUT" \
    --delta "$delta_book" \
    --output "$BOOK_OUTPUT"
}

run_own_urls_ingress() {
  local delta_pgn=""
  local failed_urls=""

  delta_pgn="$(mktemp "$TMP_DIR/own_urls_delta_XXXXXX.pgn")"
  failed_urls="$(mktemp "$TMP_DIR/own_urls_failed_XXXXXX.log")"
  tmp_files+=("$delta_pgn" "$failed_urls")

  echo "==> Ingesting own game URLs from $OWN_URL_LOG"
  fetch_own_urls_to_pgn "$delta_pgn" "$failed_urls"

  if [[ ! -s "$delta_pgn" ]]; then
    echo "==> No newly fetched games from OWN-URLS source; skipping local pipeline"
  else
    if [[ "$RUN_BOOK" -eq 1 ]]; then
      build_book_delta_and_merge "$delta_pgn"
    fi

    if [[ "$RUN_LOCATION" -eq 1 ]]; then
      train_location_from_pgn "$delta_pgn"
    fi
  fi

  if [[ "$CLEAR_OWN_URL_LOG" -eq 1 ]]; then
    if [[ -s "$failed_urls" ]]; then
      cp "$failed_urls" "$OWN_URL_LOG"
      local retained_failed
      retained_failed="$(wc -l < "$failed_urls")"
      retained_failed="${retained_failed//[[:space:]]/}"
      echo "==> Cleared processed OWN-URL entries; retained $retained_failed failed entries in $OWN_URL_LOG"
    else
      : > "$OWN_URL_LOG"
      echo "==> Cleared own URL log: $OWN_URL_LOG"
    fi
  fi
}

run_lichess_db_ingress() {
  local month="$1"
  local source_id="lichess_db_standard_rated_${month}.pgn.zst"
  local url="https://database.lichess.org/standard/${source_id}"
  local archive_path=""
  local -a decompress_cmd

  if manifest_contains_source "$MANIFEST_PATH" "$source_id"; then
    if [[ "$ALLOW_DUPLICATE_SOURCE" -eq 1 ]]; then
      echo "==> Source already in manifest, continuing due to --allow-duplicate-source"
    else
      echo "==> Source already ingested, skipping: $source_id"
      return
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required" >&2
    exit 1
  fi

  if command -v zstdcat >/dev/null 2>&1; then
    decompress_cmd=(zstdcat --)
  elif command -v zstd >/dev/null 2>&1; then
    decompress_cmd=(zstd -dc --)
  else
    echo "zstdcat or zstd is required to read .pgn.zst" >&2
    exit 1
  fi

  mkdir -p "$TMP_DIR"
  archive_path="$(mktemp "$TMP_DIR/lichess_standard_${month}_XXXXXX.pgn.zst")"
  if [[ "$KEEP_DOWNLOAD" -ne 1 ]]; then
    tmp_files+=("$archive_path")
  fi

  echo "==> Downloading Lichess PGN archive"
  echo "    URL: $url"
  echo "    Source ID: $source_id"
  echo "    Temp file: $archive_path"
  curl -fL --retry 3 --retry-delay 2 "$url" -o "$archive_path"

  if [[ "$RUN_BOOK" -eq 1 ]]; then
    echo "==> Updating opening book: $BOOK_OUTPUT"
    build_book_delta_and_merge "$archive_path"
  fi

  if [[ "$RUN_LOCATION" -eq 1 ]]; then
    local -a train_cmd
    echo "==> Training location modifiers: $LOCATION_OUTPUT"
    train_cmd=(
      "$ROOT_DIR/init"
      train-location
      --output "$LOCATION_OUTPUT"
      --games "$LOCATION_GAMES"
      --accumulate
    )
    if [[ -n "$LOCATION_SCALE" ]]; then
      train_cmd+=(--scale "$LOCATION_SCALE")
    fi
    "${decompress_cmd[@]}" "$archive_path" | "${train_cmd[@]}"
  fi

  echo "==> Recording source in manifest: $MANIFEST_PATH"
  append_manifest_entry "$MANIFEST_PATH" "$source_id" "$url" >/dev/null

  if [[ "$KEEP_DOWNLOAD" -eq 1 ]]; then
    echo "==> Kept archive: $archive_path"
  else
    echo "==> Removed temp archive"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    LICHESS-DB-PGNS|--lichess-db-pgns)
      if [[ $# -lt 2 ]]; then
        echo "LICHESS-DB-PGNS requires <YYYY-MM>" >&2
        exit 1
      fi
      RUN_LICHESS_DB=1
      LICHESS_MONTH="$2"
      shift 2
      ;;
    OWN-URLS|--own-urls)
      RUN_OWN_URLS=1
      shift
      ;;
    --tmp-dir)
      require_value "--tmp-dir" "${2:-}"
      TMP_DIR="${2:-}"
      shift 2
      ;;
    --keep-download)
      KEEP_DOWNLOAD=1
      shift
      ;;
    --manifest)
      require_value "--manifest" "${2:-}"
      MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    --allow-duplicate-source)
      ALLOW_DUPLICATE_SOURCE=1
      shift
      ;;
    --own-url-log)
      require_value "--own-url-log" "${2:-}"
      OWN_URL_LOG="${2:-}"
      shift 2
      ;;
    --own-pgn-output)
      require_value "--own-pgn-output" "${2:-}"
      OWN_PGN_OUTPUT="${2:-}"
      shift 2
      ;;
    --own-append)
      OWN_APPEND=1
      shift
      ;;
    --clear-own-url-log)
      CLEAR_OWN_URL_LOG=1
      shift
      ;;
    --skip-book)
      RUN_BOOK=0
      shift
      ;;
    --book-output)
      require_value "--book-output" "${2:-}"
      BOOK_OUTPUT="${2:-}"
      shift 2
      ;;
    --book-max-plies)
      require_value "--book-max-plies" "${2:-}"
      BOOK_MAX_PLIES="${2:-}"
      shift 2
      ;;
    --book-max-games)
      require_value "--book-max-games" "${2:-}"
      BOOK_MAX_GAMES="${2:-}"
      shift 2
      ;;
    --book-min-position-games)
      require_value "--book-min-position-games" "${2:-}"
      BOOK_MIN_POSITION_GAMES="${2:-}"
      shift 2
      ;;
    --book-min-move-games)
      require_value "--book-min-move-games" "${2:-}"
      BOOK_MIN_MOVE_GAMES="${2:-}"
      shift 2
      ;;
    --skip-location)
      RUN_LOCATION=0
      shift
      ;;
    --location-output)
      require_value "--location-output" "${2:-}"
      LOCATION_OUTPUT="${2:-}"
      shift 2
      ;;
    --location-games)
      require_value "--location-games" "${2:-}"
      LOCATION_GAMES="${2:-}"
      shift 2
      ;;
    --location-scale)
      require_value "--location-scale" "${2:-}"
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

if [[ "$RUN_LICHESS_DB" -eq 0 && "$RUN_OWN_URLS" -eq 0 ]]; then
  echo "At least one source flag is required: LICHESS-DB-PGNS <YYYY-MM> and/or OWN-URLS" >&2
  usage
  exit 1
fi

if [[ "$RUN_LICHESS_DB" -eq 1 ]] && ! validate_year_month "$LICHESS_MONTH"; then
  echo "Invalid LICHESS-DB-PGNS value: '$LICHESS_MONTH' (expected YYYY-MM)" >&2
  exit 1
fi

if [[ "$RUN_BOOK" -eq 0 && "$RUN_LOCATION" -eq 0 ]]; then
  echo "Nothing to do: both --skip-book and --skip-location are set" >&2
  exit 1
fi

mkdir -p "$TMP_DIR"
mkdir -p "$(dirname "$BOOK_OUTPUT")"
mkdir -p "$(dirname "$LOCATION_OUTPUT")"

if [[ "$RUN_LICHESS_DB" -eq 1 ]]; then
  run_lichess_db_ingress "$LICHESS_MONTH"
fi

if [[ "$RUN_OWN_URLS" -eq 1 ]]; then
  run_own_urls_ingress
fi

echo "==> Data ingress complete"
