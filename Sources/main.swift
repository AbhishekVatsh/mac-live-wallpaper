import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

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
        // Remove previously imported videos and stills.
        if let old = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in old where file != dest { try? FileManager.default.removeItem(at: file) }
        }
        return dest
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
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player?.pause()
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
        windows.forEach { $0.orderOut(nil) }
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

/// Sets the regular macOS wallpaper to the video's first frame so the lock screen,
/// Mission Control and the moment the app quits all match the live wallpaper.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "Mac Live Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        enableStartAtLoginByDefault()

        if let video = Store.currentVideo {
            wallpaper.load(video)
        } else {
            showWindow()
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
        menu.addItem(withTitle: "Stop Running", action: #selector(stopRunning), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
    }

    @objc func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 350),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Mac Live Wallpaper"
            w.isReleasedWhenClosed = false
            w.center()

            let drop = DropView(frame: .zero)
            drop.onDrop = { [weak self] url in self?.apply(url) }
            drop.translatesAutoresizingMaskIntoConstraints = false

            let button = NSButton(title: "Choose Video…", target: self, action: #selector(chooseVideo))
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"
            button.translatesAutoresizingMaskIntoConstraints = false

            let hint = NSTextField(wrappingLabelWithString: "The video loops silently behind your desktop icons. Use the menu bar icon to pause it.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.alignment = .center
            hint.translatesAutoresizingMaskIntoConstraints = false

            let stop = NSButton(title: "Stop Running", target: self, action: #selector(stopRunning))
            let remove = NSButton(title: "Uninstall…", target: self, action: #selector(uninstall))
            let actions = NSStackView(views: [stop, remove])
            actions.spacing = 12
            actions.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView()
            [drop, button, hint, actions].forEach(content.addSubview)
            NSLayoutConstraint.activate([
                drop.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                drop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                drop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                drop.heightAnchor.constraint(equalToConstant: 160),
                button.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 16),
                button.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                hint.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 12),
                hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
                hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
                actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                actions.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            ])
            w.contentView = content
            window = w
            dropView = drop
        }
        if let video = Store.currentVideo {
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

    private func apply(_ source: URL) {
        dropView?.setText("Importing \(source.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let imported = try Store.importVideo(from: source)
                DispatchQueue.main.async {
                    Store.currentVideo = imported
                    Store.paused = false
                    self.wallpaper.load(imported)
                    setStillWallpaper(from: imported)
                    self.dropView?.setText("Now playing: \(source.lastPathComponent)\n\nDrop a new video to replace it")
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

    @objc func stopRunning() {
        NSApp.terminate(nil)
    }

    @objc func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let confirm = NSAlert()
        confirm.messageText = "Uninstall Mac Live Wallpaper?"
        confirm.informativeText = "This stops the live wallpaper, removes it from login items, deletes your imported video, and moves the app to the Bin. Your desktop keeps the video's still frame."
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        confirm.buttons[0].hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        wallpaper.pause()
        try? SMAppService.mainApp.unregister()

        // Keep the still frame as the desktop picture, since its folder is about to be removed.
        let fm = FileManager.default
        if let still = (try? fm.contentsOfDirectory(at: Store.folder, includingPropertiesForKeys: nil))?
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
