import AllHandsKit
import Foundation
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
    private var streamTask: Task<Void, Never>?
    private let lastSelectedServerDefaultsKey = "lastSelectedServerID"
    private var hasBootstrapped = false
    private var bootstrapInFlight = false
    private var signInInFlight = false
    private var completionInFlight = false

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
        self.discoveryService = discoveryService ?? ServerDiscoveryService()
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
        pendingAuthenticationURL = nil
        UserDefaults.standard.set(server.id, forKey: lastSelectedServerDefaultsKey)
        onboardingStatus = .connected
        await loadServerInfo()
        await loadSessions()
    }

    func loadSessions() async {
        guard let selectedServer else { return }
        await withClient(baseURL: selectedServer.baseURL) { [self] client in
            let sessions = try await client.listSessions()
            self.sessionStore.replaceSessions(sessions)
            if self.selectedSessionID == nil {
                self.selectedSessionID = sessions.first?.id
            }
        }
    }

    func refreshSelectedServer() async {
        await loadServerInfo()
        await loadSessions()
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
        await withClient(baseURL: selectedServer.baseURL) { [self] client in
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
        await withClient(baseURL: selectedServer.baseURL) { [self] client in
            try await client.sendPrompt(sessionID: selectedSessionID, prompt: PromptRequest(text: prompt))
            let refreshed = try await client.session(id: selectedSessionID)
            self.sessionStore.upsert(session: refreshed)
        }
    }

    func connectStream(for sessionID: String) {
        guard let selectedServer else { return }
        streamTask?.cancel()
        streamTask = Task {
            do {
                let session = try await tailnetProvider.makeURLSession()
                let sse = SSEClient(session: session)
                let stream = try await sse.stream(url: selectedServer.baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "events"))
                for try await event in stream {
                    guard let data = event.data?.data(using: .utf8) else { continue }
                    let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
                    await MainActor.run {
                        self.sessionStore.append(event: decoded)
                    }
                }
            } catch {
                await MainActor.run {
                    self.inlineError = error.localizedDescription
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

    private func loadServerInfo() async {
        guard let selectedServer else { return }
        await withClient(baseURL: selectedServer.baseURL) { [self] client in
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

    private func withClient(baseURL: URL, _ body: @escaping (APIClient) async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let session = try await tailnetProvider.makeURLSession()
            let client = APIClient(baseURL: baseURL, session: session)
            try await body(client)
            inlineError = nil
        } catch {
            inlineError = error.localizedDescription
        }
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
