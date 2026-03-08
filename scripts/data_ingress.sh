#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

BOOK_OUTPUT="$ROOT_DIR/data/opening_book.json"
BOOK_MAX_PLIES=18
BOOK_MAX_GAMES=200000
BOOK_MAX_GAMES_SET=0
BOOK_MIN_POSITION_GAMES=5
BOOK_MIN_MOVE_GAMES=2
BOOK_MAX_GAMES_LICHESS_DB_DEFAULT="${BOOK_MAX_GAMES_LICHESS_DB_DEFAULT:-60000}"
BOOK_BUILD_RETRY_MIN_GAMES="${BOOK_BUILD_RETRY_MIN_GAMES:-10000}"
RUN_BOOK=1

LOCATION_OUTPUT="$ROOT_DIR/data/location_modifiers.local.json"
LOCATION_GAMES=5000
LOCATION_SCALE=""
LOCATION_ADAPTIVE_MIN_GAMES=120
LOCATION_ADAPTIVE_MIN_SCALE=16
RUN_LOCATION=1

MANIFEST_PATH="$ROOT_DIR/data/lichess_ingest_manifest.json"
ALLOW_DUPLICATE_SOURCE=0

OWN_URL_LOG="$ROOT_DIR/data/lichess_game_urls.log"
OWN_PGN_OUTPUT="$ROOT_DIR/data/lichess_games_export.pgn"
OWN_EXPORT_QUERY="${PERLGIGACHESS_OWN_EXPORT_QUERY:-clocks=0&evals=0&moves=1&tags=1&opening=1}"
OWN_APPEND=0
CLEAR_OWN_URL_LOG=0
OWN_URL_WORKERS="${OWN_URL_WORKERS:-1}"

DEFAULT_TMP_DIR="${PERLGIGACHESS_TMP_DIR:-/mnt/throughput/perlgigachess-tmp}"
TMP_DIR="$DEFAULT_TMP_DIR"
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
  --tmp-dir <dir>                 Temp directory (default: $PERLGIGACHESS_TMP_DIR or /mnt/throughput/perlgigachess-tmp)
  --keep-download                 Keep downloaded monthly archive
  --manifest <path>               Ingest manifest path (default: data/lichess_ingest_manifest.json)
  --allow-duplicate-source        Allow ingesting an already-tracked monthly source

  --own-url-log <path>            URL log path for OWN-URLS (default: data/lichess_game_urls.log)
  --own-pgn-output <path>         PGN output path for OWN-URLS (default: data/lichess_games_export.pgn)
  --own-export-query <query>      Query string for Lichess export URL
                                  (default: clocks=0&evals=0&moves=1&tags=1&opening=1)
  --own-append                    Append OWN-URLS fetched games to existing own PGN output
  --clear-own-url-log             Truncate own URL log after successful OWN-URLS ingest
  --own-url-workers <n>           Concurrent OWN-URL fetch workers (default: 1; env: OWN_URL_WORKERS)

  --skip-book                     Skip opening book updates
  --book-output <path>            Opening book output (default: data/opening_book.json)
  --book-max-plies <n>            Max plies per game (default: 18)
  --book-max-games <n>            Max games for book (default: 200000)
                                  Lichess DB ingest uses a safer default cap of 60000 unless overridden
  --book-min-position-games <n>   Min games per position (default: 5)
  --book-min-move-games <n>       Min games per move (default: 2)

  --skip-location                 Skip location modifier training
  --location-output <path>        Location table output (default: data/location_modifiers.local.json)
  --location-games <n>            Max games for location training (default: 5000)
  --location-scale <n>            Scale passed to ./init train-location
  --location-adaptive-min-games <n>  Game-count target for full location scale (default: 120)
  --location-adaptive-min-scale <n>  Minimum auto-scale for tiny OWN-URL samples (default: 16)

Notes:
  - For OWN-URLS, you can run fetch-only mode with both --skip-book and --skip-location.
  - LICHESS-DB-PGNS still requires at least one processing stage (book or location).

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
    elif [[ -n "$path" && -d "$path" ]]; then
      rm -rf "$path"
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

  if [[ "$line" =~ ^([A-Za-z0-9]{8})([A-Za-z0-9]{4})?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$line" =~ ^https?://lichess\.org/([A-Za-z0-9]{8})([A-Za-z0-9]{4})?([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$line" =~ ^https?://lichess\.org/game/export/([A-Za-z0-9]{8})([A-Za-z0-9]{4})?([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$line" =~ ^/?([A-Za-z0-9]{8})([A-Za-z0-9]{4})?([/#?].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

fetch_own_game_to_file() {
  local url="$1"
  local pgn_output="$2"
  local status_output="$3"

  if curl -fsSL "$url" > "$pgn_output"; then
    printf 'ok\n' > "$status_output"
  else
    : > "$pgn_output"
    printf 'fail\n' > "$status_output"
  fi
}

wait_for_worker_slot() {
  local max_workers="$1"
  local -n active_pids_ref="$2"
  local -a remaining=()
  local pid=""

  while (( ${#active_pids_ref[@]} >= max_workers )); do
    if ! wait -n 2>/dev/null; then
      wait "${active_pids_ref[0]}" 2>/dev/null || true
    fi

    remaining=()
    for pid in "${active_pids_ref[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        remaining+=("$pid")
      fi
    done
    active_pids_ref=("${remaining[@]}")
  done
}

own_export_url_for_game_id() {
  local game_id="$1"
  local base_url="https://lichess.org/game/export/$game_id"
  if [[ -z "$OWN_EXPORT_QUERY" ]]; then
    printf '%s\n' "$base_url"
    return
  fi
  if [[ "$OWN_EXPORT_QUERY" == \?* ]]; then
    printf '%s%s\n' "$base_url" "$OWN_EXPORT_QUERY"
    return
  fi
  printf '%s?%s\n' "$base_url" "$OWN_EXPORT_QUERY"
}

fetch_own_urls_to_pgn() {
  local delta_pgn_output="${1:-}"
  local failed_url_output="${2:-}"
  local worker_count="$OWN_URL_WORKERS"

  if [[ ! -f "$OWN_URL_LOG" ]]; then
    echo "List file not found: $OWN_URL_LOG" >&2
    exit 1
  fi

  if ! [[ "$worker_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid OWN_URL_WORKERS value: '$worker_count' (expected integer >= 1)" >&2
    exit 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required" >&2
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
  local -a game_ids=()
  local total=0
  local fetched=0
  local skipped=0
  local failed=0
  local fetch_tmp_dir=""
  local i=0

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
    game_ids+=("$game_id")
  done < "$OWN_URL_LOG"

  if (( ${#game_ids[@]} > 0 )); then
    local -a active_pids=()

    fetch_tmp_dir="$(mktemp -d "$TMP_DIR/own_urls_fetch_XXXXXX")"
    tmp_files+=("$fetch_tmp_dir")

    for i in "${!game_ids[@]}"; do
      local game_id="${game_ids[$i]}"
      local url
      url="$(own_export_url_for_game_id "$game_id")"
      local pgn_part="$fetch_tmp_dir/$i.pgn"
      local status_part="$fetch_tmp_dir/$i.status"

      wait_for_worker_slot "$worker_count" active_pids
      fetch_own_game_to_file "$url" "$pgn_part" "$status_part" &
      local pid="$!"
      active_pids+=("$pid")
    done

    for pid in "${active_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done

    for i in "${!game_ids[@]}"; do
      local game_id="${game_ids[$i]}"
      local url
      url="$(own_export_url_for_game_id "$game_id")"
      local pgn_part="$fetch_tmp_dir/$i.pgn"
      local status_part="$fetch_tmp_dir/$i.status"
      local status="fail"

      if [[ -f "$status_part" ]]; then
        status="$(<"$status_part")"
      fi

      if [[ "$status" == "ok" && -s "$pgn_part" ]]; then
        cat "$pgn_part" >> "$OWN_PGN_OUTPUT"
        printf '\n\n' >> "$OWN_PGN_OUTPUT"
        if [[ -n "$delta_pgn_output" ]]; then
          cat "$pgn_part" >> "$delta_pgn_output"
          printf '\n\n' >> "$delta_pgn_output"
        fi
        fetched=$((fetched + 1))
        echo "Fetched $game_id" >&2
      else
        failed=$((failed + 1))
        if [[ -n "$failed_url_output" ]]; then
          printf '%s\n' "$game_id" >> "$failed_url_output"
        fi
        echo "Failed $game_id ($url)" >&2
      fi
    done
  fi

  echo "Done: total=$total fetched=$fetched skipped=$skipped failed=$failed out=$OWN_PGN_OUTPUT" >&2
}

train_location_from_pgn() {
  local pgn_file="$1"
  local -a train_cmd
  local effective_scale="$LOCATION_SCALE"
  local pgn_games=0

  if command -v rg >/dev/null 2>&1; then
    pgn_games="$(rg -c '^\[Event ' "$pgn_file" || true)"
  else
    pgn_games="$(grep -c '^\[Event ' "$pgn_file" || true)"
  fi
  pgn_games="${pgn_games//[[:space:]]/}"
  if [[ -z "$pgn_games" || ! "$pgn_games" =~ ^[0-9]+$ ]]; then
    pgn_games=0
  fi

  if [[ -z "$effective_scale" && "$pgn_games" -gt 0 && "$LOCATION_ADAPTIVE_MIN_GAMES" =~ ^[0-9]+$ && "$LOCATION_ADAPTIVE_MIN_GAMES" -gt 0 ]]; then
    if [[ "$pgn_games" -lt "$LOCATION_ADAPTIVE_MIN_GAMES" ]]; then
      local scale_top=$((60 * pgn_games))
      local auto_scale=$((scale_top / LOCATION_ADAPTIVE_MIN_GAMES))
      if [[ "$auto_scale" -lt "$LOCATION_ADAPTIVE_MIN_SCALE" ]]; then
        auto_scale="$LOCATION_ADAPTIVE_MIN_SCALE"
      fi
      if [[ "$auto_scale" -gt 60 ]]; then
        auto_scale=60
      fi
      effective_scale="$auto_scale"
      echo "==> Auto-scaled location training for small sample ($pgn_games games): --scale $effective_scale" >&2
    fi
  fi

  train_cmd=(
    "$ROOT_DIR/init"
    train-location
    --output "$LOCATION_OUTPUT"
    --games "$LOCATION_GAMES"
    --accumulate
  )
  if [[ -n "$effective_scale" ]]; then
    train_cmd+=(--scale "$effective_scale")
  fi

  "${train_cmd[@]}" < "$pgn_file"
}

build_book_delta_and_merge() {
  local pgn_input="$1"
  local requested_max_games="${2:-$BOOK_MAX_GAMES}"
  local delta_book
  local current_max_games="$requested_max_games"

  delta_book="$(mktemp "$TMP_DIR/opening_book_delta_XXXXXX.json")"
  tmp_files+=("$delta_book")

  while :; do
    if perl "$ROOT_DIR/scripts/build_opening_book.pl" \
      --output "$delta_book" \
      --max-plies "$BOOK_MAX_PLIES" \
      --max-games "$current_max_games" \
      --min-position-games "$BOOK_MIN_POSITION_GAMES" \
      --min-move-games "$BOOK_MIN_MOVE_GAMES" \
      "$pgn_input"
    then
      last
    fi

    local status="$?"
    local oom_like=0
    if [[ "$status" -eq 137 || "$status" -eq 9 ]]; then
      oom_like=1
    fi

    if [[ "$oom_like" -eq 1 ]]; then
      if ! [[ "$current_max_games" =~ ^[0-9]+$ ]] || [[ "$current_max_games" -le 1 ]]; then
        echo "Opening-book build was killed (exit $status) and cannot auto-retry because --max-games is not reducible." >&2
        return "$status"
      fi
      local next_max_games=$((current_max_games / 2))
      if [[ "$next_max_games" -lt "$BOOK_BUILD_RETRY_MIN_GAMES" ]]; then
        echo "Opening-book build was killed (exit $status) at --max-games $current_max_games." >&2
        echo "Auto-retry would drop below BOOK_BUILD_RETRY_MIN_GAMES=$BOOK_BUILD_RETRY_MIN_GAMES; aborting." >&2
        return "$status"
      fi
      echo "Opening-book build was killed (likely OOM) at --max-games $current_max_games; retrying with --max-games $next_max_games." >&2
      current_max_games="$next_max_games"
      continue
    fi

    echo "Opening-book build failed with exit $status at --max-games $current_max_games." >&2
    return "$status"
  done

  if [[ "$current_max_games" != "$requested_max_games" ]]; then
    echo "==> Opening-book build succeeded after reducing --max-games from $requested_max_games to $current_max_games"
  fi

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
      build_book_delta_and_merge "$delta_pgn" "$BOOK_MAX_GAMES"
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
  if curl -fL --retry 3 --retry-delay 2 "$url" -o "$archive_path"; then
    :
  else
    local curl_status="$?"
    if [[ "$curl_status" -eq 23 ]]; then
      local free_space_human="unknown"
      if command -v df >/dev/null 2>&1; then
        free_space_human="$(df -h "$TMP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
        free_space_human="${free_space_human:-unknown}"
      fi
      echo "Download failed while writing archive to TMP_DIR='$TMP_DIR' (curl exit 23)." >&2
      echo "Likely insufficient free disk space in TMP_DIR (available: $free_space_human)." >&2
      echo "Retry with a larger temp volume via --tmp-dir <path>, e.g. --tmp-dir \"$DEFAULT_TMP_DIR\"." >&2
    fi
    exit "$curl_status"
  fi

  if [[ "$RUN_BOOK" -eq 1 ]]; then
    local book_max_games="$BOOK_MAX_GAMES"
    if [[ "$BOOK_MAX_GAMES_SET" -eq 0 ]] \
      && [[ "$book_max_games" =~ ^[0-9]+$ ]] \
      && [[ "$BOOK_MAX_GAMES_LICHESS_DB_DEFAULT" =~ ^[0-9]+$ ]] \
      && [[ "$book_max_games" -gt "$BOOK_MAX_GAMES_LICHESS_DB_DEFAULT" ]]
    then
      book_max_games="$BOOK_MAX_GAMES_LICHESS_DB_DEFAULT"
      echo "==> Using safer Lichess DB book cap: --max-games $book_max_games (default override; set --book-max-games to change)"
    fi
    echo "==> Updating opening book: $BOOK_OUTPUT"
    build_book_delta_and_merge "$archive_path" "$book_max_games"
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
    --own-export-query)
      require_value "--own-export-query" "${2:-}"
      OWN_EXPORT_QUERY="${2:-}"
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
    --own-url-workers)
      require_value "--own-url-workers" "${2:-}"
      OWN_URL_WORKERS="${2:-}"
      shift 2
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
      BOOK_MAX_GAMES_SET=1
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
    --location-adaptive-min-games)
      require_value "--location-adaptive-min-games" "${2:-}"
      LOCATION_ADAPTIVE_MIN_GAMES="${2:-}"
      shift 2
      ;;
    --location-adaptive-min-scale)
      require_value "--location-adaptive-min-scale" "${2:-}"
      LOCATION_ADAPTIVE_MIN_SCALE="${2:-}"
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

if [[ "$RUN_OWN_URLS" -eq 1 ]] && ! [[ "$OWN_URL_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid OWN_URL_WORKERS/--own-url-workers value: '$OWN_URL_WORKERS' (expected integer >= 1)" >&2
  exit 1
fi

if [[ "$RUN_BOOK" -eq 0 && "$RUN_LOCATION" -eq 0 ]]; then
  if [[ "$RUN_OWN_URLS" -eq 1 && "$RUN_LICHESS_DB" -eq 0 ]]; then
    echo "==> Running OWN-URLS in fetch-only mode (--skip-book --skip-location)"
  else
    echo "Nothing to do: both --skip-book and --skip-location are set" >&2
    echo "Lichess DB ingestion requires at least one processing stage." >&2
    exit 1
  fi
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
