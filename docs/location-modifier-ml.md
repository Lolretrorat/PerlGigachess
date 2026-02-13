# ML-Derived Location Modifiers

## Objective
Turn raw classical game data into empirically grounded piece-square tables used by `Chess::LocationModifer`. The target artifact is a hash that mirrors `%location_modifiers`, populated with centipawn offsets learned from millions of positions. The workflow below keeps the Perl engine untouched while experiments iterate quickly in Python.

## Data Requirements
- Source PGN: monthly Lichess or CCRL dumps provide billions of moves. Start with a 5–10M game sample filtered to classical/rapid controls so middlegame patterns dominate.
- Metadata: result (`1-0`, `0-1`, `1/2-1/2`), player ratings, and termination reason.
- Storage: expect ≈40 GB compressed PGN. Process in streaming fashion to avoid holding full sets in memory.

## Feature Pipeline
1. Parse PGNs with `python-chess` via `analysis/game_feature_extract.py`:
   ```bash
   python -m pip install python-chess pandas numpy scikit-learn zstandard
   python analysis/game_feature_extract.py lichess.pgn.zst --output-dir jsons/processed
   ```
2. For every ply where no capture or promotion occurred (clean positional steps), extract the board as FEN.
3. Encode each position into a 64×12 binary matrix (piece × square). Mirror black-to-move positions so features are always “from white’s perspective”.
4. Attach contextual scalars per position: move number bucket (opening/middlegame/endgame) and a game-weight (e.g., opponent Elo, result confidence).
5. Label each position with game outcome (+1 for win, −1 for loss, 0 for draw) so the model learns correlations between occupancy and success.

## Model & Training
- Model: Ridge-regularized linear regression predicting outcome from piece-square indicators plus context buckets. Coefficients map directly to centipawn bonuses.
- Objective: Minimize squared error with per-sample weights that emphasize higher-rated games and later moves.
- Training loop skeleton:
  ```python
  from sklearn.linear_model import Ridge
  model = Ridge(alpha=5.0, fit_intercept=False)
  model.fit(X_train, y_train, sample_weight=weights)
  ```
- Post-process coefficients into a `{piece: {square: value}}` hierarchy. Normalize so the mean modifier per piece is zero and clamp extremes (±40) to avoid unstable evaluations.
- Notebook: `analysis/location_modifer_training.ipynb` orchestrates load → train → evaluate → export, surfaces accuracy/precision/recall/F1 tables plus a confusion-matrix visualization, and includes an optional cell to regenerate `Chess/LocationModifer.pm`.

## Evaluation
- Hold out at least 10% of games for validation.
- Metrics: R² of outcome prediction, and engine-strength proxies (perft unaffected, Elo gain via self-play against baseline tables).
- Sanity checks: heatmaps should resemble known PSTs (knights favor center, pawns push forward). Flag any regressions where modifiers invert expected gradients.

## Integration Plan
1. Export the coefficient table to JSON matching `%location_modifiers` (piece => square => score).
2. Run `perl script/update_location_modifiers.pl jsons/location_modifiers.json` to validate the structure and install it under `jsons/location_modifiers.json` (or `--output` for custom paths) so `Chess::LocationModifer` picks it up on load.
3. Gate updates through CI: run `perl perft.pl 4` plus a 100-game self-play suite comparing the old and new tables.
4. Document the workflow in `AGENTS.md` and keep the training notebook under `analysis/` for reproducibility.
