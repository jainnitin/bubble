#!/bin/sh
# Packs an app into the download DMG: a "Bubble" volume with Bubble.app, an Applications shortcut
# and a background with an arrow between them, laid out in a toolbar-less icon-view window.
# Usage: scripts/dmg.sh [build/Bubble.app] [out.dmg]      (default out: build/Bubble.dmg)
#
# The layout (.DS_Store) is written by dmgbuild (pure Python, pinned with wheel hashes in
# scripts/dmg/requirements.txt), not by scripting Finder, which needs a GUI session and is
# unreliable on CI runners. It is installed into a venv in build/dmgbuild-venv on first use.
# Settings: scripts/dmg/settings.py. Background: assets/dmg-background{,@2x}.png, drawn by
# scripts/dmg/render-background.swift.
#
# Signing: with SIGN_IDENTITY (and SIGN_KEYCHAIN in CI), or else the app's own Developer ID
# identity, the DMG is signed with it. Ad-hoc apps give an unsigned DMG. Notarizing is
# scripts/release.sh's job.
set -e
APP="${1:-build/Bubble.app}"
OUT="${2:-build/Bubble.dmg}"
[ -d "$APP" ] || { echo "No app at $APP" >&2; exit 1; }
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
APP="${APP%/}"
cd "$(dirname "$0")/.."

VENV="${DMGBUILD_VENV:-build/dmgbuild-venv}"
REQ=scripts/dmg/requirements.txt
STAMP="$VENV/.requirements"
if ! cmp -s "$REQ" "$STAMP" 2>/dev/null; then
    echo "Installing dmgbuild into ${VENV}…" >&2
    rm -rf "$VENV"
    "${PYTHON:-/usr/bin/python3}" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --no-deps \
        --only-binary :all: --require-hashes -r "$REQ"
    cp "$REQ" "$STAMP"
fi

ICON="$APP/Contents/Resources/AppIcon.icns"
set -- -s scripts/dmg/settings.py -D app="$APP" -D background="$PWD/assets/dmg-background.png"
[ -f "$ICON" ] && set -- "$@" -D icon="$ICON"

mkdir -p "$(dirname "$OUT")"
# hdiutil now and then fails with "Resource busy" on CI runners; try a few times.
n=0
until rm -f "$OUT" && "$VENV/bin/dmgbuild" "$@" Bubble "$OUT"; do
    n=$((n + 1))
    [ $n -lt 3 ] || { echo "dmgbuild failed" >&2; exit 1; }
    echo "dmgbuild failed; retrying in $((n * 10))s…" >&2
    sleep $((n * 10))
done
hdiutil verify -quiet "$OUT"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
fi
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_KEYCHAIN_ARGS=""
    [ -n "$SIGN_KEYCHAIN" ] && SIGN_KEYCHAIN_ARGS="--keychain $SIGN_KEYCHAIN"
    # shellcheck disable=SC2086
    codesign --force --sign "$SIGN_IDENTITY" --timestamp $SIGN_KEYCHAIN_ARGS "$OUT"
    codesign --verify --strict "$OUT"
    echo "Signed $OUT with $SIGN_IDENTITY" >&2
else
    echo "App isn't Developer ID signed; leaving $OUT unsigned." >&2
fi
echo "Built $OUT"
