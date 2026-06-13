#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/Mockingbird.app"
ZIP="$DIST/Mockingbird.zip"

"$ROOT/scripts/package_app.sh" >/dev/null

rm -rf "$DIST"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$APP"

echo "$ZIP"
