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
        let pcm16AudioConverter = PCM16AudioConverter(targetSampleRate: 16_000)
        let audioDataHandler = onAudioData

        // Use the input node's native format for the tap — AVAudioEngine requires this.
        // Requesting a different sample rate (e.g. 16kHz when hardware runs at 24kHz)
        // causes "Format mismatch" + "Failed to create tap" errors.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        print("[MicrophoneCaptureEngine] Hardware format: \(hardwareFormat)")

        // Tap at the hardware's native format, then convert each buffer directly
        // into the exact PCM16 mono stream the websocket expects.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, _ in
            guard let pcmData = pcm16AudioConverter.convertToPCM16Data(from: buffer) else {
                return
            }

            audioDataHandler?(pcmData)
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
