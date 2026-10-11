#!/bin/sh
# Builds Bubble.app into ./build. Usage: scripts/bundle.sh [--install]
#
# Version comes from ./VERSION (override with BUBBLE_VERSION=1.2.3). CFBundleVersion, which
# Sparkle compares to decide whether an update is newer, is derived from it as
# major*1000000 + minor*1000 + patch (override with BUILD_NUMBER=...).
# Signing: uses the first "Developer ID Application" identity in your keychains, else ad-hoc.
# Override with SIGN_IDENTITY ("-" forces ad-hoc). A stable Developer ID signature also keeps
# macOS privacy grants (Full Disk Access) across rebuilds; ad-hoc ones are reset each build.
# Every build, ad-hoc included, is signed with the hardened runtime (--options runtime).
#
# BUBBLE_DEV=1 compiles in the debug hooks (-DBUBBLE_DEV): the -simulate… launch arguments,
# -lastTab and -autoStart. Release builds (scripts/release.sh, CI) must not set it.
set -e
cd "$(dirname "$0")/.."
. ./updates.conf

# SwiftUI macros (@State, @Observable) need Xcode's toolchain, not the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION="${BUBBLE_VERSION:-$(tr -d ' \n' < VERSION)}"
case "$VERSION" in
    *[!0-9.]*|"") echo "Bad version '$VERSION' (want X.Y.Z)" >&2; exit 1 ;;
esac
if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{ printf "%d", $1*1000000 + $2*1000 + $3 }')
fi
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
echo "Signing with: $SIGN_IDENTITY" >&2

SWIFT_FLAGS=""
if [ "$BUBBLE_DEV" = "1" ]; then
    SWIFT_FLAGS="-Xswiftc -DBUBBLE_DEV"
    echo "BUBBLE_DEV=1: building with debug hooks. Don't ship this build." >&2
fi
# shellcheck disable=SC2086
swift build -c release $SWIFT_FLAGS
# shellcheck disable=SC2086
BIN="$(swift build -c release $SWIFT_FLAGS --show-bin-path)"

APP=build/Bubble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Bubble" "$APP/Contents/MacOS/Bubble"
[ -d "$BIN/Bubble_Bubble.bundle" ] && cp -R "$BIN/Bubble_Bubble.bundle" "$APP/Contents/Resources/"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle.framework (the binary links it via @executable_path/../Frameworks). ditto keeps
# the framework's Versions/ symlinks intact.
SPARKLE="$BIN/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Bubble</string>
    <key>CFBundleDisplayName</key><string>Bubble</string>
    <key>CFBundleIdentifier</key><string>com.jainnitin.Bubble</string>
    <key>CFBundleExecutable</key><string>Bubble</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Mole, which Bubble runs, asks System Events and Finder which apps are open and quits apps before removing them.</string>
    <key>SUFeedURL</key><string>$SU_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
    <!-- Checks daily without asking first; Settings has the switch to turn it off. -->
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SURequireSignedFeed</key><true/>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict>
</plist>
PLIST

# Entitlements for the app itself (hardened runtime):
# - automation.apple-events: Mole runs osascript to ask System Events and Finder which apps
#   are open and to quit apps before removing them. Under the hardened runtime, TCC checks
#   the *responsible* app (Bubble) for this entitlement when its child osascript sends Apple
#   Events; without it the events fail with errAEEventNotPermitted (-1743) and no consent
#   prompt is shown. The consent prompt itself uses NSAppleEventsUsageDescription.
# - cs.disable-library-validation, ad-hoc builds only: with the hardened runtime, dyld only
#   loads frameworks signed by Apple or by the app's own Team ID. An ad-hoc signature has no
#   Team ID, so Bubble dies at launch with "Library not loaded: @rpath/Sparkle.framework …
#   not valid for use in process". A Developer ID build signs Sparkle with the same
#   team and keeps library validation on. Sparkle's helpers (Autoupdate, Updater.app, the
#   XPC services) link only system libraries, so they need nothing.
SIGN_KEYCHAIN_ARGS=""
[ -n "$SIGN_KEYCHAIN" ] && SIGN_KEYCHAIN_ARGS="--keychain $SIGN_KEYCHAIN"   # CI's temporary keychain
ENTITLEMENTS="build/Bubble.entitlements"
LIBRARY_VALIDATION=""
if [ "$SIGN_IDENTITY" = "-" ]; then
    LIBRARY_VALIDATION="<key>com.apple.security.cs.disable-library-validation</key><true/>"
fi
cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
    $LIBRARY_VALIDATION
</dict>
</plist>
ENT

# Sign inside-out: Sparkle's helpers, then the framework, then the app (no --deep).
sign() {
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --sign - --options runtime "$@"
    else
        # shellcheck disable=SC2086
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp $SIGN_KEYCHAIN_ARGS "$@"
    fi
}
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for x in "$FW/XPCServices/Installer.xpc" "$FW/Autoupdate" "$FW/Updater.app"; do
    if [ -e "$x" ]; then sign "$x"; fi
done
if [ -e "$FW/XPCServices/Downloader.xpc" ]; then
    sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
fi
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
# Refuse to produce an app without the hardened runtime.
codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime' || { echo "Bubble.app isn't signed with the hardened runtime" >&2; exit 1; }
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if [ "$1" = "--install" ]; then
    rm -rf /Applications/Bubble.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/Bubble.app"
fi
