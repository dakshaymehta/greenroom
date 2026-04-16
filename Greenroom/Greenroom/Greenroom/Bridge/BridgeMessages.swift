import Foundation

enum PersonaIdentity: String, CaseIterable, Codable, Hashable {
    case gary
    case fred
    case jackie
    case troll

    var displayName: String {
        switch self {
        case .gary:
            return "Gary"
        case .fred:
            return "Fred"
        case .jackie:
            return "Jackie"
        case .troll:
            return "The Troll"
        }
    }
}

/// Persona responses sent from Swift to the sidebar JS.
/// Each persona is either an object with their response, or null if they have nothing to say.
struct PersonaUpdate: Codable {
    let gary: GaryResponse?
    let fred: FredResponse?
    let jackie: JackieResponse?
    let troll: TrollResponse?

    func toJSONString() throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    var highlightInputs: [PersonaHighlightInput] {
        var inputs: [PersonaHighlightInput] = []

        if let gary,
           let trigger = nonEmptyValue(gary.trigger) {
            inputs.append(
                PersonaHighlightInput(
                    persona: .gary,
                    trigger: trigger,
                    reactionText: gary.text,
                    verdict: nonEmptyValue(gary.verdict),
                    sourceNote: nonEmptyValue(gary.sourceNote),
                    sources: gary.sources ?? []
                )
            )
        }

        if let fred,
           let trigger = nonEmptyValue(fred.trigger) {
            inputs.append(
                PersonaHighlightInput(
                    persona: .fred,
                    trigger: trigger,
                    reactionText: fred.context ?? fredReactionText(effect: fred.effect),
                    verdict: nil,
                    sourceNote: nil,
                    sources: []
                )
            )
        }

        if let jackie,
           let trigger = nonEmptyValue(jackie.trigger) {
            inputs.append(
                PersonaHighlightInput(
                    persona: .jackie,
                    trigger: trigger,
                    reactionText: jackie.text,
                    verdict: nil,
                    sourceNote: nil,
                    sources: []
                )
            )
        }

        if let troll,
           let trigger = nonEmptyValue(troll.trigger) {
            inputs.append(
                PersonaHighlightInput(
                    persona: .troll,
                    trigger: trigger,
                    reactionText: troll.text,
                    verdict: nil,
                    sourceNote: nil,
                    sources: []
                )
            )
        }

        return inputs
    }

    private func nonEmptyValue(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func fredReactionText(effect: String?) -> String {
        guard let effect = nonEmptyValue(effect) else {
            return "Tracked the room for a timing cue."
        }

        return "Queued \(effect.replacingOccurrences(of: "_", with: " ")) for the room."
    }
}

struct PersonaHighlightInput {
    let persona: PersonaIdentity
    let trigger: String
    let reactionText: String
    let verdict: String?
    let sourceNote: String?
    let sources: [GarySource]
}

struct TranscriptContextSnapshot: Codable {
    let lines: [TranscriptContextLinePayload]
    let focusedSegmentID: String?
    let liveDraft: TranscriptContextLiveDraftPayload?
}

struct TranscriptContextLinePayload: Codable {
    let id: String
    let text: String
    let timestamp: TimeInterval
    let highlights: [TranscriptContextHighlightPayload]
}

struct TranscriptContextHighlightPayload: Codable {
    let id: String
    let persona: String
    let displayName: String
    let trigger: String
    let matchedAt: TimeInterval
    let reactionText: String
    let verdict: String?
    let sourceNote: String?
    let sources: [GarySource]
}

struct TranscriptContextLiveDraftPayload: Codable {
    let text: String
    let timestamp: TimeInterval
    let turnOrder: Int?
}

struct GaryResponse: Codable {
    let trigger: String?
    let text: String
    let confidence: Double?
    /// A compact classification that helps the UI show Gary's value at a glance.
    /// Expected values are: confirmed, contradicted, context, or unclear.
    let verdict: String?
    /// A short label describing the evidence Gary used, such as a source type
    /// or verification mode. Example: "NASA page" or "live web check".
    let sourceNote: String?
    /// Structured source metadata attached by the app after a live web search.
    let sources: [GarySource]?
    /// When Gary wants to verify a claim with live web data, he includes a search
    /// query here. The engine detects this and makes a follow-up Exa search call.
    let searchQuery: String?

    enum CodingKeys: String, CodingKey {
        case trigger, text, confidence, verdict, sources
        case sourceNote = "source_note"
        case searchQuery = "search_query"
    }

    init(
        text: String,
        confidence: Double? = nil,
        trigger: String? = nil,
        searchQuery: String? = nil,
        verdict: String? = nil,
        sourceNote: String? = nil,
        sources: [GarySource]? = nil
    ) {
        self.trigger = trigger
        self.text = text
        self.confidence = confidence
        self.verdict = verdict
        self.sourceNote = sourceNote
        self.sources = sources
        self.searchQuery = searchQuery
    }
}

struct GarySource: Codable, Equatable, Hashable {
    let title: String
    let url: String
    let host: String
}

struct FredResponse: Codable {
    let trigger: String?
    let effect: String?
    let context: String?

    init(trigger: String? = nil, effect: String? = nil, context: String? = nil) {
        self.trigger = trigger
        self.effect = effect
        self.context = context
    }
}

struct JackieResponse: Codable {
    let trigger: String?
    let text: String
}

struct TrollResponse: Codable {
    let trigger: String?
    let text: String
}

/// Action messages received from the sidebar JS when the user interacts with controls.
struct SidebarAction: Codable {
    let action: String
    let muted: Bool?
    let paused: Bool?
    let url: String?
}
