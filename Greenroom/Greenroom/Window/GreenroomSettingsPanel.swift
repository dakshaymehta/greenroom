import AppKit
import SwiftUI

/// Manages the floating settings panel that lets the user configure their
/// Worker URL, AI model, sound effects, and window behavior.
///
/// The panel is lazily created on first `show()` and reused for the rest of
/// the session. It floats above other windows so the user can adjust settings
/// while watching the sidebar.
@MainActor
final class GreenroomSettingsPanel {

    // MARK: - Properties

    private var panel: NSPanel?

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
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        settingsPanel.title = "Greenroom Settings"
        settingsPanel.isFloatingPanel = true
        settingsPanel.center()

        let hostingView = NSHostingView(rootView: SettingsFormView())
        settingsPanel.contentView = hostingView

        self.panel = settingsPanel
    }
}

// MARK: - SwiftUI Settings Form

struct SettingsFormView: View {

    // MARK: - Persisted Settings

    @AppStorage("workerBaseURL") private var workerURL = ""
    @AppStorage("aiIntervalSeconds") private var aiInterval: Double = 15
    @AppStorage("contextWindowSeconds") private var contextWindow: Double = 120
    @AppStorage("selectedModel") private var selectedModel = "claude-sonnet-4-6-20250514"
    @AppStorage("fredSFXMuted") private var fredMuted = false
    @AppStorage("fredSFXVolume") private var fredVolume: Double = 0.7
    @AppStorage("floatOnTop") private var floatOnTop = true

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
                Text("Claude Sonnet 4.6").tag("claude-sonnet-4-6-20250514")
                Text("Claude Opus 4.6").tag("claude-opus-4-6-20250514")
            }

            VStack(alignment: .leading) {
                Text("Tick Interval: \(Int(aiInterval))s")
                Slider(value: $aiInterval, in: 5...60, step: 5)
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
