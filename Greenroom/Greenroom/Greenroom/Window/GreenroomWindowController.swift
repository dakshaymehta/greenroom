import AppKit
import WebKit

/// Controls the main Greenroom sidebar window that hosts the HTML/CSS/JS UI.
///
/// We use NSWindow + WKWebView directly rather than SwiftUI because:
/// 1. We need precise control over window chrome and transparency.
/// 2. The sidebar UI is already built as a standalone web app.
/// 3. WKWebView interop is simpler at the AppKit layer.
@MainActor
final class GreenroomWindowController: NSWindowController {

    // MARK: - Constants

    private static let compactWindowWidth: CGFloat = 356
    private static let expandedWindowWidth: CGFloat = 820
    private static let expandedWidthThreshold: CGFloat = 680
    private static let windowHeight: CGFloat = 720
    private static let minimumWindowWidth: CGFloat = 320
    private static let minimumWindowHeight: CGFloat = 400
    private static let windowTitle = "Greenroom"
    private static let windowAutosaveName = "GreenroomMainWindow"

    // MARK: - Properties

    private let coordinator: GreenroomCoordinator
    private let settingsPanel = GreenroomSettingsPanel()
    private let transcriptPanel: GreenroomTranscriptPanel

    // MARK: - Initializer

    /// Creates the controller with a coordinator that manages the audio/AI pipeline.
    /// Call `showWindow(_:)` to display the window.
    init(coordinator: GreenroomCoordinator) {
        self.coordinator = coordinator
        self.transcriptPanel = GreenroomTranscriptPanel(
            transcriptContextStore: coordinator.engine.transcriptContextStore
        )
        // NSWindowController's designated initializer requires a window or nib name.
        // We build the window programmatically, so we call super.init(window:) with nil
        // and assign the window ourselves in buildWindowIfNeeded().
        super.init(window: nil)

        settingsPanel.onClose = { [weak self] in
            guard let self else { return }
            Task {
                await self.coordinator.refreshListeningConfiguration()
            }
        }
        settingsPanel.onSoundSettingsChanged = { [weak self] muted, volume in
            self?.coordinator.engine.updateSoundEffectsMuted(muted)
            self?.coordinator.engine.updateSoundEffectsVolume(volume)
        }
        settingsPanel.onFloatOnTopChanged = { [weak self] shouldFloatOnTop in
            self?.updateWindowLevel(isFloating: shouldFloatOnTop)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("GreenroomWindowController must be created programmatically, not from a nib.")
    }

    // MARK: - NSWindowController overrides

    /// Creates the window lazily on first call, then brings it to the front.
    override func showWindow(_ sender: Any?) {
        if window == nil {
            buildWindowIfNeeded()
        }

        window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Private window construction

    private func buildWindowIfNeeded() {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: Self.compactWindowWidth,
            height: Self.windowHeight
        )

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]

        let mainWindow = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        mainWindow.title = Self.windowTitle
        mainWindow.minSize = NSSize(
            width: Self.minimumWindowWidth,
            height: Self.minimumWindowHeight
        )
        mainWindow.isRestorable = false

        // Persists window position across launches. On the very first launch,
        // cascadeTopLeft produces a default position; we override with center()
        // so the window appears in a predictable place.
        let didRestorePosition = mainWindow.setFrameAutosaveName(Self.windowAutosaveName)
        if !didRestorePosition {
            mainWindow.center()
        }

        let webView = buildWebView()
        mainWindow.contentView = webView

        // Wire the bridge between the coordinator's engine and the sidebar JS.
        let bridge = WebViewBridge()
        bridge.attach(to: webView)
        coordinator.engine.bridge = bridge
        transcriptPanel.onVisibilityChanged = { [weak bridge] isVisible in
            bridge?.setTranscriptWindowVisible(isVisible)
        }

        // Handle actions from the sidebar UI (mute, pause, settings).
        bridge.onSidebarAction = { [weak self] action in
            guard let self else { return }
            switch action.action {
            case "toggleFredMute":
                let isMuted = action.muted ?? false
                UserDefaults.standard.set(isMuted, forKey: "fredSFXMuted")
                self.coordinator.engine.updateSoundEffectsMuted(isMuted)
            case "togglePause":
                self.coordinator.engine.isPaused = action.paused ?? !self.coordinator.engine.isPaused
            case "openSettings":
                self.settingsPanel.show()
            case "openTranscriptViewer":
                self.transcriptPanel.toggle()
            case "toggleWorkspaceMode":
                self.toggleWorkspaceMode()
            case "openSource":
                guard let rawURL = action.url,
                      let sourceURL = URL(string: rawURL) else {
                    return
                }
                NSWorkspace.shared.open(sourceURL)
            default:
                break
            }
        }

        loadSidebarHTML(into: webView)
        bridge.setTranscriptWindowVisible(transcriptPanel.isVisible)

        self.window = mainWindow
        applyPersistedWindowAndSoundSettings()

        // On first launch, open settings so the user can configure their Worker URL.
        let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if !hasLaunchedBefore {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            settingsPanel.show()
        }

        // Auto-start listening if a Worker URL is already configured.
        let workerBaseURL = WorkerURLNormalizer.normalize(
            UserDefaults.standard.string(forKey: "workerBaseURL")
        )
        if !workerBaseURL.isEmpty {
            Task {
                await coordinator.startListening()
            }
        }
    }

    private func buildWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Allow the sidebar to make fetch() calls to the local worker process.
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: configuration)

        // Make the WebView background transparent so the window chrome shows through
        // any areas the HTML intentionally leaves uncolored.
        webView.setValue(false, forKey: "drawsBackground")

        return webView
    }

    /// Attempts to locate sidebar/index.html and load it into the web view.
    ///
    /// Search order:
    /// 1. App bundle "sidebar" subdirectory — used in production/release builds.
    /// 2. The sidebar directory inside the Swift source tree — used during Xcode
    ///    debug runs where the bundle may not yet contain the sidebar assets.
    private func loadSidebarHTML(into webView: WKWebView) {
        if let bundleURL = locateSidebarURLInBundle() {
            print("[GreenroomWindowController] Loading sidebar from bundle: \(bundleURL.path)")
            webView.loadFileURL(bundleURL, allowingReadAccessTo: bundleURL.deletingLastPathComponent())
            return
        }

        if let developmentURL = locateSidebarURLRelativeToSourceFile() {
            print("[GreenroomWindowController] Loading sidebar from dev path: \(developmentURL.path)")
            webView.loadFileURL(developmentURL, allowingReadAccessTo: developmentURL.deletingLastPathComponent())
            return
        }

        print("[GreenroomWindowController] ERROR: Could not locate sidebar/index.html")

        // Neither path worked — load a diagnostic page so the window isn't blank.
        let fallbackHTML = """
        <html><body style="font-family:system-ui;color:white;background:#1a1a1a;padding:40px">
        <h2>Greenroom</h2>
        <p>Could not locate sidebar/index.html.<br>
        Verify the bundled resources or the in-tree sidebar source files are present.</p>
        </body></html>
        """
        webView.loadHTMLString(fallbackHTML, baseURL: nil)
    }

    /// Looks for index.html inside the main app bundle.
    ///
    /// When the sidebar/ folder is added to Xcode as a folder reference (blue folder),
    /// files land at Resources/sidebar/index.html. When added as a group (yellow folder),
    /// files land flat at Resources/index.html. We check both locations.
    private func locateSidebarURLInBundle() -> URL? {
        guard let bundleResourceURL = Bundle.main.resourceURL else {
            return nil
        }

        // Check for folder reference structure first (sidebar/ subdirectory)
        let folderReferenceURL = bundleResourceURL
            .appendingPathComponent("sidebar")
            .appendingPathComponent("index.html")

        if FileManager.default.fileExists(atPath: folderReferenceURL.path) {
            return folderReferenceURL
        }

        // Fall back to flat structure (files directly in Resources/)
        let flatURL = bundleResourceURL.appendingPathComponent("index.html")

        if FileManager.default.fileExists(atPath: flatURL.path) {
            return flatURL
        }

        return nil
    }

    /// Walks up from this Swift source file's compile-time path to find the
    /// source root, then resolves sidebar/index.html from there.
    ///
    /// This covers the common Xcode workflow where you run the app directly
    /// from the scheme without packaging sidebar assets into the bundle first.
    private func locateSidebarURLRelativeToSourceFile() -> URL? {
        // #file expands to the absolute path of this source file at compile time:
        // …/greenroom/Greenroom/Greenroom/Greenroom/Window/GreenroomWindowController.swift
        // We need to walk up 2 levels to reach the app source root:
        // GreenroomWindowController.swift → Window/ → Greenroom (source root)
        let sourceFileURL = URL(fileURLWithPath: #file)

        let sourceRootURL = sourceFileURL
            .deletingLastPathComponent() // → Window/
            .deletingLastPathComponent() // → Greenroom (source)

        let candidateURL = sourceRootURL
            .appendingPathComponent("sidebar")
            .appendingPathComponent("index.html")

        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return nil
        }

        return candidateURL
    }

    private func applyPersistedWindowAndSoundSettings() {
        let shouldFloatOnTop = UserDefaults.standard.object(forKey: "floatOnTop") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "floatOnTop")
        let isFredMuted = UserDefaults.standard.bool(forKey: "fredSFXMuted")
        let fredVolume = UserDefaults.standard.object(forKey: "fredSFXVolume") == nil
            ? 0.7
            : UserDefaults.standard.double(forKey: "fredSFXVolume")

        updateWindowLevel(isFloating: shouldFloatOnTop)
        coordinator.engine.updateSoundEffectsMuted(isFredMuted)
        coordinator.engine.updateSoundEffectsVolume(Float(fredVolume))
    }

    private func updateWindowLevel(isFloating: Bool) {
        guard let window else { return }
        window.level = isFloating ? .floating : .normal
    }

    private func toggleWorkspaceMode() {
        guard let window else { return }
        let shouldExpand = window.frame.width < Self.expandedWidthThreshold
        setWorkspaceMode(expanded: shouldExpand)
    }

    private func setWorkspaceMode(expanded: Bool) {
        guard let window else { return }

        let targetWidth = expanded ? Self.expandedWindowWidth : Self.compactWindowWidth
        var targetFrame = window.frame
        targetFrame.size.width = targetWidth

        if let visibleFrame = window.screen?.visibleFrame {
            let maximumAllowedX = visibleFrame.maxX - targetWidth
            targetFrame.origin.x = min(targetFrame.origin.x, maximumAllowedX)
            targetFrame.origin.x = max(targetFrame.origin.x, visibleFrame.minX)
        }

        window.setFrame(targetFrame, display: true, animate: true)
    }
}
