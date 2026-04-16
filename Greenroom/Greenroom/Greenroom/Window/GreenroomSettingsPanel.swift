import AppKit
import SwiftUI

/// Manages the floating settings panel that lets the user configure their
/// Worker URL, AI model, sound effects, and window behavior.
///
/// The panel is lazily created on first `show()` and reused for the rest of
/// the session. It floats above other windows so the user can adjust settings
/// while watching the sidebar.
@MainActor
final class GreenroomSettingsPanel: NSObject, NSWindowDelegate {

    // MARK: - Properties

    private var panel: NSPanel?
    var onClose: (() -> Void)?
    var onSoundSettingsChanged: ((Bool, Float) -> Void)?
    var onFloatOnTopChanged: ((Bool) -> Void)?

    // MARK: - Show

    /// Creates the panel lazily on first call, then brings it to the front.
    func show() {
        if panel == nil {
            buildPanel()
        }

        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panel Construction

    private func buildPanel() {
        let settingsPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        settingsPanel.title = "Greenroom Settings"
        settingsPanel.isFloatingPanel = true
        settingsPanel.delegate = self
        settingsPanel.center()

        let hostingView = NSHostingView(
            rootView: SettingsFormView(
                onSoundSettingsChanged: { [weak self] muted, volume in
                    self?.onSoundSettingsChanged?(muted, volume)
                },
                onFloatOnTopChanged: { [weak self] shouldFloatOnTop in
                    self?.onFloatOnTopChanged?(shouldFloatOnTop)
                }
            )
        )
        settingsPanel.contentView = hostingView

        self.panel = settingsPanel
    }

    func windowWillClose(_ notification: Notification) {
        let normalizedWorkerBaseURL = WorkerURLNormalizer.normalize(
            UserDefaults.standard.string(forKey: "workerBaseURL")
        )
        UserDefaults.standard.set(normalizedWorkerBaseURL, forKey: "workerBaseURL")
        onClose?()
    }
}

// MARK: - SwiftUI Settings Form

struct SettingsFormView: View {

    // MARK: - Persisted Settings

    @AppStorage("workerBaseURL") private var workerURL = ""
    @AppStorage("aiIntervalSeconds") private var aiInterval: Double = 4
    @AppStorage("contextWindowSeconds") private var contextWindow: Double = 120
    @AppStorage("selectedModel") private var selectedModel = ClaudeModelCatalog.defaultModel
    @AppStorage("fredSFXMuted") private var fredMuted = false
    @AppStorage("fredSFXVolume") private var fredVolume: Double = 0.7
    @AppStorage("floatOnTop") private var floatOnTop = true

    let onSoundSettingsChanged: (Bool, Float) -> Void
    let onFloatOnTopChanged: (Bool) -> Void

    // MARK: - Body

    var body: some View {
        Form {
            connectionSection
            aiSection
            soundEffectsSection
            windowSection
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 400)
        .onAppear {
            selectedModel = ClaudeModelCatalog.normalized(selectedModel)
            onSoundSettingsChanged(fredMuted, Float(fredVolume))
            onFloatOnTopChanged(floatOnTop)
        }
        .onChange(of: fredMuted) { _, newValue in
            onSoundSettingsChanged(newValue, Float(fredVolume))
        }
        .onChange(of: fredVolume) { _, newValue in
            onSoundSettingsChanged(fredMuted, Float(newValue))
        }
        .onChange(of: floatOnTop) { _, newValue in
            onFloatOnTopChanged(newValue)
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section("Connection (BYOK)") {
            TextField("Worker URL", text: $workerURL)
                .textFieldStyle(.roundedBorder)

            Text("Deploy your own Worker with your API keys. See README for setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aiSection: some View {
        Section("AI") {
            Picker("Model", selection: $selectedModel) {
                Text("Claude Sonnet 4").tag(ClaudeModelCatalog.sonnet)
                Text("Claude Opus 4").tag(ClaudeModelCatalog.opus)
            }

            VStack(alignment: .leading) {
                Text("Response Interval: \(Int(aiInterval))s")
                Slider(value: $aiInterval, in: 2...20, step: 1)
            }

            VStack(alignment: .leading) {
                let displayMinutes = contextWindow / 60.0
                Text("Context Window: \(String(format: "%.1f", displayMinutes)) min")
                Slider(value: $contextWindow, in: 60...300, step: 30)
            }
        }
    }

    private var soundEffectsSection: some View {
        Section("Sound Effects (Fred)") {
            Toggle("Muted", isOn: $fredMuted)

            VStack(alignment: .leading) {
                Text("Volume: \(Int(fredVolume * 100))%")
                Slider(value: $fredVolume, in: 0...1)
                    .disabled(fredMuted)
            }
        }
    }

    private var windowSection: some View {
        Section("Window") {
            Toggle("Float on Top", isOn: $floatOnTop)
        }
    }
}
