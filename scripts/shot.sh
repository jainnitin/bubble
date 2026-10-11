#!/bin/sh
# Dev helper: relaunch on a tab and screenshot the window. Usage: scripts/shot.sh <tab> <out.png> [delay]
#
# Needs a BUBBLE_DEV build: -lastTab and -autoStart are compiled only with -DBUBBLE_DEV, so a
# release build ignores them. Build one first with:  BUBBLE_DEV=1 scripts/bundle.sh
# (or set BUILD=1 to have this script do it).
#
# WARNING: screenshots are of your real Mac. The Status tab shows your local IP address, the
# running process list and Bluetooth device names. Check every image before you commit it or
# post it anywhere, or take it on a machine with nothing personal on it.
set -e
cd "$(dirname "$0")/.."
if [ "${BUILD:-0}" = "1" ]; then
    BUBBLE_DEV=1 scripts/bundle.sh
fi
if ! strings build/Bubble.app/Contents/MacOS/Bubble 2>/dev/null | grep -q 'simulateNoMole'; then
    echo "build/Bubble.app isn't a BUBBLE_DEV build, so -lastTab is ignored. Run: BUBBLE_DEV=1 scripts/bundle.sh" >&2
    exit 1
fi
pkill -x Bubble || true; sleep 1
open build/Bubble.app --args -lastTab "$1" -autoStart "${AUTO:-NO}"
sleep "${3:-5}"
ID=$(swift scripts/winid.swift | head -1)
screencapture -x -o -l "$ID" "$2" && sips -Z 1400 "$2" >/dev/null
