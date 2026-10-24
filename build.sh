#!/bin/zsh
# Builds "Mac Live Wallpaper.app" with the Xcode Command Line Tools (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Mac Live Wallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  Sources/main.swift -o "$APP/Contents/MacOS/MacLiveWallpaper"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mac Live Wallpaper</string>
  <key>CFBundleDisplayName</key><string>Mac Live Wallpaper</string>
  <key>CFBundleIdentifier</key><string>com.abhishek.livewallpaper</string>
  <key>CFBundleExecutable</key><string>MacLiveWallpaper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.7</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

# Package a drag-to-install DMG next to the app.
DMG="build/MacLiveWallpaper.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mac Live Wallpaper" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
