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
        WorkerURLNormalizer.normalize(UserDefaults.standard.string(forKey: "workerBaseURL"))
    }

    /// The Claude model to request. Falls back to a known-good Sonnet version if
    /// the user hasn't explicitly chosen one yet.
    private var selectedModel: String {
        ClaudeModelCatalog.normalized(
            UserDefaults.standard.string(forKey: "selectedModel")
        )
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

    struct ExaSearchResult {
        let title: String
        let snippet: String
        let url: String
        let host: String
    }

    struct ExaSearchResponse {
        let query: String
        let results: [ExaSearchResult]
        let promptSummary: String
    }

    /// Searches the web via Exa through the Cloudflare Worker.
    ///
    /// Used by Gary to verify factual claims with real-time data. The Worker
    /// proxies the request to Exa's neural search API so the API key stays
    /// server-side.
    func searchViaExa(query: String) async throws -> ExaSearchResponse {
        let baseURLString = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURLString.isEmpty else { throw ClaudeAPIError.noWorkerURL }

        guard let searchURL = URL(string: "\(baseURLString)/exa-search") else {
            throw ClaudeAPIError.invalidURL
        }

        let requestBody: [String: Any] = ["query": query, "numResults": 8]
        let jsonData = try JSONSerialization.data(withJSONObject: requestBody)

        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "(unreadable body)"
            throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, body: responseBody)
        }

        // Extract text snippets from Exa results for Claude context and UI source chips.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return ExaSearchResponse(
                query: query,
                results: [],
                promptSummary: "No search results found."
            )
        }

        var parsedResults: [ExaSearchResult] = []

        for result in results.prefix(8) {
            let title = result["title"] as? String ?? "Untitled"
            let text = result["text"] as? String ?? ""
            let url = result["url"] as? String ?? ""
            let cleanedSnippet = text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = String(cleanedSnippet.prefix(320))
            let sourceHost = URL(string: url)?
                .host?
                .replacingOccurrences(of: "www.", with: "") ?? "Unknown source"

            parsedResults.append(
                ExaSearchResult(
                    title: title,
                    snippet: snippet,
                    url: url,
                    host: sourceHost
                )
            )
        }

        let rankedResults = parsedResults.sorted { leftResult, rightResult in
            Self.factCheckPriorityScore(for: leftResult) > Self.factCheckPriorityScore(for: rightResult)
        }

        let preferredResults = rankedResults.filter(Self.isPreferredFactCheckSource)
        let promptResults = Array((preferredResults.isEmpty ? rankedResults : preferredResults).prefix(4))

        var searchSummary = "Live web results for '\(query)':\n\n"

        if preferredResults.isEmpty, !rankedResults.isEmpty {
            searchSummary += """
            No strong independent reporting or official source was found in the search results. The available hits skew toward low-signal or user-generated pages, so any fact-check should stay cautious and avoid overclaiming.

            """
        }

        for (index, result) in promptResults.enumerated() {
            searchSummary += """
            \(index + 1). \(result.title)
            Source: \(result.host)
            Snippet: \(result.snippet)
            URL: \(result.url)

            """
        }

        return ExaSearchResponse(
            query: query,
            results: Array(preferredResults.prefix(3)),
            promptSummary: searchSummary
        )
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
            let contentArray = rootObject["content"] as? [[String: Any]]
        else {
            print("[ClaudeAPIClient] Response was not in expected Claude Messages format")
            return nil
        }

        let rawText = contentArray
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        guard !rawText.isEmpty else {
            print("[ClaudeAPIClient] Claude response did not contain any text blocks")
            return nil
        }

        if let personaUpdate = PersonaUpdateParser.parse(rawText) {
            return personaUpdate
        }

        print("[ClaudeAPIClient] Failed to decode PersonaUpdate from Claude text")
        print("[ClaudeAPIClient] Raw Claude text was: \(rawText)")
        return nil
    }
}

private extension ClaudeAPIClient {

    static func factCheckPriorityScore(for result: ExaSearchResult) -> Int {
        let normalizedHost = normalizedHost(result.host)

        if lowSignalFactCheckHosts.contains(normalizedHost) {
            return -100
        }

        if normalizedHost.hasSuffix(".gov") || normalizedHost.hasSuffix(".mil") {
            return 120
        }

        if preferredNewsFactCheckHosts.contains(normalizedHost) {
            return 100
        }

        if normalizedHost.contains(".gov.") || normalizedHost.contains(".mil.") {
            return 95
        }

        if result.url.contains("/press") || result.url.contains("/news") || result.url.contains("/releases") {
            return 80
        }

        return 10
    }

    static func isPreferredFactCheckSource(_ result: ExaSearchResult) -> Bool {
        let normalizedHost = normalizedHost(result.host)

        if lowSignalFactCheckHosts.contains(normalizedHost) {
            return false
        }

        if normalizedHost.hasSuffix(".gov") || normalizedHost.hasSuffix(".mil") {
            return true
        }

        if preferredNewsFactCheckHosts.contains(normalizedHost) {
            return true
        }

        return result.url.contains("/press")
            || result.url.contains("/news")
            || result.url.contains("/releases")
    }

    static func normalizedHost(_ host: String) -> String {
        host
            .replacingOccurrences(of: "www.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static let lowSignalFactCheckHosts: Set<String> = [
        "youtube.com",
        "youtu.be",
        "x.com",
        "twitter.com",
        "reddit.com",
        "instagram.com",
        "facebook.com",
        "fb.com",
        "tiktok.com",
        "linkedin.com",
        "threads.net"
    ]

    static let preferredNewsFactCheckHosts: Set<String> = [
        "reuters.com",
        "apnews.com",
        "bbc.com",
        "bbc.co.uk",
        "nytimes.com",
        "wsj.com",
        "bloomberg.com",
        "ft.com",
        "npr.org",
        "nbcnews.com",
        "abcnews.go.com",
        "cbsnews.com",
        "cnn.com",
        "axios.com",
        "theguardian.com",
        "politico.com"
    ]
}

enum PersonaUpdateParser {

    static func parse(_ rawText: String) -> PersonaUpdate? {
        if let directJSON = decode(rawText) {
            return directJSON
        }

        if let fencedJSON = parseFromMarkdownFence(rawText) {
            return fencedJSON
        }

        if let extractedJSONObject = extractOutermostJSONObject(from: rawText),
           let decodedJSON = decode(extractedJSONObject) {
            return decodedJSON
        }

        return nil
    }

    private static func parseFromMarkdownFence(_ rawText: String) -> PersonaUpdate? {
        let normalizedText = rawText.replacingOccurrences(of: "```json", with: "```")
        let fenceComponents = normalizedText.components(separatedBy: "```")

        for component in fenceComponents {
            if let decodedJSON = decode(component.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return decodedJSON
            }
        }

        return nil
    }

    private static func extractOutermostJSONObject(from rawText: String) -> String? {
        guard let firstOpeningBrace = rawText.firstIndex(of: "{"),
              let lastClosingBrace = rawText.lastIndex(of: "}") else {
            return nil
        }

        return String(rawText[firstOpeningBrace...lastClosingBrace])
    }

    private static func decode(_ rawText: String) -> PersonaUpdate? {
        guard let textData = rawText.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(PersonaUpdate.self, from: textData)
    }
}
