import Foundation

/// A rolling buffer that accumulates transcribed text segments within a configurable time window.
///
/// Segments older than `maxStorageDurationSeconds` are automatically pruned on each append,
/// keeping memory usage bounded even during long recording sessions.
///
/// The tick boundary concept lets callers distinguish between text that has already been
/// sent to the AI (the context window) and text that is new since the last AI call.
final class TranscriptBuffer {

    // MARK: - Nested Types

    /// A single piece of transcribed text with stable identity for UI highlighting.
    struct TranscriptSegment: Equatable, Identifiable {
        let id: UUID
        let text: String
        let timestamp: Date
    }

    /// The result of extracting a chunk from the buffer for an AI call.
    struct Chunk {
        /// Text that arrived after the last tick boundary — this is what the AI should respond to.
        let newText: String
        /// Text from before the last tick boundary that still falls within the context window.
        /// Gives the AI enough context to understand references in the new text.
        let contextText: String
    }

    // MARK: - Properties

    /// All segments currently held in the buffer, ordered from oldest to newest.
    private var segments: [TranscriptSegment] = []

    /// The index into `segments` marking where the last tick boundary fell.
    ///
    /// Segments at indices 0..<lastTickBoundaryIndex are "context" (already processed).
    /// Segments at indices lastTickBoundaryIndex... are "new" (not yet sent to the AI).
    private var lastTickBoundaryIndex: Int = 0

    /// How long (in seconds) to keep segments before pruning them.
    ///
    /// Defaults to 5 minutes — enough to give the AI meaningful context while
    /// keeping the buffer from growing indefinitely.
    let maxStorageDurationSeconds: TimeInterval

    // MARK: - Initialization

    init(maxStorageDurationSeconds: TimeInterval = 300) {
        self.maxStorageDurationSeconds = maxStorageDurationSeconds
    }

    // MARK: - Public Interface

    /// Adds a new transcribed text segment to the buffer and prunes expired segments.
    @discardableResult
    func append(_ text: String, at timestamp: Date = Date()) -> TranscriptSegment {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            if let lastSegment = segments.last {
                return lastSegment
            }

            let emptySegment = TranscriptSegment(id: UUID(), text: "", timestamp: timestamp)
            return emptySegment
        }

        if let lastSegment = segments.last,
           let mergedSegment = mergedSegmentIfNeeded(
            previousSegment: lastSegment,
            incomingText: trimmedText,
            timestamp: timestamp
           ) {
            segments[segments.count - 1] = mergedSegment
            pruneOldSegments()
            return mergedSegment
        }

        let segment = TranscriptSegment(id: UUID(), text: trimmedText, timestamp: timestamp)
        segments.append(segment)
        pruneOldSegments()
        return segment
    }

    /// Records the current end of the buffer as the tick boundary.
    ///
    /// Call this immediately after extracting a chunk and sending it to the AI,
    /// so the next extraction correctly identifies which text is new.
    func markTickBoundary() {
        lastTickBoundaryIndex = segments.count
    }

    /// Extracts the current chunk for an AI call.
    ///
    /// - Parameter contextWindowSeconds: How far back (in seconds) to look for context text.
    ///   The AI doesn't need to see the entire 5-minute buffer — just enough to understand
    ///   references in the new text.
    /// - Returns: A `Chunk` containing the new text and any relevant prior context.
    func extractChunk(contextWindowSeconds: TimeInterval) -> Chunk {
        let now = Date()
        let contextCutoffDate = now.addingTimeInterval(-contextWindowSeconds)

        // Segments after the boundary are new — the AI hasn't seen them yet.
        let newSegments = segments[safeRange: lastTickBoundaryIndex...]
        let newText = newSegments.map(\.text).joined(separator: " ")

        // Segments before the boundary that fall within the context window give
        // the AI enough runway to understand what the new text is referring to.
        let contextSegments = segments[safeRange: 0..<lastTickBoundaryIndex]
            .filter { $0.timestamp >= contextCutoffDate }
        let contextText = contextSegments.map(\.text).joined(separator: " ")

        return Chunk(newText: newText, contextText: contextText)
    }

    /// Returns the most relevant transcript segment for a persona trigger quote.
    ///
    /// Persona triggers are intentionally short excerpts, so the matching logic
    /// first looks for a normalized substring match and then falls back to
    /// token-overlap scoring when punctuation or formatting differs slightly.
    func bestMatchingSegment(for trigger: String, maximumSegmentsToSearch: Int = 40) -> TranscriptSegment? {
        let normalizedTrigger = Self.normalizedSearchableText(from: trigger)
        guard !normalizedTrigger.isEmpty else { return nil }

        let candidateSegments = Array(segments.suffix(maximumSegmentsToSearch)).reversed()

        if let exactMatch = candidateSegments.first(where: {
            Self.normalizedSearchableText(from: $0.text).contains(normalizedTrigger)
        }) {
            return exactMatch
        }

        let triggerTokens = Self.significantTokens(from: normalizedTrigger)
        guard !triggerTokens.isEmpty else { return nil }

        var bestMatch: TranscriptSegment?
        var bestScore = 0.0

        for segment in candidateSegments {
            let segmentTokens = Self.significantTokens(from: segment.text)
            guard !segmentTokens.isEmpty else { continue }

            let overlapCount = triggerTokens.intersection(segmentTokens).count
            guard overlapCount > 0 else { continue }

            let score = Double(overlapCount) / Double(triggerTokens.count)
            if score > bestScore {
                bestScore = score
                bestMatch = segment
            }
        }

        guard bestScore >= 0.4 else { return nil }
        return bestMatch
    }

    func recentSegments(limit: Int? = nil) -> [TranscriptSegment] {
        guard let limit else { return segments }
        return Array(segments.suffix(limit))
    }

    /// Discards every buffered segment and resets the tick boundary.
    ///
    /// Called on listening teardown so a fresh session never carries forward
    /// speech from the previous one — both for conversational hygiene and so
    /// that prior transcripts don't linger in memory after the user stops.
    func clearAll() {
        segments.removeAll()
        lastTickBoundaryIndex = 0
    }

    /// Removes segments that have exceeded `maxStorageDurationSeconds` and adjusts the boundary.
    ///
    /// We remove from the front of the array and shift the boundary index down accordingly.
    /// This keeps array indices consistent with the logical position of the boundary.
    func pruneOldSegments() {
        let cutoffDate = Date().addingTimeInterval(-maxStorageDurationSeconds)

        let numberOfExpiredSegments = segments.prefix(while: { $0.timestamp < cutoffDate }).count

        guard numberOfExpiredSegments > 0 else { return }

        segments.removeFirst(numberOfExpiredSegments)

        // Shift the boundary index to account for the segments we just removed.
        // Clamp to zero in case we removed segments that were after the boundary
        // (which shouldn't happen in normal use, but is safe to handle).
        lastTickBoundaryIndex = max(0, lastTickBoundaryIndex - numberOfExpiredSegments)
    }

    private static func normalizedSearchableText(from text: String) -> String {
        let lowercaseText = text.lowercased()
        let scalarCharacters = lowercaseText.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }

        return String(scalarCharacters)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func significantTokens(from text: String) -> Set<String> {
        Set(
            normalizedSearchableText(from: text)
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 }
        )
    }

    private func mergedSegmentIfNeeded(
        previousSegment: TranscriptSegment,
        incomingText: String,
        timestamp: Date
    ) -> TranscriptSegment? {
        guard !incomingText.isEmpty else { return previousSegment }

        let normalizedPreviousText = Self.normalizedSearchableText(from: previousSegment.text)
        let normalizedIncomingText = Self.normalizedSearchableText(from: incomingText)

        guard !normalizedPreviousText.isEmpty,
              !normalizedIncomingText.isEmpty else {
            return nil
        }

        let shouldMergeForward = normalizedIncomingText.hasPrefix(normalizedPreviousText)
        let shouldMergeBackward = normalizedPreviousText.hasPrefix(normalizedIncomingText)

        if shouldMergeForward || shouldMergeBackward {
            let preferredText = incomingText.count >= previousSegment.text.count
                ? incomingText
                : previousSegment.text

            return TranscriptSegment(
                id: previousSegment.id,
                text: preferredText,
                timestamp: timestamp
            )
        }

        guard shouldMergeShortContinuation(
            previousText: previousSegment.text,
            incomingText: incomingText,
            timestamp: timestamp,
            previousTimestamp: previousSegment.timestamp
        ) else {
            return nil
        }

        let mergedContinuationText = mergedContinuationText(
            previousText: previousSegment.text,
            incomingText: incomingText
        )

        return TranscriptSegment(
            id: previousSegment.id,
            text: mergedContinuationText,
            timestamp: timestamp
        )
    }

    private func shouldMergeShortContinuation(
        previousText: String,
        incomingText: String,
        timestamp: Date,
        previousTimestamp: Date
    ) -> Bool {
        let continuationWindowSeconds: TimeInterval = 2.5
        guard timestamp.timeIntervalSince(previousTimestamp) <= continuationWindowSeconds else {
            return false
        }

        let trimmedPreviousText = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let continuationMarkers = ["—", "-", "…", "...", ":"]
        guard continuationMarkers.contains(where: { trimmedPreviousText.hasSuffix($0) }) else {
            return false
        }

        let incomingWordCount = incomingText.split(whereSeparator: \.isWhitespace).count
        return incomingText.count <= 48 || incomingWordCount <= 6
    }

    private func mergedContinuationText(previousText: String, incomingText: String) -> String {
        var previousTextWithoutMarker = previousText.trimmingCharacters(in: .whitespacesAndNewlines)

        if previousTextWithoutMarker.hasSuffix("...") {
            previousTextWithoutMarker.removeLast(3)
        } else if let finalCharacter = previousTextWithoutMarker.last,
                  ["—", "-", "…", ":"].contains(finalCharacter) {
            previousTextWithoutMarker.removeLast()
        }

        previousTextWithoutMarker = previousTextWithoutMarker.trimmingCharacters(in: .whitespacesAndNewlines)

        var incomingWords = incomingText.split(whereSeparator: \.isWhitespace).map(String.init)
        let previousWords = previousTextWithoutMarker.split(whereSeparator: \.isWhitespace).map(String.init)

        if let previousWord = previousWords.last?.lowercased(),
           let incomingWord = incomingWords.first?.lowercased(),
           previousWord == incomingWord {
            incomingWords.removeFirst()
        }

        let cleanedIncomingText = incomingWords.joined(separator: " ")
        guard !cleanedIncomingText.isEmpty else { return previousTextWithoutMarker }
        guard !previousTextWithoutMarker.isEmpty else { return cleanedIncomingText }

        return "\(previousTextWithoutMarker) \(cleanedIncomingText)"
    }
}

// MARK: - Array Subscript Helpers

private extension Array {

    /// Returns a slice for the given range, clamping to valid bounds.
    ///
    /// This avoids out-of-bounds crashes when the buffer is partially pruned
    /// and indices temporarily fall outside the current array bounds.
    subscript(safeRange range: Range<Int>) -> ArraySlice<Element> {
        let clampedLower = Swift.max(0, Swift.min(range.lowerBound, count))
        let clampedUpper = Swift.max(clampedLower, Swift.min(range.upperBound, count))
        return self[clampedLower..<clampedUpper]
    }

    subscript(safeRange range: PartialRangeFrom<Int>) -> ArraySlice<Element> {
        let clampedLower = Swift.max(0, Swift.min(range.lowerBound, count))
        return self[clampedLower...]
    }
}
