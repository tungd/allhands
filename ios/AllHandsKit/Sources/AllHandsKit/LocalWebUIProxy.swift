import Foundation
import Network

public actor LocalWebUIProxy {
    private struct HTTPRequest {
        let method: String
        let target: String
        let headers: [(String, String)]
        let body: Data
    }

    private let queue = DispatchQueue(label: "dev.allhands.local-web-ui-proxy")
    private var listener: NWListener?
    private var localBaseURL: URL?
    private var remoteBaseURL: URL?
    private var session: URLSession?

    public init() {}

    public func start(remoteBaseURL: URL, session: URLSession) async throws -> URL {
        if let listener,
           let currentLocalBaseURL = localBaseURL,
           self.remoteBaseURL == remoteBaseURL {
            _ = listener
            self.session = session
            return currentLocalBaseURL
        }

        stop()

        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            Task {
                await self.handle(connection: connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            final class State: @unchecked Sendable {
                let lock = NSLock()
                var resumed = false

                func resumeOnce(_ action: () -> Void) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    action()
                }
            }

            let readiness = State()
            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    readiness.resumeOnce {
                        continuation.resume(returning: ())
                    }
                case .failed(let error):
                    readiness.resumeOnce {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.badServerResponse)
        }

        self.listener = listener
        self.remoteBaseURL = remoteBaseURL
        self.session = session
        let url = URL(string: "http://127.0.0.1:\(port)")!
        self.localBaseURL = url
        return url
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        localBaseURL = nil
        remoteBaseURL = nil
        session = nil
    }

    private func handle(connection: NWConnection) async {
        guard let remoteBaseURL, let session else {
            connection.cancel()
            return
        }

        connection.start(queue: queue)

        do {
            let request = try await readRequest(from: connection)
            let remoteRequest = try makeURLRequest(from: request, remoteBaseURL: remoteBaseURL)
            let (bytes, response) = try await session.bytes(for: remoteRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                try await writeSimpleResponse(
                    to: connection,
                    statusCode: 502,
                    reasonPhrase: "Bad Gateway",
                    body: Data("Invalid upstream response".utf8)
                )
                connection.cancel()
                return
            }

            try await writeResponseHead(
                to: connection,
                statusCode: httpResponse.statusCode,
                reasonPhrase: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                headers: forwardedHeaders(from: httpResponse)
            )

            if shouldStreamBody(for: request.method, statusCode: httpResponse.statusCode) {
                try await pipe(bytes: bytes, to: connection)
            }
            connection.cancel()
        } catch {
            try? await writeSimpleResponse(
                to: connection,
                statusCode: 502,
                reasonPhrase: "Bad Gateway",
                body: Data("Proxy error: \(error.localizedDescription)".utf8)
            )
            connection.cancel()
        }
    }

    private func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        let headerBoundary = Data("\r\n\r\n".utf8)

        while true {
            if let range = buffer.range(of: headerBoundary) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let bodyStart = range.upperBound
                let headerString = String(decoding: headerData, as: UTF8.self)
                let lines = headerString.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else {
                    throw URLError(.badURL)
                }

                let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
                guard requestParts.count >= 2 else {
                    throw URLError(.badURL)
                }

                let headers = lines.dropFirst().compactMap { line -> (String, String)? in
                    guard let separator = line.firstIndex(of: ":") else { return nil }
                    let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (name, value)
                }

                let contentLength = headers.first(where: { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame })
                    .flatMap { Int($0.1) } ?? 0

                var body = Data()
                if buffer.count > bodyStart {
                    body.append(buffer.subdata(in: bodyStart..<buffer.count))
                }

                while body.count < contentLength {
                    guard let chunk = try await receive(on: connection), !chunk.isEmpty else {
                        throw URLError(.networkConnectionLost)
                    }
                    body.append(chunk)
                }

                return HTTPRequest(
                    method: String(requestParts[0]),
                    target: String(requestParts[1]),
                    headers: headers,
                    body: Data(body.prefix(contentLength))
                )
            }

            guard let chunk = try await receive(on: connection), !chunk.isEmpty else {
                throw URLError(.networkConnectionLost)
            }
            buffer.append(chunk)
        }
    }

    private func makeURLRequest(from request: HTTPRequest, remoteBaseURL: URL) throws -> URLRequest {
        let remoteURL = try mapTarget(request.target, onto: remoteBaseURL)
        var urlRequest = URLRequest(url: remoteURL)
        urlRequest.httpMethod = request.method

        for (name, value) in request.headers {
            let lowercased = name.lowercased()
            if ["host", "connection", "proxy-connection", "content-length"].contains(lowercased) {
                continue
            }
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }

        return urlRequest
    }

    private func mapTarget(_ target: String, onto remoteBaseURL: URL) throws -> URL {
        if let absolute = URL(string: target), absolute.scheme != nil {
            return absolute
        }

        guard var components = URLComponents(url: remoteBaseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }

        let placeholder = URL(string: "http://localhost\(target)")!
        let targetComponents = URLComponents(url: placeholder, resolvingAgainstBaseURL: false)
        components.percentEncodedPath = targetComponents?.percentEncodedPath.isEmpty == false
            ? targetComponents?.percentEncodedPath ?? "/"
            : "/"
        components.percentEncodedQuery = targetComponents?.percentEncodedQuery

        guard let mappedURL = components.url else {
            throw URLError(.badURL)
        }
        return mappedURL
    }

    private func forwardedHeaders(from response: HTTPURLResponse) -> [(String, String)] {
        response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String else { return nil }
            let lowercased = name.lowercased()
            if ["content-length", "transfer-encoding", "connection", "keep-alive"].contains(lowercased) {
                return nil
            }
            return (name, String(describing: value))
        } + [
            ("Connection", "close"),
            ("Transfer-Encoding", "chunked")
        ]
    }

    private func shouldStreamBody(for method: String, statusCode: Int) -> Bool {
        if method.caseInsensitiveCompare("HEAD") == .orderedSame {
            return false
        }
        return !(100..<200).contains(statusCode) && statusCode != 204 && statusCode != 304
    }

    private func pipe(bytes: URLSession.AsyncBytes, to connection: NWConnection) async throws {
        var buffer = Data()
        buffer.reserveCapacity(8192)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 8192 {
                try await writeChunk(buffer, to: connection)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try await writeChunk(buffer, to: connection)
        }

        try await send(Data("0\r\n\r\n".utf8), on: connection)
    }

    private func writeSimpleResponse(
        to connection: NWConnection,
        statusCode: Int,
        reasonPhrase: String,
        body: Data
    ) async throws {
        let head =
            "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n" +
            "Content-Type: text/plain; charset=utf-8\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        try await send(Data(head.utf8), on: connection)
        if !body.isEmpty {
            try await send(body, on: connection)
        }
    }

    private func writeResponseHead(
        to connection: NWConnection,
        statusCode: Int,
        reasonPhrase: String,
        headers: [(String, String)]
    ) async throws {
        let headerLines = headers.map { "\($0.0): \($0.1)\r\n" }.joined()
        let head = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n\(headerLines)\r\n"
        try await send(Data(head.utf8), on: connection)
    }

    private func writeChunk(_ data: Data, to connection: NWConnection) async throws {
        let prefix = Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8)
        let suffix = Data("\r\n".utf8)
        try await send(prefix + data + suffix, on: connection)
    }

    private func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}
