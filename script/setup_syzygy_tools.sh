#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_ROOT="${1:-/tmp/perlgigachess-syzygy}"
TB_REPO="${TB_REPO:-https://github.com/syzygy1/tb}"
PROBETOOL_REPO="${PROBETOOL_REPO:-https://github.com/syzygy1/probetool}"

usage() {
  cat <<USAGE
Usage:
  script/setup_syzygy_tools.sh [target_dir]

Defaults:
  target_dir: /tmp/perlgigachess-syzygy

Environment overrides:
  TB_REPO        (default: https://github.com/syzygy1/tb)
  PROBETOOL_REPO (default: https://github.com/syzygy1/probetool)
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p -- "$TOOLS_ROOT"

clone_or_update() {
  local repo_url="$1"
  local dest_dir="$2"
  if [[ -d "$dest_dir/.git" ]]; then
    git -C "$dest_dir" pull --ff-only
  else
    git clone "$repo_url" "$dest_dir"
  fi
}

echo "==> Cloning/updating Syzygy generator repo (tb)"
clone_or_update "$TB_REPO" "$TOOLS_ROOT/tb"

echo "==> Cloning/updating Syzygy probing repo (probetool)"
clone_or_update "$PROBETOOL_REPO" "$TOOLS_ROOT/probetool"

echo "==> Building probetool"
make -C "$TOOLS_ROOT/probetool/regular"

BIN_PATH="$TOOLS_ROOT/probetool/regular/probetool"

echo
echo "Syzygy tooling ready."
echo "Set this to use C probing from PerlGigachess:"
echo "  export CHESS_SYZYGY_PROBETOOL=$BIN_PATH"
echo
echo "And point tablebase files here before running the engine:"
echo "  export CHESS_SYZYGY_PATH=/path/to/syzygy/3-4-5:/path/to/syzygy/6-7"
