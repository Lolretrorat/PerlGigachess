#!/usr/bin/env python3
"""Interactive Streamlit dashboard for PerlGigachess metrics."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import altair as alt
import numpy as np
import pandas as pd
import streamlit as st

REPO_ROOT = Path(__file__).resolve().parents[1]
ENGINE_PATH = REPO_ROOT / "Chess" / "Engine.pm"
LOC_MOD_PATH = REPO_ROOT / "Chess" / "LocationModifer.pm"
PERFT_SCRIPT = REPO_ROOT / "perft.pl"

BUILTIN_POSITIONS: List[Dict[str, Optional[str]]] = [
    {"label": "Default start position", "index": None, "fen": None},
    {
        "label": "Position 0 – r3k2r/p1ppqpb1/…",
        "index": 0,
        "fen": "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -",
    },
    {
        "label": "Position 1 – 8/2p5/…",
        "index": 1,
        "fen": "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -",
    },
    {
        "label": "Position 2 – r3k2r/Pppp1ppp/…",
        "index": 2,
        "fen": "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    },
    {
        "label": "Position 3 – rnbq1k1r/pp1Pbppp/…",
        "index": 3,
        "fen": "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    },
    {
        "label": "Position 4 – r4rk1/1pp1qppp/…",
        "index": 4,
        "fen": "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    },
]


@st.cache_data(show_spinner=False)
def load_piece_values() -> Dict[str, int]:
    """Parse %piece_values from Chess::Engine."""
    text = ENGINE_PATH.read_text(encoding="utf-8")
    match = re.search(r"my %piece_values = \((.*?)\);", text, re.S)
    if not match:
        raise ValueError("Could not locate %piece_values in Chess/Engine.pm")
    block = match.group(1)
    values: Dict[str, int] = {}
    for key, value in re.findall(r"([A-Z_]+),\s*(-?\d+)", block):
        values[key] = int(value)
    return values


@st.cache_data(show_spinner=False)
def load_location_modifiers() -> Dict[str, Dict[str, float]]:
    """Parse %location_modifiers from Chess::LocationModifer."""
    text = LOC_MOD_PATH.read_text(encoding="utf-8")
    pieces = {}
    piece = None
    for line in text.splitlines():
        piece_match = re.match(r"\s*([A-Z_]+)\s*=>\s*\{", line)
        if piece_match:
            piece = piece_match.group(1)
            pieces[piece] = {}
            continue
        if piece is None:
            continue
        if "}," in line:
            piece = None
            continue
        entry_match = re.findall(r"([a-h][1-8])\s*=>\s*(-?\d+)", line, re.I)
        for square, value in entry_match:
            pieces[piece][square.lower()] = float(value)
    if not pieces:
        raise ValueError("Failed to parse location modifiers.")
    return pieces


@st.cache_data(show_spinner=True)
def run_perft(depth: int, position_index: int | None) -> Dict[str, Dict[str, int]]:
    """Invoke perft.pl and parse its output."""
    cmd = ["perl", str(PERFT_SCRIPT), str(depth)]
    if position_index is not None:
        cmd.append(str(position_index))
    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout)
    depth_stats: Dict[str, Dict[str, int]] = {}
    current_depth = None
    for line in proc.stdout.splitlines():
        depth_match = re.match(r"\s*Depth\s+(\d+):", line)
        if depth_match:
            current_depth = depth_match.group(1)
            depth_stats[current_depth] = {}
            continue
        if current_depth:
            metric_match = re.match(r"\s*(\w+):\s+(\d+)", line.strip())
            if metric_match:
                metric, value = metric_match.groups()
                depth_stats[current_depth][metric.lower()] = int(value)
    return depth_stats


def render_piece_values(values: Dict[str, int]) -> None:
    friendly = []
    for name, score in values.items():
        color = "White" if not name.startswith("OPP_") else "Black"
        friendly_name = name.replace("OPP_", "Opposition ").title()
        friendly.append({"Piece": friendly_name, "Color": color, "Value": score})
    df = pd.DataFrame(friendly).sort_values(by="Value", ascending=False)
    st.dataframe(df, use_container_width=True, hide_index=True)


def location_heatmap(piece: str, squares: Dict[str, float]) -> None:
    data = []
    files = "abcdefgh"
    for file_idx, file in enumerate(files):
        for rank in range(1, 9):
            square = f"{file}{rank}"
            row = 8 - rank
            col = file_idx
            data.append(
                {
                    "file": file.upper(),
                    "rank": rank,
                    "value": squares.get(square, 0.0),
                    "row": row,
                    "col": col,
                }
            )
    df = pd.DataFrame(data)
    heatmap = (
        alt.Chart(df)
        .mark_rect()
        .encode(
            x=alt.X("file:O", sort=list(reversed(list("ABCDEFGH")))),
            y=alt.Y("rank:O", sort=list(range(8, 0, -1))),
            color=alt.Color("value:Q", scale=alt.Scale(scheme="redyellowgreen")),
        )
        .properties(width=350, height=350, title=f"{piece} Location Modifiers")
    )
    st.altair_chart(heatmap, use_container_width=True)
    st.caption(
        "Values in centipawns; positive favors the side to move after mirroring black positions."
    )


def perft_section() -> None:
    st.subheader("Perft Explorer")
    col_depth, col_pos = st.columns([1, 2])
    with col_depth:
    depth = st.slider("Depth", min_value=1, max_value=6, value=3)
    with col_pos:
        selection_index = st.selectbox(
            "Built-in position",
            options=list(range(len(BUILTIN_POSITIONS))),
            format_func=lambda idx: BUILTIN_POSITIONS[idx]["label"],
        )
    selected = BUILTIN_POSITIONS[selection_index]
    if selected["fen"]:
        st.code(selected["fen"], language="text")
    if st.button("Run perft", type="primary"):
        try:
            stats = run_perft(depth, selected["index"])
        except RuntimeError as exc:
            st.error(f"Perft failed: {exc}")
            return
        st.success(f"Computed perft({depth}) with {len(stats)} depth rows.")
        rows = []
        for lvl, metrics in stats.items():
            row = {"Depth": int(lvl)}
            row.update({k.title(): v for k, v in metrics.items()})
            rows.append(row)
        df = pd.DataFrame(rows).sort_values("Depth")
        st.dataframe(df, use_container_width=True, hide_index=True)


def main() -> None:
    st.set_page_config(
        page_title="PerlGigachess Dashboard", layout="wide", initial_sidebar_state="expanded"
    )
    st.title("PerlGigachess Engine Dashboard")
    st.write(
        "Inspect static evaluation parameters, visualize location modifiers, "
        "and trigger quick perft runs without leaving your browser."
    )

    values = load_piece_values()
    modifiers = load_location_modifiers()

    st.subheader("Piece Value Summary")
    render_piece_values(values)

    st.subheader("Location Modifier Heatmap")
    selected_piece = st.selectbox("Piece", options=sorted(modifiers.keys()))
    location_heatmap(selected_piece, modifiers[selected_piece])

    perft_section()

    st.sidebar.header("About")
    st.sidebar.markdown(
        f"""
        - Engine depth in `uci.pl`/`play.pl`: **4 ply**
        - Piece-square tables parsed from `Chess/LocationModifer.pm`
        - Piece values parsed from `Chess/Engine.pm`
        - Perft script: `{PERFT_SCRIPT.name}`
        """
    )
    st.sidebar.info("Run with `streamlit run analysis/engine_dashboard.py`.")


if __name__ == "__main__":
    main()
