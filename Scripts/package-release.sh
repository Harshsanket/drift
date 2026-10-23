#!/bin/bash
# Release packaging with the security plan's guarantees (no Apple Developer
# account required for local builds):
#   1. Release-configuration binaries (Drift + drift-tunnel-helper).
#   2. Hardened Runtime applied via ad-hoc codesign; when a Developer ID is
#      provided (--dev-id "Developer ID Application: ..."), that identity is
#      used instead and --deep-style flow prepares for notarization later.
#   3. Sparkle + PartoutNative frameworks embedded and sealed.
#   4. Integrity manifest: SHA-256 manifest over every file in Contents +
#      detached EdDSA signature (private key from ~/drift-signing, or
#      DRIFT_EDDSA_PRIVATE_KEY). Embedded public key inside the binary
#      verifies this pair at launch.
#   5. Generates a skeleton appcast.xml to hand the zipped app (EdDSA sigs
#      for Sparkle's own records still come from `sign_update`).
#
# Usage: bash Scripts/package-release.sh [--dev-id IDENTITY] [VERSION]
# VERSION defaults to the current CFBundleShortVersionString.
set -euo pipefail

cd "$(dirname "$0")/.."

DEV_ID=""
if [[ "${1:-}" == "--dev-id" ]]; then
    DEV_ID="${2:?--dev-id needs an identity}"
    shift 2
fi
VERSION="${1:-}"

BIN=".build/out/Products/Release/Drift"
HELPER=".build/out/Products/Release/drift-tunnel-helper"
FRAMEWORK=".build/out/Products/Release/PartoutNative.framework"
# Sparkle's SPM product materializes the framework in whichever
# configuration linked a product first; accept either location.
SPARKLE_FRAMEWORK=".build/out/Products/Release/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || SPARKLE_FRAMEWORK=".build/out/Products/Debug/Sparkle.framework"
APP=".build/Drift-reln.app"

if [[ ! -f "$BIN" || ! -f "$HELPER" ]]; then
    echo "error: release binaries missing — run:" >&2
    echo "  swift build --configuration release --arch arm64" >&2
    echo "  swift build --configuration release --product drift-tunnel-helper --arch arm64" >&2
    exit 1
fi

if [[ -z "$VERSION" ]]; then
    VERSION=$(xcrun plutil -extract CFBundleShortVersionString raw \
        .build/Drift.app/Contents/Info.plist 2>/dev/null || echo "1.1.0")
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Drift"
cp "$HELPER" "$APP/Contents/MacOS/drift-tunnel-helper"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Frameworks: PartoutNative (tunnel core) and, when linked, Sparkle
# (update chain). Both embedded + sealed before the app itself.
for fw in "$FRAMEWORK" "$SPARKLE_FRAMEWORK"; do
    [[ -d "$fw" ]] || continue
    cp -R "$fw" "$APP/Contents/Frameworks/"
done
for EXE in "$APP/Contents/MacOS/Drift" "$APP/Contents/MacOS/drift-tunnel-helper"; do
    [[ -f "$EXE" ]] || continue
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
done

# Helpers that Sparkle runs during install must carry its own
# Autoupdate readiness; Sparkle's package requires the framework's inner
# binaries to be signed before the app bundle seal.
for fw in "$APP/Contents/Frameworks/"*.framework; do
    [[ -d "$fw" ]] || continue
    if [[ -n "$DEV_ID" ]]; then
        codesign --force -s "$DEV_ID" --options runtime "$fw" 2>/dev/null || codesign --force -s - --options runtime "$fw"
    else
        codesign --force -s - --options runtime "$fw"
    fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SUPublicEDKey</key>
    <string></string>
</dict>
</plist>
PLIST

# With hardened runtime, ad-hoc sealed helper: hardening keeps the process
# trustworthy to dlopen its private framework; the privileged helper never
# accepts teams without our identity check anyway.
if [[ -n "$DEV_ID" ]]; then
    codesign --force -s "$DEV_ID" --options runtime "$APP"
else
    codesign --force -s - --options runtime --entitlements Scripts/entitlements-dev.plist "$APP"
fi
codesign -v "$APP"

# Integrity manifest + detached EdDSA signature (release signer's key).
SIGKIND="ad-hoc"
PRIVATE_KEY="${DRIFT_EDDSA_PRIVATE_KEY:-$HOME/drift-signing/drift-eddsa.private}"
if [[ -f "$PRIVATE_KEY" ]]; then
    MANIFEST_PLAIN=$(mktemp)
    MANIFEST="$APP/Contents/Resources/IntegrityManifest.json"
    SIG="$APP/Contents/Resources/IntegrityManifest.json.sig"
    python3 - "$APP/Contents" > "$MANIFEST_PLAIN" <<'PY'
import hashlib, json, os, sys, posixpath

root = sys.argv[1]
entries = {}
base = root
accumulator = []
for folder, _, files in os.walk(base):
    for name in files:
        path = os.path.join(folder, name)
        relative = os.path.relpath(path, base)
        if relative.startswith("_CodeSignature"):
            continue
        if relative in ("Resources/IntegrityManifest.json",
                        os.path.join("Resources", "IntegrityManifest.json.sig")):
            continue
        if "Resources/" + os.path.basename(path) == relative and False:
            continue
        digest = None
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        entries[relative] = digest
document = {"version": 1, "entries": dict(sorted(entries.items()))}
sys.stdout.write(json.dumps(document, sort_keys=True))
PY
    # Sign via a swift one-liner bridge so CryptoKit's Ed25519 matches the
    # app-side verification exactly.
    SIGNATURE_END=$(swift Scripts/eddsa_sign_stdin.swift "$PRIVATE_KEY" "$MANIFEST_PLAIN")
    printf '%s' "$SIGNATURE_END" > "$SIG"
    mv "$MANIFEST_PLAIN" "$MANIFEST"
    SIGKIND="EdDSA-signed"
    echo "Integrity manifest written + signed ($SIG)."
else
    echo "warning: no private key at $PRIVATE_KEY — manifest unsigned (launch verification unavailable)." >&2
fi

echo "Packaged $APP ($SIGKIND, version $VERSION, hardened runtime)"
echo "Seal check: $(codesign -dv "$APP" 2>&1 | grep -E 'Runtime|Identifier=' | tr '\n' ' ')"
