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

    private static let windowWidth: CGFloat = 320
    private static let windowHeight: CGFloat = 700
    private static let minimumWindowWidth: CGFloat = 280
    private static let minimumWindowHeight: CGFloat = 400
    private static let windowTitle = "Greenroom"
    private static let windowAutosaveName = "GreenroomMainWindow"

    // MARK: - Initializer

    /// Creates the controller without yet showing the window.
    /// Call `showWindow(_:)` to display it.
    init() {
        // NSWindowController's designated initializer requires a window or nib name.
        // We build the window programmatically, so we call super.init(window:) with nil
        // and assign the window ourselves in buildWindowIfNeeded().
        super.init(window: nil)
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
            width: Self.windowWidth,
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

        // Persists window position across launches. On the very first launch,
        // cascadeTopLeft produces a default position; we override with center()
        // so the window appears in a predictable place.
        let didRestorePosition = mainWindow.setFrameAutosaveName(Self.windowAutosaveName)
        if !didRestorePosition {
            mainWindow.center()
        }

        let webView = buildWebView()
        mainWindow.contentView = webView

        loadSidebarHTML(into: webView)

        self.window = mainWindow
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
    /// 2. Path derived from `#file` at compile time — used during Xcode debug runs
    ///    where the bundle may not yet contain the sidebar assets.
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
        Build the project from the repo root to include sidebar assets.</p>
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
    /// repo root, then resolves sidebar/index.html from there.
    ///
    /// This covers the common Xcode workflow where you run the app directly
    /// from the scheme without packaging sidebar assets into the bundle first.
    private func locateSidebarURLRelativeToSourceFile() -> URL? {
        // #file expands to the absolute path of this source file at compile time:
        // …/greenroom/Greenroom/Greenroom/Greenroom/Window/GreenroomWindowController.swift
        // We need to walk up 5 levels to reach the repo root (greenroom/):
        // GreenroomWindowController.swift → Window/ → Greenroom (source) → Greenroom (project) → Greenroom (wrapper) → repo root
        let sourceFileURL = URL(fileURLWithPath: #file)

        let repoRootURL = sourceFileURL
            .deletingLastPathComponent() // → Window/
            .deletingLastPathComponent() // → Greenroom (source)
            .deletingLastPathComponent() // → Greenroom (project)
            .deletingLastPathComponent() // → Greenroom (wrapper)
            .deletingLastPathComponent() // → greenroom/ (repo root)

        let candidateURL = repoRootURL
            .appendingPathComponent("sidebar")
            .appendingPathComponent("index.html")

        guard FileManager.default.fileExists(atPath: candidateURL.path) else {
            return nil
        }

        return candidateURL
    }
}
