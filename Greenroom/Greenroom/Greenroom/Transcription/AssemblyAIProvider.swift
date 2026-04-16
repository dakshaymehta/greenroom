import Foundation

/// Streams PCM16 audio to AssemblyAI's real-time WebSocket API and delivers
/// live transcript updates as turns evolve.
///
/// The provider is intentionally not main-actor isolated because audio chunks
/// arrive on background queues at high frequency. We keep websocket state on a
/// dedicated queue and only hop to the main queue when surfacing transcript updates
/// or errors back to the UI layer.
final class AssemblyAIProvider: TranscriptionProvider, @unchecked Sendable {

    private static let sharedURLSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration)
    }()

    private let stateQueue = DispatchQueue(label: "com.greenroom.assemblyai.state")
    private let sendQueue = DispatchQueue(label: "com.greenroom.assemblyai.send")

    private var webSocketTask: URLSessionWebSocketTask?
    private var cachedToken: String?
    private var tokenFetchedAt: Date?
    private var onUpdate: ((TranscriptionUpdate) -> Void)?
    private var onError: ((Error) -> Void)?
    private var isRunning = false
    private var isSocketReady = false
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var lastDeliveredUpdateByTurnOrder: [Int: TranscriptionUpdate] = [:]
    private var lastDeliveredUnorderedUpdate: TranscriptionUpdate?

    func start(
        workerBaseURL: String,
        onUpdate: @escaping (TranscriptionUpdate) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        self.onUpdate = onUpdate
        self.onError = onError

        stateQueue.sync {
            isRunning = true
            isSocketReady = false
            readyContinuation = nil
            lastDeliveredUpdateByTurnOrder.removeAll()
            lastDeliveredUnorderedUpdate = nil
        }

        let token = try await fetchToken(workerBaseURL: workerBaseURL)

        guard var urlComponents = URLComponents(string: "wss://streaming.assemblyai.com/v3/ws") else {
            throw TranscriptionError.invalidURL
        }

        urlComponents.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro"),
            URLQueryItem(name: "language_detection", value: "true"),
            URLQueryItem(name: "token", value: token),
        ]

        guard let websocketURL = urlComponents.url else {
            throw TranscriptionError.invalidURL
        }

        do {
            try await openWebSocket(at: websocketURL)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 else {
                throw error
            }

            print("[AssemblyAIProvider] Stale websocket connection detected (Code 57), retrying once")
            try await Task.sleep(for: .milliseconds(300))
            try await openWebSocket(at: websocketURL)
        }
    }

    func feedAudio(_ data: Data) {
        sendQueue.async { [weak self] in
            guard let self else { return }

            let task: URLSessionWebSocketTask? = self.stateQueue.sync {
                guard self.isRunning, self.isSocketReady else { return nil }
                return self.webSocketTask
            }

            guard let task else { return }

            task.send(.data(data)) { error in
                if let error {
                    print("[AssemblyAIProvider] Audio send error: \(error)")

                    let nsError = error as NSError
                    if nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSURLErrorDomain {
                        self.failSocket(with: error)
                    }
                }
            }
        }
    }

    func stop() {
        let task: URLSessionWebSocketTask? = stateQueue.sync {
            isRunning = false
            isSocketReady = false
            lastDeliveredUpdateByTurnOrder.removeAll()
            lastDeliveredUnorderedUpdate = nil

            if let readyContinuation {
                self.readyContinuation = nil
                readyContinuation.resume(throwing: CancellationError())
            }

            let activeTask = webSocketTask
            webSocketTask = nil
            onUpdate = nil
            onError = nil
            return activeTask
        }

        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func fetchToken(workerBaseURL: String) async throws -> String {
        let tokenCacheLifetimeSeconds: TimeInterval = 400

        if let existingToken = cachedToken,
           let fetchDate = tokenFetchedAt,
           Date().timeIntervalSince(fetchDate) < tokenCacheLifetimeSeconds {
            return existingToken
        }

        let normalizedWorkerBaseURL = WorkerURLNormalizer.normalize(workerBaseURL)
        guard let tokenEndpointURL = URL(string: "\(normalizedWorkerBaseURL)/transcribe-token") else {
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

    private func openWebSocket(at websocketURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let task = AssemblyAIProvider.sharedURLSession.webSocketTask(with: websocketURL)

            stateQueue.sync {
                webSocketTask = task
                isSocketReady = false
                self.readyContinuation = continuation
            }

            task.resume()
            receiveMessages()
        }
    }

    private func receiveMessages() {
        let task: URLSessionWebSocketTask? = stateQueue.sync { webSocketTask }
        guard let task else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleReceivedMessage(message)

                let shouldContinueReceiving = self.stateQueue.sync { self.isRunning }
                if shouldContinueReceiving {
                    self.receiveMessages()
                }

            case .failure(let error):
                self.failSocket(with: error)
            }
        }
    }

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
              let rawMessageType = jsonObject["type"] as? String else {
            return
        }

        let messageType = rawMessageType.lowercased()

        switch messageType {
        case "begin", "session_begins", "sessionbegins":
            stateQueue.sync {
                isSocketReady = true
                resolveReadyContinuationIfNeeded(with: .success(()))
            }
            print("[AssemblyAIProvider] WebSocket ready — audio streaming enabled")

        case "speechstarted", "speech_started":
            return

        case "turn":
            guard let transcript = jsonObject["transcript"] as? String else {
                return
            }

            let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else { return }

            let isCompleteTurn = (jsonObject["end_of_turn"] as? Bool) == true
            let turnOrder = jsonObject["turn_order"] as? Int

            let transcriptUpdate = TranscriptionUpdate(
                text: trimmedTranscript,
                isFinal: isCompleteTurn,
                turnOrder: turnOrder
            )

            let shouldDeliverUpdate = stateQueue.sync {
                if let turnOrder {
                    if lastDeliveredUpdateByTurnOrder[turnOrder] == transcriptUpdate {
                        return false
                    }

                    lastDeliveredUpdateByTurnOrder[turnOrder] = transcriptUpdate

                    if lastDeliveredUpdateByTurnOrder.count > 8 {
                        let retainedTurnOrders = Set(lastDeliveredUpdateByTurnOrder.keys.sorted().suffix(4))
                        lastDeliveredUpdateByTurnOrder = lastDeliveredUpdateByTurnOrder.filter {
                            retainedTurnOrders.contains($0.key)
                        }
                    }
                } else if lastDeliveredUnorderedUpdate == transcriptUpdate {
                    return false
                } else {
                    lastDeliveredUnorderedUpdate = transcriptUpdate
                }

                return true
            }

            guard shouldDeliverUpdate else { return }

            DispatchQueue.main.async { [onUpdate] in
                onUpdate?(transcriptUpdate)
            }

        case "error":
            let errorMessage = (jsonObject["error"] as? String)
                ?? (jsonObject["message"] as? String)
                ?? "Unknown AssemblyAI error"
            failSocket(with: TranscriptionError.serverError(errorMessage))

        case "termination":
            // If the server terminates the session while we still expect audio to
            // flow, treat it as an error so the coordinator's recovery logic fires.
            // A termination that arrives after a client-initiated stop() is benign —
            // isRunning will already be false and we just resolve any pending state.
            let wasRunningWhenTerminated = stateQueue.sync { isRunning }
            if wasRunningWhenTerminated {
                failSocket(with: TranscriptionError.serverError("Session terminated by server"))
            } else {
                stateQueue.sync {
                    isSocketReady = false
                    resolveReadyContinuationIfNeeded(with: .success(()))
                }
            }

        default:
            return
        }
    }

    private func failSocket(with error: Error) {
        let isAuthFailure = Self.looksLikeAuthenticationFailure(error)

        let notificationHandler: ((Error) -> Void)? = stateQueue.sync {
            guard isRunning else { return nil }

            // A stale or rejected token will keep failing every retry if we don't
            // invalidate the cache here. Clear it so the next `start()` forces a
            // fresh token fetch from the Worker.
            if isAuthFailure {
                cachedToken = nil
                tokenFetchedAt = nil
            }

            isRunning = false
            isSocketReady = false
            lastDeliveredUpdateByTurnOrder.removeAll()
            lastDeliveredUnorderedUpdate = nil
            let activeTask = webSocketTask
            webSocketTask = nil
            resolveReadyContinuationIfNeeded(with: .failure(error))
            activeTask?.cancel(with: .goingAway, reason: nil)
            return onError
        }

        guard let notificationHandler else { return }

        DispatchQueue.main.async {
            notificationHandler(error)
        }
    }

    private static func looksLikeAuthenticationFailure(_ error: Error) -> Bool {
        if case TranscriptionError.serverError(let message) = error {
            let loweredMessage = message.lowercased()
            if loweredMessage.contains("token")
                || loweredMessage.contains("auth")
                || loweredMessage.contains("unauthorized")
                || loweredMessage.contains("forbidden") {
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorUserAuthenticationRequired
            || nsError.code == NSURLErrorUserCancelledAuthentication {
            return true
        }

        return false
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        guard let readyContinuation else { return }
        self.readyContinuation = nil
        readyContinuation.resume(with: result)
    }
}

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
