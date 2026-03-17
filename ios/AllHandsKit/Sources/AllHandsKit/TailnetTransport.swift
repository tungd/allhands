import Foundation

#if canImport(TailscaleKit)
import TailscaleKit
#endif

public enum TailnetTransportError: Error, LocalizedError {
    case sdkUnavailable
    case invalidDataPath
    case loginRequired
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .sdkUnavailable:
            return "TailscaleKit.framework is not embedded in the app target."
        case .invalidDataPath:
            return "A writable data path is required for the embedded Tailscale node."
        case .loginRequired:
            return "Tailscale sign-in is required before continuing."
        case .notAuthenticated:
            return "The embedded Tailscale node is not authenticated."
        }
    }
}

public struct TailnetConfiguration: Sendable, Equatable {
    public var hostName: String
    public var statePath: String
    public var controlURL: String

    public init(hostName: String, statePath: String, controlURL: String = "https://controlplane.tailscale.com") {
        self.hostName = hostName
        self.statePath = statePath
        self.controlURL = controlURL
    }
}

public struct TailnetPeer: Equatable, Sendable {
    public var id: String
    public var name: String
    public var hostnames: [String]

    public init(id: String, name: String, hostnames: [String]) {
        self.id = id
        self.name = name
        self.hostnames = hostnames
    }
}

public protocol SessionProviding: Sendable {
    func restore() async throws -> Bool
    func prepareAuthenticationURL() async throws -> URL?
    func completeAuthentication() async throws
    func makeURLSession() async throws -> URLSession
    func discoverPeers() async throws -> [TailnetPeer]
}

public struct DirectSessionProvider: SessionProviding {
    public init() {}

    public func restore() async throws -> Bool {
        true
    }

    public func prepareAuthenticationURL() async throws -> URL? {
        nil
    }

    public func completeAuthentication() async throws {}

    public func makeURLSession() async throws -> URLSession {
        URLSession(configuration: .default)
    }

    public func discoverPeers() async throws -> [TailnetPeer] {
        []
    }
}

#if canImport(TailscaleKit)
private actor InteractiveLoginConsumer: MessageConsumer {
    private var continuation: CheckedContinuation<URL, Error>?
    private var resolved = false

    func installContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        guard !resolved else {
            continuation.resume(throwing: TailnetTransportError.loginRequired)
            return
        }
        self.continuation = continuation
    }

    func notify(_ notify: Ipn.Notify) {
        guard !resolved else { return }

        if let browseToURL = notify.BrowseToURL,
           let url = URL(string: browseToURL) {
            resolved = true
            continuation?.resume(returning: url)
            continuation = nil
        }
    }

    func error(_ error: any Error) {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func finishWithoutURL() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(throwing: TailnetTransportError.loginRequired)
        continuation = nil
    }
}

public actor TailscaleSessionProvider: SessionProviding {
    private let configuration: TailnetConfiguration
    private var node: TailscaleNode?
    private var localAPIClient: LocalAPIClient?
    private var cachedSession: URLSession?

    public init(configuration: TailnetConfiguration) {
        self.configuration = configuration
    }

    public func restore() async throws -> Bool {
        try ensureDataPath()
        _ = try await prepareLocalAPIClient()
        return try await backendState() == "Running"
    }

    public func prepareAuthenticationURL() async throws -> URL? {
        let client = try await prepareLocalAPIClient()
        if try await backendState() == "Running" {
            return nil
        }
        return try await awaitInteractiveLoginURL(using: client)
    }

    public func completeAuthentication() async throws {
        _ = try await prepareLocalAPIClient()
        for _ in 0..<120 {
            if try await backendState() == "Running" {
                cachedSession = nil
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TailnetTransportError.notAuthenticated
    }

    public func makeURLSession() async throws -> URLSession {
        if let cachedSession {
            return cachedSession
        }

        let node = try await prepareNode()
        guard try await backendState() == "Running" else {
            throw TailnetTransportError.loginRequired
        }

        let sessionConfiguration = try await URLSessionConfiguration.tailscaleSession(node).0
        let session = URLSession(configuration: sessionConfiguration)
        cachedSession = session
        return session
    }

    public func discoverPeers() async throws -> [TailnetPeer] {
        let status = try await backendStatusDetails()
        guard status.BackendState == "Running" else {
            return []
        }

        let magicDNSSuffix = normalizedHostName(status.CurrentTailnet?.MagicDNSSuffix)
        let peers: [IpnState.PeerStatus] = status.Peer.map { Array($0.values) } ?? []

        return peers.compactMap { peer -> TailnetPeer? in
            let hostName = normalizedHostName(peer.HostName)
            let dnsName = normalizedHostName(peer.DNSName)
            var hostnames: [String] = []

            if let dnsName {
                hostnames.append(dnsName)
            }

            if let hostName, let magicDNSSuffix {
                hostnames.append("\(hostName).\(magicDNSSuffix)")
            }

            hostnames = uniqueHostnames(hostnames)
            hostnames.removeAll(where: shouldIgnoreHostName)
            guard !hostnames.isEmpty else {
                return nil
            }

            return TailnetPeer(
                id: dnsName ?? hostnames[0],
                name: hostName ?? dnsName ?? hostnames[0],
                hostnames: hostnames
            )
        }
    }

    private func prepareNode() async throws -> TailscaleNode {
        try ensureDataPath()
        if node == nil {
            let config = Configuration(
                hostName: configuration.hostName,
                path: configuration.statePath,
                authKey: nil,
                controlURL: configuration.controlURL,
                ephemeral: false
            )
            let tailscaleNode = try TailscaleNode(config: config, logger: nil)
            try await tailscaleNode.up()
            node = tailscaleNode
        }

        guard let node else {
            throw TailnetTransportError.sdkUnavailable
        }

        return node
    }

    private func prepareLocalAPIClient() async throws -> LocalAPIClient {
        if let localAPIClient {
            return localAPIClient
        }

        let node = try await prepareNode()
        let client = LocalAPIClient(localNode: node, logger: nil)
        localAPIClient = client
        return client
    }

    private func ensureDataPath() throws {
        guard !configuration.statePath.isEmpty else {
            throw TailnetTransportError.invalidDataPath
        }
        try FileManager.default.createDirectory(atPath: configuration.statePath, withIntermediateDirectories: true, attributes: nil)
    }

    private func backendState() async throws -> String {
        try await backendStatusDetails().BackendState
    }

    private func backendStatusDetails() async throws -> IpnState.Status {
        let client = try await prepareLocalAPIClient()
        return try await client.backendStatus()
    }

    private func awaitInteractiveLoginURL(using client: LocalAPIClient) async throws -> URL {
        let consumer = InteractiveLoginConsumer()
        let processor = try await client.watchIPNBus(mask: [.initialState], consumer: consumer)
        defer { processor.cancel() }

        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await consumer.installContinuation(continuation)
                    }
                }
            }

            group.addTask {
                try await client.startLoginInteractive()
                for _ in 0..<20 {
                    let status = try await client.backendStatus()
                    if !status.AuthURL.isEmpty, let url = URL(string: status.AuthURL) {
                        return url
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }

                await consumer.finishWithoutURL()
                throw TailnetTransportError.loginRequired
            }

            let url = try await group.next() ?? {
                throw TailnetTransportError.loginRequired
            }()
            group.cancelAll()
            return url
        }
    }

    private func normalizedHostName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func uniqueHostnames(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let normalized = value.lowercased()
            return seen.insert(normalized).inserted
        }
    }

    private func shouldIgnoreHostName(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized == "localhost" || !normalized.contains(".")
    }
}
#else
public struct TailscaleSessionProvider: SessionProviding {
    public init(configuration: TailnetConfiguration) {
        _ = configuration
    }

    public func restore() async throws -> Bool {
        false
    }

    public func prepareAuthenticationURL() async throws -> URL? {
        throw TailnetTransportError.sdkUnavailable
    }

    public func completeAuthentication() async throws {
        throw TailnetTransportError.sdkUnavailable
    }

    public func makeURLSession() async throws -> URLSession {
        throw TailnetTransportError.sdkUnavailable
    }

    public func discoverPeers() async throws -> [TailnetPeer] {
        []
    }
}
#endif
