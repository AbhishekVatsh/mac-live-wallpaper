import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Storage

enum Store {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LiveWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var currentVideo: URL? {
        get {
            guard let name = UserDefaults.standard.string(forKey: "videoFile") else { return nil }
            let url = folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        set { UserDefaults.standard.set(newValue?.lastPathComponent, forKey: "videoFile") }
    }

    static var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "paused") }
        set { UserDefaults.standard.set(newValue, forKey: "paused") }
    }

    /// Copies the chosen video into Application Support so the wallpaper keeps
    /// working even if the original file is moved or deleted.
    static func importVideo(from source: URL) throws -> URL {
        let dest = folder.appendingPathComponent("wallpaper-\(Int(Date().timeIntervalSince1970)).\(source.pathExtension)")
        try FileManager.default.copyItem(at: source, to: dest)
        // Remove previously imported videos and stills (but not the tools folder).
        if let old = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in old where file != dest && !file.hasDirectoryPath { try? FileManager.default.removeItem(at: file) }
        }
        return dest
    }
}

// MARK: - YouTube links

/// Downloads YouTube videos with yt-dlp, which the app fetches from its official
/// GitHub release the first time it's needed and keeps up to date.
final class YouTubeDownloader {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    private static let toolURL = Store.folder.appendingPathComponent("bin/yt-dlp")
    private static let releaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
    /// YouTube only offers 4K as AV1 or VP9, and macOS can't play VP9. Macs with an AV1
    /// decoder (M3 and newer) get up to 4K; older Macs get H.264 up to 1080p.
    static let supports4K = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    // Video only (wallpapers are silent). Highest resolution first, AV1 preferred at equal resolution.
    private static var formatArgs: [String] {
        supports4K
            ? ["-f", "bv*[vcodec~='^(av01|avc1)'][height<=2160][protocol^=http]/bv*[vcodec~='^(av01|avc1)'][height<=2160]/b[ext=mp4]",
               "-S", "res,vcodec:av01"]
            : ["-f", "bv*[vcodec^=avc1][height<=1080][protocol^=http]/bv*[vcodec^=avc1][height<=1080]/b[ext=mp4]"]
    }

    private var process: Process?

    static func isYouTubeLink(_ text: String) -> Bool {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespaces))?.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// Calls `progress` with status text on the main queue, then `completion` with the downloaded file.
    func download(_ link: String, progress: @escaping (String) -> Void,
                  completion: @escaping (Result<URL, Error>) -> Void) {
        let finish = { (result: Result<URL, Error>) in DispatchQueue.main.async { completion(result) } }
        let report = { (text: String) in DispatchQueue.main.async { progress(text) } }

        prepareTool(report: report) { [weak self] error in
            if let error { return finish(.failure(error)) }
            self?.run(link, report: report, finish: finish)
        }
    }

    func cancel() { process?.terminate() }

    private func prepareTool(report: @escaping (String) -> Void, then: @escaping (Error?) -> Void) {
        let fm = FileManager.default
        let tool = Self.toolURL
        if fm.fileExists(atPath: tool.path) {
            // YouTube changes often, so refresh yt-dlp if it's more than a few days old.
            let modified = (try? fm.attributesOfItem(atPath: tool.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(modified) > 3 * 24 * 3600 {
                report("Updating the YouTube downloader…")
                DispatchQueue.global(qos: .userInitiated).async {
                    let update = Process()
                    update.executableURL = tool
                    update.arguments = ["--update"]
                    update.standardOutput = FileHandle.nullDevice
                    update.standardError = FileHandle.nullDevice
                    try? update.run()
                    update.waitUntilExit()
                    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: tool.path)
                    then(nil)
                }
            } else {
                then(nil)
            }
            return
        }

        report("Getting the YouTube downloader (one time, about 35 MB)…")
        URLSession.shared.downloadTask(with: Self.releaseURL) { temp, response, error in
            guard let temp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return then(Failure.message("Couldn't download the YouTube downloader. Check your internet connection and try again.\n\(error?.localizedDescription ?? "")"))
            }
            do {
                try fm.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: tool)
                try fm.moveItem(at: temp, to: tool)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
                then(nil)
            } catch {
                then(error)
            }
        }.resume()
    }

    private func run(_ link: String, report: @escaping (String) -> Void, finish: @escaping (Result<URL, Error>) -> Void) {
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveWallpaper-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = Self.toolURL
        p.arguments = [
            "--no-config", "--no-playlist", "--no-part", "--newline",
        ] + Self.formatArgs + [
            "-o", outDir.appendingPathComponent("%(title).80B.%(ext)s").path,
            "--progress-template", "download:PROGRESS %(progress._percent_str)s",
            link.trimmingCharacters(in: .whitespaces),
        ]
        // Let yt-dlp find a JavaScript runtime such as Homebrew's deno, if one is installed.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var buffer = ""
        out.fileHandleForReading.readabilityHandler = { handle in
            buffer += String(decoding: handle.availableData, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespaces)
                buffer.removeSubrange(...newline)
                if line.hasPrefix("PROGRESS ") {
                    report("Downloading… \(line.dropFirst(9).trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        let errors = NSMutableString()
        err.fileHandleForReading.readabilityHandler = { handle in
            errors.append(String(decoding: handle.availableData, as: UTF8.self))
        }

        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            errors.append(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            // Keep yt-dlp's messages from the last download for troubleshooting.
            let log = "\(Date())\n\(link)\nexit \(proc.terminationStatus) (\(proc.terminationReason == .exit ? "exit" : "signal"))\n\n\(errors)"
            try? log.write(to: Self.toolURL.deletingLastPathComponent().appendingPathComponent("last-download.log"),
                           atomically: true, encoding: .utf8)
            self?.process = nil
            if proc.terminationReason == .uncaughtSignal {
                try? FileManager.default.removeItem(at: outDir)
                return finish(.failure(Failure.message("Download cancelled.")))
            }
            let file = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil))?.first
            if proc.terminationStatus == 0, let file {
                finish(.success(file))
            } else {
                try? FileManager.default.removeItem(at: outDir)
                let reason = (errors as String).split(separator: "\n").last { $0.hasPrefix("ERROR") }
                    .map { String($0.dropFirst("ERROR: ".count)) } ?? "yt-dlp exited with code \(proc.terminationStatus)."
                finish(.failure(Failure.message("Couldn't download that video.\n\n\(reason)")))
            }
        }

        do {
            report("Starting download…")
            try p.run()
            process = p
        } catch {
            try? FileManager.default.removeItem(at: outDir)
            finish(.failure(error))
        }
    }
}

// MARK: - Desktop video windows

final class WallpaperController {
    private var windows: [NSWindow] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var isPlaying = false

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemWake), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(systemWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(systemSleep), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(systemWake), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    func load(_ url: URL) {
        // Fully stop the previous video so only the current one ever plays.
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        looper = nil

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        rebuildWindows()
        if !Store.paused { play() }
    }

    func play() {
        player?.play()
        isPlaying = player != nil
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    @objc private func systemSleep() { player?.pause() }
    @objc private func systemWake() { if !Store.paused { player?.play() } }
    @objc private func screensChanged() { rebuildWindows() }

    private func rebuildWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()
        guard let player else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            // Sit on the desktop layer: above the system wallpaper, below desktop icons and all apps.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false

            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            window.contentView = view

            window.orderBack(nil)
            windows.append(window)
        }
    }
}

// MARK: - Still frame for the system wallpaper

/// Remembers each display's own wallpaper before the app replaces it, so Exit and
/// Uninstall can put it back.
enum PreviousWallpaper {
    private static let key = "previousDesktopPictures"
    private static let fillScreen: [NSWorkspace.DesktopImageOptionKey: Any] =
        [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]

    private static func id(of screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
    }

    private static var saved: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var isKnown: Bool { !saved.isEmpty }

    /// Records the current wallpaper of every display that isn't already showing our still frame.
    static func remember() {
        var paths = saved
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !url.path.hasPrefix(Store.folder.path) else { continue }
            paths[id(of: screen)] = url.path
        }
        saved = paths
    }

    /// Puts back the remembered wallpapers. Returns false when there's nothing to restore.
    @discardableResult
    static func restore() -> Bool {
        let paths = saved
        guard let fallback = paths.values.first else { return false }
        for screen in NSScreen.screens {
            let path = paths[id(of: screen)] ?? fallback
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: fillScreen)
        }
        return true
    }
}

/// Sets the regular macOS wallpaper to the video's first frame so the lock screen
/// and Mission Control match the live wallpaper.
func setStillWallpaper(from video: URL) {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.generateCGImageAsynchronously(for: .zero) { cgImage, _, _ in
        guard let cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let still = video.deletingPathExtension().appendingPathExtension("png")
        try? data.write(to: still)
        DispatchQueue.main.async {
            PreviousWallpaper.remember()
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(still, for: screen,
                    options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true])
            }
        }
    }
}

// MARK: - Drop zone window

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        label.alignment = .center
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        setText("Drop a video here")
    }
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ text: String) { label.stringValue = text }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        if highlighted { NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); path.fill() }
        path.stroke()
    }

    private func videoURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.movie.identifier],
        ]
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard videoURL(from: sender) != nil else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let url = videoURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let wallpaper = WallpaperController()
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var dropView: DropView?
    private var linkField: NSTextField?
    private var youTubeButton: NSButton?
    private var youTubeStatus: NSTextField?
    private var youTube: YouTubeDownloader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Mac Live Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        NSApp.mainMenu = makeMainMenu()

        enableStartAtLoginByDefault()

        if let video = Store.currentVideo {
            wallpaper.load(video)
            // Exit restored the previous wallpaper, so put the still frame back.
            setStillWallpaper(from: video)
        } else {
            showWindow()
        }

        // `open -a "Mac Live Wallpaper" --args --youtube <link>` sets a YouTube video without clicking.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--youtube"), i + 1 < args.count {
            showWindow()
            linkField?.stringValue = args[i + 1]
            youTubeButtonClicked()
        }
    }

    /// Turns on Start at Login the first time the app runs from an Applications folder
    /// (not from the DMG or a build folder). After that, the menu toggle is respected.
    private func enableStartAtLoginByDefault() {
        let key = "startAtLoginDefaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let path = Bundle.main.bundlePath
        let userApps = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0].path
        guard path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/") else { return }
        if SMAppService.mainApp.status == .enabled || (try? SMAppService.mainApp.register()) != nil {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    /// The app menu bar. The Edit menu is what makes ⌘X, ⌘C, ⌘V and ⌘A work in the link box.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mac Live Wallpaper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Choose Video…", action: #selector(chooseVideo), keyEquivalent: "o").target = self
        appMenu.addItem(withTitle: "Uninstall…", action: #selector(uninstall), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mac Live Wallpaper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Exit Mac Live Wallpaper", action: #selector(exit), keyEquivalent: "q").target = self
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        return main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // Rebuild the menu each time it opens so titles reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Choose Video…", action: #selector(chooseVideo), keyEquivalent: "o")
        menu.addItem(withTitle: "Open Mac Live Wallpaper Window", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: wallpaper.isPlaying ? "Pause" : "Play", action: #selector(togglePlayback), keyEquivalent: "p")
        toggle.isEnabled = Store.currentVideo != nil
        let login = menu.addItem(withTitle: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall…", action: #selector(uninstall), keyEquivalent: "")
        menu.addItem(withTitle: "Exit", action: #selector(exit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
    }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Mac Live Wallpaper"
            w.isReleasedWhenClosed = false
            w.center()

            let drop = DropView(frame: .zero)
            drop.onDrop = { [weak self] url in self?.apply(url) }
            drop.translatesAutoresizingMaskIntoConstraints = false

            let button = NSButton(title: "Choose Video…", target: self, action: #selector(chooseVideo))
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false

            let youTubeTitle = NSTextField(labelWithString: "Or paste a YouTube link")
            youTubeTitle.font = .boldSystemFont(ofSize: 13)
            youTubeTitle.translatesAutoresizingMaskIntoConstraints = false

            let field = NSTextField()
            field.placeholderString = "https://www.youtube.com/watch?v=…"
            field.target = self
            field.action = #selector(youTubeButtonClicked)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let setButton = NSButton(title: "Set as Wallpaper", target: self, action: #selector(youTubeButtonClicked))
            setButton.bezelStyle = .rounded
            setButton.setContentHuggingPriority(.required, for: .horizontal)

            let pasteButton = NSButton(title: "Paste", target: self, action: #selector(pasteLink))
            pasteButton.bezelStyle = .rounded
            pasteButton.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView(views: [field, pasteButton, setButton])
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false

            let status = NSTextField(wrappingLabelWithString: YouTubeDownloader.supports4K
                ? "Downloads the video in up to 4K, without sound."
                : "Downloads the video in up to 1080p, without sound. 4K needs a Mac with an M3 chip or newer.")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            status.translatesAutoresizingMaskIntoConstraints = false

            let hint = NSTextField(wrappingLabelWithString: "The video loops silently behind your desktop icons. Use the menu bar icon to pause it.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.alignment = .center
            hint.translatesAutoresizingMaskIntoConstraints = false

            let exit = NSButton(title: "Exit", target: self, action: #selector(exit))
            let remove = NSButton(title: "Uninstall…", target: self, action: #selector(uninstall))
            let actions = NSStackView(views: [exit, remove])
            actions.spacing = 12
            actions.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView()
            [drop, button, youTubeTitle, row, status, hint, actions].forEach(content.addSubview)
            NSLayoutConstraint.activate([
                drop.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                drop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                drop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                drop.heightAnchor.constraint(equalToConstant: 150),
                button.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 14),
                button.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                youTubeTitle.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 26),
                youTubeTitle.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
                row.topAnchor.constraint(equalTo: youTubeTitle.bottomAnchor, constant: 8),
                row.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
                status.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 6),
                status.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
                status.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
                hint.topAnchor.constraint(greaterThanOrEqualTo: status.bottomAnchor, constant: 20),
                hint.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -14),
                hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
                hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
                actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                actions.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            ])
            w.contentView = content
            window = w
            dropView = drop
            linkField = field
            youTubeButton = setButton
            youTubeStatus = status
        }
        if let video = Store.currentVideo, youTube == nil {
            dropView?.setText("Current: \(video.lastPathComponent)\n\nDrop a new video to replace it")
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to use as your live wallpaper"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { apply(url) }
    }

    @objc func pasteLink() {
        guard youTube == nil, let text = NSPasteboard.general.string(forType: .string) else { return }
        linkField?.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        youTubeStatus?.textColor = .secondaryLabelColor
        youTubeStatus?.stringValue = YouTubeDownloader.isYouTubeLink(linkField?.stringValue ?? "")
            ? "Click Set as Wallpaper to download it."
            : "That isn't a YouTube link. Copy one from YouTube and try again."
    }

    @objc func youTubeButtonClicked() {
        // While a download runs, the button reads Cancel.
        if let youTube { youTube.cancel(); return }

        let link = linkField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        guard YouTubeDownloader.isYouTubeLink(link) else {
            youTubeStatus?.stringValue = "Paste a YouTube link, like https://www.youtube.com/watch?v=…"
            youTubeStatus?.textColor = .systemRed
            return
        }

        let downloader = YouTubeDownloader()
        youTube = downloader
        youTubeButton?.title = "Cancel"
        linkField?.isEnabled = false
        youTubeStatus?.textColor = .secondaryLabelColor

        downloader.download(link, progress: { [weak self] text in
            self?.youTubeStatus?.stringValue = text
        }, completion: { [weak self] result in
            guard let self else { return }
            self.youTube = nil
            self.youTubeButton?.title = "Set as Wallpaper"
            self.linkField?.isEnabled = true
            switch result {
            case .success(let file):
                self.youTubeStatus?.stringValue = "Downloaded. Setting it as your wallpaper…"
                self.apply(file, removeSourceAfter: true)
                self.linkField?.stringValue = ""
            case .failure(let error):
                self.youTubeStatus?.stringValue = error.localizedDescription
                self.youTubeStatus?.textColor = .systemRed
            }
        })
    }

    private func apply(_ source: URL, removeSourceAfter: Bool = false) {
        dropView?.setText("Importing \(source.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if removeSourceAfter { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) } }
            do {
                let imported = try Store.importVideo(from: source)
                DispatchQueue.main.async {
                    Store.currentVideo = imported
                    Store.paused = false
                    self.wallpaper.load(imported)
                    setStillWallpaper(from: imported)
                    self.dropView?.setText("Now playing: \(source.lastPathComponent)\n\nDrop a new video to replace it")
                    if removeSourceAfter { self.youTubeStatus?.stringValue = "Now playing: \(source.deletingPathExtension().lastPathComponent)" }
                }
            } catch {
                DispatchQueue.main.async {
                    self.dropView?.setText("Drop a video here")
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc func togglePlayback() {
        if wallpaper.isPlaying { wallpaper.pause(); Store.paused = true }
        else { wallpaper.play(); Store.paused = false }
    }

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText = "Move Mac Live Wallpaper to your Applications folder and try again."
            alert.runModal()
        }
    }

    @objc func exit() {
        NSApp.terminate(nil)
    }

    /// However the app quits (Exit, ⌘Q, logout), put back the wallpaper the user had before.
    func applicationWillTerminate(_ notification: Notification) {
        wallpaper.pause()
        PreviousWallpaper.restore()
    }

    @objc func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Uninstall Mac Live Wallpaper?"
        confirm.informativeText = "This stops the live wallpaper, puts back your previous wallpaper, removes it from login items, deletes your imported video, and moves the app to the Bin."
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        confirm.buttons[0].hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        wallpaper.pause()
        try? SMAppService.mainApp.unregister()

        // Put back the previous wallpaper. If it was never recorded, keep the still frame
        // as the desktop picture, since its folder is about to be removed.
        let fm = FileManager.default
        if !PreviousWallpaper.restore(),
           let still = (try? fm.contentsOfDirectory(at: Store.folder, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "png" }) {
            let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            let kept = pictures.appendingPathComponent("Mac Live Wallpaper.png")
            try? fm.removeItem(at: kept)
            if (try? fm.copyItem(at: still, to: kept)) != nil {
                for screen in NSScreen.screens {
                    try? NSWorkspace.shared.setDesktopImageURL(kept, for: screen,
                        options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
                }
            }
        }

        try? fm.removeItem(at: Store.folder)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }

        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// Only one copy may run, or two different videos could play at once. A newly opened
// copy (say, from the DMG or a newer install) takes over from any copy already running.
let me = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != me }
others.forEach { $0.terminate() }
let deadline = Date().addingTimeInterval(5)
while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
