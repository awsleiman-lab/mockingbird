#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/package_app.sh" >/dev/null

pkill -x Mockingbird >/dev/null 2>&1 || true
pkill -f "$ROOT/.venv/bin/python $ROOT/python/tts_service.py" >/dev/null 2>&1 || true
rm -rf /Applications/Mockingbird.app
cp -R "$ROOT/Mockingbird.app" /Applications/Mockingbird.app
rm -rf "$ROOT/Mockingbird.app"
open /Applications/Mockingbird.app

echo "/Applications/Mockingbird.app"
