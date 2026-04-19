#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_oom_retry_reg_XXXXXX)"
stdout_log="$TMP_ROOT/stdout.log"
stderr_log="$TMP_ROOT/stderr.log"
trap 'rm -rf "$TMP_ROOT"' EXIT

root="$TMP_ROOT/repo"
mock_bin="$TMP_ROOT/mockbin"
tmp_stage="$TMP_ROOT/tmp"
call_log="$TMP_ROOT/perl_calls.log"
state_file="$TMP_ROOT/perl_state"
mkdir -p "$root/scripts" "$root/data" "$mock_bin" "$tmp_stage"

cp "$ROOT_DIR/scripts/data_ingress.sh" "$root/scripts/data_ingress.sh"
: > "$root/scripts/build_opening_book.pl"
: > "$root/scripts/merge_opening_book.pl"

cat > "$mock_bin/perl" <<'MOCKPERL'
#!/usr/bin/env bash
set -euo pipefail

script="${1:-}"
printf '%s\n' "$*" >> "${MOCK_PERL_CALL_LOG:?}"

if [[ "$script" == */scripts/build_opening_book.pl ]]; then
  count=0
  if [[ -f "${MOCK_PERL_STATE:?}" ]]; then
    count="$(<"${MOCK_PERL_STATE}")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "${MOCK_PERL_STATE:?}"

  output=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--output" ]]; then
      output="$arg"
      break
    fi
    prev="$arg"
  done

  if [[ "$count" -eq 1 ]]; then
    exit 137
  fi

  printf '[]\n' > "$output"
  exit 0
fi

if [[ "$script" == */scripts/merge_opening_book.pl ]]; then
  output=""
  prev=""
  for arg in "$@"; do
    if [[ "$prev" == "--output" ]]; then
      output="$arg"
      break
    fi
    prev="$arg"
  done
  printf '[]\n' > "$output"
  exit 0
fi

exec /usr/bin/perl "$@"
MOCKPERL
chmod +x "$mock_bin/perl"

cat > "$mock_bin/curl" <<'MOCKCURL'
#!/usr/bin/env bash
set -euo pipefail

cat <<'PGN'
[Event "Mock"]
[Site "https://lichess.org/mock0001"]
[Date "2026.03.14"]
[Round "-"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 1-0
PGN
MOCKCURL
chmod +x "$mock_bin/curl"

printf 'mock0001\n' > "$TMP_ROOT/urls.log"

PATH="$mock_bin:$PATH" \
MOCK_PERL_CALL_LOG="$call_log" \
MOCK_PERL_STATE="$state_file" \
"$root/scripts/data_ingress.sh" \
  OWN-URLS \
  --own-url-log "$TMP_ROOT/urls.log" \
  --own-pgn-output "$TMP_ROOT/own.pgn" \
  --skip-location \
  --book-max-games 60000 \
  --tmp-dir "$tmp_stage" >"$stdout_log" 2>"$stderr_log"

grep -Fq -- "--max-games 60000" "$call_log"
grep -Fq -- "--max-games 30000" "$call_log"
grep -Fq "retrying with --max-games 30000" "$stderr_log"

echo "Data ingress OOM retry regression OK: preserves killed status and lowers --max-games"
