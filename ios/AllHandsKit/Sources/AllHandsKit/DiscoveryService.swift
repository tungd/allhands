@preconcurrency import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(iOS) || os(macOS)
private final class BonjourBrowserCoordinator: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private var services: [NetService] = []
    private var resolved: [String: DiscoveredServer] = [:]
    private var continuation: CheckedContinuation<[DiscoveredServer], Never>?
    private let lock = NSLock()

    func begin(_ continuation: CheckedContinuation<[DiscoveredServer], Never>) {
        lock.lock()
        self.continuation = continuation
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
        guard let hostName = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              sender.port > 0 else {
            return
        }

        let metadata = Self.decodeTXTRecord(sender.txtRecordData())
        let name = metadata["name"] ?? sender.name
        let hostname = metadata["hostname"] ?? hostName
        let identifier = metadata["hostname"] ?? hostname
        let baseURL = URL(string: "http://\(hostname):\(sender.port)")!

        lock.lock()
        resolved[identifier] = DiscoveredServer(
            id: identifier,
            name: name,
            baseURL: baseURL,
            hostname: hostname,
            port: sender.port,
            source: .bonjour
        )
        lock.unlock()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish()
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

    private func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: currentServers())
    }

    private static func decodeTXTRecord(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        return NetService.dictionary(fromTXTRecord: data).reduce(into: [:]) { result, entry in
            result[entry.key] = String(data: entry.value, encoding: .utf8)
        }
    }
}
#endif

public struct DiscoveryConfiguration: Equatable, Sendable {
    public var bonjourServiceType: String
    public var bonjourDomain: String
    public var bonjourBrowseDurationNanoseconds: UInt64
    public var magicDNSHostCandidates: [String]
    public var defaultPort: Int

    public init(
        bonjourServiceType: String = "_allhands._tcp.",
        bonjourDomain: String = "local.",
        bonjourBrowseDurationNanoseconds: UInt64 = 3_000_000_000,
        magicDNSHostCandidates: [String] = ["allhands"],
        defaultPort: Int = 8080
    ) {
        self.bonjourServiceType = bonjourServiceType
        self.bonjourDomain = bonjourDomain
        self.bonjourBrowseDurationNanoseconds = bonjourBrowseDurationNanoseconds
        self.magicDNSHostCandidates = magicDNSHostCandidates
        self.defaultPort = defaultPort
    }
}

public protocol ServerDiscovering: Sendable {
    func discover(lastSelectedServerID: String?) async -> [DiscoveredServer]
}

public actor ServerDiscoveryService: ServerDiscovering {
    private let configuration: DiscoveryConfiguration
    private let sessionProvider: SessionProviding
    private let bonjourLookup: (() async -> [DiscoveredServer])?
    private let magicDNSLookup: (() async -> [DiscoveredServer])?

    public init(
        configuration: DiscoveryConfiguration = DiscoveryConfiguration(),
        sessionProvider: SessionProviding,
        bonjourLookup: (() async -> [DiscoveredServer])? = nil,
        magicDNSLookup: (() async -> [DiscoveredServer])? = nil
    ) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.bonjourLookup = bonjourLookup
        self.magicDNSLookup = magicDNSLookup
    }

    public func discover(lastSelectedServerID: String?) async -> [DiscoveredServer] {
        let bonjourServers = if let bonjourLookup { await bonjourLookup() } else { await browseBonjour() }
        let magicDNSServers = if let magicDNSLookup { await magicDNSLookup() } else { await probeMagicDNS() }
        let merged = dedupeServers(bonjourServers + magicDNSServers)
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
            if let existing = deduped[server.id], existing.source == .bonjour {
                continue
            }
            deduped[server.id] = server
        }
        return deduped.values.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.hostname < rhs.hostname
            }
            return lhs.name < rhs.name
        }
    }

    private func probeMagicDNS() async -> [DiscoveredServer] {
        do {
            let session = try await sessionProvider.makeURLSession()
            let hostCandidates = try await sessionProvider.tailnetHostCandidates(defaults: configuration.magicDNSHostCandidates)
            var discovered: [DiscoveredServer] = []
            for hostname in hostCandidates {
                guard let baseURL = URL(string: "http://\(hostname):\(configuration.defaultPort)") else {
                    continue
                }

                do {
                    let client = APIClient(baseURL: baseURL, session: session)
                    try await client.health(timeout: 2.0)
                    discovered.append(
                        DiscoveredServer(
                            id: hostname,
                            name: hostname,
                            baseURL: baseURL,
                            hostname: hostname,
                            port: configuration.defaultPort,
                            source: .magicDNS
                        )
                    )
                } catch {
                    continue
                }
            }
            return discovered
        } catch {
            return []
        }
    }

    private func browseBonjour() async -> [DiscoveredServer] {
        #if os(iOS) || os(macOS)
        return await withCheckedContinuation { continuation in
            let browser = NetServiceBrowser()
            let coordinator = BonjourBrowserCoordinator()
            coordinator.begin(continuation)
            BrowserDelegateRetainer.shared.retain(coordinator, for: browser)
            browser.delegate = coordinator
            browser.searchForServices(ofType: configuration.bonjourServiceType, inDomain: configuration.bonjourDomain)

            Task {
                try? await Task.sleep(nanoseconds: configuration.bonjourBrowseDurationNanoseconds)
                browser.stop()
                BrowserDelegateRetainer.shared.releaseDelegate(for: browser)
            }
        }
        #else
        return []
        #endif
    }
}

#if os(iOS) || os(macOS)
private final class BrowserDelegateRetainer: @unchecked Sendable {
    static let shared = BrowserDelegateRetainer()

    private var storage: [ObjectIdentifier: AnyObject] = [:]
    private let lock = NSLock()

    func retain(_ delegate: AnyObject, for browser: NetServiceBrowser) {
        lock.lock()
        storage[ObjectIdentifier(browser)] = delegate
        lock.unlock()
    }

    func releaseDelegate(for browser: NetServiceBrowser) {
        lock.lock()
        storage.removeValue(forKey: ObjectIdentifier(browser))
        lock.unlock()
    }
}
#endif
