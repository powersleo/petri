#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# `love` isn't always on PATH even when love.app is installed -- fall back
# to the standard macOS app-bundle location.
if command -v love >/dev/null 2>&1; then
    LOVE_BIN="love"
elif [ -x "/Applications/love.app/Contents/MacOS/love" ]; then
    LOVE_BIN="/Applications/love.app/Contents/MacOS/love"
else
    echo "!! Could not find the 'love' binary (checked PATH and /Applications/love.app)." >&2
    exit 1
fi

exec "$LOVE_BIN" .
