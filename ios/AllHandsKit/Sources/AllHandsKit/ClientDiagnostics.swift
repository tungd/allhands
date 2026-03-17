import Foundation

public enum ServerTransport: String, Codable, Equatable, Sendable {
    case direct
    case tailnet
}

public enum ClientOperation: String, Sendable {
    case serverInfo = "server info"
    case sessionList = "session list"
    case sessionCreate = "session creation"
    case promptSend = "prompt send"
    case sessionStream = "session stream"
}

public struct ClientOperationError: Error, LocalizedError, Sendable {
    public let operation: ClientOperation
    public let serverHost: String
    public let serverSource: DiscoverySource
    public let underlyingDescription: String

    public init(operation: ClientOperation, server: DiscoveredServer, underlyingDescription: String) {
        self.operation = operation
        self.serverHost = server.baseURL.host ?? server.hostname
        self.serverSource = server.source
        self.underlyingDescription = underlyingDescription
    }

    public var errorDescription: String? {
        "Failed during \(operation.rawValue) for \(serverHost) over \(serverSource.rawValue): \(underlyingDescription)"
    }
}

public extension DiscoveredServer {
    var transport: ServerTransport {
        switch source {
        case .bonjour:
            return .direct
        case .tailnet:
            return .tailnet
        }
    }
}
