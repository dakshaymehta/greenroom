import Foundation

/// Centralizes the Anthropic model IDs Greenroom exposes in Settings and sends
/// through the Worker.
///
/// We normalize a couple of older saved values so existing installs recover
/// automatically if a previously-selected model ID has been retired upstream.
enum ClaudeModelCatalog {

    static let haiku = "claude-haiku-4-5"
    static let sonnet = "claude-sonnet-4-6"
    static let opus = "claude-opus-4-6"
    static let defaultModel = sonnet
    static let fastReactionModel = haiku

    static func normalized(_ rawValue: String?) -> String {
        let trimmedValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch trimmedValue {
        case "", defaultModel:
            return defaultModel

        case haiku:
            return haiku

        case opus:
            return opus

        case "claude-haiku-4-5-20251015", "claude-haiku-4-5", "claude-haiku-4":
            return haiku

        case "claude-sonnet-4-6-20250514", "claude-sonnet-4-6", "claude-sonnet-4-20250514", "claude-sonnet-4":
            return sonnet

        case "claude-opus-4-6-20250514", "claude-opus-4-6", "claude-opus-4-20250514", "claude-opus-4":
            return opus

        default:
            return trimmedValue
        }
    }
}
