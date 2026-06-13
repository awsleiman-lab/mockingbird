#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUEST_DIR="$ROOT/runtime/requests"
mkdir -p "$REQUEST_DIR"
touch "$REQUEST_DIR/command-stop-$(date +%s)-$$"
