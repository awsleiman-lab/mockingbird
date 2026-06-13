#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/KokoroBar.app"
CACHE="$ROOT/build-cache/swift"

mkdir -p "$CACHE"

cd "$ROOT"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$CACHE" \
swift build --scratch-path "$ROOT/.build"

mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/AppBundle/Contents/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :KokoroBarProjectRoot $ROOT" "$APP/Contents/Info.plist"
cp "$ROOT/.build/debug/KokoroBar" "$APP/Contents/MacOS/KokoroBar"
chmod +x "$APP/Contents/MacOS/KokoroBar"

SIGN_IDENTITY="${KOKORO_CODESIGN_IDENTITY:-Apple Development: awsleiman@gmail.com (DHJ2DRBQLW)}"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
echo "$APP"
