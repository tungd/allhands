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
                    baseURL: URL(string: "http://allhands.local:21991")!,
                    hostname: "allhands",
                    port: 21991,
                    source: .bonjour
                ),
                DiscoveredServer(
                    id: "backup",
                    name: "backup",
                    baseURL: URL(string: "http://backup.local:21991")!,
                    hostname: "backup",
                    port: 21991,
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
func discoveryMergesTailnetResultsAndPrefersBonjourForSameHost() async {
    let service = ServerDiscoveryService(
        bonjourLookup: {
            [
                DiscoveredServer(
                    id: "tungs-mbp.local",
                    name: "tungs-mbp",
                    baseURL: URL(string: "http://tungs-mbp.local:21991")!,
                    hostname: "tungs-mbp.local",
                    port: 21991,
                    source: .bonjour
                )
            ]
        },
        tailnetLookup: {
            [
                DiscoveredServer(
                    id: "tungs-mbp.tail-scale.ts.net",
                    name: "tungs-mbp",
                    baseURL: URL(string: "http://tungs-mbp.tail-scale.ts.net:21991")!,
                    hostname: "tungs-mbp.local",
                    port: 21991,
                    source: .tailnet
                ),
                DiscoveredServer(
                    id: "buildbox.tail-scale.ts.net",
                    name: "buildbox",
                    baseURL: URL(string: "http://buildbox.tail-scale.ts.net:21991")!,
                    hostname: "buildbox.tail-scale.ts.net",
                    port: 21991,
                    source: .tailnet
                )
            ]
        }
    )

    let discovered = await service.discover(lastSelectedServerID: nil)
    #expect(discovered.count == 2)
    #expect(discovered.map(\.name) == ["buildbox", "tungs-mbp"])
    #expect(discovered.last?.source == .bonjour)
}

@Test
func discoveredServerSelectsTransportFromSource() {
    let bonjourServer = DiscoveredServer(
        id: "bonjour",
        name: "Bonjour",
        baseURL: URL(string: "http://bonjour.local:21991")!,
        hostname: "bonjour.local",
        port: 21991,
        source: .bonjour
    )
    let tailnetServer = DiscoveredServer(
        id: "tailnet",
        name: "Tailnet",
        baseURL: URL(string: "http://tailnet.ts.net:21991")!,
        hostname: "tailnet.ts.net",
        port: 21991,
        source: .tailnet
    )

    #expect(bonjourServer.transport == .direct)
    #expect(tailnetServer.transport == .tailnet)
}

@Test
func clientOperationErrorIncludesPhaseHostAndSource() {
    let server = DiscoveredServer(
        id: "allhands",
        name: "All Hands",
        baseURL: URL(string: "http://allhands.local:21991")!,
        hostname: "allhands.local",
        port: 21991,
        source: .bonjour
    )

    let error = ClientOperationError(
        operation: .serverInfo,
        server: server,
        underlyingDescription: "GET /server-info failed: The request timed out."
    )

    #expect(
        error.errorDescription
            == "Failed during server info for allhands.local over bonjour: GET /server-info failed: The request timed out."
    )
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
func apiClientErrorIncludesEndpointContext() {
    let error = APIClientError.httpStatus(
        APIRequestDescriptor(method: "GET", path: "/sessions"),
        503
    )

    #expect(error.localizedDescription == "GET /sessions returned HTTP 503.")
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
