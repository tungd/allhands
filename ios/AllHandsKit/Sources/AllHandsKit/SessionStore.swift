import Combine
import Foundation

@MainActor
public final class SessionStore: ObservableObject {
    @Published public private(set) var sessions: [SessionSummary]
    @Published public private(set) var eventsBySession: [String: [StreamEvent]]

    public init(sessions: [SessionSummary] = [], eventsBySession: [String: [StreamEvent]] = [:]) {
        self.sessions = sessions
        self.eventsBySession = eventsBySession
    }

    public func replaceSessions(_ sessions: [SessionSummary]) {
        self.sessions = sessions
    }

    public func upsert(session: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    public func append(event: StreamEvent) {
        var events = eventsBySession[event.sessionId, default: []]
        events.append(event)
        events.sort { $0.seq < $1.seq }
        eventsBySession[event.sessionId] = events
    }

    public func events(for sessionID: String) -> [StreamEvent] {
        eventsBySession[sessionID, default: []]
    }
}
