#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/package_app.sh" >/dev/null

pkill -x KokoroBar >/dev/null 2>&1 || true
rm -rf /Applications/KokoroBar.app
cp -R "$ROOT/KokoroBar.app" /Applications/KokoroBar.app
rm -rf "$ROOT/KokoroBar.app"
open /Applications/KokoroBar.app

echo "/Applications/KokoroBar.app"
