#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

cd "$ROOT"

if [[ ! -x ".venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv .venv
fi

".venv/bin/python" -m pip install --upgrade pip setuptools wheel
".venv/bin/python" -m pip install kokoro soundfile numpy
".venv/bin/python" "$ROOT/python/synthesize.py" "Mockingbird setup complete." >/tmp/mockingbird-setup-smoke.log
echo "Mockingbird setup complete."
