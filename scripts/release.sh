#!/bin/sh
# Builds a release: dist/Bubble-X.Y.Z.zip plus a signed dist/appcast.xml that points at it (the
# Sparkle update), and dist/Bubble-X.Y.Z.dmg (the download for new installs, see scripts/dmg.sh).
# Usage: scripts/release.sh [X.Y.Z]        (default: contents of ./VERSION)
#
# The EdDSA private key is read from SPARKLE_ED_PRIVATE_KEY if set (CI), otherwise from the
# login Keychain (account in updates.conf). Upload all three files to the GitHub Release vX.Y.Z;
# the release workflow does that for you. DOWNLOAD_URL_PREFIX overrides where the appcast
# says the zip lives (used for local testing).
#
# Releases are signed with Developer ID and notarized, so Gatekeeper opens them without a warning.
# Notary credentials, in order:
#   - APPLE_API_KEY_PATH + APPLE_API_KEY_ID + APPLE_API_ISSUER_ID (CI; an App Store Connect API key)
#   - the notarytool keychain profile NOTARY_PROFILE (default "bubble"), saved once with:
#       xcrun notarytool store-credentials bubble --key <AuthKey.p8> --key-id <ID> --issuer <issuer>
# SKIP_NOTARIZE=1 builds without notarizing (and allows ad-hoc signing), for local testing only.
set -e
cd "$(dirname "$0")/.."
. ./updates.conf
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION="${1:-$(tr -d ' \n' < VERSION)}"
export BUBBLE_VERSION="$VERSION"
# Releases never carry the debug hooks (-simulate…, -lastTab, -autoStart).
if [ -n "$BUBBLE_DEV" ] && [ "$BUBBLE_DEV" != "0" ]; then
    echo "BUBBLE_DEV is set; unset it to build a release." >&2
    exit 1
fi
unset BUBBLE_DEV
scripts/bundle.sh
if strings build/Bubble.app/Contents/MacOS/Bubble | grep -q 'simulateNoMole'; then
    echo "build/Bubble.app contains debug hooks; refusing to release it." >&2
    exit 1
fi
codesign -dv build/Bubble.app 2>&1 | grep -q 'flags=.*runtime' || { echo "not signed with the hardened runtime" >&2; exit 1; }

# notarytool SUBCOMMAND [args…] with the release's credentials.
notarytool() {
    if [ -n "$APPLE_API_KEY_PATH" ]; then
        xcrun notarytool "$@" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID"
    else
        xcrun notarytool "$@" --keychain-profile "${NOTARY_PROFILE:-bubble}"
    fi
}
# notarize FILE: submits a zip or a DMG, waits, and stops the release (printing Apple's log)
# unless it was accepted.
notarize() {
    echo "Notarizing $(basename "$1") (usually a few minutes)…"
    notarytool submit "$1" --wait --output-format plist > build/notary.plist || true
    STATUS=$(/usr/libexec/PlistBuddy -c 'Print :status' build/notary.plist 2>/dev/null || echo "no result")
    if [ "$STATUS" != "Accepted" ]; then
        echo "Notarization of $1 failed: $STATUS" >&2
        ID=$(/usr/libexec/PlistBuddy -c 'Print :id' build/notary.plist 2>/dev/null || true)
        [ -n "$ID" ] && notarytool log "$ID" >&2
        exit 1
    fi
}

if [ "$SKIP_NOTARIZE" != "1" ]; then
    codesign -dvv build/Bubble.app 2>&1 | grep -q '^Authority=Developer ID Application' \
        || { echo "Not signed with a Developer ID; can't notarize. (SKIP_NOTARIZE=1 for a local test build.)" >&2; exit 1; }
    NOTARY_ZIP="build/Bubble-notarize.zip"
    rm -f "$NOTARY_ZIP"
    ditto -c -k --keepParent build/Bubble.app "$NOTARY_ZIP"
    notarize "$NOTARY_ZIP"
    rm -f "$NOTARY_ZIP"
    # Staple before zipping: the update's EdDSA signature covers the stapled app.
    xcrun stapler staple build/Bubble.app
    spctl --assess --type execute --verbose=2 build/Bubble.app
fi

BIN_TOOLS=.build/artifacts/sparkle/Sparkle/bin
[ -x "$BIN_TOOLS/generate_appcast" ] || { echo "Sparkle tools missing in $BIN_TOOLS" >&2; exit 1; }

DIST=dist
ZIP="Bubble-$VERSION.zip"
STAGE="$DIST/stage"
rm -rf "$DIST"
mkdir -p "$STAGE"
ditto -c -k --sequesterRsrc --keepParent build/Bubble.app "$STAGE/$ZIP"

# Optional release notes: release-notes/X.Y.Z.md is embedded in the update dialog.
if [ -f "release-notes/$VERSION.md" ]; then
    cp "release-notes/$VERSION.md" "$STAGE/Bubble-$VERSION.md"
fi

PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$GITHUB_REPO/releases/download/v$VERSION/}"
set -- --download-url-prefix "$PREFIX" --embed-release-notes \
    --link "https://github.com/$GITHUB_REPO" --maximum-deltas 0 -o "$DIST/appcast.xml"

# One item per feed: Sparkle only needs the newest build, and each release carries its own feed.
if [ -n "$SPARKLE_ED_PRIVATE_KEY" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$BIN_TOOLS/generate_appcast" --ed-key-file - "$@" "$STAGE"
else
    "$BIN_TOOLS/generate_appcast" --account "$SPARKLE_KEY_ACCOUNT" "$@" "$STAGE"
fi
mv "$STAGE/$ZIP" "$DIST/$ZIP"
rm -rf "$STAGE"

# Check what we're about to ship against the public key baked into the app.
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$DIST/appcast.xml" | head -1)
[ -n "$SIG" ] || { echo "appcast has no edSignature" >&2; exit 1; }
swift scripts/verify-update.swift "$DIST/$ZIP" "$SIG" "$SU_PUBLIC_ED_KEY"

# The download DMG, from the same stapled app. It's signed with the app's Developer ID
# (scripts/dmg.sh), then notarized and stapled itself, so opening it raises no warning even
# offline. The zip and appcast above are untouched by this; Sparkle keeps using the zip.
DMG="$DIST/Bubble-$VERSION.dmg"
scripts/dmg.sh build/Bubble.app "$DMG"
if [ "$SKIP_NOTARIZE" != "1" ]; then
    codesign -dvv "$DMG" 2>&1 | grep -q '^Authority=Developer ID Application' \
        || { echo "$DMG isn't signed with a Developer ID" >&2; exit 1; }
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -v "$DMG"
fi
echo "Release files: $DIST/$ZIP $DIST/appcast.xml $DMG"
