#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_ROOT="${MOCKINGBIRD_RESOURCE_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RUNTIME_ROOT="${MOCKINGBIRD_RUNTIME_ROOT:-$RESOURCE_ROOT}"
PYTHON_BIN="${PYTHON_BIN:-}"

mkdir -p "$RUNTIME_ROOT"
cd "$RUNTIME_ROOT"

python_is_supported() {
  "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

find_supported_python() {
  if [[ -n "$PYTHON_BIN" ]]; then
    if python_is_supported "$PYTHON_BIN"; then
      echo "$PYTHON_BIN"
      return 0
    fi
    echo "Configured Python is too old. Mockingbird needs Python 3.10 or newer."
    return 1
  fi

  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && python_is_supported "$candidate"; then
      command -v "$candidate"
      return 0
    fi
  done

  return 1
}

find_uv() {
  for candidate in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv uv; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done

  return 1
}

if [[ -x ".venv/bin/python" ]] && ! python_is_supported ".venv/bin/python"; then
  echo "Existing Python environment is too old. Recreating it..."
  rm -rf .venv
fi

if [[ ! -x ".venv/bin/python" ]]; then
  if supported_python="$(find_supported_python)"; then
    echo "Creating Python environment with $("$supported_python" --version)..."
    "$supported_python" -m venv .venv
  elif uv_bin="$(find_uv)"; then
    echo "Installing managed Python 3.12 with uv..."
    "$uv_bin" python install 3.12
    echo "Creating Python environment with Python 3.12..."
    "$uv_bin" venv --python 3.12 .venv
  else
    echo "Mockingbird needs Python 3.10 or newer. Install Python 3.12, then retry setup."
    exit 1
  fi
else
  echo "Using existing Python environment..."
fi

if ! ".venv/bin/python" -m pip --version >/dev/null 2>&1; then
  echo "Installing pip into Python environment..."
  ".venv/bin/python" -m ensurepip --upgrade
fi

echo "Installing package tooling..."
".venv/bin/python" -m pip install --upgrade pip setuptools wheel
echo "Installing speech engine packages..."
".venv/bin/python" -m pip install kokoro soundfile numpy
echo "Validating speech engine..."
".venv/bin/python" "$RESOURCE_ROOT/python/synthesize.py" "Mockingbird setup complete." >"$RUNTIME_ROOT/setup-smoke.log"
echo "Mockingbird setup complete."
