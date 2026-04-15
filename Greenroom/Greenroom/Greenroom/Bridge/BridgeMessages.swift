import Foundation

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
}

struct GaryResponse: Codable {
    let trigger: String?
    let text: String
    let confidence: Double?
    /// When Gary wants to verify a claim with live web data, he includes a search
    /// query here. The engine detects this and makes a follow-up Exa search call.
    let searchQuery: String?

    enum CodingKeys: String, CodingKey {
        case trigger, text, confidence
        case searchQuery = "search_query"
    }

    init(text: String, confidence: Double? = nil, trigger: String? = nil, searchQuery: String? = nil) {
        self.trigger = trigger
        self.text = text
        self.confidence = confidence
        self.searchQuery = searchQuery
    }
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
}
