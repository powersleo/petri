#!/usr/bin/env bash
# Launch Evocell on desktop via LÖVE. Thin wrapper around start.sh so the
# two launchers (this one and launch-ios.sh) sit side by side under
# matching names.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec ./start.sh
