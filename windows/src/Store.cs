using System.Text.Json;
using Microsoft.Win32;

namespace LiveWallpaper;

/// Settings, the imported video, and where things live on disk.
static class Store
{
    /// %LOCALAPPDATA%\LiveWallpaper: the imported video, its still frame, yt-dlp and settings.
    public static readonly string Folder =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LiveWallpaper");

    /// Where install.ps1 puts the app.
    public static readonly string InstallFolder =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "LiveWallpaper");

    public static readonly string StartMenuShortcut =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "Live Wallpaper.lnk");

    public static string BinFolder => Path.Combine(Folder, "bin");
    static string SettingsFile => Path.Combine(Folder, "settings.json");

    public sealed class Data
    {
        public string? VideoFile { get; set; }
        public bool Paused { get; set; }
        public bool StartAtLoginDefaultApplied { get; set; }
        public PreviousWallpaperInfo? PreviousWallpaper { get; set; }
    }

    public sealed class PreviousWallpaperInfo
    {
        /// A copy of the user's own wallpaper image, or null if they had a plain color.
        public string? ImageCopy { get; set; }
        public string? Style { get; set; }
        public string? Tile { get; set; }
    }

    public static Data Settings { get; private set; } = Load();

    static Data Load()
    {
        Directory.CreateDirectory(Folder);
        try { return JsonSerializer.Deserialize<Data>(File.ReadAllText(SettingsFile)) ?? new Data(); }
        catch { return new Data(); }
    }

    public static void Save()
    {
        Directory.CreateDirectory(Folder);
        File.WriteAllText(SettingsFile, JsonSerializer.Serialize(Settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    public static void Reset()
    {
        Settings = new Data();
    }

    public static string? CurrentVideo
    {
        get
        {
            if (Settings.VideoFile is not { } name) return null;
            var path = Path.Combine(Folder, name);
            return File.Exists(path) ? path : null;
        }
        set { Settings.VideoFile = value is null ? null : Path.GetFileName(value); Save(); }
    }

    /// Copies the chosen video in, so the wallpaper keeps working if the original moves.
    public static string ImportVideo(string source)
    {
        Directory.CreateDirectory(Folder);
        var dest = Path.Combine(Folder, $"wallpaper-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}{Path.GetExtension(source)}");
        File.Copy(source, dest, overwrite: true);
        // Remove previously imported videos and their still frames.
        foreach (var old in Directory.GetFiles(Folder, "wallpaper-*"))
            if (!string.Equals(old, dest, StringComparison.OrdinalIgnoreCase)) TryDelete(old);
        return dest;
    }

    public static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    /// True when running from the folder install.ps1 uses (not a download or build folder).
    public static bool IsInstalled =>
        string.Equals(Path.GetDirectoryName(Application.ExecutablePath)?.TrimEnd('\\'), InstallFolder.TrimEnd('\\'),
                      StringComparison.OrdinalIgnoreCase);
}

/// The HKCU Run entry that starts the app when you sign in.
static class StartAtLogin
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "LiveWallpaper";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(Name, $"\"{Application.ExecutablePath}\" --startup");
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }

    /// Turns Start at Login on the first time the installed app runs. After that, the user's choice wins.
    public static void ApplyDefault()
    {
        if (Store.Settings.StartAtLoginDefaultApplied || !Store.IsInstalled) return;
        Set(true);
        Store.Settings.StartAtLoginDefaultApplied = true;
        Store.Save();
    }
}

static class Log
{
    static readonly object Gate = new();

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                var path = Path.Combine(Store.Folder, "log.txt");
                if (File.Exists(path) && new FileInfo(path).Length > 512 * 1024) File.Delete(path);
                File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {message}{Environment.NewLine}");
            }
        }
        catch { }
    }
}
