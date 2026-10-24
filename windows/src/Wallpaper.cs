using System.Diagnostics;
using System.Text;
using Microsoft.Win32;

namespace LiveWallpaper;

/// The regular Windows wallpaper: shows the video's still frame while the app runs
/// (lock screen transitions, Task View), and is put back the way it was on Exit.
static class Wallpaper
{
    const string DesktopKey = @"Control Panel\Desktop";

    static string? CurrentPath()
    {
        var path = new StringBuilder(1024);
        return Native.SystemParametersInfo(Native.SPI_GETDESKWALLPAPER, (uint)path.Capacity, path, 0)
            ? path.ToString() : null;
    }

    static void Set(string path) =>
        Native.SystemParametersInfo(Native.SPI_SETDESKWALLPAPER, 0, path, Native.SPIF_UPDATEINIFILE | Native.SPIF_SENDCHANGE);

    /// Records the user's own wallpaper, unless it's already our still frame.
    static void RememberPrevious()
    {
        var current = CurrentPath() ?? "";
        if (current.StartsWith(Store.Folder, StringComparison.OrdinalIgnoreCase) &&
            Path.GetFileName(current).StartsWith("wallpaper-", StringComparison.OrdinalIgnoreCase)) return;

        using var key = Registry.CurrentUser.OpenSubKey(DesktopKey);
        var info = new Store.PreviousWallpaperInfo
        {
            Style = key?.GetValue("WallpaperStyle") as string,
            Tile = key?.GetValue("TileWallpaper") as string,
        };
        if (current.Length > 0 && File.Exists(current))
        {
            // Keep our own copy: Windows may overwrite its cached copy when we set the still frame.
            var copy = Path.Combine(Store.Folder, "previous-wallpaper" + Path.GetExtension(current));
            try { File.Copy(current, copy, overwrite: true); info.ImageCopy = copy; }
            catch (Exception e) { Log.Write($"Couldn't copy the current wallpaper: {e.Message}"); }
        }
        Store.Settings.PreviousWallpaper = info;
        Store.Save();
    }

    /// Extracts the video's first frame with mpv and makes it the Windows wallpaper.
    public static void SetStill(string video)
    {
        Task.Run(() =>
        {
            try
            {
                var still = Path.ChangeExtension(video, ".jpg");
                if (!File.Exists(still) && !ExtractFirstFrame(video, still)) return;
                RememberPrevious();
                using (var key = Registry.CurrentUser.CreateSubKey(DesktopKey))
                {
                    key.SetValue("WallpaperStyle", "10");   // Fill
                    key.SetValue("TileWallpaper", "0");
                }
                Set(still);
            }
            catch (Exception e) { Log.Write($"Couldn't set the still wallpaper: {e.Message}"); }
        });
    }

    static bool ExtractFirstFrame(string video, string still)
    {
        var outDir = Path.Combine(Path.GetTempPath(), "LiveWallpaper-still-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outDir);
        try
        {
            var psi = new ProcessStartInfo(DesktopHost.MpvPath) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "--no-config", "--no-audio", "--frames=1", "--vo=image", "--vo-image-format=jpg",
                                        "--vo-image-jpeg-quality=92", $"--vo-image-outdir={outDir}", "--", video })
                psi.ArgumentList.Add(arg);
            using var p = Process.Start(psi)!;
            if (!p.WaitForExit(30_000)) { p.Kill(); return false; }
            var frame = Directory.GetFiles(outDir, "*.jpg").FirstOrDefault();
            if (frame is null) return false;
            File.Move(frame, still, overwrite: true);
            return true;
        }
        catch (Exception e) { Log.Write($"Couldn't extract a still frame: {e.Message}"); return false; }
        finally { try { Directory.Delete(outDir, recursive: true); } catch { } }
    }

    /// Puts back the wallpaper the user had before. Returns false if it was never recorded.
    public static bool RestorePrevious()
    {
        if (Store.Settings.PreviousWallpaper is not { } info) return false;
        try
        {
            using (var key = Registry.CurrentUser.CreateSubKey(DesktopKey))
            {
                if (info.Style is not null) key.SetValue("WallpaperStyle", info.Style);
                if (info.Tile is not null) key.SetValue("TileWallpaper", info.Tile);
            }
            Set(info.ImageCopy is { } copy && File.Exists(copy) ? copy : "");
            return true;
        }
        catch (Exception e) { Log.Write($"Couldn't restore the wallpaper: {e.Message}"); return false; }
    }
}
