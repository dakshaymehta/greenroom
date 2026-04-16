import Combine
import Foundation
import SwiftUI

@MainActor
final class TranscriptContextStore: ObservableObject {

    struct Highlight: Identifiable, Equatable {
        let id = UUID()
        let persona: PersonaIdentity
        let trigger: String
        let reactionText: String
        let verdict: String?
        let sourceNote: String?
        let sources: [GarySource]
        let matchedAt: Date
    }

    struct Line: Identifiable, Equatable {
        let segment: TranscriptBuffer.TranscriptSegment
        var highlights: [Highlight]

        var id: UUID { segment.id }
        var text: String { segment.text }
        var timestamp: Date { segment.timestamp }
    }

    struct LiveDraft: Equatable {
        let text: String
        let timestamp: Date
        let turnOrder: Int?
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var focusedSegmentID: UUID?
    @Published private(set) var liveDraft: LiveDraft?

    private let maximumVisibleLines: Int

    init(maximumVisibleLines: Int = 200) {
        self.maximumVisibleLines = maximumVisibleLines
    }

    func append(_ segment: TranscriptBuffer.TranscriptSegment) {
        appendFinal(segment, turnOrder: nil)
    }

    func appendFinal(_ segment: TranscriptBuffer.TranscriptSegment, turnOrder: Int?) {
        if let existingLineIndex = lines.firstIndex(where: { $0.segment.id == segment.id }) {
            let existingHighlights = lines[existingLineIndex].highlights
            lines[existingLineIndex] = Line(segment: segment, highlights: existingHighlights)
        } else {
            lines.append(Line(segment: segment, highlights: []))
        }

        trimVisibleLinesIfNeeded()
        clearLiveDraftIfCommitted(segment: segment, turnOrder: turnOrder)
    }

    func setLiveDraft(text: String, turnOrder: Int?, at timestamp: Date = Date()) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        liveDraft = LiveDraft(
            text: trimmedText,
            timestamp: timestamp,
            turnOrder: turnOrder
        )
    }

    func clearLiveDraft() {
        liveDraft = nil
    }

    func transcriptPreviewText(maximumCommittedLines: Int = 2) -> String {
        var previewComponents = lines.suffix(maximumCommittedLines).map(\.text)

        if let liveDraft {
            if previewComponents.last != liveDraft.text {
                previewComponents.append(liveDraft.text)
            }
        }

        return previewComponents
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func snapshot(maximumVisibleLines: Int = 80) -> TranscriptContextSnapshot {
        let visibleLines = Array(lines.suffix(maximumVisibleLines))

        return TranscriptContextSnapshot(
            lines: visibleLines.map { line in
                TranscriptContextLinePayload(
                    id: line.id.uuidString,
                    text: line.text,
                    timestamp: line.timestamp.timeIntervalSince1970,
                    highlights: line.highlights.map { highlight in
                        TranscriptContextHighlightPayload(
                            id: highlight.id.uuidString,
                            persona: highlight.persona.rawValue,
                            displayName: highlight.persona.displayName,
                            trigger: highlight.trigger,
                            matchedAt: highlight.matchedAt.timeIntervalSince1970,
                            reactionText: highlight.reactionText,
                            verdict: highlight.verdict,
                            sourceNote: highlight.sourceNote,
                            sources: highlight.sources
                        )
                    }
                )
            },
            focusedSegmentID: focusedSegmentID?.uuidString,
            liveDraft: liveDraft.map {
                TranscriptContextLiveDraftPayload(
                    text: $0.text,
                    timestamp: $0.timestamp.timeIntervalSince1970,
                    turnOrder: $0.turnOrder
                )
            }
        )
    }

    func applyHighlights(for update: PersonaUpdate, using transcriptBuffer: TranscriptBuffer) {
        let now = Date()

        for highlightInput in update.highlightInputs {
            guard let matchedSegment = transcriptBuffer.bestMatchingSegment(for: highlightInput.trigger),
                  let lineIndex = lines.firstIndex(where: { $0.segment.id == matchedSegment.id }) else {
                continue
            }

            let highlight = Highlight(
                persona: highlightInput.persona,
                trigger: highlightInput.trigger,
                reactionText: highlightInput.reactionText,
                verdict: highlightInput.verdict,
                sourceNote: highlightInput.sourceNote,
                sources: highlightInput.sources,
                matchedAt: now
            )

            var updatedHighlights = lines[lineIndex].highlights
            updatedHighlights.removeAll(where: { $0.persona == highlightInput.persona })
            updatedHighlights.append(highlight)
            updatedHighlights.sort { $0.matchedAt < $1.matchedAt }

            lines[lineIndex].highlights = updatedHighlights
            focusedSegmentID = matchedSegment.id
        }
    }

    private func trimVisibleLinesIfNeeded() {
        if lines.count > maximumVisibleLines {
            lines.removeFirst(lines.count - maximumVisibleLines)
        }
    }

    private func clearLiveDraftIfCommitted(
        segment: TranscriptBuffer.TranscriptSegment,
        turnOrder: Int?
    ) {
        guard let liveDraft else { return }

        if let turnOrder,
           liveDraft.turnOrder == turnOrder {
            self.liveDraft = nil
            return
        }

        let normalizedDraftText = normalizedText(liveDraft.text)
        let normalizedCommittedText = normalizedText(segment.text)

        guard !normalizedDraftText.isEmpty,
              !normalizedCommittedText.isEmpty else {
            return
        }

        if normalizedCommittedText.hasPrefix(normalizedDraftText)
            || normalizedDraftText.hasPrefix(normalizedCommittedText) {
            self.liveDraft = nil
        }
    }

    private func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
