#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUEST_DIR="$ROOT/runtime/requests"
LOG="/tmp/kokoro-service-shortcut.log"

mkdir -p "$REQUEST_DIR"

{
  echo "----- $(date) -----"
  echo "started as: $(whoami)"
} >>"$LOG" 2>&1

selected_text="$(cat | iconv -c -f UTF-8 -t UTF-8 2>>"$LOG" || true)"
echo "selected text length: ${#selected_text}" >>"$LOG"

if [[ -z "${selected_text//[[:space:]]/}" ]]; then
  echo "no stdin text found; falling back to clipboard" >>"$LOG"
  selected_text="$(pbpaste -Prefer txt 2>>"$LOG" | iconv -c -f UTF-8 -t UTF-8 2>>"$LOG" || true)"
  echo "clipboard fallback length: ${#selected_text}" >>"$LOG"
fi

if [[ -z "${selected_text//[[:space:]]/}" ]]; then
  echo "no text found; exiting" >>"$LOG"
  exit 0
fi

request="$REQUEST_DIR/request-$(date +%s)-$$.txt"
printf "%s" "$selected_text" >"$request"
echo "wrote $request" >>"$LOG"
