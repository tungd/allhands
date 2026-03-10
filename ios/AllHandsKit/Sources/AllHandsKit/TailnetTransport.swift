import Foundation

#if canImport(TailscaleKit)
import TailscaleKit
#endif

public enum TailnetTransportError: Error, LocalizedError {
    case sdkUnavailable
    case invalidDataPath

    public var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "TailscaleKit.framework is not embedded in the app target."
        case .invalidDataPath:
            return "A writable data path is required for the embedded Tailscale node."
        }
    }
}

public struct TailnetConfiguration: Sendable, Equatable {
    public var hostName: String
    public var dataPath: String
    public var authKey: String
    public var controlURL: String
    public var ephemeral: Bool

    public init(hostName: String, dataPath: String, authKey: String, controlURL: String = "https://controlplane.tailscale.com", ephemeral: Bool = false) {
        self.hostName = hostName
        self.dataPath = dataPath
        self.authKey = authKey
        self.controlURL = controlURL
        self.ephemeral = ephemeral
    }
}

public protocol SessionProviding: Sendable {
    func makeURLSession() async throws -> URLSession
}

public struct DirectSessionProvider: SessionProviding {
    public init() {}

    public func makeURLSession() async throws -> URLSession {
        URLSession(configuration: .default)
    }
}

#if canImport(TailscaleKit)
public actor TailscaleSessionProvider: SessionProviding {
    private let configuration: TailnetConfiguration
    private var node: TailscaleNode?

    public init(configuration: TailnetConfiguration) {
        self.configuration = configuration
    }

    public func makeURLSession() async throws -> URLSession {
        if node == nil {
            let config = Configuration(
                hostName: configuration.hostName,
                path: configuration.dataPath,
                authKey: configuration.authKey,
                controlURL: configuration.controlURL,
                ephemeral: configuration.ephemeral
            )
            let tailscaleNode = try TailscaleNode(config: config, logger: DefaultLogger())
            try await tailscaleNode.up()
            node = tailscaleNode
        }

        guard let node else {
            throw TailnetTransportError.sdkUnavailable
        }

        let sessionConfiguration = try await URLSessionConfiguration.tailscaleSession(node)
        return URLSession(configuration: sessionConfiguration)
    }
}
#else
public struct TailscaleSessionProvider: SessionProviding {
    public init(configuration: TailnetConfiguration) {
        _ = configuration
    }

    public func makeURLSession() async throws -> URLSession {
        throw TailnetTransportError.sdkUnavailable
    }
}
#endif
