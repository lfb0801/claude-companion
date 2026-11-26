#!/bin/sh
# Builds mac/build/Claude Companion.app: a menu bar app (no Dock icon) that starts the Node backend
# from this repository if it is not already running. Usage: mac/build-app.sh [--open]
set -eu
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"

# COMPANION_BUNDLE_ID comes from the repository's .env (copy .env.example). macOS ties the Accessibility
# grant, the Keychain pairing with the iPhone and the logs to it.
if [ -f "$REPO/.env" ]; then set -a; . "$REPO/.env"; set +a; fi
BUNDLE_ID="${COMPANION_BUNDLE_ID:-local.claude-companion}"

swift build -c release --product Companion
BIN="$(swift build -c release --show-bin-path)/Companion"

APP="build/Claude Companion.app"
rm -rf "$APP" build/Companion.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Companion"
cp Sources/Companion/Resources/* "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # drawn by make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Companion</string>
  <key>CFBundleDisplayName</key><string>Claude Companion</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSBonjourServices</key>
  <array><string>_phone-whip._tcp</string></array>
  <key>NSLocalNetworkUsageDescription</key><string>Claude Companion advertises its iPhone Whip service on your local network.</string>
  <key>CompanionRepo</key><string>$REPO</string>
</dict></plist>
PLIST

# Ad-hoc signing pins permissions (Accessibility) to this exact build, so every rebuild would lose them.
# Pin them to the bundle identifier instead; the grant then survives rebuilds.
codesign --force --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null
echo "Built $(pwd)/$APP"
# A shortcut in /Applications, so Spotlight and `open "/Applications/Claude Companion.app"` find the build.
LINK="/Applications/Claude Companion.app"
if [ "$(readlink "$LINK" 2>/dev/null)" != "$(pwd)/$APP" ]; then
  ln -sfn "$(pwd)/$APP" "$LINK" 2>/dev/null || echo "Could not link $LINK (not writable)."
fi
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
