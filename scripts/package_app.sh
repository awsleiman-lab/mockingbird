#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Mockingbird.app"
CACHE="$ROOT/build-cache/swift"

mkdir -p "$CACHE"
mkdir -p "$ROOT/AppBundle/Contents/Resources"

cd "$ROOT"
swift "$ROOT/scripts/generate_icon.swift"
iconutil -c icns "$ROOT/AppBundle/Contents/Resources/Mockingbird.iconset" -o "$ROOT/AppBundle/Contents/Resources/Mockingbird.icns"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$CACHE" \
swift build --scratch-path "$ROOT/.build"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/AppBundle/Contents/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppBundle/Contents/Resources/Mockingbird.icns" "$APP/Contents/Resources/Mockingbird.icns"
/usr/libexec/PlistBuddy -c "Set :MockingbirdProjectRoot $ROOT" "$APP/Contents/Info.plist"
cp "$ROOT/.build/debug/Mockingbird" "$APP/Contents/MacOS/Mockingbird"
chmod +x "$APP/Contents/MacOS/Mockingbird"

SIGN_IDENTITY="${MOCKINGBIRD_CODESIGN_IDENTITY:-Apple Development: awsleiman@gmail.com (DHJ2DRBQLW)}"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
echo "$APP"
