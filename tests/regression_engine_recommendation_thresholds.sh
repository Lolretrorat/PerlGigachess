#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

(cd "$ROOT_DIR" && ./.venv/bin/python - <<'PY')
import json
from pathlib import Path

import pandas as pd

from analysis.engine_hyperparam_pipeline import optimize_constants_from_registry

registry_path = Path("analysis/engine_param_registry.json")
registry = json.loads(registry_path.read_text(encoding="utf-8"))
constants = {}
config_values = {}
for spec in registry.get("parameters", []):
    name = spec.get("name")
    if not name:
        continue
    current_key = spec.get("current_key") or name
    source = spec.get("source", "engine_constant")
    target = constants if source == "engine_constant" else config_values
    if "default_current" in spec:
        target[current_key] = float(spec["default_current"])
        continue
    min_v = float(spec.get("min", 0.0))
    max_v = float(spec.get("max", min_v + 1.0))
    target[current_key] = (min_v + max_v) / 2.0

feature_importance = [
    ("cp_loss", 1.0),
    ("opponent_checks_after", 0.8),
    ("threatened_ours", 0.7),
    ("king_ring_attacked", 0.6),
    ("mobility_delta", 0.9),
    ("time_pressure", 0.9),
    ("search_depth_gap", 1.0),
    ("book_differs_nobook", 0.6),
]

train_rows = [
    {
        "cp_loss": 210.0,
        "played_is_capture": 1,
        "threatened_ours": 2,
        "opponent_checks_after": 1,
        "king_ring_attacked": 3,
        "king_file_open": 1,
        "opening_phase": 1,
        "opening_development_lag": 3,
        "endgame_phase": 0,
        "mobility_delta": -3,
        "time_pressure": 1,
        "search_depth_gap": 4,
        "book_differs_nobook": 1,
        "pawn_islands": 4,
        "threatened_delta": 2,
    }
    for _ in range(18)
] + [
    {
        "cp_loss": 95.0,
        "played_is_capture": 0,
        "threatened_ours": 0,
        "opponent_checks_after": 0,
        "king_ring_attacked": 0,
        "king_file_open": 0,
        "opening_phase": 0,
        "opening_development_lag": 1,
        "endgame_phase": 0,
        "mobility_delta": 2,
        "time_pressure": 0,
        "search_depth_gap": 0,
        "book_differs_nobook": 0,
        "pawn_islands": 2,
        "threatened_delta": 0,
    }
    for _ in range(12)
]

df_train = pd.DataFrame(train_rows)

df_holdout_supportive = pd.DataFrame(
    [
        {
            "cp_loss": 185.0,
            "played_is_capture": 1,
            "threatened_ours": 2,
            "opponent_checks_after": 1,
            "king_ring_attacked": 2,
            "king_file_open": 1,
            "opening_phase": 1,
            "opening_development_lag": 2,
            "endgame_phase": 0,
            "mobility_delta": -2,
            "time_pressure": 1,
            "search_depth_gap": 3,
            "book_differs_nobook": 1,
            "pawn_islands": 4,
            "threatened_delta": 1,
        }
        for _ in range(8)
    ]
)

payload_supportive = optimize_constants_from_registry(
    df_train_eval=df_train,
    df_holdout_eval=df_holdout_supportive,
    summary_train={"bestmove_match_rate": 0.35},
    summary_holdout={"bestmove_match_rate": 0.38},
    feature_importance=feature_importance,
    constants=constants,
    registry_path=registry_path,
    config_values=config_values,
    severe_cp_loss=150,
    candidate_scales=[1.0],
    min_param_score=0.12,
    max_updates=6,
    training_volume_weight=0.22,
    low_volume_relax_factor=0.65,
    min_holdout_group_pressure=0.01,
    min_holdout_alignment=0.20,
)

assert payload_supportive["adaptive_min_param_score"] < 0.12, payload_supportive["adaptive_min_param_score"]
assert payload_supportive["proposed_updates"], "Expected updates with supportive holdout signals"
assert payload_supportive["proposed_config_updates"], "Expected config updates with supportive holdout signals"
assert not payload_supportive["selected_candidate"].get("safeguard_rejected"), payload_supportive["selected_candidate"]
assert any(row.get("source") == "external_config" for row in payload_supportive["parameter_rows"]), payload_supportive["parameter_rows"]

payload_rejected = optimize_constants_from_registry(
    df_train_eval=df_train,
    df_holdout_eval=df_train.iloc[0:0].copy(),
    summary_train={"bestmove_match_rate": 0.35},
    summary_holdout={"bestmove_match_rate": 0.99},
    feature_importance=feature_importance,
    constants=constants,
    registry_path=registry_path,
    config_values=config_values,
    severe_cp_loss=150,
    candidate_scales=[1.0],
    min_param_score=0.12,
    max_updates=6,
    training_volume_weight=0.22,
    low_volume_relax_factor=0.65,
    min_holdout_group_pressure=0.01,
    min_holdout_alignment=0.20,
)

assert not payload_rejected["proposed_updates"], "Expected safeguards to block unsupported updates"
assert not payload_rejected["proposed_config_updates"], "Expected safeguards to block unsupported config updates"
rejected = payload_rejected["selected_candidate"].get("safeguard_rejected")
assert rejected or payload_rejected["selected_candidate"].get("changed_constants") == [], payload_rejected["selected_candidate"]

print("engine recommendation threshold regression: ok")
PY
