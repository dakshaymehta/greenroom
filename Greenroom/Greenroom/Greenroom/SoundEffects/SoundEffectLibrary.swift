import Foundation

/// A registry that maps logical effect names to their on-disk file names.
///
/// Keeping the name-to-file mapping in one place means the rest of the app
/// never needs to know how the audio files are named on disk — it only works
/// with the human-readable effect names that Fred produces.
enum SoundEffectLibrary {

    // MARK: - Private Registry

    /// The canonical mapping from logical effect name to bundle file name.
    ///
    /// File names use underscores (filesystem-safe) while effect names use hyphens
    /// (JSON-safe and more readable). This dictionary is the single place that
    /// bridges the two naming conventions.
    private static let effectNameToFileName: [String: String] = [
        "rimshot":        "sfx_rimshot.mp3",
        "ba-dum-tss":     "sfx_ba_dum_tss.mp3",
        "laugh-track":    "sfx_laugh_track.mp3",
        "wrong-buzzer":   "sfx_wrong_buzzer.mp3",
        "sad-trombone":   "sfx_sad_trombone.mp3",
        "crickets":       "sfx_crickets.mp3",
        "dun-dun-dun":    "sfx_dun_dun_dun.mp3",
        "airhorn":        "sfx_airhorn.mp3",
        "dramatic-sting": "sfx_dramatic_sting.mp3",
        "ding":           "sfx_ding.mp3",
        "applause":       "sfx_applause.mp3",
        "chef-kiss":      "sfx_chef_kiss.mp3"
    ]

    /// System sound fallback names used when the custom bundled sound pack
    /// is unavailable in a clean checkout or development build.
    private static let effectNameToFallbackSystemSoundName: [String: String] = [
        "rimshot":        "Funk",
        "ba-dum-tss":     "Hero",
        "laugh-track":    "Purr",
        "wrong-buzzer":   "Sosumi",
        "sad-trombone":   "Submarine",
        "crickets":       "Bottle",
        "dun-dun-dun":    "Morse",
        "airhorn":        "Hero",
        "dramatic-sting": "Hero",
        "ding":           "Tink",
        "applause":       "Ping",
        "chef-kiss":      "Glass"
    ]

    // MARK: - Public Interface

    /// Returns the bundle file name for a given logical effect name, or nil if unknown.
    ///
    /// Callers should handle nil gracefully — an unknown effect name most likely
    /// means the AI returned a value that doesn't match the prompt's valid list.
    static func fileName(for effectName: String) -> String? {
        return effectNameToFileName[effectName]
    }

    static func fallbackSystemSoundName(for effectName: String) -> String? {
        return effectNameToFallbackSystemSoundName[effectName]
    }

    /// All registered effect names, sorted alphabetically.
    ///
    /// Useful for UI pickers or validation — callers can show or validate against
    /// exactly the set of effects the library knows about.
    static var allEffectNames: [String] {
        return effectNameToFileName.keys.sorted()
    }
}
