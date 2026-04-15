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
    let text: String
    let confidence: Double?

    init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

struct FredResponse: Codable {
    let effect: String?
    let context: String?

    init(effect: String? = nil, context: String? = nil) {
        self.effect = effect
        self.context = context
    }
}

struct JackieResponse: Codable {
    let text: String
}

struct TrollResponse: Codable {
    let text: String
}

/// Action messages received from the sidebar JS when the user interacts with controls.
struct SidebarAction: Codable {
    let action: String
    let muted: Bool?
    let paused: Bool?
}
