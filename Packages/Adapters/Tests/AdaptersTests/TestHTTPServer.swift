import Foundation
import Network
import Synchronization

/// A tiny loopback HTTP/1.1 server for download tests. Serves fixed bodies, honors `Range: bytes=N-`,
/// and can cut the connection part-way through the first response for a path.
final class TestHTTPServer: @unchecked Sendable {
    struct Recorded: Sendable { var path: String; var range: String? }

    private struct Route {
        var body: Data
        var etag: String
        var dropFirstResponseAfter: Int?
        var served = 0
    }
    private struct State {
        var routes: [String: Route] = [:]
        var recorded: [Recorded] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")
    private let state = Mutex(State())
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func serve(_ path: String, body: Data, dropFirstResponseAfter: Int? = nil) {
        state.withLock {
            $0.routes[path] = Route(body: body, etag: "\"\(UUID().uuidString)\"", dropFirstResponseAfter: dropFirstResponseAfter)
        }
    }

    var requests: [Recorded] { state.withLock { $0.recorded } }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    port = listener.port?.rawValue ?? 0
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { connection.cancel(); return }
        let path = String(parts[1])
        let rangeHeader = lines.first { $0.lowercased().hasPrefix("range:") }
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }

        let plan: (Route, Int?)? = state.withLock { s in
            s.recorded.append(Recorded(path: path, range: rangeHeader))
            guard var route = s.routes[path] else { return nil }
            let drop = route.served == 0 ? route.dropFirstResponseAfter : nil
            route.served += 1
            s.routes[path] = route
            return (route, drop)
        }
        guard let (route, drop) = plan else {
            send(status: "404 Not Found", headers: ["Content-Length": "0"], body: Data(), on: connection)
            return
        }

        var start = 0
        var status = "200 OK"
        var headers = ["Accept-Ranges": "bytes", "ETag": route.etag, "Content-Type": "application/octet-stream"]
        if let rangeHeader, rangeHeader.hasPrefix("bytes="),
            let from = Int(rangeHeader.dropFirst("bytes=".count).split(separator: "-").first ?? ""), from < route.body.count {
            start = from
            status = "206 Partial Content"
            headers["Content-Range"] = "bytes \(from)-\(route.body.count - 1)/\(route.body.count)"
        }
        let body = route.body.suffix(from: start)
        headers["Content-Length"] = String(body.count)
        send(status: status, headers: headers, body: Data(body), truncateTo: drop, on: connection)
    }

    private func send(status: String, headers: [String: String], body: Data, truncateTo: Int? = nil, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(truncateTo.map { body.prefix($0) } ?? body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            // A truncated response ends abruptly, like a dropped connection; a full one closes cleanly.
            if truncateTo != nil { connection.forceCancel() } else { connection.cancel() }
        })
    }
}
