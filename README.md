# Mac Live Wallpaper

Also for Windows: see [Windows](#windows) below.

Use any video as a looping live wallpaper on your Mac. It plays silently behind your desktop icons on every display, pauses while your Mac sleeps or is locked, and starts at login. It never changes your macOS wallpaper, so the lock screen keeps showing your own.

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

The app shows in the Dock and the menu bar. From the menu bar icon you can choose a new video, pause or play, and turn Start at Login on or off. The app window also has a **Start at Login** checkbox.

- **Closing the window or choosing Quit from the Dock** keeps the wallpaper playing in the background. The Dock icon goes away, and the menu bar icon stays. Open the app again to bring back the window.
- **Exit** (in the app window, the app menu, the menu bar icon, or ⌘Q) really quits. The app starts again at your next login if Start at Login is on.
- **Uninstall…** removes the app completely: it stops the wallpaper, removes the login item, deletes the imported video and settings, and moves the app to the Bin.

## Build from source

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This creates `build/Mac Live Wallpaper.app` and `build/MacLiveWallpaper.dmg`.

## Windows

**Live Wallpaper** for Windows 10 and 11 has the same features: drop or choose a video, paste a YouTube link, seamless looping behind the desktop icons on every monitor, Start at Login, and Exit and Uninstall buttons. It sits in the system tray (by the clock) instead of the menu bar.

Paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/AbhishekVatsh/mac-live-wallpaper/main/windows/install.ps1 | iex
```

It downloads the latest release, installs it in `%LOCALAPPDATA%\Programs\LiveWallpaper`, adds it to the Start menu and opens it.

- Videos play with [mpv](https://mpv.io), which is included. It plays every format YouTube uses, so YouTube videos download in up to 4K on any PC.
- Closing the window keeps the wallpaper playing. Open it again from the tray icon or the Start menu.
- The app never changes your Windows wallpaper or lock screen.

To build it yourself, install the [.NET 8 SDK](https://dotnet.microsoft.com/download) and run `dotnet publish windows/LiveWallpaper.csproj -c Release -o dist`, then put `mpv.exe` in `dist/mpv`. The GitHub workflow in `.github/workflows/windows.yml` does all of this, tests it on a Windows desktop, and attaches `LiveWallpaper-Windows.zip` to each release.
