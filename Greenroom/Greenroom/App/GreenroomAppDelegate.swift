import AppKit

/// Application delegate responsible for bootstrapping the main window and
/// wiring up top-level app lifecycle events.
///
/// Window management is intentionally done here rather than in a SwiftUI Scene
/// so we have full control over NSWindow properties (size, transparency, etc.)
/// that SwiftUI abstracts away.
@MainActor
final class GreenroomAppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var windowController: GreenroomWindowController?
    private var coordinator: GreenroomCoordinator?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let newCoordinator = GreenroomCoordinator()
        coordinator = newCoordinator

        let controller = GreenroomWindowController(coordinator: newCoordinator)
        windowController = controller
        controller.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Greenroom is a single-window utility app — quitting the window quits the app.
        return true
    }
}
