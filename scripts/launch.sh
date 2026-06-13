#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -d "$ROOT/KokoroBar.app" ]]; then
  "$ROOT/scripts/package_app.sh"
fi

open "$ROOT/KokoroBar.app"
