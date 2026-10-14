#!/bin/bash
# Scripts/package-release-app.sh — builds the Drift 1.0 release artifact.
#
# Signs with a Developer ID identity when one exists (hardened runtime +
# timestamp); otherwise falls back to an ad-hoc seal so a runnable artifact
# always exists. Notarization runs only when both --notary-profile is given
# and a Developer ID identity is available (Apple credentials required).
#
# usage: package-release-app.sh [--notary-profile <name>]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=1.0.0
BIN=".build/out/Products/Release/Drift"
APP="dist/Drift.app"
DMG="dist/Drift-$VERSION-arm64.dmg"
NOTARY_PROFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

echo "== building release binary =="
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build --arch arm64 -c release > /tmp/drift-release-build.log 2>&1
grep -q "Build complete" /tmp/drift-release-build.log || {
    echo "release build failed; see /tmp/drift-release-build.log" >&2
    exit 1
}

echo "== assembling $APP =="
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Drift"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Drift</string>
    <key>CFBundleIdentifier</key>
    <string>com.harshsanket.drift</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Drift</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "== signing =="
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Developer ID Application" | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -n "$IDENTITY" ]; then
    echo "identity: $IDENTITY (hardened runtime, timestamped)"
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
    SIGNING="Developer ID: $IDENTITY"
else
    echo "BLOCKED: no Developer ID identity in keychain"
    echo "  → notarization requires an Apple Developer account."
    echo "  → falling back to ad-hoc sealed artifact (run locally only;"
    echo "     Gatekeeper will block it on other Macs until notarized)."
    codesign --force --options runtime -s - "$APP"
    SIGNING="ad-hoc (notarization blocked: no Apple Developer credentials)"
fi
codesign -v "$APP"
echo "signature valid"

if [ -n "$NOTARY_PROFILE" ] && [ -n "$IDENTITY" ]; then
    echo "== notarizing (profile: $NOTARY_PROFILE) =="
    ditto -c -k --keepParent "$APP" /tmp/drift-notarize.zip
    xcrun notarytool submit /tmp/drift-notarize.zip \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    SIGNING="$SIGNING, notarized + stapled"
else
    echo "== notarization skipped =="
fi

echo "== creating $DMG =="
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$APP" "$stage/Drift.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Drift $VERSION" -srcfolder "$stage" -ov -format UDZO "$DMG" >/dev/null

echo "== done =="
echo "artifact: $DMG"
echo "signing:  $SIGNING"
shasum -a 256 "$DMG"
