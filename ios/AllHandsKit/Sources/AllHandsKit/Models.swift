import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct CreateSessionRequest: Codable, Equatable, Sendable {
    public var folderPath: String
    public var agent: String

    public init(folderPath: String, agent: String) {
        self.folderPath = folderPath
        self.agent = agent
    }
}

public struct PromptRequest: Codable, Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ToolDecisionRequest: Codable, Equatable, Sendable {
    public var requestId: JSONValue?
    public var callId: String?
    public var optionId: String?
    public var decision: String?
    public var note: String?

    public init(
        requestId: JSONValue? = nil,
        callId: String? = nil,
        optionId: String? = nil,
        decision: String? = nil,
        note: String? = nil
    ) {
        self.requestId = requestId
        self.callId = callId
        self.optionId = optionId
        self.decision = decision
        self.note = note
    }
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var status: String
    public var repoPath: String
    public var worktreePath: String
    public var createdAt: Double

    public init(id: String, status: String, repoPath: String, worktreePath: String, createdAt: Double) {
        self.id = id
        self.status = status
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.createdAt = createdAt
    }
}

public enum DiscoverySource: String, Codable, Equatable, Sendable {
    case bonjour
    case tailnet
}

public struct DiscoveredServer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var hostname: String
    public var port: Int
    public var source: DiscoverySource

    public init(id: String, name: String, baseURL: URL, hostname: String, port: Int, source: DiscoverySource) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.hostname = hostname
        self.port = port
        self.source = source
    }
}

public enum OnboardingStatus: Equatable, Sendable {
    case signedOut
    case authInProgress
    case discovering
    case noServers
    case serverSelection
    case connected
    case error(String)
}

public struct SessionCreationConfiguration: Equatable, Sendable {
    public var folderPath: String
    public var agent: String

    public init(folderPath: String, agent: String) {
        self.folderPath = folderPath
        self.agent = agent
    }
}

public struct AvailableAgent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct ServerInfo: Codable, Equatable, Sendable {
    public var launchRootPath: String
    public var defaultAgent: String?
    public var availableAgents: [AvailableAgent]

    public init(launchRootPath: String, defaultAgent: String?, availableAgents: [AvailableAgent]) {
        self.launchRootPath = launchRootPath
        self.defaultAgent = defaultAgent
        self.availableAgents = availableAgents
    }
}

public struct StreamEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var sessionId: String
    public var seq: Int
    public var type: String
    public var timestamp: Double
    public var payload: JSONValue

    public init(id: String, sessionId: String, seq: Int, type: String, timestamp: Double, payload: JSONValue) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.type = type
        self.timestamp = timestamp
        self.payload = payload
    }
}
