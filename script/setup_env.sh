#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON:-python3}"
VENV_PATH="$ROOT_DIR/.venv"
PERL_LOCAL_LIB="$ROOT_DIR/.perl5"
SCRIPT_IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  SCRIPT_IS_SOURCED=1
fi

echo "==> Ensuring Python virtual environment at $VENV_PATH"
if [[ ! -d "$VENV_PATH" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_PATH"
fi

source "$VENV_PATH/bin/activate"
pip install --upgrade pip
pip install -r "$ROOT_DIR/requirements.txt"
deactivate

if ! command -v cpanm >/dev/null 2>&1; then
  echo "cpanm is required to install Perl dependencies."
  echo "Install App::cpanminus (e.g., 'cpan App::cpanminus') and rerun."
  exit 1
fi

echo "==> Installing Perl modules under $PERL_LOCAL_LIB"
cpanm --local-lib "$PERL_LOCAL_LIB" --quiet --notest --installdeps "$ROOT_DIR"

PERL5LIB_PATH="$PERL_LOCAL_LIB/lib/perl5"

if [[ $SCRIPT_IS_SOURCED -eq 1 ]]; then
  echo "==> Activating Python venv and Perl lib for current shell"
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"
  if [[ -n "${PERL5LIB:-}" ]]; then
    export PERL5LIB="$PERL5LIB_PATH:$PERL5LIB"
  else
    export PERL5LIB="$PERL5LIB_PATH"
  fi
  if [[ -n "${PERL_LOCAL_LIB_ROOT:-}" ]]; then
    export PERL_LOCAL_LIB_ROOT="$PERL_LOCAL_LIB:$PERL_LOCAL_LIB_ROOT"
  else
    export PERL_LOCAL_LIB_ROOT="$PERL_LOCAL_LIB"
  fi
  export PERL_MB_OPT="--install_base $PERL_LOCAL_LIB"
  export PERL_MM_OPT="INSTALL_BASE=$PERL_LOCAL_LIB"
else
  cat <<EOF

Environment ready.
Activate the Python venv and Perl libs in new shells with:
  source $ROOT_DIR/.venv/bin/activate
  export PERL5LIB="$ROOT_DIR/.perl5/lib/perl5:\$PERL5LIB"
  export PERL_LOCAL_LIB_ROOT="$ROOT_DIR/.perl5\${PERL_LOCAL_LIB_ROOT:+:\$PERL_LOCAL_LIB_ROOT}"
  export PERL_MB_OPT="--install_base $ROOT_DIR/.perl5"
  export PERL_MM_OPT="INSTALL_BASE=$ROOT_DIR/.perl5"
Or rerun this script via 'source script/setup_env.sh' to apply them automatically.
EOF
fi
