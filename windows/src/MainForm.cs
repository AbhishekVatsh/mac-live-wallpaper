using System.Drawing.Drawing2D;

namespace LiveWallpaper;

/// The app window: drop or choose a video, paste a YouTube link, Start at Login, Exit, Uninstall.
sealed class MainForm : Form
{
    static readonly string[] VideoExtensions = { ".mp4", ".mov", ".m4v", ".mkv", ".webm", ".avi", ".wmv" };
    static readonly uint TaskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");

    readonly App app;
    readonly DropZone drop = new();
    readonly TextBox linkBox = new();
    readonly Button setButton = new();
    readonly Label youTubeStatus = new();
    readonly CheckBox loginBox = new();

    public MainForm(App app)
    {
        this.app = app;
        Text = "Live Wallpaper";
        Icon = App.AppIcon;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(460, 540);
        Font = new Font("Segoe UI", 9.5f);
        AllowDrop = true;

        drop.SetBounds(20, 20, 420, 150);
        drop.Text = "Drop a video here";

        var choose = new Button { Text = "Choose Video…", AutoSize = true, Padding = new Padding(8, 2, 8, 2) };
        choose.Click += (_, _) => ChooseVideo();
        choose.Location = new Point((ClientSize.Width - 130) / 2, 184);
        choose.Width = 130;

        var youTubeTitle = new Label { Text = "Or paste a YouTube link", AutoSize = true, Location = new Point(20, 238),
                                       Font = new Font(Font, FontStyle.Bold) };

        linkBox.SetBounds(20, 264, 236, 28);
        linkBox.PlaceholderText = "https://www.youtube.com/watch?v=…";
        linkBox.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; YouTubeClicked(); } };

        var paste = new Button { Text = "Paste" };
        paste.SetBounds(262, 263, 64, 28);
        paste.Click += (_, _) => PasteLink();

        setButton.Text = "Set as Wallpaper";
        setButton.SetBounds(332, 263, 108, 28);
        setButton.Click += (_, _) => YouTubeClicked();

        youTubeStatus.SetBounds(20, 298, 420, 40);
        youTubeStatus.ForeColor = SystemColors.GrayText;
        youTubeStatus.Text = "Downloads the video in up to 4K, without sound.";

        var hint = new Label
        {
            Text = "The video loops silently behind your desktop icons, even after you close this window. " +
                   "Use the tray icon to pause it, or Exit to stop it.",
            ForeColor = SystemColors.GrayText, TextAlign = ContentAlignment.MiddleCenter,
        };
        hint.SetBounds(30, 380, 400, 44);

        loginBox.Text = "Start at Login";
        loginBox.AutoSize = true;
        loginBox.Location = new Point((ClientSize.Width - 110) / 2, 436);
        loginBox.Click += (_, _) => app.ToggleStartAtLogin();

        var exit = new Button { Text = "Exit" };
        exit.SetBounds(130, 476, 90, 30);
        exit.Click += (_, _) => app.Exit();

        var uninstall = new Button { Text = "Uninstall…" };
        uninstall.SetBounds(232, 476, 100, 30);
        uninstall.Click += (_, _) => app.Uninstall();

        Controls.AddRange(new Control[] { drop, choose, youTubeTitle, linkBox, paste, setButton, youTubeStatus, hint, loginBox, exit, uninstall });

        // Accept drops anywhere in the window, including on the drop zone itself.
        drop.AllowDrop = true;
        foreach (var target in new Control[] { this, drop })
        {
            target.DragEnter += (_, e) =>
            {
                var ok = DroppedVideo(e) is not null;
                e.Effect = ok ? DragDropEffects.Copy : DragDropEffects.None;
                drop.Highlighted = ok;
            };
            target.DragLeave += (_, _) => drop.Highlighted = false;
            target.DragDrop += (_, e) =>
            {
                drop.Highlighted = false;
                if (DroppedVideo(e) is { } file) app.Apply(file);
            };
        }
    }

    static string? DroppedVideo(DragEventArgs e) =>
        (e.Data?.GetData(DataFormats.FileDrop) as string[])?.FirstOrDefault(f =>
            VideoExtensions.Contains(Path.GetExtension(f).ToLowerInvariant()));

    public bool Downloading { get; private set; }

    public void SetDropText(string text) => drop.Text = text;

    public void RefreshState()
    {
        loginBox.Checked = StartAtLogin.IsEnabled;
        if (!Downloading && Store.CurrentVideo is { } video)
            drop.Text = $"Current: {Path.GetFileName(video)}\n\nDrop a new video to replace it";
    }

    public void ChooseVideo()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "Choose a video to use as your live wallpaper",
            Filter = "Videos|" + string.Join(";", VideoExtensions.Select(x => "*" + x)) + "|All files|*.*",
        };
        if (dialog.ShowDialog(Visible ? this : null) == DialogResult.OK) app.Apply(dialog.FileName);
    }

    void PasteLink()
    {
        if (Downloading || !Clipboard.ContainsText()) return;
        linkBox.Text = Clipboard.GetText().Trim();
        SetStatus(YouTubeDownloader.IsYouTubeLink(linkBox.Text)
            ? "Click Set as Wallpaper to download it."
            : "That isn't a YouTube link. Copy one from YouTube and try again.", error: !YouTubeDownloader.IsYouTubeLink(linkBox.Text));
    }

    YouTubeDownloader? downloader;

    /// Starts a download, or cancels the one in progress (the button reads Cancel meanwhile).
    public async void YouTubeClicked()
    {
        if (downloader is not null) { downloader.Cancel(); return; }

        var link = linkBox.Text.Trim();
        if (!YouTubeDownloader.IsYouTubeLink(link))
        {
            SetStatus("Paste a YouTube link, like https://www.youtube.com/watch?v=…", error: true);
            return;
        }

        downloader = new YouTubeDownloader();
        Downloading = true;
        setButton.Text = "Cancel";
        linkBox.Enabled = false;
        SetStatus("Starting…");
        try
        {
            var file = await downloader.DownloadAsync(link, new Progress<string>(text => SetStatus(text)));
            SetStatus("Downloaded. Setting it as your wallpaper…");
            linkBox.Text = "";
            app.Apply(file, removeSourceFolderAfter: true);
        }
        catch (Exception e)
        {
            SetStatus(e.Message, error: true);
        }
        finally
        {
            downloader = null;
            Downloading = false;
            setButton.Text = "Set as Wallpaper";
            linkBox.Enabled = true;
        }
    }

    public void SetLink(string link) => linkBox.Text = link;

    public void SetStatus(string text, bool error = false)
    {
        youTubeStatus.Text = text;
        youTubeStatus.ForeColor = error ? Color.Firebrick : SystemColors.GrayText;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // Closing the window (or "Close window" on the taskbar) keeps the wallpaper playing.
        if (e.CloseReason == CloseReason.UserClosing && !app.IsExiting)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnFormClosing(e);
    }

    protected override void WndProc(ref Message m)
    {
        // Explorer restarted: the desktop windows were recreated, so put the video back.
        if (m.Msg == TaskbarCreated) app.DesktopRecreated();
        base.WndProc(ref m);
    }

    /// The dashed drop target.
    sealed class DropZone : Control
    {
        bool highlighted;
        public bool Highlighted { get => highlighted; set { highlighted = value; Invalidate(); } }

        public DropZone()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                     ControlStyles.UserPaint, true);
        }

        protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Parent?.BackColor ?? SystemColors.Control);
            var rect = new Rectangle(2, 2, Width - 5, Height - 5);
            using var path = Rounded(rect, 12);
            if (highlighted) { using var fill = new SolidBrush(Color.FromArgb(24, SystemColors.Highlight)); g.FillPath(fill, path); }
            using var pen = new Pen(highlighted ? SystemColors.Highlight : SystemColors.GrayText, 2) { DashPattern = new[] { 4f, 3f } };
            g.DrawPath(pen, path);
            TextRenderer.DrawText(g, Text, Font, rect, SystemColors.GrayText,
                                  TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
        }

        static GraphicsPath Rounded(Rectangle r, int radius)
        {
            var path = new GraphicsPath();
            var d = radius * 2;
            path.AddArc(r.X, r.Y, d, d, 180, 90);
            path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }
    }
}
