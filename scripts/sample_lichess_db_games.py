#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import sys
import urllib.request
from pathlib import Path


def _is_zst(url: str) -> bool:
    base = url.split("?", 1)[0].lower()
    return base.endswith(".zst")


def sample_games(url: str, output: Path, max_games: int, progress_every: int) -> int:
    output.parent.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "PerlGigachess-sampler/1.0",
            "Accept-Encoding": "identity",
        },
    )

    with urllib.request.urlopen(req) as response:
        if _is_zst(url):
            try:
                import zstandard as zstd
            except ImportError as exc:
                raise RuntimeError("zstandard package is required for .zst URLs") from exc
            stream = zstd.ZstdDecompressor().stream_reader(response)
            text_stream = io.TextIOWrapper(stream, encoding="utf-8", errors="ignore")
        else:
            text_stream = io.TextIOWrapper(response, encoding="utf-8", errors="ignore")

        count = 0
        with output.open("w", encoding="utf-8") as out:
            for line in text_stream:
                if line.startswith("[Event "):
                    if count >= max_games:
                        break
                    count += 1
                    if progress_every > 0 and count % progress_every == 0:
                        print(f"[sample] {output.name}: captured {count} games", file=sys.stderr, flush=True)
                if count > 0 and count <= max_games:
                    out.write(line)

        return count


def main() -> int:
    parser = argparse.ArgumentParser(description="Stream-sample N games from a Lichess monthly PGN URL")
    parser.add_argument("--url", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-games", type=int, required=True)
    parser.add_argument("--progress-every", type=int, default=500)
    args = parser.parse_args()

    if args.max_games <= 0:
        raise SystemExit("--max-games must be > 0")

    output = Path(args.output).resolve()
    print(f"[sample] url={args.url}", file=sys.stderr, flush=True)
    print(f"[sample] output={output}", file=sys.stderr, flush=True)
    print(f"[sample] target_games={args.max_games}", file=sys.stderr, flush=True)
    count = sample_games(args.url, output, args.max_games, args.progress_every)
    print(f"[sample] complete: wrote {count} games to {output}", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
