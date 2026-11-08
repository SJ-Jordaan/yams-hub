#!/usr/bin/env bash
# One-time (idempotent) set-up of the benchmark toolchain under ~/development:
#   ~/development/perf-venv        python venv with playwright + pillow
#   ~/development/ms-playwright    Playwright's Chromium (PLAYWRIGHT_BROWSERS_PATH)
set -euo pipefail

VENV="${PERF_VENV:-$HOME/development/perf-venv}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/development/ms-playwright}"

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
if ! "$VENV/bin/python" -c 'import playwright, PIL' 2>/dev/null; then
  "$VENV/bin/pip" install -q playwright pillow
fi
if ! ls "$PLAYWRIGHT_BROWSERS_PATH"/chromium-* >/dev/null 2>&1; then
  "$VENV/bin/playwright" install chromium
fi
echo "ok: $VENV, browsers in $PLAYWRIGHT_BROWSERS_PATH"
