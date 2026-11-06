#!/bin/sh
# Builds mac/build/Companion.app: a menu bar app (no Dock icon) that starts the Node backend
# from this repository if it is not already running. Usage: mac/build-app.sh [--open]
set -eu
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"

swift build -c release --product Companion
BIN="$(swift build -c release --show-bin-path)/Companion"

APP=build/Companion.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Companion"
cp Sources/Companion/Resources/* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Companion</string>
  <key>CFBundleDisplayName</key><string>Claude Code Companion</string>
  <key>CFBundleIdentifier</key><string>nl.lloydvanzaalen.claude-companion</string>
  <key>CFBundleExecutable</key><string>Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CompanionRepo</key><string>$REPO</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
