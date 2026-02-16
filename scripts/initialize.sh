#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_INGRESS_SCRIPT="$ROOT_DIR/scripts/data_ingress.sh"
ENDGAME_TABLE_PATH="$ROOT_DIR/data/endgame_table.json"

RUN_ENV=1
RUN_TOOLS=1
RUN_INGRESS=1
RUN_ENDGAME_TABLE=1

RUN_LICHESS_DB=0
LICHESS_MONTH=""
RUN_OWN_URLS=0
AUTO_OWN_URLS=1

SYZYGY_TOOLS_DIR="/tmp/perlgigachess-syzygy"
TMP_DIR="/tmp"
KEEP_DOWNLOAD=0
ALLOW_DUPLICATE_SOURCE=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/initialize.sh [options] [INGRESS_FLAGS...]

Ingress flags:
  LICHESS-DB-PGNS <YYYY-MM>      Ingest a Lichess monthly dump (required month arg)
  OWN-URLS                        Ingest URLs from data/lichess_game_urls.log

Options:
  --skip-env                      Skip environment setup
  --skip-tools                    Skip Syzygy tooling setup
  --skip-ingress                  Skip data ingress
  --skip-endgame-table            Skip endgame table creation/validation
  --no-own-urls                   Disable default OWN-URLS ingestion when no ingress flag is set
  --syzygy-tools-dir <dir>        Target directory for Syzygy tooling (default: /tmp/perlgigachess-syzygy)
  --tmp-dir <dir>                 Temp directory for ingest stages (default: /tmp)
  --keep-download                 Keep downloaded monthly archive
  --allow-duplicate-source        Allow duplicate monthly source ingest
  -h, --help                      Show this message

Examples:
  scripts/initialize.sh
  scripts/initialize.sh LICHESS-DB-PGNS 2025-01
  scripts/initialize.sh LICHESS-DB-PGNS 2025-01 OWN-URLS
USAGE
}

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

setup_env() {
  local python_bin="${PYTHON:-python3}"
  local venv_path="$ROOT_DIR/.venv"
  local perl_local_lib="$ROOT_DIR/.perl5"

  echo "==> Ensuring Python virtual environment at $venv_path"
  if [[ ! -d "$venv_path" ]]; then
    "$python_bin" -m venv "$venv_path"
  fi

  # shellcheck disable=SC1090
  source "$venv_path/bin/activate"
  pip install --upgrade pip
  pip install -r "$ROOT_DIR/requirements.txt"
  deactivate

  if ! command -v cpanm >/dev/null 2>&1; then
    echo "cpanm is required to install Perl dependencies." >&2
    echo "Install App::cpanminus (e.g., 'cpan App::cpanminus') and rerun." >&2
    exit 1
  fi

  echo "==> Installing Perl modules under $perl_local_lib"
  cpanm --local-lib "$perl_local_lib" --quiet --notest --installdeps "$ROOT_DIR"

  cat <<EOM

Environment ready.
Activate in new shells with:
  source $ROOT_DIR/.venv/bin/activate
  export PERL5LIB="$ROOT_DIR/.perl5/lib/perl5:\$PERL5LIB"
  export PERL_LOCAL_LIB_ROOT="$ROOT_DIR/.perl5\${PERL_LOCAL_LIB_ROOT:+:\$PERL_LOCAL_LIB_ROOT}"
  export PERL_MB_OPT="--install_base $ROOT_DIR/.perl5"
  export PERL_MM_OPT="INSTALL_BASE=$ROOT_DIR/.perl5"
EOM
}

setup_syzygy_tools() {
  local tools_root="$1"
  local tb_repo="${TB_REPO:-https://github.com/syzygy1/tb}"
  local probetool_repo="${PROBETOOL_REPO:-https://github.com/syzygy1/probetool}"

  mkdir -p -- "$tools_root"

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
  clone_or_update "$tb_repo" "$tools_root/tb"

  echo "==> Cloning/updating Syzygy probing repo (probetool)"
  clone_or_update "$probetool_repo" "$tools_root/probetool"

  echo "==> Building probetool"
  make -C "$tools_root/probetool/regular"

  local bin_path="$tools_root/probetool/regular/probetool"

  echo
  echo "Syzygy tooling ready."
  echo "Set this to use C probing from PerlGigachess:"
  echo "  export CHESS_SYZYGY_PROBETOOL=$bin_path"
  echo
  echo "And point tablebase files here before running the engine:"
  echo "  export CHESS_SYZYGY_PATH=/path/to/syzygy/3-4-5:/path/to/syzygy/6-7"
}

endgame_table_is_valid() {
  local table_path="$1"
  [[ -s "$table_path" ]] || return 1
  perl -MJSON::PP -e '
    my ($path) = @ARGV;
    open my $fh, q{<}, $path or exit 1;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { JSON::PP->new->decode($raw) };
    exit (($@ || ref($data) ne q{ARRAY}) ? 1 : 0);
  ' "$table_path"
}

build_endgame_table() {
  mkdir -p "$ROOT_DIR/data"

  if endgame_table_is_valid "$ENDGAME_TABLE_PATH"; then
    echo "==> Endgame table already valid: $ENDGAME_TABLE_PATH"
    return
  fi

  if [[ -e "$ENDGAME_TABLE_PATH" ]]; then
    local backup_path="${ENDGAME_TABLE_PATH}.bak.$(date -u +%Y%m%d%H%M%S)"
    cp "$ENDGAME_TABLE_PATH" "$backup_path"
    echo "==> Existing endgame table was invalid; backup saved to $backup_path"
  fi

  cat > "$ENDGAME_TABLE_PATH" <<'JSON'
[
  {
    "key": "7k/6Q1/6K1/8/8/8/8/8 w - -",
    "moves": [
      {"uci": "g7h7", "weight": 100, "rank": 100},
      {"uci": "g7f8", "weight": 20, "rank": 40}
    ]
  },
  {
    "key": "7k/6R1/6K1/8/8/8/8/8 w - -",
    "moves": [
      {"uci": "g7h7", "weight": 100, "rank": 100},
      {"uci": "g7a7", "weight": 20, "rank": 30}
    ]
  },
  {
    "key": "6k1/5Q2/6K1/8/8/8/8/8 w - -",
    "moves": [
      {"uci": "f7g7", "weight": 100, "rank": 100},
      {"uci": "f7e8", "weight": 20, "rank": 35}
    ]
  },
  {
    "key": "8/8/8/8/8/8/5kq1/7K b - -",
    "moves": [
      {"uci": "g2g1", "weight": 100, "rank": 100},
      {"uci": "g2h2", "weight": 15, "rank": 20}
    ]
  },
  {
    "key": "8/8/8/8/8/8/5kr1/7K b - -",
    "moves": [
      {"uci": "g2g1", "weight": 100, "rank": 100},
      {"uci": "g2h2", "weight": 15, "rank": 15}
    ]
  },
  {
    "key": "6k1/8/6Q1/6K1/8/8/8/8 b - -",
    "moves": [
      {"uci": "g8f8", "weight": 50, "rank": 50},
      {"uci": "g8h8", "weight": 50, "rank": 50}
    ]
  }
]
JSON

  echo "==> Wrote endgame table seed: $ENDGAME_TABLE_PATH"
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
    --skip-env)
      RUN_ENV=0
      shift
      ;;
    --skip-tools)
      RUN_TOOLS=0
      shift
      ;;
    --skip-ingress)
      RUN_INGRESS=0
      shift
      ;;
    --skip-endgame-table)
      RUN_ENDGAME_TABLE=0
      shift
      ;;
    --no-own-urls)
      AUTO_OWN_URLS=0
      shift
      ;;
    --syzygy-tools-dir)
      require_value "--syzygy-tools-dir" "${2:-}"
      SYZYGY_TOOLS_DIR="${2:-}"
      shift 2
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
    --allow-duplicate-source)
      ALLOW_DUPLICATE_SOURCE=1
      shift
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

if [[ "$RUN_LICHESS_DB" -eq 1 ]] && ! validate_year_month "$LICHESS_MONTH"; then
  echo "Invalid LICHESS-DB-PGNS value: '$LICHESS_MONTH' (expected YYYY-MM)" >&2
  exit 1
fi

if [[ "$RUN_INGRESS" -eq 1 && "$RUN_LICHESS_DB" -eq 0 && "$RUN_OWN_URLS" -eq 0 && "$AUTO_OWN_URLS" -eq 1 ]]; then
  RUN_OWN_URLS=1
fi

if [[ "$RUN_ENV" -eq 1 ]]; then
  setup_env
else
  echo "==> Skipping environment setup"
fi

if [[ "$RUN_TOOLS" -eq 1 ]]; then
  setup_syzygy_tools "$SYZYGY_TOOLS_DIR"
else
  echo "==> Skipping Syzygy tooling setup"
fi

if [[ "$RUN_INGRESS" -eq 1 ]]; then
  if [[ ! -x "$DATA_INGRESS_SCRIPT" ]]; then
    echo "Missing executable script: $DATA_INGRESS_SCRIPT" >&2
    exit 1
  fi

  ingress_args=(--tmp-dir "$TMP_DIR")
  if [[ "$KEEP_DOWNLOAD" -eq 1 ]]; then
    ingress_args+=(--keep-download)
  fi
  if [[ "$ALLOW_DUPLICATE_SOURCE" -eq 1 ]]; then
    ingress_args+=(--allow-duplicate-source)
  fi
  if [[ "$RUN_LICHESS_DB" -eq 1 ]]; then
    ingress_args+=(LICHESS-DB-PGNS "$LICHESS_MONTH")
  fi
  if [[ "$RUN_OWN_URLS" -eq 1 ]]; then
    ingress_args+=(OWN-URLS)
  fi

  if [[ "${#ingress_args[@]}" -gt 2 ]]; then
    "$DATA_INGRESS_SCRIPT" "${ingress_args[@]}"
  else
    echo "==> Skipping data ingress (no source flags selected)"
  fi
else
  echo "==> Skipping data ingress"
fi

if [[ "$RUN_ENDGAME_TABLE" -eq 1 ]]; then
  build_endgame_table
else
  echo "==> Skipping endgame table setup"
fi

echo "==> Initialization complete"
