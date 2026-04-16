import Foundation

/// Normalizes persisted Worker URLs so the networking layer doesn't depend on
/// users pasting an exact slash-free format into Settings.
enum WorkerURLNormalizer {

    static func normalize(_ rawValue: String?) -> String {
        let trimmedValue = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return "" }

        guard let parsedURL = URL(string: trimmedValue), parsedURL.host != nil else {
            return trimmedValue
        }

        var normalizedValue = trimmedValue
        while normalizedValue.hasSuffix("/") {
            normalizedValue.removeLast()
        }

        return normalizedValue
    }
}
