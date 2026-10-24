using System.Diagnostics;
using System.Text;

namespace LiveWallpaper;

/// Downloads YouTube videos with yt-dlp, which the app fetches from its official GitHub
/// release the first time it's needed and keeps up to date.
sealed class YouTubeDownloader
{
    static string ToolPath => Path.Combine(Store.BinFolder, "yt-dlp.exe");
    const string ReleaseUrl = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";

    Process? process;
    bool cancelled;

    public static bool IsYouTubeLink(string text)
    {
        if (!Uri.TryCreate(text.Trim(), UriKind.Absolute, out var uri)) return false;
        var host = uri.Host.ToLowerInvariant();
        return host == "youtu.be" || host == "youtube.com" || host.EndsWith(".youtube.com");
    }

    /// Reports status text through `progress` (on the caller's thread) and returns the downloaded file.
    public async Task<string> DownloadAsync(string link, IProgress<string> progress)
    {
        await PrepareToolAsync(progress);
        return await RunAsync(link.Trim(), progress);
    }

    public void Cancel()
    {
        cancelled = true;
        try { if (process is { HasExited: false }) process.Kill(entireProcessTree: true); } catch { }
    }

    static async Task PrepareToolAsync(IProgress<string> progress)
    {
        if (File.Exists(ToolPath))
        {
            // YouTube changes often, so refresh yt-dlp if it's more than a few days old.
            if (DateTime.Now - File.GetLastWriteTime(ToolPath) > TimeSpan.FromDays(3))
            {
                progress.Report("Updating the YouTube downloader…");
                await Task.Run(() =>
                {
                    try
                    {
                        using var update = Process.Start(new ProcessStartInfo(ToolPath, "--update")
                                                         { UseShellExecute = false, CreateNoWindow = true })!;
                        update.WaitForExit(120_000);
                        File.SetLastWriteTime(ToolPath, DateTime.Now);
                    }
                    catch (Exception e) { Log.Write($"yt-dlp update failed: {e.Message}"); }
                });
            }
            return;
        }

        progress.Report("Getting the YouTube downloader (one time, about 18 MB)…");
        Directory.CreateDirectory(Store.BinFolder);
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.UserAgent.ParseAdd("LiveWallpaper");
            var temp = ToolPath + ".download";
            await using (var source = await http.GetStreamAsync(ReleaseUrl))
            await using (var file = File.Create(temp))
                await source.CopyToAsync(file);
            File.Move(temp, ToolPath, overwrite: true);
        }
        catch (Exception e)
        {
            throw new Exception($"Couldn't download the YouTube downloader. Check your internet connection and try again.\n{e.Message}");
        }
    }

    async Task<string> RunAsync(string link, IProgress<string> progress)
    {
        var outDir = Path.Combine(Path.GetTempPath(), "LiveWallpaper-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outDir);

        var psi = new ProcessStartInfo(ToolPath)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var arg in new[]
        {
            "--no-config", "--no-playlist", "--no-part", "--newline",
            // Video only (wallpapers are silent), the highest resolution up to 4K.
            // mpv plays AV1, VP9 and H.264, so any of them will do; AV1 is preferred at equal resolution.
            "-f", "bv*[height<=2160][protocol^=http]/bv*[height<=2160]/b",
            "-S", "res,vcodec:av01",
            "-o", Path.Combine(outDir, "%(title).80B.%(ext)s"),
            "--progress-template", "download:PROGRESS %(progress._percent_str)s",
            link,
        }) psi.ArgumentList.Add(arg);

        var errors = new StringBuilder();
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) =>
        {
            if (e.Data is { } line && line.StartsWith("PROGRESS "))
                progress.Report($"Downloading… {line["PROGRESS ".Length..].Trim()}");
        };
        p.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (errors) errors.AppendLine(e.Data); };

        progress.Report("Starting download…");
        try { p.Start(); }
        catch (Exception e) { TryDeleteDir(outDir); throw new Exception($"Couldn't start the YouTube downloader.\n{e.Message}"); }
        process = p;
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        await p.WaitForExitAsync();
        p.WaitForExit();   // flushes the output events

        var log = $"{DateTime.Now}\n{link}\nexit {p.ExitCode}\n\n{errors}";
        try { File.WriteAllText(Path.Combine(Store.BinFolder, "last-download.log"), log); } catch { }

        if (cancelled) { TryDeleteDir(outDir); throw new OperationCanceledException("Download cancelled."); }
        var file = Directory.GetFiles(outDir).FirstOrDefault();
        if (p.ExitCode == 0 && file is not null) return file;

        TryDeleteDir(outDir);
        var reason = errors.ToString().Split('\n').LastOrDefault(l => l.StartsWith("ERROR"))?.Replace("ERROR:", "").Trim()
                     ?? $"yt-dlp exited with code {p.ExitCode}.";
        throw new Exception($"Couldn't download that video.\n\n{reason}");
    }

    static void TryDeleteDir(string dir)
    {
        try { Directory.Delete(dir, recursive: true); } catch { }
    }
}
