#!/bin/bash
# Builds DyskLink.app into dist. Uses the local certificate if present, see create-signing-cert.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release

APP="dist/DyskLink.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PhoneLinkMac" "$APP/Contents/MacOS/DyskLink"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DyskLink</string>
    <key>CFBundleIdentifier</key><string>id.phonelink.mac</string>
    <key>CFBundleName</key><string>DyskLink</string>
    <key>CFBundleDisplayName</key><string>DyskLink</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>DyskLink uses the local network to connect to your phone.</string>
    <key>NSBonjourServices</key>
    <array><string>_phonelink._tcp</string></array>
</dict>
</plist>
PLIST

SIGNING_NAME="DyskLink Local Signing"
if security find-certificate -c "$SIGNING_NAME" >/dev/null 2>&1; then
    codesign --force --deep --sign "$SIGNING_NAME" "$APP"
else
    # Without the certificate, Accessibility has to be granted again after every new build.
    echo "Warning: using an ad-hoc signature. Run scripts/create-signing-cert.sh."
    codesign --force --deep --sign - "$APP"
fi
echo "Done: $(pwd)/$APP"
