#!/usr/bin/env bash
# Run the sim for a few seconds and copy a window-sized PNG into docs/.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

export EVECELL_SCREENSHOT="${1:-3}"

if command -v love >/dev/null 2>&1; then
    LOVE_BIN="love"
elif [ -x "/Applications/love.app/Contents/MacOS/love" ]; then
    LOVE_BIN="/Applications/love.app/Contents/MacOS/love"
else
    echo "!! Could not find the 'love' binary." >&2
    exit 1
fi

"$LOVE_BIN" .

SAVE_DIR="${HOME}/Library/Application Support/LOVE"
SRC=""
for identity in petri Evocell evocell; do
    candidate="${SAVE_DIR}/${identity}/portfolio.png"
    if [ -f "$candidate" ]; then
        SRC="$candidate"
        break
    fi
done

if [ -z "$SRC" ]; then
    echo "!! Screenshot was not written to ${SAVE_DIR} (looked for petri/Evocell/evocell)." >&2
    exit 1
fi

mkdir -p docs
cp "$SRC" docs/screenshot.png
echo "Wrote docs/screenshot.png"
