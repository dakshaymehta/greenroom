import Foundation
import Testing
@testable import Greenroom

struct GreenroomTests {

    @Test
    func transcriptBufferSeparatesNewTextFromContext() {
        let now = Date()
        let transcriptBuffer = TranscriptBuffer(maxStorageDurationSeconds: 600)

        transcriptBuffer.append("first segment", at: now.addingTimeInterval(-30))
        transcriptBuffer.append("second segment", at: now.addingTimeInterval(-15))
        transcriptBuffer.markTickBoundary()
        transcriptBuffer.append("third segment", at: now)

        let chunk = transcriptBuffer.extractChunk(contextWindowSeconds: 120)

        #expect(chunk.contextText == "first segment second segment")
        #expect(chunk.newText == "third segment")
    }

    @Test
    func transcriptBufferMatchesRecentSegmentUsingTriggerQuote() {
        let now = Date()
        let transcriptBuffer = TranscriptBuffer(maxStorageDurationSeconds: 600)

        let earlySegment = transcriptBuffer.append(
            "I think the moon landing happened in 1969.",
            at: now.addingTimeInterval(-20)
        )
        let latestSegment = transcriptBuffer.append(
            "Actually, the moon landing happened in July 1969 during Apollo 11.",
            at: now
        )

        let matchedSegment = transcriptBuffer.bestMatchingSegment(for: "moon landing happened in July 1969")

        #expect(matchedSegment?.id == latestSegment.id)
        #expect(matchedSegment?.id != earlySegment.id)
    }

    @Test
    func transcriptBufferMergesShortContinuationIntoPreviousSegment() {
        let now = Date()
        let transcriptBuffer = TranscriptBuffer(maxStorageDurationSeconds: 600)

        let firstSegment = transcriptBuffer.append(
            "advocates are hoping for—",
            at: now
        )
        let mergedSegment = transcriptBuffer.append(
            "For change.",
            at: now.addingTimeInterval(1)
        )

        #expect(mergedSegment.id == firstSegment.id)
        #expect(mergedSegment.text == "advocates are hoping for change.")
        #expect(transcriptBuffer.recentSegments().count == 1)
    }

    @Test
    func personaUpdateParserHandlesMarkdownWrappedJSON() {
        let wrappedJSON = """
        Here you go:

        ```json
        {
          "gary": {"trigger": "moon landing happened in July 1969", "text": "Correct — Apollo 11 landed on July 20, 1969.", "confidence": 0.99, "search_query": null},
          "fred": null,
          "jackie": null,
          "troll": null
        }
        ```
        """

        let personaUpdate = PersonaUpdateParser.parse(wrappedJSON)

        #expect(personaUpdate?.gary?.trigger == "moon landing happened in July 1969")
        #expect(personaUpdate?.gary?.text == "Correct — Apollo 11 landed on July 20, 1969.")
        #expect(personaUpdate?.fred == nil)
    }

    @MainActor
    @Test
    func transcriptContextStoreAddsPersonaHighlightsToMatchedSegment() {
        let now = Date()
        let transcriptBuffer = TranscriptBuffer(maxStorageDurationSeconds: 600)
        let transcriptContextStore = TranscriptContextStore()

        let firstSegment = transcriptBuffer.append(
            "The Great Wall is visible from space with the naked eye.",
            at: now
        )
        transcriptContextStore.append(firstSegment)

        let secondSegment = transcriptBuffer.append(
            "That myth gets repeated all the time on podcasts.",
            at: now.addingTimeInterval(5)
        )
        transcriptContextStore.append(secondSegment)

        let personaUpdate = PersonaUpdate(
            gary: GaryResponse(
                text: "That is a myth — the Great Wall is generally not visible to the naked eye from low Earth orbit.",
                confidence: 0.97,
                trigger: "Great Wall is visible from space",
                searchQuery: nil
            ),
            fred: nil,
            jackie: nil,
            troll: nil
        )

        transcriptContextStore.applyHighlights(for: personaUpdate, using: transcriptBuffer)

        let highlightedLine = transcriptContextStore.lines.first(where: { !$0.highlights.isEmpty })

        #expect(highlightedLine?.segment.id == firstSegment.id)
        #expect(highlightedLine?.highlights.first?.persona == .gary)
        #expect(transcriptContextStore.focusedSegmentID == firstSegment.id)
    }

    @MainActor
    @Test
    func transcriptContextStoreClearsLiveDraftWhenFinalTurnArrives() {
        let transcriptContextStore = TranscriptContextStore()
        let transcriptBuffer = TranscriptBuffer(maxStorageDurationSeconds: 600)

        transcriptContextStore.setLiveDraft(
            text: "The show is starting right now",
            turnOrder: 42
        )

        let committedSegment = transcriptBuffer.append("The show is starting right now")
        transcriptContextStore.appendFinal(committedSegment, turnOrder: 42)

        #expect(transcriptContextStore.liveDraft == nil)
        #expect(transcriptContextStore.lines.count == 1)
        #expect(transcriptContextStore.lines.first?.text == "The show is starting right now")
    }

    @Test
    func audioMixerFramesMicrophoneAudioIntoStablePackets() {
        let audioMixer = AudioMixer(outputSampleRate: 20, outputFrameDurationMilliseconds: 100)
        let frameReceived = DispatchSemaphore(value: 0)
        let captureQueue = DispatchQueue(label: "com.greenroom.tests.audiomixer.capture")
        var emittedFrames: [Data] = []

        audioMixer.onMixedAudio = { audioFrame in
            captureQueue.sync {
                emittedFrames.append(audioFrame)
            }
            frameReceived.signal()
        }

        audioMixer.receiveMicrophoneAudio(Self.pcm16Data(from: [1_200]))
        audioMixer.receiveMicrophoneAudio(Self.pcm16Data(from: [1_200]))

        let didReceiveFrame = frameReceived.wait(timeout: .now() + 1) == .success
        let capturedFrames = captureQueue.sync { emittedFrames }

        #expect(didReceiveFrame)
        #expect(capturedFrames.count == 1)
        #expect(capturedFrames.first?.count == 4)
        let firstFrame = capturedFrames.first
        #expect(firstFrame != nil)
        guard let firstFrame else { return }

        #expect(Self.pcm16Samples(from: firstFrame) == [1_200, 1_200])
    }

    @Test
    func audioMixerMixesAndClipsSamplesWhenSecondSourceIsPartial() {
        let audioMixer = AudioMixer(outputSampleRate: 20, outputFrameDurationMilliseconds: 100)
        let frameReceived = DispatchSemaphore(value: 0)
        let captureQueue = DispatchQueue(label: "com.greenroom.tests.audiomixer.clip")
        var emittedFrames: [Data] = []

        audioMixer.onMixedAudio = { audioFrame in
            captureQueue.sync {
                emittedFrames.append(audioFrame)
            }
            frameReceived.signal()
        }

        audioMixer.receiveSystemAudio(Self.pcm16Data(from: [30_000]))
        audioMixer.receiveMicrophoneAudio(Self.pcm16Data(from: [10_000]))
        audioMixer.receiveSystemAudio(Self.pcm16Data(from: [30_000]))

        let didReceiveFrame = frameReceived.wait(timeout: .now() + 1) == .success
        let capturedFrames = captureQueue.sync { emittedFrames }

        #expect(didReceiveFrame)
        #expect(capturedFrames.count == 1)
        let firstFrame = capturedFrames.first
        #expect(firstFrame != nil)
        guard let firstFrame else { return }

        #expect(Self.pcm16Samples(from: firstFrame) == [32_767, 30_000])
    }

    private static func pcm16Data(from samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func pcm16Samples(from audioData: Data) -> [Int16] {
        audioData.withUnsafeBytes { audioBytes in
            Array(audioBytes.bindMemory(to: Int16.self))
        }
    }

}
