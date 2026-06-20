#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Mockingbird.app"
CACHE="$ROOT/build-cache/swift"
HELPER_DIR="$ROOT/build-cache/helpers/MockingbirdSynth"
HELPER_BIN="$HELPER_DIR/MockingbirdSynth"
SPEECH_ASSETS="$ROOT/build-cache/speech-assets/huggingface"
APP_HELPER_ROOT="$APP/Contents/Resources/speech-helper"

mkdir -p "$CACHE"
mkdir -p "$ROOT/AppBundle/Contents/Resources"

sign_macho_files() {
  local search_root="$1"
  while IFS= read -r -d '' file_path; do
    if [[ "$(file -b "$file_path")" == Mach-O* ]]; then
      codesign "${CODESIGN_OPTIONS[@]}" "$file_path"
    fi
  done < <(find "$search_root" -type f -print0)
}

cd "$ROOT"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$CACHE" \
swift "$ROOT/scripts/generate_icon.swift"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$CACHE" \
swift build --scratch-path "$ROOT/.build"

if [[ "${MOCKINGBIRD_SKIP_SPEECH_HELPER:-0}" != "1" ]]; then
  if [[ "${MOCKINGBIRD_REUSE_SPEECH_HELPER:-0}" != "1" || ! -x "$HELPER_BIN" ]]; then
    "$ROOT/scripts/build_speech_helper.sh" >/dev/null
  fi
  if [[ ! -x "$HELPER_BIN" ]]; then
    echo "Speech helper was not built: $HELPER_BIN" >&2
    exit 1
  fi
  "$ROOT/scripts/vendor_speech_assets.sh" >/dev/null
fi

rm -rf "$APP/Contents/Helpers"
rm -rf "$APP_HELPER_ROOT"
rm -rf "$APP/Contents/Resources/huggingface"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/python" "$APP/Contents/Resources/scripts" "$APP_HELPER_ROOT"
cp "$ROOT/AppBundle/Contents/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppBundle/Contents/Resources/Mockingbird.icns" "$APP/Contents/Resources/Mockingbird.icns"
cp "$ROOT/python/synthesize.py" "$APP/Contents/Resources/python/synthesize.py"
cp "$ROOT/scripts/setup.sh" "$APP/Contents/Resources/scripts/setup.sh"
cp "$ROOT/.build/debug/Mockingbird" "$APP/Contents/MacOS/Mockingbird"
if [[ -d "$HELPER_DIR" && "${MOCKINGBIRD_SKIP_SPEECH_HELPER:-0}" != "1" ]]; then
  ditto "$HELPER_DIR" "$APP_HELPER_ROOT/MockingbirdSynth"
fi
if [[ -d "$SPEECH_ASSETS" && "${MOCKINGBIRD_SKIP_SPEECH_HELPER:-0}" != "1" ]]; then
  ditto "$SPEECH_ASSETS" "$APP/Contents/Resources/huggingface"
fi
chmod +x "$APP/Contents/MacOS/Mockingbird"
chmod +x "$APP/Contents/Resources/scripts/setup.sh"

SIGN_IDENTITY="${MOCKINGBIRD_CODESIGN_IDENTITY:-"-"}"
CODESIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  CODESIGN_OPTIONS+=(--options runtime)
fi
if [[ -d "$APP_HELPER_ROOT/MockingbirdSynth" ]]; then
  sign_macho_files "$APP_HELPER_ROOT/MockingbirdSynth"
fi
codesign "${CODESIGN_OPTIONS[@]}" "$APP"
echo "$APP"
