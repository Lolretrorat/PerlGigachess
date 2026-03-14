from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Tuple

import numpy as np
import pandas as pd


def _clamp(v: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, v))


def _safe_mean(series: pd.Series) -> float:
    if series is None or len(series) == 0:
        return 0.0
    val = series.mean()
    if pd.isna(val):
        return 0.0
    return float(val)


def _mean_for_mask(df: pd.DataFrame, mask: pd.Series, col: str = "cp_loss") -> float:
    if col not in df.columns or len(df) == 0:
        return 0.0
    subset = df.loc[mask, col]
    return _safe_mean(subset)


def normalize_feature_importance(feature_importance: Iterable[Tuple[str, float]]) -> Dict[str, float]:
    vals = {name: float(max(0.0, score)) for name, score in feature_importance}
    total = float(sum(vals.values()))
    if total <= 1e-12:
        return {k: 0.0 for k in vals}
    return {k: float(v / total) for k, v in vals.items()}


def load_parameter_registry(path: Path) -> Dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    params = raw.get("parameters")
    if not isinstance(params, list):
        raise ValueError(f"Invalid parameter registry format: {path}")

    seen = set()
    normalized: List[Dict[str, Any]] = []
    for entry in params:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            continue
        if name in seen:
            raise ValueError(f"Duplicate registry parameter: {name}")
        seen.add(name)

        typ = str(entry.get("type", "float")).lower()
        if typ not in {"int", "float"}:
            raise ValueError(f"Unsupported type for {name}: {typ}")

        direction = str(entry.get("direction", "increase")).lower()
        if direction not in {"increase", "decrease"}:
            raise ValueError(f"Unsupported direction for {name}: {direction}")

        source = str(entry.get("source", "engine_constant")).lower()
        if source not in {"engine_constant", "external_config"}:
            raise ValueError(f"Unsupported source for {name}: {source}")

        normalized.append(
            {
                "name": name,
                "group": str(entry.get("group", "misc")),
                "source": source,
                "current_key": str(entry.get("current_key", name)),
                "type": typ,
                "min": float(entry.get("min", 0)),
                "max": float(entry.get("max", 10**9)),
                "step": float(entry.get("step", 1)),
                "max_step_change": float(entry.get("max_step_change", 1)),
                "direction": direction,
                "base_weight": float(entry.get("base_weight", 1.0)),
                "feature_weights": dict(entry.get("feature_weights", {})),
                "signal_weights": dict(entry.get("signal_weights", {})),
                "default_current": entry.get("default_current"),
            }
        )

    return {
        "version": raw.get("version", 1),
        "description": raw.get("description", ""),
        "parameters": normalized,
    }


def build_signal_context(df_eval: pd.DataFrame, summary: Dict[str, Any], severe_cp_loss: float) -> Dict[str, float]:
    if len(df_eval) == 0:
        return {
            "avg_cp_loss_risk": 0.0,
            "severe_rate": 0.0,
            "bestmove_miss_rate": 0.0,
            "instability_risk": 0.0,
            "capture_risk_delta": 0.0,
            "hanging_risk_delta": 0.0,
            "check_risk_delta": 0.0,
            "king_ring_risk_delta": 0.0,
            "king_file_risk": 0.0,
            "opening_risk": 0.0,
            "development_risk": 0.0,
            "endgame_risk": 0.0,
            "mobility_risk": 0.0,
            "pawn_structure_risk": 0.0,
            "threat_risk": 0.0,
            "endgame_conversion_risk": 0.0,
            "time_scramble_risk": 0.0,
            "depth_headroom_risk": 0.0,
        }

    cp = df_eval["cp_loss"].astype(float)
    avg_cp_loss = float(_safe_mean(cp))
    severe_rate = float((cp >= severe_cp_loss).mean()) if len(cp) else 0.0
    match_rate = summary.get("bestmove_match_rate")
    miss_rate = float(max(0.0, 1.0 - float(match_rate))) if match_rate is not None else 0.0

    capture_delta = 0.0
    if "played_is_capture" in df_eval.columns:
        cap = _mean_for_mask(df_eval, df_eval["played_is_capture"] == 1)
        quiet = _mean_for_mask(df_eval, df_eval["played_is_capture"] == 0)
        capture_delta = max(0.0, cap - quiet)

    hanging_delta = 0.0
    if "threatened_ours" in df_eval.columns:
        hi = _mean_for_mask(df_eval, df_eval["threatened_ours"] >= 1)
        lo = _mean_for_mask(df_eval, df_eval["threatened_ours"] == 0)
        hanging_delta = max(0.0, hi - lo)

    check_delta = 0.0
    if "opponent_checks_after" in df_eval.columns:
        hi = _mean_for_mask(df_eval, df_eval["opponent_checks_after"] >= 1)
        lo = _mean_for_mask(df_eval, df_eval["opponent_checks_after"] == 0)
        check_delta = max(0.0, hi - lo)

    ring_delta = 0.0
    if "king_ring_attacked" in df_eval.columns:
        hi = _mean_for_mask(df_eval, df_eval["king_ring_attacked"] >= 2)
        lo = _mean_for_mask(df_eval, df_eval["king_ring_attacked"] == 0)
        ring_delta = max(0.0, hi - lo)

    king_file_risk = 0.0
    if "king_file_open" in df_eval.columns:
        kf_hi = _mean_for_mask(df_eval, df_eval["king_file_open"] == 1)
        kf_lo = _mean_for_mask(df_eval, df_eval["king_file_open"] == 0)
        king_file_risk = max(0.0, kf_hi - kf_lo)

    opening_risk = 0.0
    if "opening_phase" in df_eval.columns:
        opening_risk = _mean_for_mask(df_eval, df_eval["opening_phase"] == 1)

    development_risk = 0.0
    if "opening_development_lag" in df_eval.columns:
        dev_hi = _mean_for_mask(df_eval, df_eval["opening_development_lag"] >= 2)
        dev_lo = _mean_for_mask(df_eval, df_eval["opening_development_lag"] <= 1)
        development_risk = max(0.0, dev_hi - dev_lo)

    endgame_risk = 0.0
    if "endgame_phase" in df_eval.columns:
        endgame_risk = _mean_for_mask(df_eval, df_eval["endgame_phase"] == 1)

    mobility_risk = 0.0
    if "mobility_delta" in df_eval.columns:
        cramped = _mean_for_mask(df_eval, df_eval["mobility_delta"] <= -1)
        fluid = _mean_for_mask(df_eval, df_eval["mobility_delta"] >= 1)
        mobility_risk = max(0.0, cramped - fluid)

    pawn_structure_delta = 0.0
    for col, threshold in (
        ("isolated_pawns", 1),
        ("doubled_pawns", 1),
        ("backward_pawns", 1),
        ("pawn_islands", 3),
    ):
        if col not in df_eval.columns:
            continue
        hi = _mean_for_mask(df_eval, df_eval[col] >= threshold)
        lo = _mean_for_mask(df_eval, df_eval[col] < threshold)
        pawn_structure_delta = max(pawn_structure_delta, hi - lo)

    threat_risk = 0.0
    if "threatened_delta" in df_eval.columns:
        high_pressure = _mean_for_mask(df_eval, df_eval["threatened_delta"] >= 1)
        calm = _mean_for_mask(df_eval, df_eval["threatened_delta"] <= 0)
        threat_risk = max(threat_risk, high_pressure - calm)
    if "threatened_ours" in df_eval.columns:
        under_attack = _mean_for_mask(df_eval, df_eval["threatened_ours"] >= 2)
        stable = _mean_for_mask(df_eval, df_eval["threatened_ours"] == 0)
        threat_risk = max(threat_risk, under_attack - stable)
    if "opponent_checks_after" in df_eval.columns:
        forcing = _mean_for_mask(df_eval, df_eval["opponent_checks_after"] >= 1)
        quiet = _mean_for_mask(df_eval, df_eval["opponent_checks_after"] == 0)
        threat_risk = max(threat_risk, forcing - quiet)

    endgame_conversion_risk = 0.0
    if "endgame_phase" in df_eval.columns:
        advantaged_mask = df_eval["endgame_phase"] == 1
        if "material_cp" in df_eval.columns:
            advantaged_mask = advantaged_mask & (df_eval["material_cp"] >= 60)
        neutral_mask = df_eval["endgame_phase"] == 0
        converted = _mean_for_mask(df_eval, advantaged_mask)
        non_endgame = _mean_for_mask(df_eval, neutral_mask)
        endgame_conversion_risk = max(0.0, converted - non_endgame, endgame_risk)
    else:
        endgame_conversion_risk = endgame_risk

    time_scramble_risk = 0.0
    if "time_pressure" in df_eval.columns:
        pressured = _mean_for_mask(df_eval, df_eval["time_pressure"] >= 1)
        calm = _mean_for_mask(df_eval, df_eval["time_pressure"] == 0)
        time_scramble_risk = max(0.0, pressured - calm)
    elif "remaining_ms" in df_eval.columns:
        pressured = _mean_for_mask(df_eval, df_eval["remaining_ms"] <= 10_000)
        calm = _mean_for_mask(df_eval, df_eval["remaining_ms"] >= 60_000)
        time_scramble_risk = max(0.0, pressured - calm)

    depth_headroom_risk = 0.0
    if "search_depth_gap" in df_eval.columns:
        constrained = _mean_for_mask(df_eval, df_eval["search_depth_gap"] >= 2)
        unconstrained = _mean_for_mask(df_eval, df_eval["search_depth_gap"] <= 0)
        depth_headroom_risk = max(0.0, constrained - unconstrained)

    avg_cp_loss_risk = _clamp(max(0.0, avg_cp_loss) / 220.0, 0.0, 1.0)
    severe_rate_risk = _clamp(severe_rate / 0.25, 0.0, 1.0)
    miss_risk = _clamp(miss_rate / 0.80, 0.0, 1.0)
    capture_risk = _clamp(capture_delta / 180.0, 0.0, 1.0)
    hanging_risk = _clamp(hanging_delta / 160.0, 0.0, 1.0)
    check_risk = _clamp(check_delta / 180.0, 0.0, 1.0)
    ring_risk = _clamp(ring_delta / 180.0, 0.0, 1.0)
    king_file_risk_n = _clamp(king_file_risk / 180.0, 0.0, 1.0)
    opening_risk_n = _clamp(max(0.0, opening_risk) / 220.0, 0.0, 1.0)
    development_risk_n = _clamp(development_risk / 180.0, 0.0, 1.0)
    endgame_risk_n = _clamp(max(0.0, endgame_risk) / 220.0, 0.0, 1.0)
    mobility_risk_n = _clamp(max(0.0, mobility_risk) / 180.0, 0.0, 1.0)
    pawn_structure_risk_n = _clamp(max(0.0, pawn_structure_delta) / 160.0, 0.0, 1.0)
    threat_risk_n = _clamp(max(0.0, threat_risk) / 180.0, 0.0, 1.0)
    endgame_conversion_risk_n = _clamp(max(0.0, endgame_conversion_risk) / 220.0, 0.0, 1.0)
    time_scramble_risk_n = _clamp(max(0.0, time_scramble_risk) / 180.0, 0.0, 1.0)
    instability = _clamp(0.55 * miss_risk + 0.25 * severe_rate_risk + 0.20 * avg_cp_loss_risk, 0.0, 1.0)
    depth_headroom_risk_n = _clamp(
        max(0.0, depth_headroom_risk, 0.65 * instability + 0.35 * miss_risk),
        0.0,
        1.0,
    )

    return {
        "avg_cp_loss_risk": avg_cp_loss_risk,
        "severe_rate": severe_rate_risk,
        "bestmove_miss_rate": miss_risk,
        "instability_risk": instability,
        "capture_risk_delta": capture_risk,
        "hanging_risk_delta": hanging_risk,
        "check_risk_delta": check_risk,
        "king_ring_risk_delta": ring_risk,
        "king_file_risk": king_file_risk_n,
        "opening_risk": opening_risk_n,
        "development_risk": development_risk_n,
        "endgame_risk": endgame_risk_n,
        "mobility_risk": mobility_risk_n,
        "pawn_structure_risk": pawn_structure_risk_n,
        "threat_risk": threat_risk_n,
        "endgame_conversion_risk": endgame_conversion_risk_n,
        "time_scramble_risk": time_scramble_risk_n,
        "depth_headroom_risk": depth_headroom_risk_n,
    }


def _weighted_average(mapping: Dict[str, float], weights: Dict[str, Any]) -> float:
    if not weights:
        return 0.0
    num = 0.0
    den = 0.0
    for key, raw_w in weights.items():
        try:
            w = float(raw_w)
        except Exception:
            continue
        den += abs(w)
        num += float(mapping.get(str(key), 0.0)) * w
    if den <= 1e-12:
        return 0.0
    return float(num / den)


def _quantize_value(value: float, step: float, kind: str) -> float:
    if step <= 0:
        return int(round(value)) if kind == "int" else float(value)
    snapped = round(value / step) * step
    if kind == "int":
        return float(int(round(snapped)))
    return float(snapped)


def _group_pressures(param_rows: List[Dict[str, Any]]) -> Dict[str, float]:
    by_group: Dict[str, List[float]] = {}
    for row in param_rows:
        grp = str(row.get("group", "misc"))
        by_group.setdefault(grp, []).append(float(row.get("composite_score", 0.0)))
    return {g: float(np.mean(vals)) if vals else 0.0 for g, vals in by_group.items()}


def _build_parameter_rows(
    constants: Dict[str, float],
    config_values: Dict[str, float],
    registry: Dict[str, Any],
    signal_context: Dict[str, float],
    importance_norm: Dict[str, float],
    training_volume_weight: float = 1.0,
) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for spec in registry.get("parameters", []):
        name = spec["name"]
        source = str(spec.get("source", "engine_constant"))
        current_key = str(spec.get("current_key", name))
        source_map = constants if source == "engine_constant" else config_values
        cur = source_map.get(current_key)
        if cur is None:
            cur = spec.get("default_current")
        if cur is None:
            continue

        feature_score = _weighted_average(importance_norm, spec.get("feature_weights", {}))
        signal_score = _weighted_average(signal_context, spec.get("signal_weights", {}))

        group = spec.get("group", "misc")
        if group == "capture_safety":
            group_score = (
                0.45 * signal_context.get("capture_risk_delta", 0.0)
                + 0.35 * signal_context.get("hanging_risk_delta", 0.0)
                + 0.20 * signal_context.get("severe_rate", 0.0)
            )
        elif group == "king_safety":
            group_score = (
                0.40 * signal_context.get("check_risk_delta", 0.0)
                + 0.35 * signal_context.get("king_ring_risk_delta", 0.0)
                + 0.25 * signal_context.get("king_file_risk", 0.0)
            )
        elif group == "tactical_horizon":
            group_score = (
                0.45 * signal_context.get("severe_rate", 0.0)
                + 0.35 * signal_context.get("check_risk_delta", 0.0)
                + 0.20 * signal_context.get("instability_risk", 0.0)
            )
        elif group == "search_stability":
            group_score = (
                0.50 * signal_context.get("instability_risk", 0.0)
                + 0.25 * signal_context.get("avg_cp_loss_risk", 0.0)
                + 0.25 * signal_context.get("bestmove_miss_rate", 0.0)
            )
        elif group == "opening_discipline":
            group_score = (
                0.55 * signal_context.get("opening_risk", 0.0)
                + 0.30 * signal_context.get("development_risk", 0.0)
                + 0.15 * signal_context.get("king_file_risk", 0.0)
            )
        elif group == "pawn_structure":
            group_score = (
                0.50 * signal_context.get("pawn_structure_risk", 0.0)
                + 0.25 * signal_context.get("opening_risk", 0.0)
                + 0.25 * signal_context.get("endgame_conversion_risk", 0.0)
            )
        elif group == "piece_activity":
            group_score = (
                0.50 * signal_context.get("mobility_risk", 0.0)
                + 0.30 * signal_context.get("threat_risk", 0.0)
                + 0.20 * signal_context.get("instability_risk", 0.0)
            )
        elif group == "threat_eval":
            group_score = (
                0.45 * signal_context.get("threat_risk", 0.0)
                + 0.30 * signal_context.get("hanging_risk_delta", 0.0)
                + 0.25 * signal_context.get("check_risk_delta", 0.0)
            )
        elif group == "endgame_conversion":
            group_score = (
                0.55 * signal_context.get("endgame_conversion_risk", 0.0)
                + 0.25 * signal_context.get("endgame_risk", 0.0)
                + 0.20 * signal_context.get("avg_cp_loss_risk", 0.0)
            )
        elif group == "root_regression":
            group_score = (
                0.45 * signal_context.get("instability_risk", 0.0)
                + 0.30 * signal_context.get("depth_headroom_risk", 0.0)
                + 0.25 * signal_context.get("bestmove_miss_rate", 0.0)
            )
        elif group == "lichess_time":
            group_score = (
                0.45 * signal_context.get("time_scramble_risk", 0.0)
                + 0.30 * signal_context.get("instability_risk", 0.0)
                + 0.25 * signal_context.get("endgame_conversion_risk", 0.0)
            )
        elif group == "lichess_depth":
            group_score = (
                0.50 * signal_context.get("depth_headroom_risk", 0.0)
                + 0.30 * signal_context.get("bestmove_miss_rate", 0.0)
                + 0.20 * signal_context.get("opening_risk", 0.0)
            )
        else:
            group_score = signal_context.get("avg_cp_loss_risk", 0.0)

        base_weight = float(spec.get("base_weight", 1.0))
        effective_weight = base_weight * _clamp(training_volume_weight, 0.05, 1.5)
        composite = _clamp(
            effective_weight * (0.45 * group_score + 0.35 * signal_score + 0.20 * feature_score),
            0.0,
            1.5,
        )

        rows.append(
            {
                "name": name,
                "group": group,
                "source": source,
                "current_key": current_key,
                "type": spec.get("type", "float"),
                "direction": spec.get("direction", "increase"),
                "current": float(cur),
                "min": float(spec.get("min", -1e18)),
                "max": float(spec.get("max", 1e18)),
                "step": float(spec.get("step", 1.0)),
                "max_step_change": float(spec.get("max_step_change", 1.0)),
                "base_weight": base_weight,
                "training_volume_weight": float(training_volume_weight),
                "feature_score": float(feature_score),
                "signal_score": float(signal_score),
                "group_score": float(group_score),
                "composite_score": float(composite),
            }
        )

    rows.sort(key=lambda r: r["composite_score"], reverse=True)
    return rows


def _candidate_from_rows(
    param_rows: List[Dict[str, Any]],
    scale: float,
    min_param_score: float,
    max_updates: int,
) -> Tuple[Dict[str, float], List[Dict[str, Any]]]:
    updates: Dict[str, float] = {}
    details: List[Dict[str, Any]] = []

    for row in param_rows:
        score = float(row["composite_score"])
        if score < min_param_score:
            continue

        direction = 1.0 if row["direction"] == "increase" else -1.0
        max_step_change = float(row["max_step_change"])
        step = float(row["step"])
        cur = float(row["current"])

        raw_step_units = score * max_step_change * max(0.1, scale)
        if raw_step_units < 0.35:
            continue
        step_units = max(1.0, raw_step_units)

        delta = direction * step_units * step
        candidate = _quantize_value(cur + delta, step, str(row["type"]))
        candidate = _clamp(candidate, float(row["min"]), float(row["max"]))
        candidate = _quantize_value(candidate, step, str(row["type"]))

        if abs(candidate - cur) < 1e-12:
            continue

        if row["type"] == "int":
            updates[row["name"]] = float(int(round(candidate)))
        else:
            updates[row["name"]] = float(candidate)

        details.append(
            {
                "name": row["name"],
                "group": row["group"],
                "source": row.get("source", "engine_constant"),
                "current_key": row.get("current_key", row["name"]),
                "old": cur,
                "new": float(updates[row["name"]]),
                "delta": float(updates[row["name"]] - cur),
                "direction": row["direction"],
                "composite_score": score,
                "normalized_change": float(
                    abs(updates[row["name"]] - cur) / max(1e-9, (float(row["max"]) - float(row["min"])))
                ),
            }
        )

        if len(updates) >= max_updates:
            break

    return updates, details


def _score_candidate_proxy(
    details: List[Dict[str, Any]],
    holdout_group_pressure: Dict[str, float],
) -> float:
    if not details:
        return -1e9

    gain = 0.0
    used_groups = set()
    for row in details:
        grp = str(row.get("group", "misc"))
        used_groups.add(grp)
        grp_pressure = float(holdout_group_pressure.get(grp, 0.0))
        base_score = float(row.get("composite_score", 0.0))
        change = float(row.get("normalized_change", 0.0))
        gain += (0.55 * base_score + 0.45 * grp_pressure) * max(0.02, change)

    complexity_penalty = 0.03 * len(details)
    group_penalty = 0.01 * max(0, len(used_groups) - 3)
    return float(gain - complexity_penalty - group_penalty)


def _adaptive_min_param_score(
    min_param_score: float,
    training_volume_weight: float,
    low_volume_relax_factor: float,
) -> float:
    # Relax threshold for low sample sizes while retaining a hard floor.
    relax = low_volume_relax_factor + (1.0 - low_volume_relax_factor) * _clamp(training_volume_weight, 0.0, 1.0)
    return float(max(0.04, float(min_param_score) * relax))


def _holdout_alignment_score(
    changed_groups: Iterable[str],
    train_group_pressure: Dict[str, float],
    holdout_group_pressure: Dict[str, float],
) -> float:
    vals: List[float] = []
    for grp in changed_groups:
        train_v = max(0.0, float(train_group_pressure.get(grp, 0.0)))
        holdout_v = max(0.0, float(holdout_group_pressure.get(grp, 0.0)))
        if train_v <= 1e-9:
            vals.append(1.0)
        else:
            vals.append(_clamp(holdout_v / train_v, 0.0, 1.0))
    return float(np.mean(vals)) if vals else 0.0


def optimize_constants_from_registry(
    df_train_eval: pd.DataFrame,
    df_holdout_eval: pd.DataFrame,
    summary_train: Dict[str, Any],
    summary_holdout: Dict[str, Any],
    feature_importance: Iterable[Tuple[str, float]],
    constants: Dict[str, float],
    registry_path: Path,
    severe_cp_loss: float,
    candidate_scales: Iterable[float],
    min_param_score: float,
    max_updates: int,
    training_volume_weight: float = 1.0,
    low_volume_relax_factor: float = 0.65,
    min_holdout_group_pressure: float = 0.035,
    min_holdout_alignment: float = 0.30,
    config_values: Dict[str, float] | None = None,
) -> Dict[str, Any]:
    registry = load_parameter_registry(registry_path)
    importance_norm = normalize_feature_importance(feature_importance)
    config_values = {} if config_values is None else dict(config_values)

    signal_context_train = build_signal_context(df_train_eval, summary_train, severe_cp_loss)
    signal_context_holdout = build_signal_context(df_holdout_eval, summary_holdout, severe_cp_loss)

    param_rows = _build_parameter_rows(
        constants,
        config_values,
        registry,
        signal_context_train,
        importance_norm,
        training_volume_weight=training_volume_weight,
    )
    group_pressure_train = _group_pressures(param_rows)

    holdout_rows = _build_parameter_rows(
        constants,
        config_values,
        registry,
        signal_context_holdout,
        importance_norm,
        training_volume_weight=training_volume_weight,
    )
    group_pressure_holdout = _group_pressures(holdout_rows)

    adaptive_min_param_score = _adaptive_min_param_score(
        min_param_score=min_param_score,
        training_volume_weight=training_volume_weight,
        low_volume_relax_factor=low_volume_relax_factor,
    )

    candidate_results: List[Dict[str, Any]] = []
    for scale in candidate_scales:
        updates, details = _candidate_from_rows(
            param_rows,
            float(scale),
            adaptive_min_param_score,
            max_updates,
        )

        changed_groups = sorted({str(row.get("group", "misc")) for row in details})
        holdout_support = float(
            np.mean([float(group_pressure_holdout.get(g, 0.0)) for g in changed_groups])
        ) if changed_groups else 0.0
        holdout_alignment = _holdout_alignment_score(changed_groups, group_pressure_train, group_pressure_holdout)
        safeguard_rejected = bool(
            changed_groups
            and (
                holdout_support < float(min_holdout_group_pressure)
                or holdout_alignment < float(min_holdout_alignment)
            )
        )
        reject_reason = None
        if safeguard_rejected:
            reject_reason = (
                f"holdout_support={holdout_support:.4f} (< {float(min_holdout_group_pressure):.4f}) "
                f"or holdout_alignment={holdout_alignment:.4f} (< {float(min_holdout_alignment):.4f})"
            )
            updates = {}
            details = []

        proxy_score = _score_candidate_proxy(details, group_pressure_holdout)

        candidate_results.append(
            {
                "name": f"scale_{scale}",
                "scale": float(scale),
                "proxy_score": float(proxy_score),
                "estimated_cp_loss_reduction": float(max(0.0, proxy_score) * 65.0),
                "updates": updates,
                "details": details,
                "changed_constants": sorted(list(updates.keys())),
                "adaptive_min_param_score": float(adaptive_min_param_score),
                "holdout_support": float(holdout_support),
                "holdout_alignment": float(holdout_alignment),
                "safeguard_rejected": safeguard_rejected,
                "safeguard_reason": reject_reason,
            }
        )

    candidate_results.sort(key=lambda x: x["proxy_score"], reverse=True)
    selected = (
        candidate_results[0]
        if candidate_results
        else {
            "name": "none",
            "scale": 0.0,
            "proxy_score": -1e9,
            "estimated_cp_loss_reduction": 0.0,
            "updates": {},
            "details": [],
            "changed_constants": [],
            "adaptive_min_param_score": float(adaptive_min_param_score),
            "holdout_support": 0.0,
            "holdout_alignment": 0.0,
            "safeguard_rejected": False,
            "safeguard_reason": None,
        }
    )

    proposed_constant_updates = {
        row["name"]: float(selected["updates"][row["name"]])
        for row in selected.get("details", [])
        if row.get("source") == "engine_constant" and row.get("name") in selected.get("updates", {})
    }
    proposed_config_updates = {
        row["name"]: float(selected["updates"][row["name"]])
        for row in selected.get("details", [])
        if row.get("source") == "external_config" and row.get("name") in selected.get("updates", {})
    }

    return {
        "registry": registry,
        "importance_norm": importance_norm,
        "signal_context_train": signal_context_train,
        "signal_context_holdout": signal_context_holdout,
        "group_pressure_train": group_pressure_train,
        "group_pressure_holdout": group_pressure_holdout,
        "training_volume_weight": float(training_volume_weight),
        "low_volume_relax_factor": float(low_volume_relax_factor),
        "min_holdout_group_pressure": float(min_holdout_group_pressure),
        "min_holdout_alignment": float(min_holdout_alignment),
        "adaptive_min_param_score": float(adaptive_min_param_score),
        "parameter_rows": param_rows,
        "candidate_results": candidate_results,
        "selected_candidate": selected,
        "proposed_updates": proposed_constant_updates,
        "proposed_constant_updates": proposed_constant_updates,
        "proposed_config_updates": proposed_config_updates,
    }
