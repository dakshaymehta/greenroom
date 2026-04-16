import Foundation

/// Combines system audio and microphone audio into one stable PCM16 stream for
/// the transcription provider.
///
/// AssemblyAI's streaming websocket expects binary audio packets that represent
/// a bounded span of time rather than arbitrary callback-sized blobs. The
/// capture engines produce chunks at different cadences, so the mixer buffers
/// both sources into fixed-duration frames and sums their samples together with
/// clipping. This keeps the websocket payload shape predictable and avoids
/// concatenating two independent audio timelines into one malformed stream.
final class AudioMixer {

    // MARK: - Constants

    private static let bytesPerSample = MemoryLayout<Int16>.size

    // MARK: - Properties

    /// Serializes access from both audio capture callbacks, which can fire on
    /// different background threads simultaneously.
    private let mixQueue = DispatchQueue(label: "com.greenroom.audiomixer", qos: .userInteractive)

    /// The exact byte size for each output frame sent downstream. At 16 kHz
    /// mono PCM16, 100 ms equals 3,200 bytes.
    private let outputFrameByteCount: Int

    /// Human-readable duration used for debug logging.
    private let outputFrameDurationMilliseconds: Int

    /// Reused zero-filled frame for silent / missing input.
    private let silenceFrame: Data

    private var systemAudioBuffer = Data()
    private var microphoneAudioBuffer = Data()
    private var emittedFrameCount = 0

    /// Called with each chunk of mixed audio data, ready to be sent to the transcription provider.
    var onMixedAudio: ((Data) -> Void)?

    // MARK: - Initialization

    init(
        outputSampleRate: Int = 16_000,
        outputFrameDurationMilliseconds: Int = 100
    ) {
        let samplesPerFrame = max(
            1,
            Int((Double(outputSampleRate) * Double(outputFrameDurationMilliseconds) / 1000.0).rounded())
        )

        self.outputFrameByteCount = samplesPerFrame * Self.bytesPerSample
        self.outputFrameDurationMilliseconds = outputFrameDurationMilliseconds
        self.silenceFrame = Data(repeating: 0, count: outputFrameByteCount)
    }

    // MARK: - Audio Input

    /// Receives a chunk of PCM s16le audio from the system audio capture engine.
    func receiveSystemAudio(_ data: Data) {
        enqueue(data, from: .system)
    }

    /// Receives a chunk of PCM s16le audio from the microphone capture engine.
    func receiveMicrophoneAudio(_ data: Data) {
        enqueue(data, from: .microphone)
    }

    /// Clears any buffered audio so a fresh listening session always starts from
    /// silence rather than replaying leftover partial frames.
    func reset() {
        mixQueue.async { [weak self] in
            self?.systemAudioBuffer.removeAll(keepingCapacity: true)
            self?.microphoneAudioBuffer.removeAll(keepingCapacity: true)
            self?.emittedFrameCount = 0
        }
    }

    // MARK: - Private

    private enum AudioSource {
        case system
        case microphone
    }

    private struct SourceFrame {
        let audioData: Data
        let contributingByteCount: Int

        var isSilent: Bool {
            contributingByteCount == 0
        }
    }

    private func enqueue(_ data: Data, from audioSource: AudioSource) {
        let pcmAlignedData: Data

        if data.count.isMultiple(of: Self.bytesPerSample) {
            pcmAlignedData = data
        } else {
            pcmAlignedData = data.dropLast()
        }

        guard !pcmAlignedData.isEmpty else { return }

        mixQueue.async { [weak self] in
            guard let self else { return }

            switch audioSource {
            case .system:
                self.systemAudioBuffer.append(pcmAlignedData)
            case .microphone:
                self.microphoneAudioBuffer.append(pcmAlignedData)
            }

            self.emitMixedFramesIfPossible()
        }
    }

    private func emitMixedFramesIfPossible() {
        while systemAudioBuffer.count >= outputFrameByteCount
            || microphoneAudioBuffer.count >= outputFrameByteCount {
            let systemFrame = dequeueNextFrame(from: &systemAudioBuffer)
            let microphoneFrame = dequeueNextFrame(from: &microphoneAudioBuffer)
            let mixedFrame = makeMixedFrame(systemFrame: systemFrame, microphoneFrame: microphoneFrame)

            if emittedFrameCount < 6 {
                print(
                    "[AudioMixer] Emitting \(outputFrameDurationMilliseconds)ms frame " +
                    "(system=\(systemFrame.contributingByteCount) bytes, mic=\(microphoneFrame.contributingByteCount) bytes)"
                )
            }
            emittedFrameCount += 1

            onMixedAudio?(mixedFrame)
        }
    }

    private func dequeueNextFrame(from buffer: inout Data) -> SourceFrame {
        guard !buffer.isEmpty else {
            return SourceFrame(audioData: silenceFrame, contributingByteCount: 0)
        }

        if buffer.count >= outputFrameByteCount {
            let frameData = Data(buffer.prefix(outputFrameByteCount))
            buffer.removeFirst(outputFrameByteCount)
            return SourceFrame(audioData: frameData, contributingByteCount: outputFrameByteCount)
        }

        let partialFrame = buffer
        buffer.removeAll(keepingCapacity: true)

        var paddedFrame = partialFrame
        paddedFrame.append(Data(repeating: 0, count: outputFrameByteCount - partialFrame.count))

        return SourceFrame(audioData: paddedFrame, contributingByteCount: partialFrame.count)
    }

    private func makeMixedFrame(systemFrame: SourceFrame, microphoneFrame: SourceFrame) -> Data {
        if systemFrame.isSilent {
            return microphoneFrame.audioData
        }

        if microphoneFrame.isSilent {
            return systemFrame.audioData
        }

        var mixedFrame = Data(count: outputFrameByteCount)

        mixedFrame.withUnsafeMutableBytes { outputBytes in
            let outputSamples = outputBytes.bindMemory(to: Int16.self)

            systemFrame.audioData.withUnsafeBytes { systemBytes in
                let systemSamples = systemBytes.bindMemory(to: Int16.self)

                microphoneFrame.audioData.withUnsafeBytes { microphoneBytes in
                    let microphoneSamples = microphoneBytes.bindMemory(to: Int16.self)

                    for sampleIndex in 0..<outputSamples.count {
                        let mixedSample = Int(systemSamples[sampleIndex]) + Int(microphoneSamples[sampleIndex])
                        outputSamples[sampleIndex] = clippedPCM16Sample(from: mixedSample)
                    }
                }
            }
        }

        return mixedFrame
    }

    private func clippedPCM16Sample(from mixedSample: Int) -> Int16 {
        let clampedSample = min(Int(Int16.max), max(Int(Int16.min), mixedSample))
        return Int16(clampedSample)
    }
}
