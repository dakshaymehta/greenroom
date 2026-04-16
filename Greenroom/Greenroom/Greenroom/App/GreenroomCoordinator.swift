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
    private var activeWorkerBaseURL: String?
    private var isRecoveringTranscription = false

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
        audioMixer.reset()

        let workerBaseURL = WorkerURLNormalizer.normalize(
            UserDefaults.standard.string(forKey: "workerBaseURL")
        )
        if workerBaseURL.isEmpty {
            engine.bridge?.setErrorStatus("Set your Worker URL in Settings to get started")
            isListening = false
            return
        }

        let audioMixer = self.audioMixer
        let transcriptionProvider = self.transcriptionProvider

        // Wire audio mixer output → transcription provider input.
        audioMixer.onMixedAudio = { audioData in
            transcriptionProvider.feedAudio(audioData)
        }

        // Wire normalized system audio → mixer.
        systemAudioCaptureEngine.onAudioData = { audioData in
            audioMixer.receiveSystemAudio(audioData)
        }

        // Wire microphone capture → mixer (mic data is already normalized PCM16).
        microphoneCaptureEngine.onAudioData = { audioData in
            audioMixer.receiveMicrophoneAudio(audioData)
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
            try await startTranscriptionSession(workerBaseURL: workerBaseURL)
        } catch {
            print("[GreenroomCoordinator] Failed to start transcription: \(error)")
            engine.bridge?.setErrorStatus("Transcription failed to connect: \(error.localizedDescription)")
            activeWorkerBaseURL = nil
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
        activeWorkerBaseURL = workerBaseURL
        engine.start()
    }

    /// Tears down every subsystem in reverse order of startup.
    ///
    /// Transcript state is purged at the end so a stopped session doesn't keep
    /// the user's speech resident in memory, and so a subsequent `startListening`
    /// begins from a clean slate without replaying prior context to the AI.
    func stopListening() async {
        isListening = false
        activeWorkerBaseURL = nil
        engine.stop()
        transcriptionProvider.stop()
        audioMixer.reset()
        await systemAudioCaptureEngine.stop()
        microphoneCaptureEngine.stop()
        engine.clearAllTranscriptState()
    }

    /// Re-applies persisted settings that affect the live pipeline without
    /// requiring the user to relaunch the app after editing Settings.
    func refreshListeningConfiguration() async {
        let configuredWorkerBaseURL = WorkerURLNormalizer.normalize(
            UserDefaults.standard.string(forKey: "workerBaseURL")
        )

        engine.refreshTimingConfiguration()

        guard !configuredWorkerBaseURL.isEmpty else {
            if isListening {
                await stopListening()
            }
            engine.bridge?.setErrorStatus("Set your Worker URL in Settings to get started")
            return
        }

        if isListening, configuredWorkerBaseURL == activeWorkerBaseURL {
            return
        }

        if isListening {
            await stopListening()
        }

        await startListening()
    }

    // MARK: - Transcription Recovery

    private func startTranscriptionSession(workerBaseURL: String) async throws {
        try await transcriptionProvider.start(
            workerBaseURL: workerBaseURL,
            onUpdate: { [weak self] update in
                self?.engine.onTranscriptionUpdate(update)
            },
            onError: { [weak self] error in
                print("[GreenroomCoordinator] Transcription error: \(error)")

                Task { @MainActor [weak self] in
                    await self?.recoverFromTranscriptionDrop(error)
                }
            }
        )
    }

    private func recoverFromTranscriptionDrop(_ error: Error) async {
        guard isListening else { return }
        guard !isRecoveringTranscription else { return }

        let workerBaseURL = activeWorkerBaseURL ?? WorkerURLNormalizer.normalize(
            UserDefaults.standard.string(forKey: "workerBaseURL")
        )
        guard !workerBaseURL.isEmpty else {
            await shutDownAfterTranscriptionFailure(
                message: "Transcription disconnected — add your Worker URL and try again"
            )
            return
        }

        isRecoveringTranscription = true
        defer { isRecoveringTranscription = false }

        engine.clearLiveTranscriptDraft()
        engine.bridge?.setErrorStatus("Transcription connection dropped — reconnecting...")

        for attempt in 1...3 {
            transcriptionProvider.stop()

            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(600 * attempt))
            }

            do {
                try await startTranscriptionSession(workerBaseURL: workerBaseURL)
                engine.bridge?.setLiveStatus(true)
                return
            } catch {
                print("[GreenroomCoordinator] Reconnect attempt \(attempt) failed: \(error)")
            }
        }

        await shutDownAfterTranscriptionFailure(
            message: "Transcription disconnected — press play again to reconnect"
        )
    }

    private func shutDownAfterTranscriptionFailure(message: String) async {
        isListening = false
        activeWorkerBaseURL = nil
        transcriptionProvider.stop()
        audioMixer.reset()
        await systemAudioCaptureEngine.stop()
        microphoneCaptureEngine.stop()
        engine.stop()
        engine.bridge?.setErrorStatus(message)
    }
}
