import AppKit

/// Design tokens shared between the native Swift layer and the HTML/CSS sidebar.
///
/// These color values mirror the CSS custom properties defined in sidebar/styles.css.
/// Keeping them in sync here means we can tint native UI elements (menu bar icons,
/// notifications, etc.) with the same palette as the web UI.
enum DesignTokens {

    enum Colors {

        /// Gary's accent color — a calm blue used for his speaking state.
        /// Matches CSS: #4A9EFF
        static let garyAccent = NSColor(
            red: 0x4A / 255.0,
            green: 0x9E / 255.0,
            blue: 0xFF / 255.0,
            alpha: 1.0
        )

        /// Fred's accent color — a fresh green used for his speaking state.
        /// Matches CSS: #4ADE80
        static let fredAccent = NSColor(
            red: 0x4A / 255.0,
            green: 0xDE / 255.0,
            blue: 0x80 / 255.0,
            alpha: 1.0
        )

        /// Jackie's accent color — a warm amber used for her speaking state.
        /// Matches CSS: #FBBF24
        static let jackieAccent = NSColor(
            red: 0xFB / 255.0,
            green: 0xBF / 255.0,
            blue: 0x24 / 255.0,
            alpha: 1.0
        )

        /// Troll's accent color — a soft red used for the troll/alert state.
        /// Matches CSS: #F87171
        static let trollAccent = NSColor(
            red: 0xF8 / 255.0,
            green: 0x71 / 255.0,
            blue: 0x71 / 255.0,
            alpha: 1.0
        )
    }
}
