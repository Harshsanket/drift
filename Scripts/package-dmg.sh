#!/bin/bash
# Scripts/package-dmg.sh — Drift Stage B release artifact (E5).
#
# Produces an arm64-only, ad-hoc signed, hardened-runtime DMG containing the
# app + embedded drift-engine + tunnel helper, an EULA and a styled background.
# Also generates dist/appcast.xml (Sparkle EdDSA) and release notes.
#
# No Developer ID / notarization (D20). GitHub release upload is intentionally
# NOT automatic: every publish needs explicit user confirmation (D16). The
# exact `gh release create` command is printed at the end; run it yourself.
#
# usage: Scripts/package-dmg.sh [--skip-build]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.2.0}"
BUILD="${BUILD:-120}"
TAG="${TAG:-v$VERSION}"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

APP="dist/Drift.app"
DMG="dist/Drift-$VERSION-arm64.dmg"
STAGE=""
MNT=""
TMP_KEY=""

cleanup() {
    [[ -n "$MNT" && -d "$MNT" ]] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
    [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf "$STAGE"
    [[ -n "$TMP_KEY" && -f "$TMP_KEY" ]] && rm -f "$TMP_KEY"
}
trap cleanup EXIT

RAW_KEY="${DRIFT_EDDSA_PRIVATE_KEY:-$HOME/drift-signing/drift-eddsa.private}"
PUB_KEY="${DRIFT_EDDSA_PUBLIC_KEY:-$HOME/drift-signing/drift-eddsa.public}"
if [[ ! -f "$RAW_KEY" || ! -f "$PUB_KEY" ]]; then
    echo "error: EdDSA keys missing at $HOME/drift-signing/" >&2
    exit 1
fi
PUBLIC_BASE64="$(base64 -i "$PUB_KEY" | tr -d '\n')"
TMP_KEY="$(mktemp)"
base64 -i "$RAW_KEY" | tr -d '\n' > "$TMP_KEY"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "== building embedded engine =="
    ( cd engine && ./build.sh )

    echo "== building release app + tunnel helper =="
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        swift build --configuration release --arch arm64
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        swift build --configuration release --arch arm64 --product drift-tunnel-helper
fi

BIN=".build/out/Products/Release/Drift"
HELPER=".build/out/Products/Release/drift-tunnel-helper"
ENGINE="engine/build/drift-engine"
FRAMEWORK=".build/out/Products/Release/PartoutNative.framework"
SPARKLE_FRAMEWORK=".build/out/Products/Release/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || SPARKLE_FRAMEWORK=".build/out/Products/Debug/Sparkle.framework"

for required in "$BIN" "$HELPER" "$ENGINE"; do
    [[ -f "$required" ]] || { echo "error: missing $required" >&2; exit 1; }
done

echo "== assembling $APP =="
rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Drift"
cp "$HELPER" "$APP/Contents/MacOS/drift-tunnel-helper"
cp "$ENGINE" "$APP/Contents/MacOS/drift-engine"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/EULA.txt "$APP/Contents/Resources/EULA.txt"
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp engine/licenses/* "$APP/Contents/Resources/ThirdPartyLicenses/"
[[ -f ThirdParty/partout/LICENSE ]] && cp ThirdParty/partout/LICENSE \
    "$APP/Contents/Resources/ThirdPartyLicenses/partout-LICENSE"
[[ -f .build/checkouts/Sparkle/LICENSE ]] && cp .build/checkouts/Sparkle/LICENSE \
    "$APP/Contents/Resources/ThirdPartyLicenses/sparkle-LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

for fw in "$FRAMEWORK" "$SPARKLE_FRAMEWORK"; do
    [[ -d "$fw" ]] || continue
    cp -R "$fw" "$APP/Contents/Frameworks/"
done
for EXE in "$APP/Contents/MacOS/Drift" "$APP/Contents/MacOS/drift-tunnel-helper"; do
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
done

cp Support/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
plutil -insert CFBundleIconFile -string "AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -insert LSMinimumSystemVersion -string "26.0" "$APP/Contents/Info.plist" 2>/dev/null || true
plutil -insert SUPublicEDKey -string "$PUBLIC_BASE64" "$APP/Contents/Info.plist" 2>/dev/null || true

echo "== signing (ad-hoc, hardened runtime, no sandbox) =="
for fw in "$APP/Contents/Frameworks/"*.framework; do
    [[ -d "$fw" ]] || continue
    codesign --force --deep --options runtime -s - "$fw"
done
codesign --force --options runtime -s - "$APP/Contents/MacOS/drift-tunnel-helper"
codesign --force --options runtime -s - "$APP/Contents/MacOS/drift-engine"
codesign --force --options runtime --entitlements Scripts/entitlements-release.plist -s - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# The manifest must hash the already-signed binaries. Adding it invalidates
# the bundle seal, so the app is re-signed afterwards (the root
# _CodeSignature is excluded from the manifest).
echo "== integrity manifest (EdDSA) =="
MANIFEST_PLAIN="$(mktemp)"
python3 - "$APP/Contents" > "$MANIFEST_PLAIN" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
entries = {}
for folder, _, files in os.walk(root):
    for name in files:
        path = os.path.join(folder, name)
        relative = os.path.relpath(path, root)
        if relative.startswith("_CodeSignature"):
            continue
        if relative in ("Resources/IntegrityManifest.json",
                        "Resources/IntegrityManifest.json.sig"):
            continue
        # The app executable is re-signed after the manifest is added (the
        # ad-hoc signature is embedded in the Mach-O), so it is covered by
        # codesign, not by the resource manifest.
        if relative == "MacOS/Drift":
            continue
        with open(path, "rb") as handle:
            entries[relative] = hashlib.sha256(handle.read()).hexdigest()
sys.stdout.write(json.dumps({"version": 1, "entries": dict(sorted(entries.items()))},
                            sort_keys=True))
PY
MANIFEST="$APP/Contents/Resources/IntegrityManifest.json"
SIG="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift Scripts/eddsa_sign_stdin.swift "$RAW_KEY" "$MANIFEST_PLAIN")"
printf '%s' "$SIG" > "$MANIFEST.sig"
mv "$MANIFEST_PLAIN" "$MANIFEST"

codesign --force --options runtime --entitlements Scripts/entitlements-release.plist -s - "$APP"
codesign --verify --deep --strict "$APP"

if otool -L "$APP/Contents/MacOS/drift-engine" | grep -q "/opt/homebrew"; then
    echo "error: engine still links Homebrew dylibs" >&2
    otool -L "$APP/Contents/MacOS/drift-engine" >&2
    exit 1
fi

echo "== staging DMG contents =="
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Drift.app"
mkdir -p "$STAGE/.background"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift Scripts/make-dmg-background.swift "$STAGE/.background/background.png"

echo "== creating $DMG =="
create_dmg() {
    create-dmg \
        --volname "Drift $VERSION" \
        --volicon Resources/AppIcon.icns \
        --background "$STAGE/.background/background.png" \
        --window-pos 200 120 \
        --window-size 660 420 \
        --icon-size 96 \
        --icon "Drift.app" 180 170 \
        --hide-extension "Drift.app" \
        --app-drop-link 480 170 \
        --eula Resources/EULA.txt \
        --no-internet-enable \
        --format UDZO \
        --overwrite \
        "$@" \
        "$DMG" "$STAGE"
}
set +e
create_dmg
CREATE_STATUS=$?
if [[ $CREATE_STATUS -ne 0 ]]; then
    echo "warning: Finder layout unavailable; retrying create-dmg without AppleScript" >&2
    rm -f "$DMG"
    create_dmg --skip-jenkins
    CREATE_STATUS=$?
fi
set -e
if [[ $CREATE_STATUS -ne 0 || ! -f "$DMG" ]]; then
    echo "warning: create-dmg failed; using hdiutil (no Finder layout)" >&2
    rm -f "$DMG"
    hdiutil create -volname "Drift $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
fi

echo "== appcast + signature =="
SIZE="$(stat -f%z "$DMG")"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -x "$SIGN_TOOL" ]]; then
    SIGNATURE="$("$SIGN_TOOL" --ed-key-file "$TMP_KEY" -p "$DMG" | tr -d '\n')"
else
    SIGNATURE="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        swift Scripts/eddsa_sign_stdin.swift "$RAW_KEY" "$DMG" | tr -d '\n')"
fi
ENCLOSURE_URL="https://github.com/Harshsanket/drift/releases/download/$TAG/Drift-$VERSION-arm64.dmg"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "dist/release-notes-$VERSION.md" <<EOF
# Drift $VERSION

Stage B embedded engine release.

- **Embedded libtorrent 2.1.2** — Drift now ships its own out-of-process
  \`drift-engine\`; no Docker or separate qBittorrent install is required on
  first launch. Server mode remains available in Settings.
- **Parity wave** — lifecycle flags, queue/recheck/rename/location, file
  priorities, categories/tags, trackers, web seeds, limits, statistics and
  persistent peer bans.
- **Native search** — Jackett/Prowlarr support in embedded mode; server-mode
  plugin search is unchanged.
- **Packaging** — arm64-only, ad-hoc signed DMG. No notarization.

## Install

1. Open \`Drift-$VERSION-arm64.dmg\` and drag Drift to Applications.
2. First launch: macOS Gatekeeper may block the ad-hoc build. Open
   **System Settings → Privacy & Security → Open Anyway**, or run
   \`xattr -dr com.apple.quarantine /Applications/Drift.app\`.
3. Embedded mode is the default for fresh installs. Existing server users
   can switch in **Settings → Torrent Engine**.
EOF

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Drift</title>
    <link>https://github.com/Harshsanket/drift/releases</link>
    <description>Drift macOS releases</description>
    <language>en</language>
    <item>
      <title>Drift $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[Embedded libtorrent engine, parity wave, native Jackett/Prowlarr search.]]></description>
      <enclosure url="$ENCLOSURE_URL"
                 length="$SIZE"
                 type="application/octet-stream"
                 sparkle:edSignature="$SIGNATURE" />
    </item>
  </channel>
</rss>
EOF
xmllint --noout dist/appcast.xml
if [[ -x "$SIGN_TOOL" ]]; then
    "$SIGN_TOOL" --ed-key-file "$TMP_KEY" --verify "$DMG" "$SIGNATURE"
fi

echo "== verifying DMG install =="
MNT="$(mktemp -d)"
# A DMG with an EULA asks for agreement on attach; feed "Y" for the
# non-interactive release verification.
printf 'Y\n' | hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
test -x "$MNT/Drift.app/Contents/MacOS/drift-engine"
"$MNT/Drift.app/Contents/MacOS/drift-engine" --version
codesign --verify --deep --strict "$MNT/Drift.app"
test -f "$MNT/Drift.app/Contents/Resources/ThirdPartyLicenses/libtorrent-LICENSE"
hdiutil detach "$MNT" -quiet
MNT=""

shasum -a 256 "$DMG" | tee "dist/Drift-$VERSION-arm64.dmg.sha256"
echo
echo "artifact:  $DMG"
echo "appcast:   dist/appcast.xml"
echo "notes:     dist/release-notes-$VERSION.md"
echo "signing:   ad-hoc (no Developer ID, no notarization — D20)"
echo "gatekeeper: users must use System Settings → Privacy & Security → Open Anyway"
echo
echo "publish (requires explicit user confirmation — D16):"
echo "  gh release create $TAG \"$DMG\" dist/appcast.xml dist/release-notes-$VERSION.md \\"
echo "    --title \"Drift $VERSION\" --notes-file dist/release-notes-$VERSION.md"
