import AVFoundation
import Foundation

/// Plays on-demand sound effects in response to Fred's persona outputs.
///
/// All audio playback is intentionally fire-and-forget — the engine holds a
/// reference to the current player only so it can stop early if needed. A new
/// call to `play` replaces any currently playing sound.
@MainActor
final class SoundEffectEngine {

    // MARK: - Properties

    /// The currently active player, if a sound is in progress.
    private var currentPlayer: AVAudioPlayer?

    /// Output volume for all effects, between 0.0 (silent) and 1.0 (full).
    ///
    /// Updating this property immediately affects the current player so volume
    /// changes feel instantaneous rather than only kicking in on the next sound.
    var volume: Float = 0.7 {
        didSet {
            currentPlayer?.volume = volume
        }
    }

    /// When true, `play` is a no-op — useful for pausing without losing the
    /// current volume setting.
    var isMuted: Bool = false

    // MARK: - Playback

    /// Looks up the effect name, loads its audio file from the bundle's Sounds
    /// subdirectory, and plays it at the current volume.
    ///
    /// We look inside a "Sounds" subdirectory to keep the bundle root tidy.
    /// Unknown effect names are logged and silently ignored so a bad AI response
    /// doesn't crash or interrupt the show.
    func play(effectName: String) {
        guard !isMuted else { return }

        guard let fileName = SoundEffectLibrary.fileName(for: effectName) else {
            print("[SoundEffectEngine] Unknown effect name '\(effectName)' — ignoring. Valid names: \(SoundEffectLibrary.allEffectNames.joined(separator: ", "))")
            return
        }

        // Audio files live in a "Sounds" subdirectory inside the app bundle.
        // Using a subdirectory prevents name collisions with other bundled resources.
        guard let soundURL = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "Sounds") else {
            print("[SoundEffectEngine] Could not find '\(fileName)' in bundle Sounds directory")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: soundURL)
            player.volume = volume
            player.prepareToPlay()
            player.play()

            // Hold a strong reference so the player stays alive for the duration of playback.
            currentPlayer = player
        } catch {
            print("[SoundEffectEngine] Failed to create audio player for '\(fileName)': \(error)")
        }
    }

    /// Stops any currently playing sound immediately.
    func stop() {
        currentPlayer?.stop()
        currentPlayer = nil
    }
}
