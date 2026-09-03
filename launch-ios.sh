#!/usr/bin/env bash
# Build Evocell for iOS and install it. Defaults to your connected iPhone;
# pass "sim" to build for the Simulator instead.
#
# Usage:
#   ./launch-ios.sh              # build + install on the connected iPhone
#   ./launch-ios.sh sim          # build + run in the iOS Simulator ("iPhone 17" by default)
#   ./launch-ios.sh sim "iPhone 16e"   # build + run in a specific simulator
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

IOS_DIR="$HOME/Developer/petri-ios"
if [ ! -d "$IOS_DIR" ]; then
    echo "!! iOS project scaffold not found at $IOS_DIR"
    exit 1
fi

TARGET="${1:-device}"
case "$TARGET" in
    device)
        exec "$IOS_DIR/device.sh"
        ;;
    sim|simulator)
        shift
        exec "$IOS_DIR/rebuild.sh" "$@"
        ;;
    *)
        echo "Usage: $0 [device|sim [simulator-name]]"
        exit 1
        ;;
esac
