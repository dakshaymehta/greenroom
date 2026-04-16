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
    let transcriptContextStore = TranscriptContextStore()
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
    private var pendingLiveTickTask: Task<Void, Never>?
    private var lastTickStartTime: Date?

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
        return stored > 0 ? stored : 4
    }

    /// How many seconds of prior transcript to include as context in each request.
    var contextWindowSeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: "contextWindowSeconds")
        return stored > 0 ? stored : 120
    }

    private var liveReactionDebounceSeconds: TimeInterval {
        0.85
    }

    private var minimumTickSpacingSeconds: TimeInterval {
        min(max(1.2, tickIntervalSeconds * 0.45), 2.4)
    }

    // MARK: - Lifecycle

    /// Starts the AI tick loop and marks the sidebar as live.
    func start() {
        pendingLiveTickTask?.cancel()
        tickTimer?.invalidate()
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
        pendingLiveTickTask?.cancel()
        pendingLiveTickTask = nil
        tickTimer?.invalidate()
        tickTimer = nil
        soundEffectEngine.stop()
        transcriptContextStore.clearLiveDraft()
        refreshTranscriptPreview()
        bridge?.setLiveStatus(false)
    }

    // MARK: - Transcript Input

    /// Accepts a live transcription update and decides whether it should remain
    /// transient in the UI or be committed to the durable transcript buffer.
    func onTranscriptionUpdate(_ update: TranscriptionUpdate) {
        let trimmedText = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if update.isFinal {
            let segment = transcriptBuffer.append(trimmedText)
            transcriptContextStore.appendFinal(segment, turnOrder: update.turnOrder)
            scheduleLiveTick(after: liveReactionDebounceSeconds)
        } else {
            transcriptContextStore.setLiveDraft(text: trimmedText, turnOrder: update.turnOrder)
        }

        refreshTranscriptPreview()
    }

    /// Compatibility shim for older call sites that still deliver only final text.
    func onTranscriptText(_ text: String) {
        onTranscriptionUpdate(
            TranscriptionUpdate(text: text, isFinal: true, turnOrder: nil)
        )
    }

    private func refreshTranscriptPreview() {
        bridge?.sendTranscriptUpdate(transcriptContextStore.transcriptPreviewText())
        bridge?.sendTranscriptContext(transcriptContextStore.snapshot())
    }

    func clearLiveTranscriptDraft() {
        transcriptContextStore.clearLiveDraft()
        refreshTranscriptPreview()
    }

    /// Discards every piece of session state that carries transcript text:
    /// the rolling buffer, the sidebar context store, and the conversation
    /// history sent alongside each AI request. Used when the user stops
    /// listening so prior speech doesn't persist in memory past the session.
    func clearAllTranscriptState() {
        transcriptBuffer.clearAll()
        transcriptContextStore.clearAll()
        conversationHistory.removeAll()
        refreshTranscriptPreview()
    }

    func refreshTimingConfiguration() {
        guard tickTimer != nil else { return }
        start()
    }

    // MARK: - Tick Loop

    /// The core AI loop, called once per `tickIntervalSeconds`.
    ///
    /// We skip silently when paused or when a request is already running so the
    /// show never gets flooded with stacked AI calls or redundant responses.
    private func tick() {
        guard !isPaused else { return }
        guard !isRequestInFlight else { return }

        if let lastTickStartTime {
            let elapsedSinceLastTick = Date().timeIntervalSince(lastTickStartTime)
            if elapsedSinceLastTick < minimumTickSpacingSeconds {
                scheduleLiveTick(after: minimumTickSpacingSeconds - elapsedSinceLastTick)
                return
            }
        }

        let chunk = transcriptBuffer.extractChunk(contextWindowSeconds: contextWindowSeconds)

        // Nothing new has been said — no point burning an API call.
        guard !chunk.newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        pendingLiveTickTask?.cancel()
        pendingLiveTickTask = nil
        isRequestInFlight = true
        lastTickStartTime = Date()
        transcriptBuffer.markTickBoundary()
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
            defer {
                self.isRequestInFlight = false

                if self.hasPendingTranscriptSinceLastTick() {
                    self.scheduleLiveTick(after: 0.35)
                }
            }

            do {
                let personaUpdate = try await self.claudeClient.sendRequest(
                    systemPrompt: PersonaPrompts.masterSystemPrompt,
                    messages: messagesForRequest
                )

                self.consecutiveFailureCount = 0

                if var update = personaUpdate {
                    // Gary is most valuable when he grounds claims with sources.
                    // If he spoke at all, run a live verification pass using either
                    // his explicit search query or a query derived from the trigger.
                    if let garyResponse = update.gary,
                       let searchQuery = self.liveSearchQuery(
                        for: garyResponse,
                        transcriptSeed: chunk.newText
                       ) {
                        update = await self.enrichGaryWithSearch(
                            searchQuery: searchQuery,
                            currentUpdate: update,
                            messagesForRequest: messagesForRequest,
                            transcriptSeed: chunk.newText
                        )
                    }

                    self.transcriptContextStore.applyHighlights(for: update, using: self.transcriptBuffer)
                    self.bridge?.sendTranscriptContext(self.transcriptContextStore.snapshot())
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

    // MARK: - Exa Search Follow-Up

    /// Fetches Exa search results and asks Claude to produce an updated, sourced
    /// Gary response. Falls back to the original update if anything goes wrong —
    /// a failed search should never block the rest of the persona responses.
    private func enrichGaryWithSearch(
        searchQuery: String,
        currentUpdate: PersonaUpdate,
        messagesForRequest: [[String: Any]],
        transcriptSeed: String
    ) async -> PersonaUpdate {
        let originalGary = currentUpdate.gary
        var fallbackSources: [GarySource] = []

        do {
            let liveSearchResponse = try await claudeClient.searchViaExa(query: searchQuery)
            let garySources = Array(
                liveSearchResponse.results.prefix(3).map {
                    GarySource(title: $0.title, url: $0.url, host: $0.host)
                }
            )
            fallbackSources = garySources
            let fallbackSourceNote = Self.sourceNoteLabel(for: garySources)
            let transcriptExcerpt = String(
                transcriptSeed
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(420)
            )

            let followUpMessage: [String: Any] = [
                "role": "user",
                "content": """
                Gary is fact-checking this live transcript excerpt:

                \(transcriptExcerpt.isEmpty ? "(No transcript excerpt available)" : transcriptExcerpt)

                Here are the web search results for Gary's fact-check:

                \(liveSearchResponse.promptSummary)

                Please provide Gary's updated response with the sourced information.
                Return the same JSON format but only include Gary's updated response.
                The other personas should be null.

                Gary must:
                - check the exact claim in `trigger`, not the entire topic
                - use `contradicted` only if the sources directly conflict with the claim
                - use `context` if the claim is too broad, compressed, or missing important framing
                - use `unclear` if the reporting is mixed or still too early
                - if no strong independent or official sources are available, do not use `confirmed` or `contradicted`
                - explain what the evidence does show in one or two short sentences
                - keep `search_query` set to "\(searchQuery)"
                - include a short `source_note` naming the source family only when the sources are genuinely useful
                """
            ]

            let followUpMessages = messagesForRequest + [followUpMessage]
            if let enrichedUpdate = try await claudeClient.sendRequest(
                systemPrompt: PersonaPrompts.masterSystemPrompt,
                messages: followUpMessages
            ), let enrichedGary = enrichedUpdate.gary {
                let mergedGary = GaryResponse(
                    text: enrichedGary.text,
                    confidence: enrichedGary.confidence ?? originalGary?.confidence,
                    trigger: enrichedGary.trigger ?? originalGary?.trigger,
                    searchQuery: enrichedGary.searchQuery ?? searchQuery,
                    verdict: enrichedGary.verdict ?? originalGary?.verdict,
                    sourceNote: enrichedGary.sourceNote ?? originalGary?.sourceNote ?? fallbackSourceNote ?? "live web check",
                    sources: enrichedGary.sources ?? (garySources.isEmpty ? nil : garySources)
                )

                let normalizedGary = normalizeGaryFactCheck(
                    mergedGary,
                    availableSources: garySources,
                    searchQuery: searchQuery
                )

                // Swap in the enriched Gary response, keep the other personas from the original.
                return PersonaUpdate(
                    gary: normalizedGary,
                    fred: currentUpdate.fred,
                    jackie: currentUpdate.jackie,
                    troll: currentUpdate.troll
                )
            }
        } catch {
            print("[GreenroomEngine] Exa search follow-up failed (using original Gary response): \(error)")
        }

        if let originalGary {
            let normalizedGary = normalizeGaryFactCheck(
                GaryResponse(
                    text: originalGary.text,
                    confidence: originalGary.confidence,
                    trigger: originalGary.trigger,
                    searchQuery: originalGary.searchQuery ?? searchQuery,
                    verdict: originalGary.verdict,
                    sourceNote: originalGary.sourceNote ?? Self.sourceNoteLabel(for: fallbackSources) ?? (fallbackSources.isEmpty ? nil : "live web check"),
                    sources: fallbackSources.isEmpty ? originalGary.sources : fallbackSources
                ),
                availableSources: fallbackSources.isEmpty ? (originalGary.sources ?? []) : fallbackSources,
                searchQuery: searchQuery
            )

            return PersonaUpdate(
                gary: normalizedGary,
                fred: currentUpdate.fred,
                jackie: currentUpdate.jackie,
                troll: currentUpdate.troll
            )
        }

        return currentUpdate
    }

    private func scheduleLiveTick(after delaySeconds: TimeInterval) {
        guard !isPaused else { return }

        pendingLiveTickTask?.cancel()
        pendingLiveTickTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let clampedDelaySeconds = max(0, delaySeconds)
            if clampedDelaySeconds > 0 {
                let delayNanoseconds = UInt64(clampedDelaySeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            guard !Task.isCancelled else { return }

            self.pendingLiveTickTask = nil

            if self.isRequestInFlight {
                self.scheduleLiveTick(after: 0.45)
                return
            }

            self.tick()
        }
    }

    private func hasPendingTranscriptSinceLastTick() -> Bool {
        let pendingChunk = transcriptBuffer.extractChunk(contextWindowSeconds: contextWindowSeconds)
        return !pendingChunk.newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizeGaryFactCheck(
        _ garyResponse: GaryResponse,
        availableSources: [GarySource],
        searchQuery: String
    ) -> GaryResponse {
        let resolvedSources = availableSources.isEmpty
            ? (garyResponse.sources ?? [])
            : availableSources
        let normalizedSourceNote = Self.normalizedSearchText(garyResponse.sourceNote)

        guard !resolvedSources.isEmpty else {
            let liveSearchWasRequested = Self.normalizedSearchText(garyResponse.searchQuery ?? searchQuery) != nil
            let currentVerdict = Self.normalizedSearchText(garyResponse.verdict)?.lowercased()

            if liveSearchWasRequested,
               currentVerdict == "confirmed" || currentVerdict == "contradicted" {
                return GaryResponse(
                    text: "Live check is still thin — I do not have strong independent sourcing to confirm that claim yet.",
                    confidence: min(garyResponse.confidence ?? 0.55, 0.58),
                    trigger: garyResponse.trigger,
                    searchQuery: garyResponse.searchQuery ?? searchQuery,
                    verdict: "unclear",
                    sourceNote: nil,
                    sources: nil
                )
            }

            return GaryResponse(
                text: garyResponse.text,
                confidence: garyResponse.confidence,
                trigger: garyResponse.trigger,
                searchQuery: garyResponse.searchQuery ?? searchQuery,
                verdict: garyResponse.verdict,
                sourceNote: nil,
                sources: nil
            )
        }

        return GaryResponse(
            text: garyResponse.text,
            confidence: garyResponse.confidence,
            trigger: garyResponse.trigger,
            searchQuery: garyResponse.searchQuery ?? searchQuery,
            verdict: garyResponse.verdict,
            sourceNote: normalizedSourceNote ?? Self.sourceNoteLabel(for: resolvedSources),
            sources: resolvedSources
        )
    }

    private func liveSearchQuery(for garyResponse: GaryResponse, transcriptSeed: String) -> String? {
        if let explicitSearchQuery = Self.normalizedSearchText(garyResponse.searchQuery) {
            return explicitSearchQuery
        }

        if let triggerQuote = Self.normalizedSearchText(garyResponse.trigger) {
            return Self.fallbackSearchQuery(
                trigger: triggerQuote,
                transcriptSeed: transcriptSeed
            )
        }

        if let responseText = Self.normalizedSearchText(garyResponse.text) {
            return responseText
        }

        return Self.normalizedSearchText(transcriptSeed)
    }

    static func fallbackSearchQuery(trigger: String, transcriptSeed: String) -> String? {
        guard let normalizedTrigger = normalizedSearchText(trigger) else {
            return nil
        }

        let normalizedTriggerTokens = Set(
            normalizedTrigger
                .split(separator: " ")
                .map { String($0) }
        )

        let additionalTerms = contextTermCandidates(from: transcriptSeed).filter { term in
            guard let normalizedTerm = normalizedSearchText(term) else { return false }

            let normalizedTermTokens = Set(
                normalizedTerm
                    .split(separator: " ")
                    .map { String($0) }
            )

            return normalizedTermTokens.isDisjoint(with: normalizedTriggerTokens)
        }

        let queryComponents = [normalizedTrigger] + Array(additionalTerms.prefix(3))
        let query = queryComponents.joined(separator: " ")

        return normalizedSearchText(query)
    }

    static func normalizedSearchText(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }

        let collapsedWhitespaceValue = trimmedValue
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsedWhitespaceValue.isEmpty else { return nil }
        return String(collapsedWhitespaceValue.prefix(140))
    }

    private static func contextTermCandidates(from transcriptSeed: String) -> [String] {
        let rawWords = transcriptSeed
            .components(separatedBy: .whitespacesAndNewlines)
            .map(Self.cleanedContextToken)

        var phrases: [String] = []
        var currentPhrase: [String] = []

        func commitCurrentPhrase() {
            guard !currentPhrase.isEmpty else { return }

            let committedTokens = currentPhrase
            let phrase = committedTokens.joined(separator: " ")
            currentPhrase.removeAll()

            let lowercasedPhrase = phrase.lowercased()
            let isSingleUppercaseAcronym = committedTokens.count == 1
                && committedTokens[0] == committedTokens[0].uppercased()

            if committedTokens.count == 1,
               ignoredSingleWordSearchTerms.contains(lowercasedPhrase),
               !isSingleUppercaseAcronym {
                return
            }

            if !phrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
                phrases.append(phrase)
            }
        }

        for rawWord in rawWords {
            guard !rawWord.isEmpty else {
                commitCurrentPhrase()
                continue
            }

            if isContextSearchToken(rawWord) {
                currentPhrase.append(rawWord)

                if currentPhrase.count >= 3 {
                    commitCurrentPhrase()
                }
            } else {
                commitCurrentPhrase()
            }
        }

        commitCurrentPhrase()
        return phrases
    }

    private static func cleanedContextToken(_ rawToken: String) -> String {
        rawToken.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    private static func isContextSearchToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }

        if token.range(of: #"^\d+(\.\d+)?%?$"#, options: .regularExpression) != nil {
            return true
        }

        if token.range(of: #"^[A-Z]{2,}$"#, options: .regularExpression) != nil {
            return true
        }

        if token.range(of: #"^[A-Z][a-z]+$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func sourceNoteLabel(for sources: [GarySource]) -> String? {
        let sourceLabels = sources
            .map(\.host)
            .map(Self.displaySourceLabel)
            .filter { !$0.isEmpty }

        var uniqueLabels: [String] = []

        for label in sourceLabels {
            if !uniqueLabels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
                uniqueLabels.append(label)
            }
        }

        guard !uniqueLabels.isEmpty else { return nil }
        return uniqueLabels.prefix(2).joined(separator: " + ")
    }

    private static func displaySourceLabel(for host: String) -> String {
        let cleanedHost = host
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedHost.isEmpty else { return "" }

        let hostPrefix = cleanedHost
            .split(separator: ".")
            .first
            .map(String.init) ?? cleanedHost

        switch hostPrefix.lowercased() {
        case "ap":
            return "AP"
        case "bbc":
            return "BBC"
        default:
            return hostPrefix
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    private static let ignoredSingleWordSearchTerms: Set<String> = [
        "a", "an", "and", "as", "at", "but", "for", "from", "he", "her", "here",
        "him", "his", "i", "if", "in", "it", "its", "meanwhile", "now", "of", "on",
        "or", "she", "that", "the", "their", "there", "they", "this", "to", "us",
        "we", "well", "with", "you"
    ]

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
