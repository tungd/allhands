@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#endif

#if os(iOS) || os(macOS)
private final class BonjourBrowserCoordinator: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredServer] = [:]
    private var continuation: CheckedContinuation<[DiscoveredServer], Never>?
    private var onFinish: (() -> Void)?
    private let lock = NSLock()

    func begin(
        _ continuation: CheckedContinuation<[DiscoveredServer], Never>,
        onFinish: @escaping () -> Void
    ) {
        lock.lock()
        self.continuation = continuation
        self.onFinish = onFinish
        lock.unlock()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        lock.lock()
        services.append(service)
        lock.unlock()
        service.resolve(withTimeout: 3.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        finish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else {
            return
        }

        let metadata = Self.decodeTXTRecord(sender.txtRecordData())
        let name = metadata["name"] ?? sender.name
        guard let connectionHost =
            Self.normalizedHostName(sender.hostName)
            ?? Self.normalizedHostName(metadata["hostname"]) else {
            if let ipAddress = Self.firstIPAddress(from: sender.addresses) {
                storeResolvedServer(
                    id: metadata["hostname"] ?? ipAddress,
                    name: name,
                    baseURL: URL(string: "http://\(ipAddress):\(sender.port)")!,
                    hostname: ipAddress,
                    port: sender.port
                )
            }
            return
        }

        storeResolvedServer(
            id: metadata["hostname"] ?? connectionHost,
            name: name,
            baseURL: URL(string: "http://\(connectionHost):\(sender.port)")!,
            hostname: connectionHost,
            port: sender.port
        )
    }

    private func storeResolvedServer(id: String, name: String, baseURL: URL, hostname: String, port: Int) {
        lock.lock()
        resolved[id] = DiscoveredServer(
            id: id,
            name: name,
            baseURL: baseURL,
            hostname: hostname,
            port: port,
            source: .bonjour
        )
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let _ = sender
        let _ = errorDict
    }

    private func currentServers() -> [DiscoveredServer] {
        lock.lock()
        defer { lock.unlock() }
        return resolved.values.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.hostname < rhs.hostname
            }
            return lhs.name < rhs.name
        }
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let onFinish = self.onFinish
        self.onFinish = nil
        lock.unlock()
        onFinish?()
        continuation?.resume(returning: currentServers())
    }

    private static func decodeTXTRecord(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        return NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, entry in
            result[entry.key] = String(data: entry.value, encoding: .utf8)
        }
    }

    private static func normalizedHostName(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: ".")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(".") {
            return trimmed
        }
        return "\(trimmed).local"
    }

    private static func firstIPAddress(from addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for address in addresses {
            if let ipAddress = ipAddress(from: address) {
                return ipAddress
            }
        }
        return nil
    }

    private static func ipAddress(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let sockaddrPointer = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                return nil
            }

            switch Int32(sockaddrPointer.pointee.sa_family) {
            case AF_INET:
                guard let ipv4Pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr_in.self) else {
                    return nil
                }
                var address = ipv4Pointer.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return String(cString: buffer)
            case AF_INET6:
                guard let ipv6Pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr_in6.self) else {
                    return nil
                }
                var address = ipv6Pointer.pointee.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return "[\(String(cString: buffer))]"
            default:
                return nil
            }
        }
    }
}
#endif

public struct DiscoveryConfiguration: Equatable, Sendable {
    public var bonjourServiceType: String
    public var bonjourDomain: String
    public var bonjourBrowseDurationNanoseconds: UInt64

    public init(
        bonjourServiceType: String = "_allhands._tcp.",
        bonjourDomain: String = "local.",
        bonjourBrowseDurationNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.bonjourServiceType = bonjourServiceType
        self.bonjourDomain = bonjourDomain
        self.bonjourBrowseDurationNanoseconds = bonjourBrowseDurationNanoseconds
    }
}

public protocol ServerDiscovering: Sendable {
    func discover(lastSelectedServerID: String?) async -> [DiscoveredServer]
}

public actor ServerDiscoveryService: ServerDiscovering {
    private let configuration: DiscoveryConfiguration
    private let bonjourLookup: (@Sendable () async -> [DiscoveredServer])?
    private let tailnetLookup: (@Sendable () async -> [DiscoveredServer])?

    public init(
        configuration: DiscoveryConfiguration = DiscoveryConfiguration(),
        bonjourLookup: (@Sendable () async -> [DiscoveredServer])? = nil,
        tailnetLookup: (@Sendable () async -> [DiscoveredServer])? = nil
    ) {
        self.configuration = configuration
        self.bonjourLookup = bonjourLookup
        self.tailnetLookup = tailnetLookup
    }

    public func discover(lastSelectedServerID: String?) async -> [DiscoveredServer] {
        async let bonjourServers: [DiscoveredServer] = if let bonjourLookup { await bonjourLookup() } else { await browseBonjour() }
        async let tailnetServers: [DiscoveredServer] = if let tailnetLookup { await tailnetLookup() } else { [] }
        let bonjourResults = await bonjourServers
        let tailnetResults = await tailnetServers
        let merged = dedupeServers(bonjourResults + tailnetResults)
        guard !merged.isEmpty else { return [] }

        if let lastSelectedServerID,
           let preferred = merged.first(where: { $0.id == lastSelectedServerID }) {
            return [preferred] + merged.filter { $0.id != preferred.id }
        }

        return merged
    }

    private func dedupeServers(_ servers: [DiscoveredServer]) -> [DiscoveredServer] {
        var deduped: [String: DiscoveredServer] = [:]
        for server in servers {
            let key = canonicalDiscoveryKey(for: server)
            if let existing = deduped[key] {
                if existing.source == .bonjour {
                    continue
                }
                if server.source == .bonjour {
                    deduped[key] = server
                    continue
                }
            }
            deduped[key] = server
        }
        return deduped.values.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.hostname < rhs.hostname
            }
            return lhs.name < rhs.name
        }
    }

    private func canonicalDiscoveryKey(for server: DiscoveredServer) -> String {
        let hostname = server.hostname
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        if !hostname.isEmpty {
            return hostname
        }
        return server.id.lowercased()
    }

    private func browseBonjour() async -> [DiscoveredServer] {
        #if os(iOS) || os(macOS)
        return await withCheckedContinuation { continuation in
            let browser = NetServiceBrowser()
            let coordinator = BonjourBrowserCoordinator()
            coordinator.begin(continuation) {
                BrowserSearchRetainer.shared.releaseSearch(for: browser)
            }
            BrowserSearchRetainer.shared.retain(browser: browser, delegate: coordinator)
            browser.delegate = coordinator
            browser.searchForServices(ofType: configuration.bonjourServiceType, inDomain: configuration.bonjourDomain)

            Task {
                try? await Task.sleep(nanoseconds: configuration.bonjourBrowseDurationNanoseconds)
                browser.stop()
                coordinator.finish()
            }
        }
        #else
        return []
        #endif
    }
}

public enum TailnetServerDiscovery {
    public static func discover(
        using sessionProvider: SessionProviding,
        port: Int = 8080,
        timeout: TimeInterval = 1.5
    ) async -> [DiscoveredServer] {
        guard let session = try? await sessionProvider.makeURLSession() else {
            return []
        }
        guard let peers = try? await sessionProvider.discoverPeers(), !peers.isEmpty else {
            return []
        }

        return await withTaskGroup(of: DiscoveredServer?.self) { group in
            for peer in peers {
                group.addTask {
                    await probePeer(peer, port: port, timeout: timeout, session: session)
                }
            }

            var discovered: [DiscoveredServer] = []
            for await result in group {
                if let result {
                    discovered.append(result)
                }
            }
            return discovered
        }
    }

    private static func probePeer(
        _ peer: TailnetPeer,
        port: Int,
        timeout: TimeInterval,
        session: URLSession
    ) async -> DiscoveredServer? {
        for hostname in peer.hostnames {
            guard let baseURL = URL(string: "http://\(hostname):\(port)") else {
                continue
            }
            let client = APIClient(baseURL: baseURL, session: session)
            do {
                try await client.health(timeout: timeout)
                return DiscoveredServer(
                    id: peer.id,
                    name: peer.name,
                    baseURL: baseURL,
                    hostname: hostname,
                    port: port,
                    source: .tailnet
                )
            } catch {
                continue
            }
        }
        return nil
    }
}

#if os(iOS) || os(macOS)
private final class BrowserSearchRetainer: @unchecked Sendable {
    static let shared = BrowserSearchRetainer()

    private final class SearchLease {
        let browser: NetServiceBrowser
        let delegate: AnyObject

        init(browser: NetServiceBrowser, delegate: AnyObject) {
            self.browser = browser
            self.delegate = delegate
        }
    }

    private var storage: [ObjectIdentifier: SearchLease] = [:]
    private let lock = NSLock()

    func retain(browser: NetServiceBrowser, delegate: AnyObject) {
        lock.lock()
        storage[ObjectIdentifier(browser)] = SearchLease(browser: browser, delegate: delegate)
        lock.unlock()
    }

    func releaseSearch(for browser: NetServiceBrowser) {
        lock.lock()
        storage.removeValue(forKey: ObjectIdentifier(browser))
        lock.unlock()
    }
}
#endif
