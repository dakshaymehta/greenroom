import Foundation

/// Routes audio data from the system capture and microphone capture engines to a
/// single downstream consumer (the transcription provider).
///
/// For v1, both sources feed independently (pass-through). AssemblyAI handles
/// interleaved multi-speaker audio well. AGC normalization can be added in v2
/// if transcription quality suffers.
final class AudioMixer {

    // MARK: - Properties

    /// Serializes access from both audio capture callbacks, which can fire on
    /// different background threads simultaneously.
    private let mixQueue = DispatchQueue(label: "com.greenroom.audiomixer", qos: .userInteractive)

    /// Called with each chunk of mixed audio data, ready to be sent to the transcription provider.
    var onMixedAudio: ((Data) -> Void)?

    // MARK: - Audio Input

    /// Receives a chunk of PCM s16le audio from the system audio capture engine.
    func receiveSystemAudio(_ data: Data) {
        mixQueue.async { [weak self] in
            self?.onMixedAudio?(data)
        }
    }

    /// Receives a chunk of PCM s16le audio from the microphone capture engine.
    func receiveMicrophoneAudio(_ data: Data) {
        mixQueue.async { [weak self] in
            self?.onMixedAudio?(data)
        }
    }
}
