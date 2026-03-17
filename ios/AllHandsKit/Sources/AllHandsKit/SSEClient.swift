import Foundation

public struct ServerSentEvent: Equatable, Sendable {
    public var id: String?
    public var event: String?
    public var data: String?

    public init(id: String? = nil, event: String? = nil, data: String? = nil) {
        self.id = id
        self.event = event
        self.data = data
    }
}

public struct SSEParser: Sendable {
    private var currentID: String?
    private var currentEvent: String?
    private var currentDataLines: [String] = []

    public init() {}

    public mutating func feed(line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer {
                currentID = nil
                currentEvent = nil
                currentDataLines = []
            }
            if currentID == nil && currentEvent == nil && currentDataLines.isEmpty {
                return nil
            }
            return ServerSentEvent(id: currentID, event: currentEvent, data: currentDataLines.joined(separator: "\n"))
        }

        if line.hasPrefix("id:") {
            currentID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("event:") {
            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            currentDataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }

        return nil
    }
}

public final class SSEClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(url: URL, lastEventID: String? = nil) async throws -> AsyncThrowingStream<ServerSentEvent, Error> {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw APIClientError.invalidResponse(
                APIRequestDescriptor(method: "GET", path: url.path.isEmpty ? "/" : url.path)
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await line in bytes.lines {
                        let normalized = line.trimmingCharacters(in: .newlines)
                        if let event = parser.feed(line: normalized) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
