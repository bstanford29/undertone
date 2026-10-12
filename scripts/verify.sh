#!/usr/bin/env bash
# Shared local/CI checks. No app installation, signing, or model inference.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PYTHON="${PYTHON:-$ROOT/.venv/bin/python}"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Verification requires macOS with Swift 6 and the macOS SDK." >&2
  exit 1
fi
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "Python not found. Install requirements-test.txt in .venv or set PYTHON to a Python 3.12+ interpreter." >&2
  exit 1
fi
"$PYTHON" -c 'import sys; sys.exit("Python 3.12+ is required") if sys.version_info < (3, 12) else None'

# Model APIs are faked by the synthetic tests. Also disable Hub downloads.
export HF_HUB_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export PYTHONPATH="$ROOT/engine"

echo "== Python synthetic tests =="
"$PYTHON" -m unittest discover -s tests

echo "== Swift tests (includes debug compilation) =="
swift test --package-path app --jobs 3

echo "Verification passed. Real app, audio, and model acceptance remain local; see docs/VERIFICATION.md."
