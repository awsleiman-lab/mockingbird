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
swift build -c release --scratch-path "$ROOT/.build"

# Packaging modes:
#   default                               -> small app; users download an engine during onboarding
#   MOCKINGBIRD_BUNDLE_SPEECH_HELPER=1    -> legacy self-contained app with the frozen helper and model baked in
#   MOCKINGBIRD_SKIP_SPEECH_HELPER=1      -> legacy dev build that installs a Python venv on first run
BUNDLE_HELPER="${MOCKINGBIRD_BUNDLE_SPEECH_HELPER:-0}"
LEGACY_VENV="${MOCKINGBIRD_SKIP_SPEECH_HELPER:-0}"

if [[ "$BUNDLE_HELPER" == "1" ]]; then
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
rm -rf "$APP/Contents/Resources/scripts"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/python" "$APP/Contents/Resources/scripts"
cp "$ROOT/AppBundle/Contents/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/AppBundle/Contents/Resources/Mockingbird.icns" "$APP/Contents/Resources/Mockingbird.icns"
cp "$ROOT/python/synthesize.py" "$APP/Contents/Resources/python/synthesize.py"
cp "$ROOT/python/synthesize_piper.py" "$APP/Contents/Resources/python/synthesize_piper.py"
cp "$ROOT"/python/requirements-*.txt "$APP/Contents/Resources/python/"
cp "$ROOT/scripts/engine_setup.sh" "$APP/Contents/Resources/scripts/engine_setup.sh"
chmod +x "$APP/Contents/Resources/scripts/engine_setup.sh"
cp "$ROOT/.build/release/Mockingbird" "$APP/Contents/MacOS/Mockingbird"
rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
ditto "$ROOT/.build/release/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Mockingbird" 2>/dev/null || true
if [[ "$LEGACY_VENV" == "1" ]]; then
  cp "$ROOT/scripts/setup.sh" "$APP/Contents/Resources/scripts/setup.sh"
  chmod +x "$APP/Contents/Resources/scripts/setup.sh"
fi
if [[ "$BUNDLE_HELPER" == "1" && -d "$HELPER_DIR" ]]; then
  mkdir -p "$APP_HELPER_ROOT"
  ditto "$HELPER_DIR" "$APP_HELPER_ROOT/MockingbirdSynth"
fi
if [[ "$BUNDLE_HELPER" == "1" && -d "$SPEECH_ASSETS" ]]; then
  ditto "$SPEECH_ASSETS" "$APP/Contents/Resources/huggingface"
fi
chmod +x "$APP/Contents/MacOS/Mockingbird"

# Prefer a stable signing identity so macOS keeps Accessibility grants across rebuilds.
# Ad-hoc signatures change every build, which makes TCC treat each build as a new app.
SIGN_IDENTITY="${MOCKINGBIRD_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  for pattern in "Developer ID Application" "Apple Development"; do
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' -v p="$pattern" 'index($2, p) == 1 {print $2; exit}')"
    if [[ -n "$SIGN_IDENTITY" ]]; then
      break
    fi
  done
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-"-"}"
CODESIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  CODESIGN_OPTIONS+=(--options runtime --timestamp)
fi
if [[ -d "$APP_HELPER_ROOT/MockingbirdSynth" ]]; then
  sign_macho_files "$APP_HELPER_ROOT/MockingbirdSynth"
fi

# Sparkle's nested components must be signed innermost-first.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  codesign "${CODESIGN_OPTIONS[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
  codesign "${CODESIGN_OPTIONS[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
  codesign "${CODESIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  codesign "${CODESIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  codesign "${CODESIGN_OPTIONS[@]}" "$SPARKLE_FW"
fi

codesign "${CODESIGN_OPTIONS[@]}" "$APP"
echo "$APP"
