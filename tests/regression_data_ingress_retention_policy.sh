#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d /tmp/perlgigachess_retention_reg_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_contains() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    echo "Expected '$needle' in $path" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local needle="$2"
  if grep -Fq -- "$needle" "$path"; then
    echo "Did not expect '$needle' in $path" >&2
    exit 1
  fi
}

run_location_wrapper_checks() {
  local root="$TMP_ROOT/location"
  local args_log="$root/location_ingress_args.log"
  mkdir -p "$root/scripts" "$root/data" "$root/Chess"

  cp "$ROOT_DIR/DO_LOCATION_MODIFIER.sh" "$root/DO_LOCATION_MODIFIER.sh"
  cat > "$root/scripts/data_ingress.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$LOCATION_INGRESS_ARGS_LOG"
EOF
  chmod +x "$root/scripts/data_ingress.sh"
  : > "$root/scripts/update_location_modifiers.pl"
  cat > "$root/Chess/LocationModifer.pm" <<'EOF'
package Chess::LocationModifer;
use strict;
use warnings;
1;
EOF

  (
    cd "$root"
    PERLGIGACHESS_TMP_DIR="$root/tmp" \
    LOCATION_INGRESS_ARGS_LOG="$args_log" \
      ./DO_LOCATION_MODIFIER.sh --skip-validation
  )
  assert_not_contains "$args_log" "--clear-own-url-log"

  (
    cd "$root"
    PERLGIGACHESS_TMP_DIR="$root/tmp" \
    LOCATION_INGRESS_ARGS_LOG="$args_log" \
      ./DO_LOCATION_MODIFIER.sh --skip-validation --clear-url-log
  )
  assert_contains "$args_log" "--clear-own-url-log"
}

run_parameter_wrapper_checks() {
  local root="$TMP_ROOT/parameter"
  local env_log="$root/parameter_env.log"
  local bundle_ts="20260314010101"
  local bundle_dir="$root/engineMigration/V${bundle_ts}__engine_training_recommendations"
  mkdir -p "$root/scripts" "$root/analysis" "$root/engineMigration" "$root/data"

  cp "$ROOT_DIR/DO_PARAMATER_EXTRACTION.sh" "$root/DO_PARAMATER_EXTRACTION.sh"
  cat > "$root/scripts/data_ingress.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$root/scripts/data_ingress.sh"
  cat > "$root/scripts/run_notebook_noninteractive.py" <<'EOF'
#!/usr/bin/env python3
EOF
  cat > "$root/scripts/apply_engine_migration.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$root/scripts/apply_engine_migration.sh"
  cat > "$root/analysis/engine_training.ipynb" <<'EOF'
{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}
EOF
  cat > "$root/data/lichess_games_export.pgn" <<'EOF'
[Event "Mock"]
[Site "https://lichess.org/mock0001"]
[Date "2026.03.14"]
[Round "-"]
[White "White"]
[Black "Black"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 1-0
EOF
  cat > "$root/mock_python.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'ENGINE_TRAINING_CLEAR_GAME_URL_LOG=%s\n' "\${ENGINE_TRAINING_CLEAR_GAME_URL_LOG:-}" > "$env_log"
mkdir -p "$bundle_dir"
EOF
  chmod +x "$root/mock_python.sh"

  (
    cd "$root"
    PERLGIGACHESS_TMP_DIR="$root/tmp" \
    ./DO_PARAMATER_EXTRACTION.sh \
      --skip-ingress \
      --python "$root/mock_python.sh" \
      --migration-timestamp "$bundle_ts"
  )

  assert_contains "$env_log" "ENGINE_TRAINING_CLEAR_GAME_URL_LOG=0"
}

run_giga_wrapper_checks() {
  local root="$TMP_ROOT/giga"
  local engine_log="$root/giga_engine_args.log"
  local validation_log="$root/giga_validation_args.log"
  mkdir -p "$root"

  cp "$ROOT_DIR/DO_GIGA_DATA_PROCESSING.sh" "$root/DO_GIGA_DATA_PROCESSING.sh"
  cat > "$root/DO_ENGINE_PIPELINE.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$GIGA_ENGINE_ARGS_LOG"
EOF
  chmod +x "$root/DO_ENGINE_PIPELINE.sh"
  cat > "$root/DO_LOCATION_MODIFIER.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$GIGA_LOCATION_ARGS_LOG"
EOF
  chmod +x "$root/DO_LOCATION_MODIFIER.sh"

  (
    cd "$root"
    GIGA_ENGINE_ARGS_LOG="$engine_log" \
    GIGA_LOCATION_ARGS_LOG="$validation_log" \
      ./DO_GIGA_DATA_PROCESSING.sh --max-games 12
  )
  assert_not_contains "$engine_log" "--clear-url-log"
  assert_contains "$engine_log" "--include-location-ingress"
  assert_contains "$validation_log" "--skip-ingress"

  (
    cd "$root"
    GIGA_ENGINE_ARGS_LOG="$engine_log" \
    GIGA_LOCATION_ARGS_LOG="$validation_log" \
      ./DO_GIGA_DATA_PROCESSING.sh --consume-own-urls --max-games 12
  )
  assert_contains "$engine_log" "--clear-url-log"
  assert_contains "$engine_log" "--max-games"
  assert_contains "$engine_log" "12"

  if (
    cd "$root"
    GIGA_ENGINE_ARGS_LOG="$engine_log" \
    GIGA_LOCATION_ARGS_LOG="$validation_log" \
      ./DO_GIGA_DATA_PROCESSING.sh --month 2026-01 --consume-own-urls
  ); then
    echo "Expected --consume-own-urls without --with-own-urls to fail" >&2
    exit 1
  fi

  (
    cd "$root"
    GIGA_ENGINE_ARGS_LOG="$engine_log" \
    GIGA_LOCATION_ARGS_LOG="$validation_log" \
      ./DO_GIGA_DATA_PROCESSING.sh --month 2026-01 --with-own-urls --consume-own-urls
  )
  assert_contains "$engine_log" "--month"
  assert_contains "$engine_log" "2026-01"
  assert_contains "$engine_log" "--clear-url-log"
}

check_notebook_contract() {
  python - <<'PY'
import json
from pathlib import Path

root = Path("/home/josh/code/PerlGigachess")

engine = json.loads((root / "analysis" / "engine_training.ipynb").read_text(encoding="utf-8"))
location = json.loads((root / "analysis" / "location_modifer_training.ipynb").read_text(encoding="utf-8"))

engine_text = "\n".join(
    "".join(cell.get("source", [])) if isinstance(cell.get("source"), list) else str(cell.get("source", ""))
    for cell in engine.get("cells", [])
)
location_text = "\n".join(
    "".join(cell.get("source", [])) if isinstance(cell.get("source"), list) else str(cell.get("source", ""))
    for cell in location.get("cells", [])
)

assert 'ENGINE_TRAINING_CLEAR_GAME_URL_LOG' in engine_text
assert 'LOCATION_TRAINING_CLEAR_GAME_URL_LOG' in location_text
PY
}

run_location_wrapper_checks
run_parameter_wrapper_checks
run_giga_wrapper_checks
check_notebook_contract

echo "Data ingress retention regression OK: standard wrappers retain URLs, DO_GIGA_DATA_PROCESSING consumes explicitly"
