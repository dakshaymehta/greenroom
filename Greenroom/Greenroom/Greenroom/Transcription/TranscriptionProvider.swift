import Foundation

/// Defines the interface that all real-time transcription backends must satisfy.
///
/// The protocol decouples the audio pipeline from any specific transcription
/// service, making it straightforward to swap AssemblyAI for a different provider
/// (e.g. Deepgram, Whisper) without touching the audio capture layer.
protocol TranscriptionProvider {

    /// Connects to the transcription service and begins a streaming session.
    ///
    /// - Parameters:
    ///   - workerBaseURL: Base URL of the Cloudflare Worker that vends short-lived
    ///     transcription tokens, e.g. `"https://worker.example.com"`.
    ///   - onText: Called on the main actor whenever a completed speech turn arrives.
    ///     The string includes a trailing space so callers can concatenate turns
    ///     directly without adding their own delimiter.
    ///   - onError: Called on the main actor if the connection drops or the service
    ///     returns an error. The provider stops automatically after calling this.
    func start(
        workerBaseURL: String,
        onText: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws

    /// Sends a chunk of PCM s16le audio data to the transcription service.
    ///
    /// The caller should stop sending after calling `stop()`. Sending to a
    /// stopped provider is a no-op.
    func feedAudio(_ data: Data)

    /// Closes the connection to the transcription service gracefully.
    func stop()
}
