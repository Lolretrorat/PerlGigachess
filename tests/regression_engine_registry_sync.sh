#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

(cd "$ROOT_DIR" && ./.venv/bin/python - <<'PY')
import json
import re
from pathlib import Path

registry = json.loads(Path("analysis/engine_param_registry.json").read_text(encoding="utf-8"))

constant_names = set()
const_re = re.compile(r"^\s*use constant\s+([A-Z0-9_]+)\s*=>", re.MULTILINE)
for path in (Path("Chess/Heuristics.pm"), Path("Chess/Engine.pm")):
    constant_names.update(const_re.findall(path.read_text(encoding="utf-8")))

lichess_text = Path("lichess.pl").read_text(encoding="utf-8")
env_names = set(re.findall(r"ENV\{([A-Z0-9_]+)\}", lichess_text))
env_names.update(re.findall(r"_env_int_range\(\s*'([A-Z0-9_]+)'", lichess_text))

missing_constants = []
missing_config = []

for spec in registry.get("parameters", []):
    source = str(spec.get("source", "engine_constant"))
    name = str(spec.get("name", ""))
    current_key = str(spec.get("current_key", name))
    if not name:
        continue
    if source == "engine_constant":
        if current_key not in constant_names:
            missing_constants.append(current_key)
    elif source == "external_config":
        if current_key not in env_names:
            missing_config.append(current_key)
    else:
        raise AssertionError(f"unsupported registry source: {source}")

assert not missing_constants, f"registry engine constants missing in code: {sorted(set(missing_constants))}"
assert not missing_config, f"registry external config keys missing in lichess.pl: {sorted(set(missing_config))}"

print("engine registry sync regression: ok")
PY
