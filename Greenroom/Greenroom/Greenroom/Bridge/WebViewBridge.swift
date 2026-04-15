import Foundation
import WebKit

/// Manages bidirectional communication between the Swift layer and the sidebar JavaScript.
///
/// Swift calls methods on this class to push data into the JS side (persona updates, tick events,
/// live status). JS calls back by posting messages to the "greenroom" handler, which this class
/// receives and forwards via the `onSidebarAction` callback.
@MainActor
final class WebViewBridge: NSObject, WKScriptMessageHandler {

    /// The webView this bridge is attached to. Set during `attach(to:)`.
    private weak var webView: WKWebView?

    /// Called whenever the sidebar JS posts a user-action message (mute, pause, settings).
    var onSidebarAction: ((SidebarAction) -> Void)?

    // MARK: - Setup

    /// Registers this bridge as the message handler for the "greenroom" channel on the given webView.
    ///
    /// Must be called before the webView loads any content, so the JS side can reference
    /// `window.webkit.messageHandlers.greenroom` during initialization.
    func attach(to webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.add(self, name: "greenroom")
    }

    // MARK: - Swift → JS

    /// Serializes a PersonaUpdate and calls `greenroom.onPersonaUpdate(parsedObject)` in the sidebar.
    ///
    /// The JS side expects a parsed object (not a raw string), so we pass the JSON string into
    /// JSON.parse() before handing it off to the handler.
    func sendPersonaUpdate(_ update: PersonaUpdate) {
        do {
            let jsonString = try update.toJSONString()
            // We wrap the JSON string in JSON.parse() so the JS receives a proper object,
            // not a string that would need its own parsing step on that side.
            let escapedJSON = jsonString.replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "'", with: "\\'")
            evaluateJS("greenroom.onPersonaUpdate(JSON.parse('\(escapedJSON)'))")
        } catch {
            print("[WebViewBridge] Failed to serialize PersonaUpdate: \(error)")
        }
    }

    /// Forwards new transcript text to the sidebar so the UI can display a live transcript.
    func sendTranscriptUpdate(_ text: String) {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
                          .replacingOccurrences(of: "\n", with: "\\n")
        evaluateJS("greenroom.onTranscriptUpdate('\(escaped)')")
    }

    /// Tells the sidebar that a new AI tick is starting, so it can show thinking indicators.
    func sendTickStart() {
        evaluateJS("greenroom.onTickStart()")
    }

    /// Updates the live/offline status indicator in the sidebar.
    func setLiveStatus(_ isLive: Bool) {
        let booleanLiteral = isLive ? "true" : "false"
        evaluateJS("greenroom.setLiveStatus(\(booleanLiteral))")
    }

    /// Puts the status indicator into an error state and displays the given message.
    func setErrorStatus(_ message: String) {
        // Single quotes delimit the JS string, so we escape any that appear in the message.
        let escapedMessage = message.replacingOccurrences(of: "'", with: "\\'")
        evaluateJS("greenroom.setErrorStatus('\(escapedMessage)')")
    }

    // MARK: - JS → Swift (WKScriptMessageHandler)

    /// Receives messages posted by `window.webkit.messageHandlers.greenroom.postMessage(...)`.
    ///
    /// The message body is expected to be a dictionary matching the SidebarAction shape.
    /// We re-encode it to JSON and decode it into our Swift type so we have a clean, typed value.
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let bodyDictionary = message.body as? [String: Any] else {
            print("[WebViewBridge] Received message with unexpected body type: \(type(of: message.body))")
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: bodyDictionary)
            let sidebarAction = try JSONDecoder().decode(SidebarAction.self, from: jsonData)
            Task { @MainActor in
                self.onSidebarAction?(sidebarAction)
            }
        } catch {
            print("[WebViewBridge] Failed to decode SidebarAction from message body: \(error)")
        }
    }

    // MARK: - Private helpers

    /// Evaluates a JavaScript string in the attached webView and logs any errors.
    ///
    /// Errors here are usually benign (e.g., JS not yet loaded), but we log them so
    /// unexpected failures surface during development.
    private func evaluateJS(_ script: String) {
        guard let webView = webView else {
            print("[WebViewBridge] evaluateJS called but webView is nil")
            return
        }

        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("[WebViewBridge] JavaScript evaluation error for script '\(script)': \(error)")
            }
        }
    }
}
