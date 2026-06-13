#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -d "$ROOT/Mockingbird.app" ]]; then
  "$ROOT/scripts/package_app.sh"
fi

open "$ROOT/Mockingbird.app"
