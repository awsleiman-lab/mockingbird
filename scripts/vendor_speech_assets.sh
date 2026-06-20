#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${MOCKINGBIRD_KOKORO_CACHE:-$HOME/.cache/huggingface/hub/models--hexgrad--Kokoro-82M}"
DEST_ROOT="$ROOT/build-cache/speech-assets/huggingface"
DEST="$DEST_ROOT/hub/models--hexgrad--Kokoro-82M"
REQUIRED_FILES=(
  "config.json"
  "kokoro-v1_0.pth"
  "voices/af_heart.pt"
  "voices/af_bella.pt"
  "voices/af_nicole.pt"
  "voices/af_sarah.pt"
  "voices/af_sky.pt"
  "voices/am_adam.pt"
  "voices/am_michael.pt"
)

if [[ ! -d "$SOURCE" ]]; then
  echo "Kokoro Hugging Face cache was not found: $SOURCE" >&2
  echo "Run the speech setup and use each packaged voice once, then retry." >&2
  exit 1
fi

revision="$(cat "$SOURCE/refs/main" 2>/dev/null || true)"
if [[ -z "$revision" || ! -d "$SOURCE/snapshots/$revision" ]]; then
  echo "Kokoro cache is missing refs/main or its snapshot directory: $SOURCE" >&2
  exit 1
fi

missing=()
for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -e "$SOURCE/snapshots/$revision/$file" ]]; then
    missing+=("$file")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "Kokoro cache is missing required assets:" >&2
  for file in "${missing[@]}"; do
    echo "  $file" >&2
  done
  echo "Download the missing assets into $SOURCE, then retry." >&2
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST_ROOT/hub"
ditto "$SOURCE" "$DEST"

echo "$DEST_ROOT"
