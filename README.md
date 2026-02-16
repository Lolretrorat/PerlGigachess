# PerlGigachess

This repository contains a minimalist Perl chess engine along with several entry
points:

- `play.pl` — interactive CLI (default) or `--uci` for a headless engine loop.
- `tests/perft.pl` — perft validation driver (`perft.pl` remains as a compatibility shim).
- `lichess.pl` — Bot API bridge that lets the engine play on lichess.org.

## Development Environment

Dependencies are isolated with a Python virtual environment and a local Perl
lib.

```bash
scripts/initialize.sh --skip-tools --skip-ingress --skip-endgame-table
```

This installs Python packages from `requirements.txt` into `.venv` and Perl
modules declared in `cpanfile` under `.perl5`, then prints activation commands
for new shells.

If `cpanm` is missing, install `App::cpanminus` (e.g., `cpan App::cpanminus`)
before running the helper.

## Unified Scripts

Primary top-level scripts:

- `scripts/initialize.sh` — full bootstrap: environment setup, Syzygy tooling setup, data ingress, and endgame table seeding/validation.
- `scripts/data_ingress.sh` — data-only pipeline for opening book + location modifier updates.

Typical usage:

```bash
scripts/initialize.sh
scripts/initialize.sh LICHESS-DB-PGNS 2025-01 OWN-URLS
scripts/data_ingress.sh LICHESS-DB-PGNS 2025-01
scripts/data_ingress.sh OWN-URLS
```

Master pipeline wrappers:

```bash
./DO_LOCATION_MODIFIER.sh
./DO_PARAMATER_EXTRACTION.sh
./DO_ENGINE_PIPELINE.sh
./DO_ALL_DATA_PROCESSING.sh
./DO_ALL_DATA_PROCESSING.sh --month 2026-01 --batch-months 3
```

- `DO_LOCATION_MODIFIER.sh` runs ingest + location modifier training + validation.
- `DO_PARAMATER_EXTRACTION.sh` runs ingest + engine training notebook and emits a migration bundle.
- `DO_ENGINE_PIPELINE.sh` runs parameter extraction, applies the newest patch when present, and validates via `perl -c` + `perft`.
- `DO_ALL_DATA_PROCESSING.sh` runs the combined location + parameter + engine patch pipeline in one command.

Regression tests live under `tests/`:

```bash
tests/run_regressions.sh
perl tests/regression_hyhMjQD2_kg8.pl --depth 3 --movetime 10000
```

## Running the Lichess bridge

1. [Create a Lichess bot account](https://lichess.org/account/oauth/bot) and
   generate a Bot API token.
2. Install Perl TLS essentials (`IO::Socket::SSL` and `Mozilla::CA`) so HTTPS
   requests succeed.
3. Store the token in a `.env` file (same directory as the scripts):
   ```
   LICHESS_TOKEN=lip_<TOKEN>
   ```
   The script reads `.env` on startup and also respects any variable already set
   in the process environment.
4. Launch the bridge (you can still `export` to override values temporarily):
   ```bash
   export LICHESS_TOKEN=lip_abc123...
   perl lichess.pl
   ```

The bridge keeps a long-lived streaming connection, automatically accepts
standard, non-correspondence challenges, spawns the bundled UCI engine for each
game, and posts moves back to Lichess.

### Configuration

- `LICHESS_ENGINE_CMD` — override the command used to start the engine
  (defaults to `perl play.pl --uci`). Example:
  ```bash
  LICHESS_ENGINE_CMD="perl play.pl --uci --depth 6" perl lichess.pl
  ```
- Set `LICHESS_TOKEN` in `.env` or in the shell environment before launching.
  Do **not** hard-code it inside the script.
- `CHESS_SYZYGY_ENABLED` — enable local Syzygy probing in endgames (default `1`).
- `CHESS_SYZYGY_PATH` — one or more local Syzygy directories (colon-separated on
  Linux/macOS, semicolon-separated on Windows).
- `CHESS_SYZYGY_MAX_PIECES` — maximum piece count where Syzygy probes run
  (default `7`).
- `CHESS_SYZYGY_PROBETOOL` — optional path to `syzygy1/probetool` binary
  (preferred when present).
- `CHESS_SYZYGY_PYTHON` — python executable used for legacy fallback probing
  (default `python3`).
- `CHESS_SYZYGY_PROBE_SCRIPT` — optional override path for the Syzygy probe
  helper (defaults to `scripts/probe_syzygy.pl`).

The bridge talks to Lichess directly over TLS sockets, so as long as Perl can
load `IO::Socket::SSL`, `Net::SSLeay`, and `Mozilla::CA` (installed under
`.perl5` via `scripts/initialize.sh`) no external binaries such as `curl` are required.

## Local Openings

`Chess::Book` is local-only and reads `data/opening_book.json`.

To rebuild it from local PGN files:

```bash
perl scripts/build_opening_book.pl --max-plies 18 --max-games 200000 \
  --output data/opening_book.json /path/to/games.pgn.zst
```

The builder also supports multiple input files (`.pgn` and `.pgn.zst`).

For Lichess monthly dumps, use the consolidated ingest script:

```bash
scripts/data_ingress.sh LICHESS-DB-PGNS 2025-01
```

To ingest your own game URLs from `data/lichess_game_urls.log`:

```bash
scripts/data_ingress.sh OWN-URLS
```

To run both sources in one pass:

```bash
scripts/data_ingress.sh LICHESS-DB-PGNS 2025-01 OWN-URLS
```

Monthly source ingest records are tracked in `data/lichess_ingest_manifest.json`.

Book entries now include per-move outcome stats (`white`, `draw`, `black`)
alongside `played`/`weight`, and the Perl selector ranks legal book moves by
confidence + result quality (with deterministic top choice by default).

## Local Tablebases

Endgame probing is local-first via Syzygy files on disk.

```bash
export CHESS_SYZYGY_PATH=/chess/syzygy/3-4-5:/chess/syzygy/6-7
perl play.pl --uci
```

If Syzygy files are unavailable or a position is outside the piece limit, the
engine falls back to `data/endgame_table.json` and then normal search.

### Debugging Tips

- Run `perl -c lichess.pl` after editing to catch syntax errors.
- Start the script with `LICHESS_ENGINE_CMD` pointing to another UCI engine if
  you need to compare behaviour.
- Because UCI output is streamed over pipes, make sure any extra logging coming
  from the engine goes to `STDERR`; logging on `STDOUT` may confuse the bridge.

## Training Location Modifiers

`Chess::LocationModifer` can learn piece-square tables from PGNs without touching
engine code. Stream PGN text into the helper:

```bash
zstdcat lichess_db_standard_rated_2024-01.pgn.zst | ./init train-location --games 5000
```

The command updates `data/location_modifiers.json`, which the module loads at
startup. To validate and install JSON exported from other tooling, run
`perl scripts/update_location_modifiers.pl path/to/tables.json`. The pipeline and
feature format are described in `docs/location-modifier-ml.md`.

To train from a fresh Lichess dump without keeping large files in the repo,
use `scripts/data_ingress.sh` and tune `--location-games`.

## Syzygy Tooling

To bootstrap upstream C Syzygy probing tools into `/tmp`:

```bash
scripts/initialize.sh --skip-env --skip-ingress --skip-endgame-table
export CHESS_SYZYGY_PROBETOOL=/tmp/perlgigachess-syzygy/probetool/regular/probetool
```

The initializer clones both `syzygy1/tb` and `syzygy1/probetool`, builds
`probetool`, and leaves everything outside the repo tree.
