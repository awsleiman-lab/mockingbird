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
".venv/bin/python" "$ROOT/python/kokoro_service.py" --port 8766 >/tmp/kokoro-setup-smoke.log 2>&1 &
service_pid=$!

for _ in {1..80}; do
  if curl -fsS http://127.0.0.1:8766/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

curl -fsS -X POST http://127.0.0.1:8766/synthesize \
  -H 'Content-Type: application/json' \
  -d '{"text":"Kokoro setup complete.","voice":"af_heart","speed":1.0}' >/dev/null

kill "$service_pid" >/dev/null 2>&1 || true
echo "KokoroBar setup complete."
