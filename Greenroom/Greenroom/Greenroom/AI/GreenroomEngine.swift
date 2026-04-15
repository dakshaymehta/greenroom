import Foundation

/// The central orchestration brain of Greenroom.
///
/// GreenroomEngine owns the AI tick loop: it collects new transcript text,
/// decides when enough has arrived to be worth sending, calls Claude, and
/// distributes the results back to the sidebar and sound engine.
///
/// Everything runs on the main actor so there is no shared-state concurrency
/// hazard between the timer callback, the async AI task, and the bridge calls.
@MainActor
final class GreenroomEngine {

    // MARK: - Dependencies

    let claudeClient = ClaudeAPIClient()
    let transcriptBuffer = TranscriptBuffer()
    let soundEffectEngine = SoundEffectEngine()

    /// Set by the window controller once the WebView is ready.
    var bridge: WebViewBridge?

    // MARK: - Timer State

    private var tickTimer: Timer?

    // MARK: - Request Gating

    /// Prevents a new AI call from starting while one is already in flight.
    ///
    /// Without this guard, fast transcript arrival could queue up dozens of
    /// concurrent requests and generate nonsensical overlapping responses.
    private var isRequestInFlight = false

    // MARK: - Conversation History

    /// The rolling message history sent alongside each new request for continuity.
    ///
    /// We keep a bounded window — not the entire session — to avoid ballooning
    /// token counts as a long show progresses.
    private var conversationHistory: [[String: Any]] = []

    /// How many user/assistant round-trips to retain in `conversationHistory`.
    ///
    /// Each "cycle" is one user message plus one assistant message (2 entries).
    private let maximumConversationHistoryCycles = 3

    // MARK: - Control Flags

    /// When true, the tick loop skips AI calls without stopping the timer.
    /// This lets the user "pause" without losing transcript context.
    var isPaused = false

    /// Tracks how many ticks in a row have resulted in an error.
    ///
    /// We show a UI error only after several consecutive failures, which avoids
    /// alarming the user over transient network blips.
    private var consecutiveFailureCount = 0

    // MARK: - UserDefaults-backed Configuration

    /// How often (in seconds) the engine fires an AI request.
    ///
    /// Changing this in Settings takes effect on the next `start()` call.
    var tickIntervalSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "aiIntervalSeconds")
        return stored > 0 ? stored : 15
    }

    /// How many seconds of prior transcript to include as context in each request.
    var contextWindowSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "contextWindowSeconds")
        return stored > 0 ? stored : 120
    }

    // MARK: - Lifecycle

    /// Starts the AI tick loop and marks the sidebar as live.
    func start() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickIntervalSeconds, repeats: true) { [weak self] _ in
            // Timer callbacks arrive on the main thread, but we bridge into an async
            // context via Task so `tick()` can await without blocking the run loop.
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        bridge?.setLiveStatus(true)
    }

    /// Stops the AI tick loop and marks the sidebar as offline.
    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        bridge?.setLiveStatus(false)
    }

    // MARK: - Transcript Input

    /// Accepts a new transcribed text segment and stores it in the buffer.
    func onTranscriptText(_ text: String) {
        transcriptBuffer.append(text)
    }

    // MARK: - Tick Loop

    /// The core AI loop, called once per `tickIntervalSeconds`.
    ///
    /// We skip silently when paused or when a request is already running so the
    /// show never gets flooded with stacked AI calls or redundant responses.
    private func tick() {
        guard !isPaused else { return }
        guard !isRequestInFlight else { return }

        let chunk = transcriptBuffer.extractChunk(contextWindowSeconds: contextWindowSeconds)
        transcriptBuffer.markTickBoundary()

        // Nothing new has been said — no point burning an API call.
        guard !chunk.newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isRequestInFlight = true
        bridge?.sendTickStart()

        let userMessageText = PersonaPrompts.buildUserMessage(
            newTranscript: chunk.newText,
            contextWindow: chunk.contextText
        )
        let newUserMessage: [String: Any] = ["role": "user", "content": userMessageText]
        let messagesForRequest = conversationHistory + [newUserMessage]

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Always clear the in-flight flag when the task ends, whether we
            // succeeded, failed, or threw — this unblocks the next tick.
            defer { self.isRequestInFlight = false }

            do {
                let personaUpdate = try await self.claudeClient.sendRequest(
                    systemPrompt: PersonaPrompts.masterSystemPrompt,
                    messages: messagesForRequest
                )

                self.consecutiveFailureCount = 0

                if let update = personaUpdate {
                    self.bridge?.sendPersonaUpdate(update)

                    // Let Fred play a sound effect if he chose one.
                    if let fredResponse = update.fred, let effectName = fredResponse.effect {
                        self.soundEffectEngine.play(effectName: effectName)
                    }

                    self.appendToConversationHistory(userMessage: newUserMessage, response: update)
                }

            } catch {
                self.consecutiveFailureCount += 1
                print("[GreenroomEngine] AI request failed (consecutive failures: \(self.consecutiveFailureCount)): \(error)")

                // Surface the error in the sidebar only after several failures in a row.
                // A single blip isn't worth interrupting the show over.
                if self.consecutiveFailureCount >= 3 {
                    self.bridge?.setErrorStatus(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Conversation History Management

    /// Appends the latest round-trip to the conversation history and trims it to
    /// the configured window.
    ///
    /// We store the assistant's reply as a JSON string because Claude's API expects
    /// text content in the messages array, not a nested object.
    private func appendToConversationHistory(userMessage: [String: Any], response: PersonaUpdate) {
        let assistantContent: String
        if let jsonString = try? response.toJSONString() {
            assistantContent = jsonString
        } else {
            assistantContent = "{}"
        }

        let assistantMessage: [String: Any] = ["role": "assistant", "content": assistantContent]

        conversationHistory.append(userMessage)
        conversationHistory.append(assistantMessage)

        // Each cycle is one user message + one assistant message (2 entries).
        let maximumHistoryEntries = maximumConversationHistoryCycles * 2
        if conversationHistory.count > maximumHistoryEntries {
            conversationHistory.removeFirst(conversationHistory.count - maximumHistoryEntries)
        }
    }

    // MARK: - Sound Effect Controls

    /// Passes through a mute state change from the sidebar to the sound engine.
    func updateSoundEffectsMuted(_ muted: Bool) {
        soundEffectEngine.isMuted = muted
    }

    /// Passes through a volume change from the sidebar to the sound engine.
    func updateSoundEffectsVolume(_ volume: Float) {
        soundEffectEngine.volume = volume
    }
}
