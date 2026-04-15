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

    /// A single piece of transcribed text with the timestamp it arrived.
    private struct TimestampedText {
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
    private var segments: [TimestampedText] = []

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
    func append(_ text: String, at timestamp: Date = Date()) {
        let segment = TimestampedText(text: text, timestamp: timestamp)
        segments.append(segment)
        pruneOldSegments()
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
