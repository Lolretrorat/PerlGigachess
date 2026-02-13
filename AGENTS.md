# Repository Guidelines

## Project Structure & Module Organization
The repository is a small Perl 5 engine built around modules in `Chess/`. `Chess::State` owns board representation and FEN parsing, `Chess::Engine` implements search, `Chess::Book` supplies opening moves, and `Chess::Constant` plus `Chess::LocationModifer` define enumerations and square bonuses. CLI entry points live at the root: `play.pl` drives an interactive game, `uci.pl` exposes a UCI interface, and `perft.pl` is the move-generator validator. Keep new scripts alongside these so `FindBin` can locate local modules.

## Build, Test, and Development Commands
- `perl play.pl` — starts a terminal UI that alternates human and engine turns.
- `perl uci.pl` — launches a long-running loop that speaks UCI; pipe commands from a GUI such as `cutechess-cli`.
- `perl perft.pl 4` — runs depth-limited node counts from the default FEN; pass a second argument (0–4) to load canned stress positions.
- `perl -c Chess/State.pm` — fast syntax check for any touched module.

## Coding Style & Naming Conventions
Modules declare `use strict; use warnings;`—keep that consistent. Follow the existing two-space indentation with aligned hash rockets for tables. Package names mirror file paths (`Chess::State` -> `Chess/State.pm`); export helper data through `use` rather than globals. Prefer lower_snake_case for internal variables, uppercase for constants aligned with `Chess::Constant`. When adding scripts, include a shebang plus `use v5.10` if you rely on say/ state features.

## Testing Guidelines
`perft.pl` is the regression safety net; run `perl perft.pl 5 2` after touching move generation, and diff the printed node counts with trusted references. For search or interface changes, add focused FENs to `@positions` so failures reproduce quickly. Smoke-test UCI mode by sending `uci`, `isready`, `position startpos`, `go`, and `quit` through a heredoc (`printf 'uci\nisready\n...' | perl uci.pl`). Capture timing output when investigating performance changes.

## Commit & Pull Request Guidelines
Existing history favors succinct, lowercase subjects (e.g., `git commit -m "tune capture ordering"`). Continue with single-line imperatives describing behavior, optionally followed by wrapped body text for rationale. When opening a PR, include: summary of functional impact, note of any new FEN fixtures or scripts, perft depths you executed, and screenshots or CLI transcripts if you added user-facing prompts. Link related issues or lichess threads to make future archaeology painless.
