#!/bin/bash
# Assembles a minimal Drift.app around the SwiftPM-built binary.
# Dev-only wrapper: gives the app a bundle identifier so macOS system
# services (linkd/Intents, window tabbing) stop logging errors.
# Full packaging/signing/notarization is Phase 14.
set -euo pipefail

cd "$(dirname "$0")/.."

BIN=".build/out/Products/Debug/Drift"
APP=".build/Drift.app"

if [[ ! -f "$BIN" ]]; then
    echo "error: $BIN not found — run: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --arch arm64" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Drift"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Tunnel helper: bundled alongside the app so HelperLauncher finds it
# (Bundle.main executable dir lookup) without a .build path dependency.
HELPER=".build/out/Products/Debug/drift-tunnel-helper"
if [[ -f "$HELPER" ]]; then
    cp "$HELPER" "$APP/Contents/MacOS/drift-tunnel-helper"
else
    echo "warning: tunnel helper missing — build the drift-tunnel-helper target first"
fi

# PartoutNative dynamic framework: both binaries link it; embed under
# Frameworks and point rpath there before sealing.
FRAMEWORK=".build/out/Products/Debug/PartoutNative.framework"
if [[ -d "$FRAMEWORK" ]]; then
    cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"
    for EXE in "$APP/Contents/MacOS/Drift" "$APP/Contents/MacOS/drift-tunnel-helper"; do
        [[ -f "$EXE" ]] || continue
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
    done
fi

# Sparkle (update chain): the app binary links it whenever the security
# build is live; without the framework the app dies in dyld.
SPARKLE=".build/out/Products/Debug/Sparkle.framework"
[[ -d "$SPARKLE" ]] || SPARKLE=".build/out/Products/Release/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
    codesign --force -s - "$APP/Contents/Frameworks/Sparkle.framework"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Drift</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.harshsanket.drift</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Drift</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "Packaged $APP"

# Ad-hoc seal: an unsealed bundle (binary signature present, Info.plist
# modified after) fails codesign validation, which makes macOS reject all
# keychain operations from the app (-67030). Phase 14 replaces this with
# Developer ID signing + notarization. The embedded PartoutNative
# framework is unsigned from SwiftPM's copy, so it must be sealed before
# (or alongside) the app or the bundle seal refuses.
if [[ -d "$APP/Contents/Frameworks/PartoutNative.framework" ]]; then
    codesign --force -s - "$APP/Contents/Frameworks/PartoutNative.framework"
fi
codesign --force -s - --entitlements Scripts/entitlements-dev.plist "$APP"
codesign -v "$APP"
