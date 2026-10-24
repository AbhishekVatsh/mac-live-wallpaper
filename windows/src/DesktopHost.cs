using System.Diagnostics;
using System.IO.Pipes;
using System.Text;

namespace LiveWallpaper;

/// Plays the video behind the desktop icons on every monitor.
///
/// Windows draws the wallpaper and the icons in separate windows under Progman. Sending
/// Progman the undocumented 0x052C message makes it create a "WorkerW" window between the
/// two; video windows parented to it sit above the wallpaper and below the icons. Each
/// monitor gets its own window, played by an embedded mpv, which loops seamlessly at the
/// video's real end and plays every format YouTube uses (H.264, VP9, AV1).
sealed class DesktopHost : IDisposable
{
    sealed record Surface(IntPtr Window, Process Player, string Pipe);

    readonly List<Surface> surfaces = new();
    string? video;
    bool paused;

    public bool IsPlaying => video is not null && !paused && surfaces.Count > 0;

    public static string MpvPath => Path.Combine(AppContext.BaseDirectory, "mpv", "mpv.exe");

    public void Load(string path, bool startPaused)
    {
        video = path;
        paused = startPaused;
        Rebuild();
    }

    /// Recreates the video windows, for example after monitors change or Explorer restarts.
    public void Rebuild()
    {
        Clear();
        if (video is null) return;
        if (!File.Exists(MpvPath)) { Log.Write($"mpv not found at {MpvPath}"); return; }

        var parent = FindDesktopParent();
        foreach (var screen in Screen.AllScreens)
        {
            // Child-window coordinates are relative to the parent, which spans all monitors.
            var origin = new Native.POINT { X = screen.Bounds.X, Y = screen.Bounds.Y };
            Native.MapWindowPoints(IntPtr.Zero, parent, ref origin, 1);
            var window = Native.CreateWindowEx(0, "Static", "", Native.WS_CHILD | Native.WS_VISIBLE | Native.SS_BLACKRECT,
                                               origin.X, origin.Y, screen.Bounds.Width, screen.Bounds.Height,
                                               parent, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (window == IntPtr.Zero) { Log.Write("Couldn't create a video window."); continue; }

            var pipe = $"livewallpaper-mpv-{Environment.ProcessId}-{surfaces.Count}";
            var player = StartMpv(window, pipe);
            if (player is null) { Native.DestroyWindow(window); continue; }
            surfaces.Add(new Surface(window, player, pipe));
            Log.Write($"Playing on {screen.DeviceName} {screen.Bounds} at {origin.X},{origin.Y}");
        }
    }

    Process? StartMpv(IntPtr window, string pipe)
    {
        var psi = new ProcessStartInfo(MpvPath) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in new[]
        {
            $"--wid={window.ToInt64()}", "--no-config",
            "--loop-file=inf", "--no-audio", "--hwdec=auto-safe",
            "--keepaspect=yes", "--panscan=1.0",          // fill the screen, cropping like "Fill"
            "--osc=no", "--osd-level=0", "--input-default-bindings=no", "--input-vo-keyboard=no",
            "--cursor-autohide=no", "--background-color=#000000", "--msg-level=all=error",
            $"--input-ipc-server=\\\\.\\pipe\\{pipe}", $"--pause={(paused ? "yes" : "no")}",
            "--", video!,
        }) psi.ArgumentList.Add(arg);
        try { return Process.Start(psi); }
        catch (Exception e) { Log.Write($"Couldn't start mpv: {e.Message}"); return null; }
    }

    public void Play() { paused = false; SetPause(false); }
    public void Pause() { paused = true; SetPause(true); }

    /// Pauses without changing the user's choice (screen locked, PC asleep).
    public void Suspend() => SetPause(true);
    public void Resume() { if (!paused) SetPause(false); }

    void SetPause(bool value)
    {
        var json = $"{{\"command\":[\"set_property\",\"pause\",{(value ? "true" : "false")}]}}\n";
        foreach (var s in surfaces)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", s.Pipe, PipeDirection.Out);
                client.Connect(300);
                client.Write(Encoding.UTF8.GetBytes(json));
            }
            catch (Exception e) { Log.Write($"Couldn't reach mpv: {e.Message}"); }
        }
    }

    void Clear()
    {
        foreach (var s in surfaces)
        {
            try { if (!s.Player.HasExited) s.Player.Kill(); } catch { }
            s.Player.Dispose();
            if (Native.IsWindow(s.Window)) Native.DestroyWindow(s.Window);
        }
        surfaces.Clear();
    }

    public void Stop()
    {
        video = null;
        Clear();
    }

    public void Dispose() => Stop();

    /// The window to put video windows in: the WorkerW behind the desktop icons.
    static IntPtr FindDesktopParent()
    {
        var progman = Native.FindWindow("Progman", null);
        Native.SendMessageTimeout(progman, 0x052C, new IntPtr(0xD), new IntPtr(0x1), Native.SMTO_NORMAL, 1000, out _);
        Native.SendMessageTimeout(progman, 0x052C, IntPtr.Zero, IntPtr.Zero, Native.SMTO_NORMAL, 1000, out _);

        // Windows 11 24H2 and later: the WorkerW is a child of Progman.
        var child = Native.FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
        if (child != IntPtr.Zero) { Log.Write("Desktop: WorkerW inside Progman (Windows 11 24H2+)"); return child; }

        // Earlier versions: a top-level WorkerW right after the one holding the icons.
        var workerw = IntPtr.Zero;
        Native.EnumWindows((top, _) =>
        {
            if (Native.FindWindowEx(top, IntPtr.Zero, "SHELLDLL_DefView", null) != IntPtr.Zero)
                workerw = Native.FindWindowEx(IntPtr.Zero, top, "WorkerW", null);
            return true;
        }, IntPtr.Zero);
        if (workerw != IntPtr.Zero) { Log.Write("Desktop: top-level WorkerW"); return workerw; }

        Log.Write("Desktop: WorkerW not found, using Progman");
        return progman;
    }
}
