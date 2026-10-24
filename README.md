# Mac Live Wallpaper

Use any video as a looping live wallpaper on your Mac. It plays silently behind your desktop icons on every display, pauses while your Mac sleeps or is locked, and starts at login.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/AbhishekVatsh/mac-live-wallpaper/main/install.sh | bash
```

It downloads the latest release, installs it in Applications and opens it. Then drop a video (.mp4 or .mov) onto the window, or click **Choose Video…**.

You can also download `MacLiveWallpaper.dmg` from the [Releases](https://github.com/AbhishekVatsh/mac-live-wallpaper/releases) page and drag the app into Applications. The app isn't notarized by Apple, so when it's installed this way, macOS blocks the first launch. Allow it once in **System Settings → Privacy & Security → Open Anyway**.

## Use

The menu bar icon lets you choose a new video, pause or play, turn Start at Login on or off, and quit.

## Build from source

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This creates `build/Mac Live Wallpaper.app` and `build/MacLiveWallpaper.dmg`.
