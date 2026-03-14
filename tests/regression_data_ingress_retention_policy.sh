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
printf 'DO_DATA_SCIENCE=%s\n' "\${DO_DATA_SCIENCE:-}" > "$env_log"
printf 'ENGINE_TRAINING_CLEAR_GAME_URL_LOG=%s\n' "\${ENGINE_TRAINING_CLEAR_GAME_URL_LOG:-}" >> "$env_log"
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
  assert_contains "$env_log" "DO_DATA_SCIENCE="
}

run_data_science_wrapper_checks() {
  local root="$TMP_ROOT/data_science"
  local args_log="$root/data_science_args.log"
  mkdir -p "$root"

  cp "$ROOT_DIR/DO_DATA_SCIENCE.sh" "$root/DO_DATA_SCIENCE.sh"
  cat > "$root/DO_PARAMATER_EXTRACTION.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'DO_DATA_SCIENCE=%s\n' "${DO_DATA_SCIENCE:-}" > "$DATA_SCIENCE_ARGS_LOG"
printf 'ENGINE_TRAINING_CLEAR_GAME_URL_LOG=%s\n' "${ENGINE_TRAINING_CLEAR_GAME_URL_LOG:-}" >> "$DATA_SCIENCE_ARGS_LOG"
printf 'ARGS=%s\n' "$*" >> "$DATA_SCIENCE_ARGS_LOG"
EOF
  chmod +x "$root/DO_PARAMATER_EXTRACTION.sh"

  (
    cd "$root"
    DATA_SCIENCE_ARGS_LOG="$args_log" \
      ./DO_DATA_SCIENCE.sh --engine-training --python /bin/sh --max-games 12
  )

  assert_contains "$args_log" "DO_DATA_SCIENCE=1"
  assert_contains "$args_log" "ENGINE_TRAINING_CLEAR_GAME_URL_LOG=1"
  assert_contains "$args_log" "ARGS=--clear-url-log --max-games 12"
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

assert 'DO_DATA_SCIENCE = _env_bool("DO_DATA_SCIENCE", False)' in engine_text
assert 'CLEAR_GAME_URL_LOG_AFTER_CONSUME = _env_bool("ENGINE_TRAINING_CLEAR_GAME_URL_LOG", DO_DATA_SCIENCE)' in engine_text
assert 'DO_DATA_SCIENCE = _env_bool("DO_DATA_SCIENCE", False)' in location_text
assert 'CLEAR_GAME_URL_LOG_AFTER_CONSUME = _env_bool("LOCATION_TRAINING_CLEAR_GAME_URL_LOG", DO_DATA_SCIENCE)' in location_text
PY
}

run_location_wrapper_checks
run_parameter_wrapper_checks
run_data_science_wrapper_checks
check_notebook_contract

echo "Data ingress retention regression OK: standard wrappers retain URLs, DO_DATA_SCIENCE clears explicitly"
