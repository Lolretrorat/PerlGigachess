#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import traceback
from pathlib import Path


def display(*args, **kwargs):
    for arg in args:
        print(arg)


def execute_notebook(notebook_path: Path) -> None:
    nb = json.loads(notebook_path.read_text(encoding="utf-8"))
    ctx = {"__name__": "__main__", "display": display}

    code_cells = [c for c in nb.get("cells", []) if c.get("cell_type") == "code"]
    print(f"[runner] executing {len(code_cells)} code cells from {notebook_path}")
    for idx, cell in enumerate(nb.get("cells", [])):
        if cell.get("cell_type") != "code":
            continue
        src = "".join(cell.get("source", []))
        if not src.strip():
            continue
        label = f"{notebook_path}::cell{idx}"
        print(f"[runner] --> {label}", flush=True)
        try:
            exec(compile(src, label, "exec"), ctx, ctx)
        except Exception:
            print(f"[runner] cell failed: {label}", flush=True)
            traceback.print_exc()
            raise


def main() -> int:
    parser = argparse.ArgumentParser(description="Execute a notebook's code cells sequentially without Jupyter")
    parser.add_argument("--notebook", required=True)
    args = parser.parse_args()

    notebook = Path(args.notebook).resolve()
    execute_notebook(notebook)
    print("[runner] notebook execution complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
