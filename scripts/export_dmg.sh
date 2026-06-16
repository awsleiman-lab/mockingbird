#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/Mockingbird.app"
STAGING="$DIST/dmg-staging"
DMG="$DIST/Mockingbird.dmg"

"$ROOT/scripts/package_app.sh" >/dev/null

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Mockingbird.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Mockingbird" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGING" "$APP"

echo "$DMG"
