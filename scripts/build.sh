#!/bin/bash
# Compile PillMusic et assemble PillMusic.app — sans Xcode (outils en ligne de commande suffisent).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/PillMusic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PillMusic" "$APP/Contents/MacOS/PillMusic"
cp Resources/* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PillMusic</string>
    <key>CFBundleDisplayName</key><string>PillMusic</string>
    <key>CFBundleIdentifier</key><string>app.pillmusic.PillMusic</string>
    <key>CFBundleExecutable</key><string>PillMusic</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>PillMusic contrôle l'app Musique pour lancer, mettre en pause et changer de morceau.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "✅ $APP"
