import CoreMedia
import Foundation

/// Wires the full audio-to-AI pipeline: system audio and microphone feed into
/// a mixer, the mixer feeds the transcription provider, and transcription text
/// drives the GreenroomEngine tick loop.
///
/// The coordinator is the single place where all these subsystems connect.
/// Nothing in the audio layer knows about transcription, and nothing in the
/// transcription layer knows about the AI engine — the coordinator owns those
/// seams.
@MainActor
final class GreenroomCoordinator {

    // MARK: - Subsystems

    let engine = GreenroomEngine()
    let systemAudioCaptureEngine = SystemAudioCaptureEngine()
    let microphoneCaptureEngine = MicrophoneCaptureEngine()
    let audioMixer = AudioMixer()
    let transcriptionProvider = AssemblyAIProvider()

    // MARK: - State

    private var isListening = false

    // MARK: - Listening Lifecycle

    /// Connects every subsystem and begins the audio → transcription → AI pipeline.
    ///
    /// The startup order matters:
    /// 1. Validate configuration (worker URL must be set).
    /// 2. Wire data-flow closures so audio has somewhere to go before we start capturing.
    /// 3. Start the transcription WebSocket (needs the worker URL for token fetch).
    /// 4. Start audio capture engines (they immediately produce data).
    /// 5. Start the AI tick loop last, once transcript text can flow in.
    func startListening() async {
        guard !isListening else { return }
        isListening = true

        let workerBaseURL = UserDefaults.standard.string(forKey: "workerBaseURL") ?? ""
        if workerBaseURL.isEmpty {
            engine.bridge?.setErrorStatus("Set your Worker URL in Settings to get started")
            isListening = false
            return
        }

        // Wire audio mixer output → transcription provider input.
        audioMixer.onMixedAudio = { [weak self] audioData in
            self?.transcriptionProvider.feedAudio(audioData)
        }

        // Wire system audio capture → format conversion → mixer.
        systemAudioCaptureEngine.onAudioBuffer = { [weak self] sampleBuffer in
            guard let convertedData = AudioFormatConverter.convertCMSampleBufferToPCM16Data(sampleBuffer: sampleBuffer) else {
                return
            }
            self?.audioMixer.receiveSystemAudio(convertedData)
        }

        // Wire microphone capture → mixer (mic data is already PCM s16le).
        microphoneCaptureEngine.onAudioData = { [weak self] data in
            self?.audioMixer.receiveMicrophoneAudio(data)
        }

        // Notify the bridge if either audio source drops out mid-session.
        systemAudioCaptureEngine.onStreamLost = { [weak self] in
            self?.engine.bridge?.setErrorStatus("System audio lost — running on mic only")
        }
        microphoneCaptureEngine.onStreamLost = { [weak self] in
            self?.engine.bridge?.setErrorStatus("Microphone lost — running on system audio only")
        }

        // Start the transcription WebSocket. This must succeed before audio capture
        // begins, otherwise we'd be dropping audio frames with nowhere to send them.
        do {
            try await transcriptionProvider.start(
                workerBaseURL: workerBaseURL,
                onText: { [weak self] text in
                    self?.engine.onTranscriptText(text)
                },
                onError: { error in
                    print("[GreenroomCoordinator] Transcription error: \(error)")
                }
            )
        } catch {
            print("[GreenroomCoordinator] Failed to start transcription: \(error)")
            engine.bridge?.setErrorStatus("Transcription failed to connect: \(error.localizedDescription)")
            isListening = false
            return
        }

        // Start system audio capture. Failure here is non-fatal — we can still
        // transcribe from the microphone alone.
        do {
            try await systemAudioCaptureEngine.start()
        } catch {
            print("[GreenroomCoordinator] System audio capture failed (continuing with mic only): \(error)")
        }

        // Start microphone capture. Also non-fatal — system audio alone is usable.
        do {
            try microphoneCaptureEngine.start()
        } catch {
            print("[GreenroomCoordinator] Microphone capture failed (continuing with system audio only): \(error)")
        }

        // Everything is wired and streaming — kick off the AI tick loop.
        engine.start()
    }

    /// Tears down every subsystem in reverse order of startup.
    func stopListening() async {
        isListening = false
        engine.stop()
        transcriptionProvider.stop()
        await systemAudioCaptureEngine.stop()
        microphoneCaptureEngine.stop()
    }
}
