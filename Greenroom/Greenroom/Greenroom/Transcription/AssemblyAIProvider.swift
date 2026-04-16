import Foundation

/// Streams audio to AssemblyAI's real-time transcription WebSocket API and
/// delivers completed speech turns as plain text strings.
///
/// Token management: we cache the short-lived token from the worker and reuse it
/// for up to 400 seconds (AssemblyAI tokens expire at 480 s, so 400 s gives a
/// comfortable margin before expiry).
///
/// Socket management: we use a single shared URLSession for the lifetime of the
/// app rather than creating a new session per connection. Rapid session creation
/// and teardown can cause Code 57 "Socket not connected" errors because macOS
/// doesn't always release the underlying socket handle immediately. Reusing the
/// session avoids this — a proven pattern from the Lore project.
@MainActor
final class AssemblyAIProvider: TranscriptionProvider {

    // MARK: - Shared Session

    /// One session for the entire app lifetime. URLSession is thread-safe and
    /// cheap to reuse; creating a new one per call is the common mistake that
    /// triggers Code 57 socket errors on rapid reconnects.
    private static let sharedURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60 // 1 hour max session
        return URLSession(configuration: configuration)
    }()

    // MARK: - Properties

    private var webSocketTask: URLSessionWebSocketTask?

    /// The most recently fetched token from the worker.
    private var cachedToken: String?

    /// When the cached token was fetched, used to decide if a refresh is needed.
    private var tokenFetchedAt: Date?

    private var onText: ((String) -> Void)?
    private var onError: ((Error) -> Void)?

    /// Guards against feeding audio or starting a receive loop after `stop()` is called.
    private var isRunning = false

    /// True once the websocket handshake completes and the server is ready.
    /// Audio is silently dropped until this is true, preventing Code 57 errors.
    private var isSocketReady = false

    // MARK: - TranscriptionProvider

    /// Fetches a token, opens the AssemblyAI WebSocket, and starts receiving transcription events.
    ///
    /// The WebSocket URL parameters:
    /// - `sample_rate=16000` — matches our capture engine output
    /// - `encoding=pcm_s16le` — raw 16-bit signed little-endian bytes (no container)
    /// - `format_turns=true` — receive structured turn objects instead of word-level events
    /// - `speech_model=u3-rt-pro` — Universal-3 real-time pro model, highest accuracy
    /// - `language_detection=true` — automatic language identification per turn
    func start(
        workerBaseURL: String,
        onText: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        self.onText = onText
        self.onError = onError
        self.isRunning = true

        let token = try await fetchToken(workerBaseURL: workerBaseURL)

        guard var urlComponents = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws") else {
            throw TranscriptionError.invalidURL
        }

        urlComponents.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro"),
            URLQueryItem(name: "language_detection", value: "true"),
            URLQueryItem(name: "token", value: token),
        ]

        guard let websocketURL = urlComponents.url else {
            throw TranscriptionError.invalidURL
        }

        let task = AssemblyAIProvider.sharedURLSession.webSocketTask(with: websocketURL)
        self.webSocketTask = task
        self.isSocketReady = false
        task.resume()

        // Start the receive loop. The first message from AssemblyAI is a session
        // confirmation — isSocketReady is set to true when we receive it, which
        // unblocks feedAudio(). This prevents Code 57 errors from sending audio
        // before the websocket handshake completes.
        receiveMessages()

        // Give the websocket a moment to establish before returning.
        // The coordinator starts audio capture immediately after this returns,
        // so a brief delay here prevents the initial burst of Code 57 errors.
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Base64-encodes the audio bytes and sends them as a JSON message to AssemblyAI.
    ///
    /// AssemblyAI's streaming v3 API expects `{"audio": "<base64>"}` frames.
    /// We silently drop the frame if the socket isn't running — this can happen
    /// for a brief window between `stop()` being called and the audio tap being removed.
    func feedAudio(_ data: Data) {
        guard isRunning, isSocketReady, let task = webSocketTask else { return }

        let base64AudioString = data.base64EncodedString()
        let jsonPayload = "{\"audio\":\"\(base64AudioString)\"}"
        let message = URLSessionWebSocketTask.Message.string(jsonPayload)

        task.send(message) { error in
            // Send errors here are non-fatal — a single dropped frame is
            // acceptable in a live stream. Persistent errors surface through
            // the receive loop's error handling instead.
            if let error = error {
                print("[AssemblyAIProvider] Audio send error: \(error)")
            }
        }
    }

    /// Sends a normal-closure signal and tears down the WebSocket.
    func stop() {
        isRunning = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Token Fetching

    /// Returns a valid token, fetching a new one from the worker if the cache has expired.
    ///
    /// The 400-second cache window is intentionally shorter than AssemblyAI's 480-second
    /// token lifetime to ensure we never attempt to connect with an expired token due to
    /// clock skew or network latency.
    private func fetchToken(workerBaseURL: String) async throws -> String {
        let tokenCacheLifetimeSeconds: TimeInterval = 400

        if let existingToken = cachedToken,
           let fetchDate = tokenFetchedAt,
           Date().timeIntervalSince(fetchDate) < tokenCacheLifetimeSeconds {
            return existingToken
        }

        guard let tokenEndpointURL = URL(string: "\(workerBaseURL)/transcribe-token") else {
            throw TranscriptionError.invalidURL
        }

        var request = URLRequest(url: tokenEndpointURL)
        request.httpMethod = "POST"

        let (responseData, httpResponse) = try await AssemblyAIProvider.sharedURLSession.data(for: request)

        guard let httpURLResponse = httpResponse as? HTTPURLResponse,
              (200..<300).contains(httpURLResponse.statusCode) else {
            throw TranscriptionError.tokenFetchFailed
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let token = jsonObject["token"] as? String else {
            throw TranscriptionError.tokenFetchFailed
        }

        cachedToken = token
        tokenFetchedAt = Date()

        return token
    }

    // MARK: - Message Receiving

    /// Starts a recursive receive loop that processes messages until the socket closes.
    ///
    /// The recursion is intentional: URLSessionWebSocketTask.receive delivers one
    /// message at a time, so we re-schedule ourselves after each successful receive.
    /// When `isRunning` is false or the task errors, the recursion stops naturally.
    private func receiveMessages() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            guard let self = self else { return }

            Task { @MainActor in
                switch result {
                case .success(let message):
                    self.handleReceivedMessage(message)
                    // Schedule the next receive only if we're still active.
                    if self.isRunning {
                        self.receiveMessages()
                    }

                case .failure(let error):
                    // If we intentionally stopped, the socket close is expected —
                    // don't surface it as an error to the caller.
                    guard self.isRunning else { return }
                    self.isRunning = false
                    self.onError?(error)
                }
            }
        }
    }

    /// Parses an incoming WebSocket message and fires `onText` for completed turns.
    ///
    /// AssemblyAI v3 sends JSON objects with a `type` field. We care about two:
    /// - `"turn"` with `end_of_turn: true` — a speaker finished a thought
    /// - `"error"` — the service encountered a problem
    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) {
        let jsonString: String

        switch message {
        case .string(let text):
            jsonString = text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { return }
            jsonString = text
        @unknown default:
            return
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let messageType = jsonObject["type"] as? String else {
            return
        }

        switch messageType {
        case "turn":
            // We only forward turns that are marked as complete. Partial turns
            // update rapidly and would flood the transcript buffer unnecessarily.
            guard let isEndOfTurn = jsonObject["end_of_turn"] as? Bool, isEndOfTurn else {
                return
            }

            if let transcript = jsonObject["transcript"] as? String, !transcript.isEmpty {
                // The trailing space lets callers concatenate successive turns
                // into a single string without adding their own separator.
                onText?(transcript + " ")
            }

        case "error":
            let errorMessage = jsonObject["message"] as? String ?? "Unknown AssemblyAI error"
            isRunning = false
            onError?(TranscriptionError.serverError(errorMessage))

        default:
            // The first message from AssemblyAI (typically "session_begins") confirms
            // the websocket is ready. Unblock feedAudio() by setting the ready flag.
            if !isSocketReady {
                isSocketReady = true
                print("[AssemblyAIProvider] WebSocket ready — audio streaming enabled")
            }
        }
    }
}

// MARK: - Errors

enum TranscriptionError: Error, LocalizedError {

    case invalidURL
    case tokenFetchFailed
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not construct a valid URL for the transcription service."
        case .tokenFetchFailed:
            return "Failed to fetch a transcription token from the worker. Check that the worker URL is correct and reachable."
        case .serverError(let message):
            return "AssemblyAI returned an error: \(message)"
        }
    }
}
