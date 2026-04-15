import Foundation

/// Errors that can be thrown by ClaudeAPIClient during a request cycle.
enum ClaudeAPIError: Error, LocalizedError {

    /// The user hasn't entered a Worker URL in Settings yet.
    case noWorkerURL

    /// The stored URL string couldn't be parsed into a valid URL.
    case invalidURL

    /// The server returned a non-HTTP response or the response object was missing.
    case invalidResponse

    /// The server returned a non-2xx status code.
    case apiError(statusCode: Int, body: String)

    /// Claude's response existed but wasn't in the shape we expected.
    case unexpectedFormat

    var errorDescription: String? {
        switch self {
        case .noWorkerURL:
            return "No Worker URL configured. Set your Cloudflare Worker URL in Settings."
        case .invalidURL:
            return "Invalid Worker URL."
        case .invalidResponse:
            return "Invalid response from Worker."
        case .apiError(let statusCode, let body):
            return "API error (\(statusCode)): \(body)"
        case .unexpectedFormat:
            return "Unexpected response format from Claude."
        }
    }
}

/// Sends transcript chunks to Claude via a Cloudflare Worker proxy and returns
/// the parsed persona update.
///
/// The Worker acts as a BYOK proxy — the user's API key lives on the Worker,
/// not in the app, which avoids embedding secrets in the binary and lets the
/// user rotate their key without a new app release.
@MainActor
final class ClaudeAPIClient {

    // MARK: - Configuration

    /// The base URL of the user's Cloudflare Worker, stored in UserDefaults.
    private var workerBaseURL: String {
        UserDefaults.standard.string(forKey: "workerBaseURL") ?? ""
    }

    /// The Claude model to request. Falls back to a known-good Sonnet version if
    /// the user hasn't explicitly chosen one yet.
    private var selectedModel: String {
        UserDefaults.standard.string(forKey: "selectedModel") ?? "claude-sonnet-4-6-20250514"
    }

    // MARK: - Public Interface

    /// Posts a prompt to the Worker and returns the decoded PersonaUpdate, or nil
    /// if the response couldn't be parsed.
    ///
    /// Returning nil rather than throwing on parse failure means a malformed Claude
    /// response is treated as "nothing to say" rather than an error — the show goes on.
    func sendRequest(systemPrompt: String, messages: [[String: Any]]) async throws -> PersonaUpdate? {
        let baseURLString = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURLString.isEmpty else {
            throw ClaudeAPIError.noWorkerURL
        }

        guard let requestURL = URL(string: "\(baseURLString)/chat") else {
            throw ClaudeAPIError.invalidURL
        }

        // Build the request body matching the Claude Messages API shape.
        let requestBody: [String: Any] = [
            "model":      selectedModel,
            "max_tokens": 1024,
            "system":     systemPrompt,
            "messages":   messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)

        var urlRequest = URLRequest(url: requestURL, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = bodyData

        let (responseData, urlResponse) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: responseData, encoding: .utf8) ?? "(unreadable body)"
            throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, body: bodyString)
        }

        return parsePersonaUpdate(from: responseData)
    }

    // MARK: - Exa Web Search

    /// Searches the web via Exa through the Cloudflare Worker.
    ///
    /// Used by Gary to verify factual claims with real-time data. The Worker
    /// proxies the request to Exa's neural search API so the API key stays
    /// server-side.
    func searchViaExa(query: String) async throws -> String {
        let baseURLString = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURLString.isEmpty else { throw ClaudeAPIError.noWorkerURL }

        guard let searchURL = URL(string: "\(baseURLString)/exa-search") else {
            throw ClaudeAPIError.invalidURL
        }

        let requestBody: [String: Any] = ["query": query, "numResults": 3]
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)

        // Extract text snippets from Exa results for Claude context
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return "No search results found."
        }

        var searchSummary = "Web search results for '\(query)':\n\n"
        for (index, result) in results.prefix(3).enumerated() {
            let title = result["title"] as? String ?? "Untitled"
            let text = result["text"] as? String ?? ""
            let url = result["url"] as? String ?? ""
            searchSummary += "\(index + 1). \(title)\n\(String(text.prefix(300)))\nSource: \(url)\n\n"
        }
        return searchSummary
    }

    // MARK: - Private Parsing

    /// Extracts the first content block's text from a Claude response and decodes
    /// it as a PersonaUpdate.
    ///
    /// Claude wraps its reply in an `content` array — we unwrap it here so the
    /// rest of the app works with clean, typed values rather than raw JSON shapes.
    private func parsePersonaUpdate(from data: Data) -> PersonaUpdate? {
        guard
            let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArray = rootObject["content"] as? [[String: Any]],
            let firstBlock = contentArray.first,
            let rawText = firstBlock["text"] as? String
        else {
            print("[ClaudeAPIClient] Response was not in expected Claude Messages format")
            return nil
        }

        guard let textData = rawText.data(using: .utf8) else {
            print("[ClaudeAPIClient] Could not convert response text to Data")
            return nil
        }

        do {
            let personaUpdate = try JSONDecoder().decode(PersonaUpdate.self, from: textData)
            return personaUpdate
        } catch {
            // Log the raw text so developers can see exactly what Claude returned —
            // this is the most useful debug signal when the JSON shape drifts.
            print("[ClaudeAPIClient] Failed to decode PersonaUpdate from Claude text: \(error)")
            print("[ClaudeAPIClient] Raw Claude text was: \(rawText)")
            return nil
        }
    }
}
