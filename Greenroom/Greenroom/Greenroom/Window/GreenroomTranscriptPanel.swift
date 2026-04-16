import AppKit
import SwiftUI

@MainActor
final class GreenroomTranscriptPanel: NSObject, NSWindowDelegate {

    private static let minimumWindowSize = NSSize(width: 520, height: 420)
    private static let defaultMaximumWindowWidth: CGFloat = 980
    private static let defaultMaximumWindowHeight: CGFloat = 780
    private static let horizontalScreenInset: CGFloat = 28
    private static let verticalScreenInset: CGFloat = 48
    private static let preferredWindowWidthRatio: CGFloat = 0.42
    private static let preferredWindowHeightRatio: CGFloat = 0.72

    private let transcriptContextStore: TranscriptContextStore
    private var transcriptWindow: NSWindow?
    var onVisibilityChanged: ((Bool) -> Void)?

    init(transcriptContextStore: TranscriptContextStore) {
        self.transcriptContextStore = transcriptContextStore
        super.init()
    }

    func show() {
        if transcriptWindow == nil {
            buildWindow()
        }

        constrainWindowToVisibleScreen()
        transcriptWindow?.makeKeyAndOrderFront(nil)
        onVisibilityChanged?(true)
    }

    func toggle() {
        if isVisible {
            transcriptWindow?.orderOut(nil)
            onVisibilityChanged?(false)
        } else {
            show()
        }
    }

    var isVisible: Bool {
        transcriptWindow?.isVisible == true
    }

    private func buildWindow() {
        let initialFrame = preferredWindowFrame(for: NSScreen.main)
        let transcriptWindow = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        transcriptWindow.title = "Transcript Viewer"
        transcriptWindow.minSize = Self.minimumWindowSize
        transcriptWindow.isRestorable = false
        let restoredFrame = transcriptWindow.setFrameAutosaveName("GreenroomTranscriptWindow")
        transcriptWindow.tabbingMode = .disallowed
        transcriptWindow.titleVisibility = .hidden
        transcriptWindow.titlebarAppearsTransparent = true
        transcriptWindow.toolbarStyle = .unifiedCompact
        transcriptWindow.delegate = self

        if !restoredFrame {
            transcriptWindow.center()
        }

        var constrainedFrame = transcriptWindow.frame
        constrainWindowFrame(&constrainedFrame)
        transcriptWindow.setFrame(constrainedFrame, display: false)

        let hostingController = NSHostingController(
            rootView: TranscriptViewerView(transcriptContextStore: transcriptContextStore)
        )
        transcriptWindow.contentViewController = hostingController

        self.transcriptWindow = transcriptWindow
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        constrainWindowToVisibleScreen()
    }

    private func preferredWindowFrame(for screen: NSScreen?) -> NSRect {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(
            x: 0,
            y: 0,
            width: 760,
            height: 780
        )

        let insetVisibleFrame = visibleFrame.insetBy(
            dx: Self.horizontalScreenInset,
            dy: Self.verticalScreenInset
        )

        let targetWidth = min(
            max(
                insetVisibleFrame.width * Self.preferredWindowWidthRatio,
                Self.minimumWindowSize.width
            ),
            min(insetVisibleFrame.width, Self.defaultMaximumWindowWidth)
        )
        let targetHeight = min(
            max(
                insetVisibleFrame.height * Self.preferredWindowHeightRatio,
                Self.minimumWindowSize.height
            ),
            min(insetVisibleFrame.height, Self.defaultMaximumWindowHeight)
        )

        return NSRect(
            x: insetVisibleFrame.midX - (targetWidth / 2),
            y: insetVisibleFrame.midY - (targetHeight / 2),
            width: targetWidth,
            height: targetHeight
        )
    }

    private func constrainWindowToVisibleScreen() {
        guard let transcriptWindow else { return }

        var updatedFrame = transcriptWindow.frame
        constrainWindowFrame(&updatedFrame, screen: transcriptWindow.screen)

        guard updatedFrame != transcriptWindow.frame else { return }
        transcriptWindow.setFrame(updatedFrame, display: true, animate: false)
    }

    private func constrainWindowFrame(_ frame: inout NSRect, screen: NSScreen? = nil) {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? frame

        let maximumWidth = max(
            Self.minimumWindowSize.width,
            visibleFrame.width - (Self.horizontalScreenInset * 2)
        )
        let maximumHeight = max(
            Self.minimumWindowSize.height,
            visibleFrame.height - (Self.verticalScreenInset * 2)
        )

        frame.size.width = min(max(frame.width, Self.minimumWindowSize.width), maximumWidth)
        frame.size.height = min(max(frame.height, Self.minimumWindowSize.height), maximumHeight)

        let minimumAllowedX = visibleFrame.minX + Self.horizontalScreenInset
        let maximumAllowedX = visibleFrame.maxX - Self.horizontalScreenInset - frame.width
        let minimumAllowedY = visibleFrame.minY + Self.verticalScreenInset
        let maximumAllowedY = visibleFrame.maxY - Self.verticalScreenInset - frame.height

        frame.origin.x = max(minimumAllowedX, min(frame.origin.x, maximumAllowedX))
        frame.origin.y = max(minimumAllowedY, min(frame.origin.y, maximumAllowedY))
    }
}

private struct TranscriptViewerView: View {

    @ObservedObject var transcriptContextStore: TranscriptContextStore
    private let liveDraftScrollAnchorID = "live-transcript-draft"

    var body: some View {
        GeometryReader { geometry in
            let layout = TranscriptViewerLayout(for: geometry.size)

            VStack(spacing: 0) {
                header(layout: layout)
                Divider()
                    .overlay(Color.white.opacity(0.06))
                transcriptFeed(layout: layout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.06, blue: 0.08),
                        Color(red: 0.03, green: 0.03, blue: 0.04),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private func header(layout: TranscriptViewerLayout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcript Context")
                .font(.system(size: layout.titleFontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Live transcript with persona-aware context highlights so you can see exactly what Gary, Fred, Jackie, and the Troll reacted to.")
                .font(.system(size: layout.subtitleFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: layout.legendSpacing) {
                ForEach(PersonaIdentity.allCases, id: \.self) { persona in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(persona.accentColor)
                            .frame(width: 7, height: 7)

                        Text(persona.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05), in: Capsule())
                }
            }
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.vertical, layout.headerVerticalPadding)
    }

    @ViewBuilder
    private func transcriptFeed(layout: TranscriptViewerLayout) -> some View {
        if transcriptContextStore.lines.isEmpty && transcriptContextStore.liveDraft == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Waiting for live audio")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Transcript lines appear here as soon as AssemblyAI starts returning turns. Persona reaction cards stay attached to the exact lines they picked up.")
                    .font(.system(size: layout.subtitleFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(layout.feedPadding + 6)
        } else {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(transcriptContextStore.lines) { line in
                            TranscriptLineRow(
                                line: line,
                                isFocused: line.id == transcriptContextStore.focusedSegmentID,
                                layout: layout
                            )
                            .id(line.id)
                        }

                        if let liveDraft = transcriptContextStore.liveDraft {
                            TranscriptLiveDraftRow(liveDraft: liveDraft, layout: layout)
                                .id(liveDraftScrollAnchorID)
                        }
                    }
                    .padding(layout.feedPadding)
                }
                .onAppear {
                    scrollToLatestTranscript(using: scrollProxy)
                }
                .onChange(of: transcriptContextStore.focusedSegmentID) { _, _ in
                    scrollToFocusedSegment(using: scrollProxy)
                }
                .onChange(of: transcriptContextStore.liveDraft?.text) { _, _ in
                    scrollToLatestTranscript(using: scrollProxy)
                }
                .onChange(of: transcriptContextStore.lines.last?.text) { _, _ in
                    scrollToLatestTranscript(using: scrollProxy)
                }
            }
        }
    }

    private func scrollToLatestTranscript(using scrollProxy: ScrollViewProxy) {
        if transcriptContextStore.liveDraft != nil {
            withAnimation(.easeOut(duration: 0.22)) {
                scrollProxy.scrollTo(liveDraftScrollAnchorID, anchor: .bottom)
            }
            return
        }

        if let lastLineID = transcriptContextStore.lines.last?.id {
            withAnimation(.easeOut(duration: 0.22)) {
                scrollProxy.scrollTo(lastLineID, anchor: .bottom)
            }
        }
    }

    private func scrollToFocusedSegment(using scrollProxy: ScrollViewProxy) {
        guard let focusedSegmentID = transcriptContextStore.focusedSegmentID else {
            scrollToLatestTranscript(using: scrollProxy)
            return
        }

        if transcriptContextStore.liveDraft != nil
            || isFocusedSegmentNearLiveEdge(focusedSegmentID) {
            scrollToLatestTranscript(using: scrollProxy)
            return
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            scrollProxy.scrollTo(focusedSegmentID, anchor: .center)
        }
    }

    private func isFocusedSegmentNearLiveEdge(_ focusedSegmentID: UUID) -> Bool {
        guard let focusedIndex = transcriptContextStore.lines.firstIndex(where: { $0.id == focusedSegmentID }) else {
            return false
        }

        let lastPinnedIndex = max(transcriptContextStore.lines.count - 3, 0)
        return focusedIndex >= lastPinnedIndex
    }
}

private struct TranscriptLineRow: View {

    let line: TranscriptContextStore.Line
    let isFocused: Bool
    let layout: TranscriptViewerLayout

    private var latestHighlight: TranscriptContextStore.Highlight? {
        line.highlights.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if layout.usesStackedLineLayout {
                VStack(alignment: .leading, spacing: 8) {
                    timestampLabel(width: nil)
                    lineText
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    timestampLabel(width: layout.timestampColumnWidth)
                    lineText
                }
            }

            if !line.highlights.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(line.highlights) { highlight in
                        TranscriptHighlightCard(highlight: highlight, layout: layout)
                    }
                }
                .padding(.leading, layout.highlightLeadingInset)
            }
        }
        .padding(.horizontal, layout.rowHorizontalPadding)
        .padding(.vertical, layout.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: layout.rowCornerRadius, style: .continuous))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill((latestHighlight?.persona.accentColor ?? Color.clear))
                .frame(width: 3)
                .padding(.vertical, 8)
                .opacity(line.highlights.isEmpty ? 0 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: layout.rowCornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 1.4 : 1)
        }
        .shadow(color: shadowColor, radius: isFocused ? 18 : 0, y: 10)
    }

    private func timestampLabel(width: CGFloat?) -> some View {
        Text(line.timestamp.formatted(date: .omitted, time: .standard))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.45))
            .frame(width: width, alignment: .leading)
    }

    private var lineText: some View {
        Text(line.text)
            .font(.system(size: layout.lineFontSize, weight: .regular, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backgroundColor: Color {
        if let latestHighlight {
            return latestHighlight.persona.accentColor.opacity(isFocused ? 0.14 : 0.08)
        }

        return Color.white.opacity(0.035)
    }

    private var borderColor: Color {
        if let latestHighlight {
            return latestHighlight.persona.accentColor.opacity(isFocused ? 0.7 : 0.32)
        }

        return Color.white.opacity(0.06)
    }

    private var shadowColor: Color {
        guard let latestHighlight, isFocused else { return .clear }
        return latestHighlight.persona.accentColor.opacity(0.22)
    }
}

private struct TranscriptHighlightCard: View {

    let highlight: TranscriptContextStore.Highlight
    let layout: TranscriptViewerLayout

    private var sourceSummary: String? {
        guard highlight.persona == .gary else { return nil }

        if let sourceNote = highlight.sourceNote,
           !sourceNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourceNote
        }

        guard !highlight.sources.isEmpty else { return nil }
        return "\(highlight.sources.count) source\(highlight.sources.count == 1 ? "" : "s")"
    }

    private var verdictLabel: String? {
        guard let verdict = highlight.verdict?.trimmingCharacters(in: .whitespacesAndNewlines),
              !verdict.isEmpty else {
            return nil
        }

        return verdict.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: layout.highlightMetaSpacing) {
                HStack(spacing: 8) {
                    Text(highlight.persona.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))

                    if let verdictLabel {
                        Text(verdictLabel)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(highlight.persona.accentColor.opacity(0.88))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(highlight.persona.accentColor.opacity(0.13), in: Capsule())
                    }
                }

                if let sourceSummary {
                    Text(sourceSummary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(highlight.reactionText)
                .font(.system(size: layout.highlightReactionFontSize, weight: .regular, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            Text("Picked up \"\(highlight.trigger)\"")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(2)
        }
        .padding(.horizontal, layout.highlightCardHorizontalPadding)
        .padding(.vertical, layout.highlightCardVerticalPadding)
        .background(highlight.persona.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: layout.highlightCardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: layout.highlightCardCornerRadius, style: .continuous)
                .strokeBorder(highlight.persona.accentColor.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct TranscriptLiveDraftRow: View {

    let liveDraft: TranscriptContextStore.LiveDraft
    let layout: TranscriptViewerLayout

    var body: some View {
        Group {
            if layout.usesStackedLineLayout {
                VStack(alignment: .leading, spacing: 8) {
                    timestampLabel(width: nil)
                    draftText
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    timestampLabel(width: layout.timestampColumnWidth)
                    draftText
                }
            }
        }
        .padding(.horizontal, layout.rowHorizontalPadding)
        .padding(.vertical, max(12, layout.rowVerticalPadding - 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: layout.rowCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: layout.rowCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        }
    }

    private func timestampLabel(width: CGFloat?) -> some View {
        Text(liveDraft.timestamp.formatted(date: .omitted, time: .standard))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.38))
            .frame(width: width, alignment: .leading)
    }

    private var draftText: some View {
        Text(liveDraft.text)
            .font(.system(size: layout.lineFontSize, weight: .regular, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptViewerLayout {

    let size: CGSize

    init(for size: CGSize) {
        self.size = size
    }

    var isCompactWidth: Bool {
        size.width < 680
    }

    var usesStackedLineLayout: Bool {
        size.width < 760
    }

    var titleFontSize: CGFloat {
        isCompactWidth ? 21 : 24
    }

    var subtitleFontSize: CGFloat {
        isCompactWidth ? 12 : 13
    }

    var headerHorizontalPadding: CGFloat {
        isCompactWidth ? 18 : 22
    }

    var headerVerticalPadding: CGFloat {
        isCompactWidth ? 16 : 18
    }

    var legendSpacing: CGFloat {
        isCompactWidth ? 6 : 8
    }

    var feedPadding: CGFloat {
        isCompactWidth ? 14 : 18
    }

    var rowHorizontalPadding: CGFloat {
        isCompactWidth ? 14 : 18
    }

    var rowVerticalPadding: CGFloat {
        isCompactWidth ? 14 : 16
    }

    var timestampColumnWidth: CGFloat {
        82
    }

    var highlightLeadingInset: CGFloat {
        usesStackedLineLayout ? 0 : 96
    }

    var rowCornerRadius: CGFloat {
        isCompactWidth ? 16 : 18
    }

    var lineFontSize: CGFloat {
        isCompactWidth ? 14 : 15
    }

    var highlightReactionFontSize: CGFloat {
        isCompactWidth ? 12 : 12.5
    }

    var highlightMetaSpacing: CGFloat {
        isCompactWidth ? 4 : 6
    }

    var highlightCardHorizontalPadding: CGFloat {
        isCompactWidth ? 10 : 12
    }

    var highlightCardVerticalPadding: CGFloat {
        isCompactWidth ? 8 : 10
    }

    var highlightCardCornerRadius: CGFloat {
        isCompactWidth ? 12 : 14
    }
}

private struct FlowLayout: Layout {

    let spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX > 0 && currentX + size.width > maxWidth {
                totalHeight += currentRowHeight + spacing
                maxRowWidth = max(maxRowWidth, currentX - spacing)
                currentX = 0
                currentRowHeight = 0
            }

            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }

        maxRowWidth = max(maxRowWidth, max(0, currentX - spacing))
        totalHeight += currentRowHeight

        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var cursor = CGPoint(x: bounds.minX, y: bounds.minY)
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if cursor.x > bounds.minX && cursor.x + size.width > bounds.maxX {
                cursor.x = bounds.minX
                cursor.y += currentRowHeight + spacing
                currentRowHeight = 0
            }

            subview.place(
                at: cursor,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            cursor.x += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}

private extension PersonaIdentity {

    var accentColor: Color {
        switch self {
        case .gary:
            return Color(red: 0.29, green: 0.62, blue: 1.0)
        case .fred:
            return Color(red: 0.29, green: 0.87, blue: 0.5)
        case .jackie:
            return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .troll:
            return Color(red: 0.97, green: 0.44, blue: 0.44)
        }
    }
}
