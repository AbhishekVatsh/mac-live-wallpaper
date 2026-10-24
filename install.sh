#!/bin/bash
# Installs the latest Mac Live Wallpaper release into /Applications and opens it.
# Usage: curl -fsSL https://raw.githubusercontent.com/AbhishekVatsh/mac-live-wallpaper/main/install.sh | bash
set -euo pipefail

REPO="AbhishekVatsh/mac-live-wallpaper"
APP="Mac Live Wallpaper.app"
URL="https://github.com/$REPO/releases/latest/download/MacLiveWallpaper.dmg"

TMP=$(mktemp -d)
MOUNT="$TMP/mount"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "Downloading Mac Live Wallpaper..."
curl -fL --progress-bar "$URL" -o "$TMP/MacLiveWallpaper.dmg"

echo "Installing to /Applications..."
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -quiet -mountpoint "$MOUNT" "$TMP/MacLiveWallpaper.dmg"
pkill -x MacLiveWallpaper 2>/dev/null || true
rm -rf "/Applications/$APP"
ditto "$MOUNT/$APP" "/Applications/$APP"
xattr -dr com.apple.quarantine "/Applications/$APP" 2>/dev/null || true

open "/Applications/$APP"
echo "Done. Mac Live Wallpaper is running. Look for its icon in the menu bar."
