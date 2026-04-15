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
    /// We request a 16 kHz mono Float32 format from the tap, then convert each
    /// buffer to PCM s16le before forwarding it. AVAudioEngine's built-in format
    /// conversion handles any necessary resampling from the hardware's native rate.
    ///
    /// Throws if the engine cannot be prepared — most commonly because no input
    /// device is available (e.g. the user is on a Mac Pro with no microphone).
    func start() throws {
        let inputNode = audioEngine.inputNode

        // We target 16 kHz mono Float32 non-interleaved. AVAudioEngine will resample
        // from the hardware's native sample rate (typically 44.1 or 48 kHz) to 16 kHz
        // automatically when the tap format differs from the hardware format.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            // This should never fail for standard PCM formats, but we throw to
            // surface the failure rather than silently capturing nothing.
            throw MicrophoneCaptureError.formatCreationFailed
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: targetFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            guard let pcmData = AudioFormatConverter.convertAVAudioPCMBufferToPCM16Data(pcmBuffer: buffer) else {
                return
            }

            // The tap callback fires on an internal AVAudioEngine thread.
            // Hop to the main actor so callers can safely update UI from onAudioData.
            Task { @MainActor in
                self.onAudioData?(pcmData)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
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

    var errorDescription: String? {
        return "Failed to create the target audio format for microphone capture."
    }
}
