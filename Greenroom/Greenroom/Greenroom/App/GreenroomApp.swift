import SwiftUI

@main
struct GreenroomApp: App {
    @NSApplicationDelegateAdaptor(GreenroomAppDelegate.self) var appDelegate

    var body: some Scene {
        // Main window is managed by the app delegate, not SwiftUI scenes.
        // This Settings scene satisfies the SwiftUI Scene protocol requirement.
        Settings {
            EmptyView()
        }
    }
}
