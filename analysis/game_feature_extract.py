#!/usr/bin/env python3
"""
Stream chess PGNs into shardable feature/label tensors.

Each quiet (non-capture, non-promotion) position is encoded so the side to move
is always treated as white. Features are piece-square one-hot vectors plus a
phase bucket. Labels reflect the eventual game result from the normalized side
to move, and sample weights blend player rating and phase importance.
"""

from __future__ import annotations

import argparse
import io
import json
import pathlib
from typing import Dict, Iterable, List, Tuple

import numpy as np

try:
    import chess
    import chess.pgn
except ImportError as exc:  # pragma: no cover - runtime dependency
    raise SystemExit(
        "python-chess is required. Install with 'python -m pip install python-chess'."
    ) from exc


PIECE_TO_OFFSET: Dict[Tuple[bool, int], int] = {}
_piece_order = (
    (True, chess.PAWN),
    (True, chess.KNIGHT),
    (True, chess.BISHOP),
    (True, chess.ROOK),
    (True, chess.QUEEN),
    (True, chess.KING),
    (False, chess.PAWN),
    (False, chess.KNIGHT),
    (False, chess.BISHOP),
    (False, chess.ROOK),
    (False, chess.QUEEN),
    (False, chess.KING),
)
for idx, key in enumerate(_piece_order):
    PIECE_TO_OFFSET[key] = idx * 64

FEATURE_LENGTH = len(_piece_order) * 64 + 3  # PST + phase one-hot
RESULT_MAP = {"1-0": 1.0, "0-1": -1.0, "1/2-1/2": 0.0}
PHASE_NAMES = ("opening", "middlegame", "endgame")
PHASE_WEIGHTS = (0.75, 1.0, 1.25)
phase_boundaries: Tuple[int, int] = (20, 60)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert PGN games into shardable numpy training data."
    )
    parser.add_argument("pgn", help="Path to source PGN file (can be .pgn or .pgn.zst).")
    parser.add_argument(
        "--output-dir",
        default="data/processed",
        help="Directory for npz shards (default: data/processed).",
    )
    parser.add_argument(
        "--shard-size",
        type=int,
        default=25000,
        help="Number of samples per shard (default: 25000).",
    )
    parser.add_argument(
        "--max-games",
        type=int,
        help="Optional limit on games to parse (useful for smoke tests).",
    )
    parser.add_argument(
        "--min-elo",
        type=int,
        default=1600,
        help="Skip games where either player Elo is below this rating (default: 1600).",
    )
    parser.add_argument(
        "--phase-boundaries",
        type=int,
        nargs=2,
        default=(20, 60),
        metavar=("MIDGAME_PLY", "ENDGAME_PLY"),
        help="Ply where middlegame and endgame buckets begin (default: 20 60).",
    )
    parser.add_argument(
        "--write-metadata",
        action="store_true",
        help="Emit JSONL metadata next to each shard for reproducibility.",
    )
    return parser.parse_args()


def ensure_output_dir(path: str) -> pathlib.Path:
    out_path = pathlib.Path(path)
    out_path.mkdir(parents=True, exist_ok=True)
    return out_path


def open_pgn_stream(path: str):
    pgn_path = pathlib.Path(path)
    if pgn_path.suffix == ".zst":
        try:
            import zstandard
        except ImportError as exc:  # pragma: no cover
            raise SystemExit(
                "zstandard is required to read .zst PGNs. "
                "Install with 'python -m pip install zstandard'."
            ) from exc
        dctx = zstandard.ZstdDecompressor()
        reader = pgn_path.open("rb")
        stream = dctx.stream_reader(reader)
        text_stream = io.TextIOWrapper(stream, encoding="utf-8", errors="ignore")
        return text_stream
    return pgn_path.open("r", encoding="utf-8", errors="ignore")


def normalize_square(square: int) -> int:
    """Rotate board 180 degrees so the side to move always faces ranks 1-2."""
    file_idx = chess.square_file(square)
    rank_idx = chess.square_rank(square)
    norm_file = 7 - file_idx
    norm_rank = 7 - rank_idx
    return chess.square(norm_file, norm_rank)


def encode_features(board: chess.Board) -> np.ndarray:
    """Encode board occupancy plus phase bucket as a dense binary vector."""
    vector = np.zeros(FEATURE_LENGTH, dtype=np.int8)
    turn_is_white = board.turn == chess.WHITE

    for square, piece in board.piece_map().items():
        encoded_square = square
        is_white_piece = piece.color
        if not turn_is_white:
            encoded_square = normalize_square(square)
            is_white_piece = not is_white_piece

        offset = PIECE_TO_OFFSET[(is_white_piece, piece.piece_type)]
        vector[offset + encoded_square] = 1

    phase_index = phase_bucket(board, turn_is_white)
    vector[len(_piece_order) * 64 + phase_index] = 1
    return vector


def phase_bucket(board: chess.Board, turn_is_white: bool) -> int:
    """Return 0/1/2 for opening/middlegame/endgame based on ply."""
    ply_count = board.fullmove_number * 2 - (0 if turn_is_white else 1)
    midgame_ply, endgame_ply = phase_boundaries
    if ply_count < midgame_ply:
        return 0
    if ply_count < endgame_ply:
        return 1
    return 2


def compute_game_weight(game: chess.pgn.Game, min_elo: int) -> float:
    def parse_elo(tag: str) -> float | None:
        value = game.headers.get(tag)
        if not value:
            return None
        try:
            return float(value)
        except ValueError:
            return None

    white_elo = parse_elo("WhiteElo")
    black_elo = parse_elo("BlackElo")

    if white_elo and black_elo:
        if white_elo < min_elo or black_elo < min_elo:
            return 0.0
        mean_elo = (white_elo + black_elo) / 2.0
        return 1.0 + max(0.0, (mean_elo - min_elo) / 800.0)
    return 1.0


def flush_shard(
    out_dir: pathlib.Path,
    shard_idx: int,
    features: List[np.ndarray],
    labels: List[float],
    weights: List[float],
    metadata: List[Dict[str, object]],
    write_meta: bool,
) -> bool:
    if not features:
        return False
    shard_path = out_dir / f"shard_{shard_idx:05d}.npz"
    np.savez_compressed(
        shard_path,
        features=np.stack(features, axis=0),
        labels=np.asarray(labels, dtype=np.float32),
        weights=np.asarray(weights, dtype=np.float32),
    )
    if write_meta:
        meta_path = shard_path.with_suffix(".metadata.jsonl")
        with meta_path.open("w", encoding="utf-8") as handle:
            for entry in metadata:
                handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    return True


def iter_games(handle: Iterable[str]) -> Iterable[chess.pgn.Game]:
    while True:
        game = chess.pgn.read_game(handle)
        if game is None:
            break
        yield game


def main() -> None:
    args = parse_args()
    out_dir = ensure_output_dir(args.output_dir)
    shard_size = max(1, args.shard_size)

    global phase_boundaries  # cache for encode_features
    phase_boundaries = tuple(args.phase_boundaries)

    features_batch: List[np.ndarray] = []
    labels_batch: List[float] = []
    weights_batch: List[float] = []
    metadata_batch: List[Dict[str, object]] = []

    shard_idx = 0
    processed_games = 0
    kept_positions = 0

    with open_pgn_stream(args.pgn) as handle:
        for game_idx, game in enumerate(iter_games(handle)):
            if args.max_games and processed_games >= args.max_games:
                break

            result_tag = game.headers.get("Result")
            base_result = RESULT_MAP.get(result_tag)
            if base_result is None:
                continue

            game_weight = compute_game_weight(game, args.min_elo)
            if game_weight <= 0.0:
                continue

            board = game.board()
            ply_in_game = 0
            for move in game.mainline_moves():
                include = (
                    not board.is_capture(move)
                    and move.promotion is None
                    and not board.is_castling(move)
                )
                if include:
                    turn_is_white = board.turn == chess.WHITE
                    encoded = encode_features(board)
                    label = base_result if turn_is_white else -base_result
                    phase_idx = np.argmax(encoded[-3:])
                    weight = game_weight * PHASE_WEIGHTS[phase_idx]

                    features_batch.append(encoded)
                    labels_batch.append(label)
                    weights_batch.append(weight)
                    if args.write_metadata:
                        metadata_batch.append(
                            {
                                "game_index": game_idx,
                                "ply": ply_in_game,
                                "result": result_tag,
                                "phase": PHASE_NAMES[phase_idx],
                                "fen": board.fen(),
                            }
                        )
                    kept_positions += 1

                    if len(features_batch) >= shard_size:
                        if flush_shard(
                            out_dir,
                            shard_idx,
                            features_batch,
                            labels_batch,
                            weights_batch,
                            metadata_batch,
                            args.write_metadata,
                        ):
                            shard_idx += 1
                            features_batch.clear()
                            labels_batch.clear()
                            weights_batch.clear()
                            metadata_batch.clear()

                board.push(move)
                ply_in_game += 1

            processed_games += 1

    if flush_shard(
        out_dir,
        shard_idx,
        features_batch,
        labels_batch,
        weights_batch,
        metadata_batch,
        args.write_metadata,
    ):
        shard_idx += 1
        features_batch.clear()
        labels_batch.clear()
        weights_batch.clear()
        metadata_batch.clear()

    print(
        f"Processed {processed_games} games, extracted {kept_positions} quiet positions "
        f"into {shard_idx} shard(s) under {out_dir}"
    )


if __name__ == "__main__":
    main()
