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

# Notarize when a Developer ID certificate is available; otherwise the DMG
# is local-only and other Macs will refuse to open it.
NOTARY_PROFILE="${MOCKINGBIRD_NOTARY_PROFILE:-mockingbird-notary}"
DEV_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'index($2, "Developer ID Application") == 1 {print $2; exit}')"

if [[ -z "$DEV_ID" ]]; then
  echo "warning: no Developer ID Application certificate found; skipping notarization" >&2
  echo "$DMG"
  exit 0
fi

echo "Signing DMG with $DEV_ID..."
codesign --force --sign "$DEV_ID" --timestamp "$DMG"

echo "Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG"

echo "Verifying with Gatekeeper..."
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "$DMG"
