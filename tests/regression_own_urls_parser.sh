#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_own_urls_reg_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MOCK_BIN_DIR="$TMP_ROOT/mockbin"
MOCK_CALLS="$TMP_ROOT/mock_curl_calls.log"
URL_LOG="$TMP_ROOT/urls.log"
OWN_PGN="$TMP_ROOT/own_urls.pgn"
TMP_STAGE="$TMP_ROOT/tmp"
mkdir -p "$MOCK_BIN_DIR" "$TMP_STAGE"

cat > "$MOCK_BIN_DIR/curl" <<'MOCKCURL'
#!/usr/bin/env bash
set -euo pipefail

url="${!#}"
printf '%s\n' "$url" >> "${MOCK_CURL_CALLS:?}"

id="${url##*/}"
id="${id%%\?*}"
id="${id%%#*}"
id="${id%%/*}"
if [[ "${#id}" -ge 8 ]]; then
  id="${id:0:8}"
fi

cat <<PGN
[Event "Mock"]
[Site "https://lichess.org/$id"]
[Date "2026.02.17"]
[Round "-"]
[White "MockWhite"]
[Black "MockBlack"]
[Result "1-0"]

1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0
PGN
MOCKCURL
chmod +x "$MOCK_BIN_DIR/curl"

cat > "$URL_LOG" <<'URLS'
https://lichess.org/smLd7iLCIU7O
smLd7iLC
https://lichess.org/game/export/AbCd1234WXYZ
URLS

PATH="$MOCK_BIN_DIR:$PATH" \
MOCK_CURL_CALLS="$MOCK_CALLS" \
"$ROOT_DIR/scripts/data_ingress.sh" \
  OWN-URLS \
  --skip-book \
  --skip-location \
  --own-url-log "$URL_LOG" \
  --own-pgn-output "$OWN_PGN" \
  --clear-own-url-log \
  --tmp-dir "$TMP_STAGE"

test -f "$OWN_PGN"

grep -q 'https://lichess.org/smLd7iLC' "$OWN_PGN"
grep -q 'https://lichess.org/AbCd1234' "$OWN_PGN"

test "$(wc -l < "$MOCK_CALLS" | tr -d '[:space:]')" = "2"
grep -q '^https://lichess.org/game/export/smLd7iLC$' "$MOCK_CALLS"
grep -q '^https://lichess.org/game/export/AbCd1234$' "$MOCK_CALLS"

test ! -s "$URL_LOG"

echo "OWN-URL parser regression OK: accepts 12-char lichess URLs and de-duplicates by base game id"
