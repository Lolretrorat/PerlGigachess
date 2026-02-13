# PerlGigachess

This repository contains a minimalist Perl chess engine along with several entry
points:

- `play.pl` — interactive CLI (default) or `--uci` for a headless engine loop.
- `perft.pl` — perft validation driver.
- `lichess.pl` — Bot API bridge that lets the engine play on lichess.org.

## Running the Lichess bridge

1. [Create a Lichess bot account](https://lichess.org/account/oauth/bot) and
   generate a Bot API token.
2. Ensure `curl` is installed; the bridge shells out to it for HTTPS streaming.
3. Store the token in a `.env` file (same directory as the scripts):
   ```
   LICHESS_TOKEN=lip_kmfsKa2rBUqvzfOPwXg8
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

The bridge only relies on core modules available in Perl 5.26+, so no CPAN
installations are required on a standard Perl distribution.

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
`perl script/update_location_modifiers.pl path/to/tables.json`. The pipeline and
feature format are described in `docs/location-modifier-ml.md`.
