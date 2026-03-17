import Foundation
import Testing
@testable import AllHandsKit

@Test
func sessionRoundTripDecodes() throws {
    let event = StreamEvent(
        id: "session_1:1",
        sessionId: "session_1",
        seq: 1,
        type: "acp.thought",
        timestamp: 12.5,
        payload: .object(["text": .string("hello")])
    )

    let encoded = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(StreamEvent.self, from: encoded)

    #expect(decoded == event)
}

@Test
func sseParserBuildsEventBlock() {
    var parser = SSEParser()
    #expect(parser.feed(line: "id: one") == nil)
    #expect(parser.feed(line: "event: acp.thought") == nil)
    #expect(parser.feed(line: "data: {\"hello\":\"world\"}") == nil)
    let event = parser.feed(line: "")

    #expect(event == ServerSentEvent(id: "one", event: "acp.thought", data: "{\"hello\":\"world\"}"))
}

@Test
func sessionStoreAppendsInOrder() async {
    let store = await MainActor.run { SessionStore() }
    await MainActor.run {
        store.append(event: StreamEvent(id: "session:2", sessionId: "session", seq: 2, type: "acp.status", timestamp: 2, payload: .null))
        store.append(event: StreamEvent(id: "session:1", sessionId: "session", seq: 1, type: "acp.init", timestamp: 1, payload: .null))
    }
    let events = await MainActor.run { store.events(for: "session") }
    #expect(events.map(\.seq) == [1, 2])
}

@Test
func directProviderReturnsSession() async throws {
    let provider = DirectSessionProvider()
    #expect(try await provider.restore())
    #expect(try await provider.prepareAuthenticationURL() == nil)
    try await provider.completeAuthentication()
    let session = try await provider.makeURLSession()
    #expect(session.configuration.identifier == nil)
}

@Test
func discoveryPrefersBonjourAndReordersLastSelected() async {
    let service = ServerDiscoveryService(
        bonjourLookup: {
            [
                DiscoveredServer(
                    id: "allhands",
                    name: "All Hands",
                    baseURL: URL(string: "http://allhands.local:8080")!,
                    hostname: "allhands",
                    port: 8080,
                    source: .bonjour
                ),
                DiscoveredServer(
                    id: "backup",
                    name: "backup",
                    baseURL: URL(string: "http://backup.local:8080")!,
                    hostname: "backup",
                    port: 8080,
                    source: .bonjour
                )
            ]
        }
    )

    let discovered = await service.discover(lastSelectedServerID: "backup")
    #expect(discovered.map(\.id) == ["backup", "allhands"])
    #expect(discovered[1].source == .bonjour)
}

@Test
func serverInfoDecodes() throws {
    let data = Data(
        """
        {
          "launchRootPath": "/Users/tung/Projects/std23/allhands",
          "defaultAgent": "codex",
          "availableAgents": [
            { "id": "codex", "displayName": "Codex" },
            { "id": "claude", "displayName": "Claude Code" }
          ]
        }
        """.utf8
    )

    let decoded = try JSONDecoder().decode(ServerInfo.self, from: data)
    #expect(decoded.launchRootPath == "/Users/tung/Projects/std23/allhands")
    #expect(decoded.defaultAgent == "codex")
    #expect(decoded.availableAgents.map(\.id) == ["codex", "claude"])
}

@Test
func createSessionRequestEncodesStructuredLaunchFields() throws {
    let request = CreateSessionRequest(folderPath: "apps/api", agent: "codex")
    let encoded = try JSONEncoder().encode(request)
    let json = try JSONSerialization.jsonObject(with: encoded) as? [String: String]

    #expect(json?["folderPath"] == "apps/api")
    #expect(json?["agent"] == "codex")
    #expect(json?["repoPath"] == nil)
}
