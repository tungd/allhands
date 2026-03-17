import Foundation

public enum APIClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an invalid response."
        case .httpStatus(let code):
            return "The server returned HTTP \(code)."
        }
    }
}

public struct APIClient: Sendable {
    public var baseURL: URL
    public var session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func health(timeout: TimeInterval? = nil) async throws {
        var request = URLRequest(url: baseURL.appending(path: "healthz"))
        if let timeout {
            request.timeoutInterval = timeout
        }
        let (_, response) = try await session.data(for: request)
        try validate(response: response)
    }

    public func listSessions() async throws -> [SessionSummary] {
        let request = URLRequest(url: baseURL.appending(path: "sessions"))
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try decoder.decode(SessionListEnvelope.self, from: data).sessions
    }

    public func serverInfo() async throws -> ServerInfo {
        let request = URLRequest(url: baseURL.appending(path: "server-info"))
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try decoder.decode(ServerInfo.self, from: data)
    }

    public func createSession(_ createSessionRequest: CreateSessionRequest) async throws -> SessionSummary {
        var request = URLRequest(url: baseURL.appending(path: "sessions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(createSessionRequest)
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try decoder.decode(SessionEnvelope.self, from: data).session
    }

    public func session(id: String) async throws -> SessionSummary {
        let request = URLRequest(url: baseURL.appending(path: "sessions").appending(path: id))
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try decoder.decode(SessionEnvelope.self, from: data).session
    }

    public func sendPrompt(sessionID: String, prompt: PromptRequest) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "prompts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(prompt)
        let (_, response) = try await session.data(for: request)
        try validate(response: response)
    }

    public func sendToolDecision(sessionID: String, decision: ToolDecisionRequest) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "tool-decisions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(decision)
        let (_, response) = try await session.data(for: request)
        try validate(response: response)
    }

    public func cancel(sessionID: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "cancel"))
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try validate(response: response)
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIClientError.httpStatus(httpResponse.statusCode)
        }
    }
}

private struct SessionEnvelope: Codable {
    let session: SessionSummary
}

private struct SessionListEnvelope: Codable {
    let sessions: [SessionSummary]
}
