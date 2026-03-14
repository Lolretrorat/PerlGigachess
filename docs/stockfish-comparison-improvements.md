# PerlGigachess vs Stockfish: Prioritized Improvement Tasks

This document identifies key differences between PerlGigachess and Stockfish (located at `/home/josh/code/stockfish`), with prioritized recommendations for improving Gigachess's position evaluation, engine logic, and other aspects.

---

## Executive Summary

Stockfish is the world's strongest open-source chess engine due to:
1. **NNUE neural network evaluation** - replaces traditional handcrafted evaluation
2. **Sophisticated search pruning** - ProbCut, advanced LMR, razoring, etc.
3. **Multi-threading** - Lazy SMP parallelism
4. **Better move ordering** - continuation history, correction history tables

PerlGigachess has solid foundations but significant room for improvement.

---

## Prioritized Task List

### P0 - Critical (Highest Impact)

#### 1. **Implement Continuation History Tables**
**Impact:** High | **Difficulty:** Medium | **File:** `Chess/MovePicker.pm`

Stockfish tracks move history as pairs: the current move combined with 1, 2, 4, and 6 ply earlier moves. This dramatically improves move ordering for quiet moves.

**Current State:** Gigachess has basic killer moves and countermove heuristic.

**Implementation:**
- Add `PieceToHistory` table indexed by `[piece][to_square]`
- Track continuation pairs at ply-1, ply-2, ply-4, ply-6
- Weight continuation history in move ordering score

---

#### 2. **Add ProbCut (Probability Cutoff)**
**Impact:** High | **Difficulty:** Medium | **File:** `Chess/Engine.pm`

Stockfish uses ProbCut to prune subtrees when a shallow search of captures suggests the position is much better than beta.

**Current State:** Missing entirely from Gigachess.

**Implementation:**
```perl
# Before moves_loop at depth >= 3
my $probcut_beta = $beta + 229;  # tunable
if ($depth >= 3 && !is_decisive($beta)) {
  # Generate captures with SEE >= probcut_beta - static_eval
  # Shallow qsearch + reduced search
  # If value >= probcut_beta, return early
}
```

---

#### 3. **Enhance Static Exchange Evaluation (SEE) Usage**
**Impact:** High | **Difficulty:** Low | **File:** `Chess/See.pm`, `Chess/Engine.pm`

Stockfish uses SEE extensively:
- Capture pruning with history-adjusted margins
- Move ordering for captures
- Futility pruning decisions

**Current State:** Gigachess has SEE but underutilizes it.

**Implementation:**
- Add SEE-based capture pruning in search with margin `185*depth + captHist/28`
- Use SEE to skip clearly losing captures earlier
- Integrate SEE with capture history table

---

### P1 - High Priority

#### 4. **Implement Correction History**
**Impact:** Medium-High | **Difficulty:** Medium | **File:** New: `Chess/CorrectionHistory.pm`

Stockfish tracks differences between static evaluation and search results to improve future static eval.

**Current State:** Missing.

**Implementation:**
- Add pawn structure correction history (indexed by pawn hash)
- Add minor piece correction history
- Add non-pawn material correction history
- Apply weighted correction to static_eval in search

---

#### 5. **Add Aspiration Windows with Iterative Widening**
**Impact:** Medium-High | **Difficulty:** Low | **File:** `Chess/Engine.pm`

Stockfish starts with narrow windows around previous iteration's score and widens on fail-high/low.

**Current State:** Gigachess has fixed aspiration window (`ASPIRATION_WINDOW => 18`).

**Implementation:**
```perl
my $delta = 5;  # Start narrow
while (1) {
  $alpha = max($avg - $delta, -INF);
  $beta = min($avg + $delta, INF);
  $value = search(...);
  if ($value <= $alpha) {
    $beta = $alpha;
    $alpha = max($value - $delta, -INF);
  } elsif ($value >= $beta) {
    $alpha = max($beta - $delta, $alpha);
    $beta = min($value + $delta, INF);
  } else {
    last;  # Success
  }
  $delta += $delta / 3;
}
```

---

#### 6. **Improve Null Move Pruning Verification**
**Impact:** Medium | **Difficulty:** Low | **File:** `Chess/Engine.pm`

Stockfish does verification search at high depths to avoid zugzwang misses.

**Current State:** Gigachess has basic null move pruning without verification.

**Implementation:**
```perl
if ($null_value >= $beta && $depth >= 16) {
  # Verification search with nmpMinPly guard
  $nmp_min_ply = $ply + 3 * ($depth - $R) / 4;
  my $v = search($state, $depth - $R, $beta - 1, $beta, ...);
  if ($v >= $beta) {
    return $null_value;
  }
}
```

---

#### 7. **Add Razoring**
**Impact:** Medium | **Difficulty:** Low | **File:** `Chess/Engine.pm`

Skip full search at shallow depths when static eval is far below alpha.

**Current State:** Missing.

**Implementation:**
```perl
# At non-PV nodes
if ($eval < $alpha - 507 - 312 * $depth * $depth) {
  return _quiesce($state, $alpha, $beta);
}
```

---

### P2 - Medium Priority

#### 8. **Implement Low-Ply History**
**Impact:** Medium | **Difficulty:** Low | **File:** `Chess/MovePicker.pm`

Special history table for moves near the root (ply 0-4) which matters more for move ordering.

---

#### 9. **Add Capture-Piece-To History**
**Impact:** Medium | **Difficulty:** Medium | **File:** `Chess/MovePicker.pm`

Track capture history indexed by `[moved_piece][to_square][captured_piece_type]`.

---

#### 10. **Implement TT Entry Aging**
**Impact:** Medium | **Difficulty:** Low | **File:** `Chess/TranspositionTable.pm`

Stockfish uses generation counters to prefer recent entries during replacement.

**Current State:** Gigachess has basic age_weight but could be more sophisticated.

---

#### 11. **Add Shuffle Detection**
**Impact:** Medium | **Difficulty:** Low | **File:** `Chess/Engine.pm`

Detect repetitive back-and-forth moves and adjust evaluation:
```perl
sub is_shuffling {
  return 0 if is_capture($move) || $rule50 < 11;
  # Check if move.from == (ss-2)->move.to && ...
}
```

---

### P3 - Lower Priority (Long-term)

#### 12. **Consider NNUE Evaluation**
**Impact:** Very High | **Difficulty:** Very High

Stockfish's biggest strength is NNUE. This would require:
- Neural network inference in Perl (XS binding to a C library)
- Training data and training pipeline
- Incremental accumulator updates

**Recommendation:** Explore binding to existing NNUE libraries or consider a hybrid approach using external evaluation servers.

---

#### 13. **Implement Lazy SMP (Multi-threading)**
**Impact:** High | **Difficulty:** High | **File:** `Chess/Engine.pm`

Stockfish uses multiple threads searching the same tree with shared TT.

**Current State:** Gigachess has basic threading support but not Lazy SMP.

---

#### 14. **Syzygy Tablebase Integration**
**Impact:** Medium (endgames only) | **Difficulty:** High

Probe endgame tablebases for perfect play with ≤7 pieces.

**Note:** Gigachess already has `Chess/EndgameTable.pm` - evaluate extending this.

---

#### 15. **Add MultiPV Root Search Improvements**
**Impact:** Low-Medium | **Difficulty:** Low

Track mean squared score variance to adjust aspiration windows.

---

## Quick Wins (Can implement today)

1. **Razoring** - ~20 lines of code, immediate speedup
2. **Aspiration window widening** - simple loop change
3. **Null move verification** - small addition to existing code
4. **Low-ply history table** - small array addition
5. **Better TT replacement** - use generation counter more aggressively

---

## File-by-File Improvement Map

| File | Priority Improvements |
|------|----------------------|
| `Chess/Engine.pm` | ProbCut, Razoring, Null-move verification, Aspiration widening |
| `Chess/MovePicker.pm` | Continuation history, Capture history, Low-ply history |
| `Chess/TranspositionTable.pm` | Better aging, generation tracking |
| `Chess/See.pm` | Add margin-based capture pruning helper |
| `Chess/Eval.pm` | Correction history integration |
| `Chess/Heuristics.pm` | Add tunable constants for new techniques |

---

## Benchmarking Recommendations

After each improvement:
1. Run `perl tests/perft.pl 5 2` for correctness
2. Measure nodes/second on standard positions
3. Test against previous version in self-play matches
4. Track Elo gain using cutechess-cli tournaments

---

## Estimated Effort

| Task | Lines of Code | Days |
|------|---------------|------|
| Continuation History | ~150 | 2-3 |
| ProbCut | ~40 | 1 |
| Razoring | ~15 | 0.5 |
| Aspiration Widening | ~30 | 0.5 |
| Null Move Verification | ~20 | 0.5 |
| Correction History | ~200 | 3-4 |
| Capture-Piece-To History | ~100 | 1-2 |

---

## References

- Stockfish source: `/home/josh/code/stockfish/src/`
- Key files: `search.cpp`, `movepick.cpp`, `history.h`, `evaluate.cpp`
- Chess Programming Wiki: https://www.chessprogramming.org/

---

*Generated: 2026-03-14*
