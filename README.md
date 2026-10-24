# Mac Live Wallpaper

Use any video as a looping live wallpaper on your Mac. It plays silently behind your desktop icons on every display, pauses while your Mac sleeps or is locked, and starts at login.

## Install

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/AbhishekVatsh/mac-live-wallpaper/main/install.sh | bash
```

It downloads the latest release, installs it in Applications and opens it. Then drop a video (.mp4 or .mov) onto the window, click **Choose Video…**, or paste a YouTube link.

You can also download `MacLiveWallpaper.dmg` from the [Releases](https://github.com/AbhishekVatsh/mac-live-wallpaper/releases) page and drag the app into Applications. The app isn't notarized by Apple, so when it's installed this way, macOS blocks the first launch. Allow it once in **System Settings → Privacy & Security → Open Anyway**.

## YouTube links

Paste a YouTube link into **Or paste a YouTube link** and click **Set as Wallpaper**. Or click **Paste** to paste a link you copied. The app downloads the video without sound and sets it as your wallpaper. Click **Cancel** to stop a download.

Videos download in up to 4K on Macs with an M3 chip or newer, which can play AV1, the format YouTube uses for 4K. Older Macs get up to 1080p.

The first time, the app downloads [yt-dlp](https://github.com/yt-dlp/yt-dlp) (about 35 MB) from its official GitHub release, and it keeps yt-dlp up to date after that. If a download fails, yt-dlp's messages are in `~/Library/Application Support/LiveWallpaper/bin/last-download.log`.

Only use videos you have the right to download.

## Use

The menu bar icon lets you choose a new video, pause or play, and turn Start at Login on or off.

- **Exit** (in the menu bar icon or the app window, or ⌘Q) quits the app and puts back the wallpaper you had before. The app starts again at your next login if Start at Login is on.
- **Uninstall…** removes the app completely: it stops the wallpaper, puts back your previous wallpaper, removes the login item, deletes the imported video and settings, and moves the app to the Bin.

## Build from source

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This creates `build/Mac Live Wallpaper.app` and `build/MacLiveWallpaper.dmg`.
