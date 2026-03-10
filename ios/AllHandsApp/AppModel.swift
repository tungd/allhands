import AllHandsKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = ServerConfiguration(
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        repoPath: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/",
        agentCommand: "/usr/bin/env",
        agentArgs: ["python3", "server/test_support/fake_acp_agent.py"],
        useTailnet: false
    )
    @Published var selectedSessionID: String?
    @Published var promptText = ""
    @Published var inlineError: String?
    @Published var isBusy = false
    @Published var tailnetAuthKey = ""

    let sessionStore = SessionStore()
    private var streamTask: Task<Void, Never>?

    var selectedSession: SessionSummary? {
        sessionStore.sessions.first(where: { $0.id == selectedSessionID })
    }

    func loadSessions() async {
        await withClient { [self] client in
            let sessions = try await client.listSessions()
            self.sessionStore.replaceSessions(sessions)
            if self.selectedSessionID == nil {
                self.selectedSessionID = sessions.first?.id
            }
        }
    }

    func createSession() async {
        let request = CreateSessionRequest(
            repoPath: configuration.repoPath,
            agentCommand: configuration.agentCommand,
            agentArgs: configuration.agentArgs
        )
        await withClient { [self] client in
            let session = try await client.createSession(request)
            self.sessionStore.upsert(session: session)
            self.selectedSessionID = session.id
            self.connectStream(for: session.id)
        }
    }

    func sendPrompt() async {
        guard let selectedSessionID, !promptText.isEmpty else { return }
        let prompt = promptText
        promptText = ""
        await withClient { [self] client in
            try await client.sendPrompt(sessionID: selectedSessionID, prompt: PromptRequest(text: prompt))
            let refreshed = try await client.session(id: selectedSessionID)
            self.sessionStore.upsert(session: refreshed)
        }
    }

    func connectStream(for sessionID: String) {
        streamTask?.cancel()
        streamTask = Task {
            do {
                let session = try await sessionProvider().makeURLSession()
                let client = APIClient(baseURL: configuration.baseURL, session: session)
                let sse = SSEClient(session: session)
                let stream = try await sse.stream(url: configuration.baseURL.appending(path: "sessions").appending(path: sessionID).appending(path: "events"))
                for try await event in stream {
                    guard let data = event.data?.data(using: .utf8) else { continue }
                    let decoded = try JSONDecoder().decode(StreamEvent.self, from: data)
                    await MainActor.run {
                        self.sessionStore.append(event: decoded)
                    }
                }
                _ = client
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

    private func sessionProvider() -> any SessionProviding {
        if configuration.useTailnet {
            let tailscaleConfig = TailnetConfiguration(
                hostName: "AllHands",
                dataPath: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: "tailscale").path ?? "",
                authKey: tailnetAuthKey
            )
            return TailscaleSessionProvider(configuration: tailscaleConfig)
        }

        return DirectSessionProvider()
    }

    private func withClient(_ body: @escaping (APIClient) async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let session = try await sessionProvider().makeURLSession()
            let client = APIClient(baseURL: configuration.baseURL, session: session)
            try await body(client)
            inlineError = nil
        } catch {
            inlineError = error.localizedDescription
        }
    }
}
