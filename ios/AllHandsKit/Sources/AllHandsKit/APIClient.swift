import Foundation

public struct APIRequestDescriptor: Equatable, Sendable {
    public var method: String
    public var path: String

    public init(method: String, path: String) {
        self.method = method
        self.path = path
    }

    public var label: String {
        "\(method) \(path)"
    }
}

public enum APIClientError: Error, LocalizedError {
    case invalidResponse(APIRequestDescriptor)
    case httpStatus(APIRequestDescriptor, Int)
    case transport(APIRequestDescriptor, String)

    public var request: APIRequestDescriptor {
        switch self {
        case .invalidResponse(let request):
            return request
        case .httpStatus(let request, _):
            return request
        case .transport(let request, _):
            return request
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let request):
            return "\(request.label) returned an invalid response."
        case .httpStatus(let request, let code):
            return "\(request.label) returned HTTP \(code)."
        case .transport(let request, let message):
            return "\(request.label) failed: \(message)"
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
        let endpoint = Endpoint.health
        let request = makeRequest(for: endpoint, timeout: timeout)
        let (_, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
    }

    public func listSessions() async throws -> [SessionSummary] {
        let endpoint = Endpoint.listSessions
        let request = makeRequest(for: endpoint)
        let (data, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
        return try decode(SessionListEnvelope.self, from: data, endpoint: endpoint).sessions
    }

    public func serverInfo() async throws -> ServerInfo {
        let endpoint = Endpoint.serverInfo
        let request = makeRequest(for: endpoint)
        let (data, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
        return try decode(ServerInfo.self, from: data, endpoint: endpoint)
    }

    public func createSession(_ createSessionRequest: CreateSessionRequest) async throws -> SessionSummary {
        let endpoint = Endpoint.createSession
        let request = try makeJSONRequest(for: endpoint, body: createSessionRequest)
        let (data, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
        return try decode(SessionEnvelope.self, from: data, endpoint: endpoint).session
    }

    public func session(id: String) async throws -> SessionSummary {
        let endpoint = Endpoint.session(id: id)
        let request = makeRequest(for: endpoint)
        let (data, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
        return try decode(SessionEnvelope.self, from: data, endpoint: endpoint).session
    }

    public func sendPrompt(sessionID: String, prompt: PromptRequest) async throws {
        let endpoint = Endpoint.prompt(sessionID: sessionID)
        let request = try makeJSONRequest(for: endpoint, body: prompt)
        let (data, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
        let envelope = try decode(AcceptedEnvelope.self, from: data, endpoint: endpoint)
        guard envelope.accepted else {
            throw APIClientError.invalidResponse(endpoint.request)
        }
    }

    public func sendToolDecision(sessionID: String, decision: ToolDecisionRequest) async throws {
        let endpoint = Endpoint.toolDecision(sessionID: sessionID)
        let request = try makeJSONRequest(for: endpoint, body: decision)
        let (data, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
        let envelope = try decode(AcceptedEnvelope.self, from: data, endpoint: endpoint)
        guard envelope.accepted else {
            throw APIClientError.invalidResponse(endpoint.request)
        }
    }

    public func cancel(sessionID: String) async throws {
        let endpoint = Endpoint.cancel(sessionID: sessionID)
        let request = makeRequest(for: endpoint)
        let (_, response) = try await perform(request, endpoint: endpoint)
        try validate(response: response, endpoint: endpoint)
    }

    private func validate(response: URLResponse, endpoint: Endpoint) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse(endpoint.request)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIClientError.httpStatus(endpoint.request, httpResponse.statusCode)
        }
    }

    private func makeRequest(for endpoint: Endpoint, timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: endpoint.url(baseURL: baseURL))
        request.httpMethod = endpoint.request.method
        if let timeout {
            request.timeoutInterval = timeout
        }
        return request
    }

    private func makeJSONRequest<Request: Encodable>(for endpoint: Endpoint, body: Request) throws -> URLRequest {
        var request = makeRequest(for: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func perform(_ request: URLRequest, endpoint: Endpoint) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if let apiError = error as? APIClientError {
                throw apiError
            }
            throw APIClientError.transport(endpoint.request, error.localizedDescription)
        }
    }

    private func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        endpoint: Endpoint
    ) throws -> Response {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIClientError.invalidResponse(endpoint.request)
        }
    }
}

private enum Endpoint {
    case health
    case listSessions
    case serverInfo
    case createSession
    case session(id: String)
    case prompt(sessionID: String)
    case toolDecision(sessionID: String)
    case cancel(sessionID: String)

    var request: APIRequestDescriptor {
        switch self {
        case .health:
            return APIRequestDescriptor(method: "GET", path: "/healthz")
        case .listSessions:
            return APIRequestDescriptor(method: "GET", path: "/sessions")
        case .serverInfo:
            return APIRequestDescriptor(method: "GET", path: "/server-info")
        case .createSession:
            return APIRequestDescriptor(method: "POST", path: "/sessions")
        case .session(let id):
            return APIRequestDescriptor(method: "GET", path: "/sessions/\(id)")
        case .prompt(let sessionID):
            return APIRequestDescriptor(method: "POST", path: "/sessions/\(sessionID)/prompts")
        case .toolDecision(let sessionID):
            return APIRequestDescriptor(method: "POST", path: "/sessions/\(sessionID)/tool-decisions")
        case .cancel(let sessionID):
            return APIRequestDescriptor(method: "POST", path: "/sessions/\(sessionID)/cancel")
        }
    }

    func url(baseURL: URL) -> URL {
        switch self {
        case .health:
            return baseURL.appending(path: "healthz")
        case .listSessions, .createSession:
            return baseURL.appending(path: "sessions")
        case .serverInfo:
            return baseURL.appending(path: "server-info")
        case .session(let id):
            return baseURL.appending(path: "sessions").appending(path: id)
        case .prompt(let sessionID):
            return baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "prompts")
        case .toolDecision(let sessionID):
            return baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "tool-decisions")
        case .cancel(let sessionID):
            return baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "cancel")
        }
    }
}

private struct SessionEnvelope: Codable {
    let session: SessionSummary
}

private struct SessionListEnvelope: Codable {
    let sessions: [SessionSummary]
}

private struct AcceptedEnvelope: Codable {
    let accepted: Bool
}
