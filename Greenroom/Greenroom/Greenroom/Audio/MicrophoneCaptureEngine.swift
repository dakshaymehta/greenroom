import AVFoundation

/// Captures microphone audio via AVAudioEngine and delivers it as raw PCM s16le bytes.
///
/// We install a tap on the input node rather than using AVAudioRecorder because the
/// tap approach gives us fine-grained control over the output format. Downsampling
/// to 16 kHz mono here (rather than after the fact) keeps the byte stream small
/// and matches AssemblyAI's preferred input format exactly.
@MainActor
final class MicrophoneCaptureEngine {

    // MARK: - Properties

    private let audioEngine = AVAudioEngine()

    /// Called on the main actor with each chunk of PCM s16le audio data from the microphone.
    var onAudioData: ((Data) -> Void)?

    /// Called when the audio engine stops unexpectedly — e.g. the audio device
    /// is disconnected or the system routes audio away from the current input.
    var onStreamLost: (() -> Void)?

    // MARK: - Start

    /// Installs a tap on the microphone input and starts the audio engine.
    ///
    /// AVAudioEngine cannot resample arbitrarily in a tap — the tap format must
    /// match the input node's output format. We capture at the hardware's native
    /// rate and use an AVAudioConverter to downsample to 16 kHz mono for AssemblyAI.
    ///
    /// Throws if the engine cannot be prepared — most commonly because no input
    /// device is available (e.g. the user is on a Mac Pro with no microphone).
    func start() throws {
        let inputNode = audioEngine.inputNode

        // Use the input node's native format for the tap — AVAudioEngine requires this.
        // Requesting a different sample rate (e.g. 16kHz when hardware runs at 24kHz)
        // causes "Format mismatch" + "Failed to create tap" errors.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        print("[MicrophoneCaptureEngine] Hardware format: \(hardwareFormat)")

        // Build our target format: 16 kHz mono Float32 for AssemblyAI.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw MicrophoneCaptureError.formatCreationFailed
        }

        // Create a converter from hardware format → 16 kHz mono.
        guard let audioConverter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.converterCreationFailed
        }

        // Tap at the hardware's native format, then convert each buffer.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Allocate an output buffer at 16 kHz. The frame capacity is scaled down
            // proportionally to the sample rate ratio.
            let sampleRateRatio = 16000.0 / hardwareFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio)

            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
                return
            }

            // Convert from hardware rate to 16 kHz.
            var conversionError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            audioConverter.convert(to: convertedBuffer, error: &conversionError, withInputFrom: inputBlock)

            if let conversionError {
                print("[MicrophoneCaptureEngine] Conversion error: \(conversionError)")
                return
            }

            guard let pcmData = AudioFormatConverter.convertAVAudioPCMBufferToPCM16Data(pcmBuffer: convertedBuffer) else {
                return
            }

            Task { @MainActor in
                self.onAudioData?(pcmData)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        print("[MicrophoneCaptureEngine] Started — capturing at \(hardwareFormat.sampleRate) Hz, converting to 16 kHz")
    }

    // MARK: - Stop

    /// Removes the audio tap and stops the engine.
    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }
}

// MARK: - Errors

private enum MicrophoneCaptureError: Error, LocalizedError {

    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .formatCreationFailed:
            return "Failed to create the target audio format for microphone capture."
        case .converterCreationFailed:
            return "Failed to create an audio converter from the hardware format to 16 kHz."
        }
    }
}
