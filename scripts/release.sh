#!/bin/zsh
set -euo pipefail

# Cuts a Mockingbird release:
#   1. Bumps CFBundleShortVersionString to the given version and increments
#      CFBundleVersion.
#   2. Builds the notarized DMG (scripts/export_dmg.sh).
#   3. Copies it into dist/releases/ as Mockingbird-<version>.dmg.
#   4. Regenerates appcast.xml (EdDSA-signed with the "Mockingbird" key from
#      the keychain) for Sparkle auto-updates.
#
# Publishing afterwards:
#   - Upload dist/releases/Mockingbird-<version>.dmg as an asset of the
#     GitHub release tagged "downloads" on awsleiman171/mockingbird.
#     All versions live under that one rolling tag so appcast URLs stay valid.
#   - Commit and push appcast.xml to main (the app reads it from
#     raw.githubusercontent.com).
#
# Usage: scripts/release.sh 1.0.1

VERSION="${1:?usage: release.sh <marketing version, e.g. 1.0.1>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/AppBundle/Contents/Info.plist"
RELEASES="$ROOT/dist/releases"
APPCAST="$ROOT/appcast.xml"
GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
DOWNLOAD_PREFIX="${MOCKINGBIRD_DOWNLOAD_PREFIX:-https://github.com/awsleiman171/mockingbird/releases/download/downloads/}"

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "generate_appcast not found at $GENERATE_APPCAST — run 'swift build -c release' once first." >&2
  exit 1
fi

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NEW_BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
echo "Releasing Mockingbird $VERSION (build $NEW_BUILD)"

"$ROOT/scripts/export_dmg.sh"

mkdir -p "$RELEASES"
cp "$ROOT/dist/Mockingbird.dmg" "$RELEASES/Mockingbird-$VERSION.dmg"

echo "Generating signed appcast..."
"$GENERATE_APPCAST" \
  --account Mockingbird \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o "$APPCAST" \
  "$RELEASES"

echo ""
echo "Release ready:"
echo "  DMG:     $RELEASES/Mockingbird-$VERSION.dmg"
echo "  Appcast: $APPCAST"
echo ""
echo "To publish:"
echo "  1. Upload the DMG as an asset of the GitHub release tagged 'downloads'."
echo "  2. Commit and push appcast.xml to main."
