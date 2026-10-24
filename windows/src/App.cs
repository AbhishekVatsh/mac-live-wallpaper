using System.Diagnostics;
using Microsoft.Win32;

namespace LiveWallpaper;

/// The running app: tray icon, window, and the wallpaper itself.
sealed class App : ApplicationContext
{
    public static readonly Icon AppIcon =
        new(typeof(App).Assembly.GetManifestResourceStream("app.ico")!);

    readonly DesktopHost host = new();
    readonly MainForm form;
    readonly NotifyIcon tray;
    readonly ToolStripMenuItem playItem, loginItem;

    /// Set by Exit and Uninstall. Closing the window only hides the app.
    public bool IsExiting { get; private set; }

    public App(string[] args)
    {
        form = new MainForm(this);
        _ = form.Handle;   // so it receives Explorer's TaskbarCreated message while hidden

        var menu = new ContextMenuStrip();
        menu.Items.Add("Choose Video…", null, (_, _) => form.ChooseVideo());
        menu.Items.Add("Open Live Wallpaper", null, (_, _) => ShowWindow());
        menu.Items.Add(new ToolStripSeparator());
        playItem = new ToolStripMenuItem("Pause", null, (_, _) => TogglePlayback());
        loginItem = new ToolStripMenuItem("Start at Login", null, (_, _) => ToggleStartAtLogin());
        menu.Items.Add(playItem);
        menu.Items.Add(loginItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Uninstall…", null, (_, _) => Uninstall());
        menu.Items.Add("Exit", null, (_, _) => Exit());
        menu.Opening += (_, _) =>
        {
            playItem.Text = host.IsPlaying ? "Pause" : "Play";
            playItem.Enabled = Store.CurrentVideo is not null;
            loginItem.Checked = StartAtLogin.IsEnabled;
        };

        tray = new NotifyIcon { Icon = AppIcon, Text = "Live Wallpaper", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };

        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;

        StartAtLogin.ApplyDefault();

        if (Store.CurrentVideo is { } video)
        {
            host.Load(video, Store.Settings.Paused);
        }
        else
        {
            ShowWindow();
        }

        // Hooks for scripted setup and testing:
        //   LiveWallpaper.exe --video <file>      sets a video file
        //   LiveWallpaper.exe --youtube <link>    downloads and sets a YouTube video
        if (ArgValue(args, "--video") is { } file) Apply(file);
        if (ArgValue(args, "--youtube") is { } link)
        {
            ShowWindow();
            form.SetLink(link);
            form.YouTubeClicked();
        }
    }

    static string? ArgValue(string[] args, string name)
    {
        var i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    public void ShowWindow()
    {
        form.RefreshState();
        form.Show();
        if (form.WindowState == FormWindowState.Minimized) form.WindowState = FormWindowState.Normal;
        form.Activate();
    }

    /// Imports a video file and makes it the wallpaper.
    public void Apply(string source, bool removeSourceFolderAfter = false)
    {
        form.SetDropText($"Importing {Path.GetFileName(source)}…");
        Task.Run(() =>
        {
            try
            {
                var imported = Store.ImportVideo(source);
                form.BeginInvoke(() =>
                {
                    Store.CurrentVideo = imported;
                    Store.Settings.Paused = false;
                    Store.Save();
                    host.Load(imported, startPaused: false);
                    form.SetDropText($"Now playing: {Path.GetFileName(source)}\n\nDrop a new video to replace it");
                    if (removeSourceFolderAfter) form.SetStatus($"Now playing: {Path.GetFileNameWithoutExtension(source)}");
                });
            }
            catch (Exception e)
            {
                form.BeginInvoke(() =>
                {
                    form.SetDropText("Drop a video here");
                    MessageBox.Show(e.Message, "Live Wallpaper", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                });
            }
            finally
            {
                if (removeSourceFolderAfter)
                    try { Directory.Delete(Path.GetDirectoryName(source)!, recursive: true); } catch { }
            }
        });
    }

    void TogglePlayback()
    {
        if (host.IsPlaying) host.Pause(); else host.Play();
        Store.Settings.Paused = !host.IsPlaying;
        Store.Save();
    }

    public void ToggleStartAtLogin()
    {
        try { StartAtLogin.Set(!StartAtLogin.IsEnabled); }
        catch (Exception e) { MessageBox.Show(e.Message, "Live Wallpaper", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
        form.RefreshState();
    }

    public void DesktopRecreated() => host.Rebuild();

    void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect) host.Suspend();
        if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.ConsoleConnect) host.Resume();
    }

    void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) host.Suspend();
        if (e.Mode == PowerModes.Resume) host.Resume();
    }

    void OnDisplaySettingsChanged(object? sender, EventArgs e) => form.BeginInvoke(host.Rebuild);

    /// Really quits. The app never changes the Windows wallpaper, so your own shows again.
    public void Exit()
    {
        if (IsExiting) return;
        IsExiting = true;
        host.Stop();
        Shutdown();
    }

    void Shutdown()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        tray.Visible = false;
        tray.Dispose();
        form.Close();
        ExitThread();
    }

    public void Uninstall()
    {
        ShowWindow();
        var answer = MessageBox.Show(form,
            "This stops the live wallpaper, removes it from startup apps, deletes your imported video, " +
            "and removes the app. Your own wallpaper stays as it is.",
            "Uninstall Live Wallpaper?", MessageBoxButtons.OKCancel, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
        if (answer != DialogResult.OK) return;

        IsExiting = true;
        host.Stop();
        try { StartAtLogin.Set(false); } catch { }

        Store.TryDelete(Store.StartMenuShortcut);
        try { Directory.Delete(Store.Folder, recursive: true); } catch { }

        // The running .exe can't delete itself, so a short-lived cmd removes the install folder after we exit.
        if (Store.IsInstalled)
        {
            Process.Start(new ProcessStartInfo("cmd.exe",
                $"/c timeout /t 2 /nobreak >nul & rmdir /s /q \"{Store.InstallFolder}\"")
                { UseShellExecute = false, CreateNoWindow = true });
        }
        Shutdown();
    }
}
