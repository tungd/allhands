import AllHandsKit
import Foundation
import OSLog
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var sessionConfiguration = SessionCreationConfiguration(
        folderPath: ".",
        agent: ""
    )
    @Published var serverInfo: ServerInfo?
    @Published var selectedSessionID: String?
    @Published var promptText = ""
    @Published var inlineError: String?
    @Published var isBusy = false
    @Published var onboardingStatus: OnboardingStatus = .signedOut
    @Published var discoveredServers: [DiscoveredServer] = []
    @Published var selectedServer: DiscoveredServer?
    @Published var pendingAuthenticationURL: URL?

    let sessionStore = SessionStore()

    private let tailnetProvider: SessionProviding
    private let discoveryService: ServerDiscovering
    private let directSession: URLSession
    private var streamTask: Task<Void, Never>?
    private let lastSelectedServerDefaultsKey = "lastSelectedServerID"
    private var hasBootstrapped = false
    private var bootstrapInFlight = false
    private var signInInFlight = false
    private var completionInFlight = false
    private let logger = Logger(subsystem: "dev.allhands.ios", category: "AppModel")

    init(
        tailnetProvider: SessionProviding? = nil,
        discoveryService: ServerDiscovering? = nil
    ) {
        let tailscaleStatePath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appending(path: "tailscale")
            .path ?? ""
        let provider = tailnetProvider ?? TailscaleSessionProvider(
            configuration: TailnetConfiguration(
                hostName: "AllHands",
                statePath: tailscaleStatePath
            )
        )
        self.tailnetProvider = provider
        self.discoveryService = discoveryService ?? ServerDiscoveryService(
            tailnetLookup: {
                await TailnetServerDiscovery.discover(using: provider)
            }
        )
        self.directSession = URLSession(configuration: .default)
    }

    var selectedSession: SessionSummary? {
        sessionStore.sessions.first(where: { $0.id == selectedSessionID })
    }

    var canCreateSession: Bool {
        selectedServer != nil
            && serverInfo != nil
            && !(serverInfo?.availableAgents.isEmpty ?? true)
            && !sessionConfiguration.agent.isEmpty
            && !sessionConfiguration.folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var availableAgents: [AvailableAgent] {
        serverInfo?.availableAgents ?? []
    }

    func bootstrap() async {
        guard !hasBootstrapped, !bootstrapInFlight else { return }
        bootstrapInFlight = true
        defer {
            bootstrapInFlight = false
            hasBootstrapped = true
        }

        inlineError = nil
        if await restoreTailnetIfPossible() {
            await discoverServers()
        } else {
            onboardingStatus = .signedOut
        }
    }

    func beginSignIn() async {
        guard !signInInFlight else { return }
        signInInFlight = true
        defer { signInInFlight = false }

        onboardingStatus = .authInProgress
        pendingAuthenticationURL = nil
        do {
            if let url = try await tailnetProvider.prepareAuthenticationURL() {
                pendingAuthenticationURL = url
            } else {
                await discoverServers()
            }
        } catch {
            onboardingStatus = .error(error.localizedDescription)
            inlineError = error.localizedDescription
        }
    }

    func completeAuthentication() async {
        guard !completionInFlight else { return }
        completionInFlight = true
        defer { completionInFlight = false }

        onboardingStatus = .authInProgress
        do {
            let completed = try await withTimeout(seconds: 12) { [self] in
                try await self.tailnetProvider.completeAuthentication()
                return true
            } ?? false
            guard completed else {
                throw TailnetTransportError.notAuthenticated
            }
            await discoverServers()
        } catch {
            onboardingStatus = .error(error.localizedDescription)
            inlineError = error.localizedDescription
        }
    }

    func selectServer(_ server: DiscoveredServer) async {
        selectedServer = server
        serverInfo = nil
        sessionStore.replaceSessions([])
        selectedSessionID = nil
        pendingAuthenticationURL = nil
        UserDefaults.standard.set(server.id, forKey: lastSelectedServerDefaultsKey)
        onboardingStatus = .connected
        if await loadServerInfo() {
            _ = await loadSessions()
        }
    }

    @discardableResult
    func loadSessions() async -> Bool {
        guard let selectedServer else { return false }
        return await withClient(server: selectedServer, operation: .sessionList) { [self] client in
            let sessions = try await client.listSessions()
            self.sessionStore.replaceSessions(sessions)
            if self.selectedSessionID == nil {
                self.selectedSessionID = sessions.first?.id
            }
        }
    }

    func refreshSelectedServer() async {
        if await loadServerInfo() {
            _ = await loadSessions()
        }
    }

    func retryDiscovery() async {
        await discoverServers()
    }

    func createSession() async {
        guard let selectedServer, canCreateSession else { return }
        let request = CreateSessionRequest(
            folderPath: sessionConfiguration.folderPath,
            agent: sessionConfiguration.agent
        )
        await withClient(server: selectedServer, operation: .sessionCreate) { [self] client in
            let session = try await client.createSession(request)
            self.sessionStore.upsert(session: session)
            self.selectedSessionID = session.id
            self.connectStream(for: session.id)
        }
    }

    func sendPrompt() async {
        guard let selectedSessionID, !promptText.isEmpty, let selectedServer else { return }
        let prompt = promptText
        promptText = ""
        await withClient(server: selectedServer, operation: .promptSend) { client in
            try await client.sendPrompt(sessionID: selectedSessionID, prompt: PromptRequest(text: prompt))
        }
    }

    func connectStream(for sessionID: String) {
        guard let selectedServer else { return }
        streamTask?.cancel()
        streamTask = Task {
            do {
                let session = try await urlSession(for: selectedServer, operation: .sessionStream)
                let sse = SSEClient(session: session)
                let stream = try await sse.stream(url: selectedServer.baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "events"))
                for try await event in stream {
                    guard let data = event.data?.data(using: .utf8) else { continue }
                    let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
                    await MainActor.run {
                        self.sessionStore.append(event: decoded)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                let inlineError = self.operationErrorMessage(for: error, operation: .sessionStream, server: selectedServer)
                await MainActor.run {
                    self.inlineError = inlineError
                }
            }
        }
    }

    func events(for sessionID: String?) -> [StreamEvent] {
        guard let sessionID else { return [] }
        return sessionStore.events(for: sessionID)
    }

    private func restoreTailnetIfPossible() async -> Bool {
        onboardingStatus = .authInProgress
        do {
            return try await withTimeout(seconds: 8) { [self] in
                try await self.tailnetProvider.restore()
            } ?? false
        } catch {
            inlineError = error.localizedDescription
            return false
        }
    }

    private func discoverServers() async {
        onboardingStatus = .discovering
        let lastSelected = UserDefaults.standard.string(forKey: lastSelectedServerDefaultsKey)
        let servers = await discoveryService.discover(lastSelectedServerID: lastSelected)
        discoveredServers = servers

        guard !servers.isEmpty else {
            inlineError = "No All Hands server was discovered."
            onboardingStatus = .noServers
            return
        }

        if servers.count == 1 {
            await selectServer(servers[0])
        } else {
            onboardingStatus = .serverSelection
        }
    }

    @discardableResult
    private func loadServerInfo() async -> Bool {
        guard let selectedServer else { return false }
        return await withClient(server: selectedServer, operation: .serverInfo) { [self] client in
            let info = try await client.serverInfo()
            self.serverInfo = info
            if let existing = info.availableAgents.first(where: { $0.id == self.sessionConfiguration.agent }) {
                self.sessionConfiguration.agent = existing.id
            } else if let defaultAgent = info.defaultAgent {
                self.sessionConfiguration.agent = defaultAgent
            } else {
                self.sessionConfiguration.agent = info.availableAgents.first?.id ?? ""
            }
            if self.sessionConfiguration.folderPath.isEmpty {
                self.sessionConfiguration.folderPath = "."
            }
        }
    }

    private func withClient(
        server: DiscoveredServer,
        operation: ClientOperation,
        _ body: @escaping (APIClient) async throws -> Void
    ) async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            let client = try await apiClient(for: server, operation: operation)
            try await body(client)
            inlineError = nil
            return true
        } catch {
            inlineError = operationErrorMessage(for: error, operation: operation, server: server)
            return false
        }
    }

    private func apiClient(for server: DiscoveredServer, operation: ClientOperation) async throws -> APIClient {
        let session = try await urlSession(for: server, operation: operation)
        return APIClient(baseURL: server.baseURL, session: session)
    }

    private func urlSession(for server: DiscoveredServer, operation: ClientOperation) async throws -> URLSession {
        logger.debug(
            "Starting \(operation.rawValue, privacy: .public) for \(server.baseURL.absoluteString, privacy: .public) source=\(server.source.rawValue, privacy: .public) transport=\(server.transport.rawValue, privacy: .public)"
        )
        switch server.transport {
        case .direct:
            return directSession
        case .tailnet:
            return try await tailnetProvider.makeURLSession()
        }
    }

    private func operationErrorMessage(
        for error: Error,
        operation: ClientOperation,
        server: DiscoveredServer
    ) -> String {
        logger.error(
            "Operation \(operation.rawValue, privacy: .public) failed for \(server.baseURL.absoluteString, privacy: .public) source=\(server.source.rawValue, privacy: .public) transport=\(server.transport.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
        return ClientOperationError(
            operation: operation,
            server: server,
            underlyingDescription: error.localizedDescription
        ).localizedDescription
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let duration = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: duration)
                return nil
            }

            let result = try await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
