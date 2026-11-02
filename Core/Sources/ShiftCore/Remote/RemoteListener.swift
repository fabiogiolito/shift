import Foundation
import Network

/// The sockets of `RemoteServer`: HTTP and WebSocket on loopback, where only `tailscale serve` and local builds can reach
/// them. Every request is checked before anything else about it is read. Knows nothing of tasks.
public final class RemoteListener: @unchecked Sendable {
    /// More than a phone's picture, less than memory can't take.
    static let maxUpload = 50 << 20
    static let maxHeaders = 16 << 10
    /// All a client ever sends over the socket is short commands.
    static let maxInbound = 1 << 20

    struct Handlers: Sendable {
        var opened: @Sendable (RemoteConnection) -> Void
        var received: @Sendable (RemoteConnection, Data) -> Void
        var closed: @Sendable (RemoteConnection) -> Void
    }

    let auth: RemoteAuth
    private let home: URL
    private let attachments: URL
    private let queue = DispatchQueue(label: "shift.remote")
    private var listener: NWListener?

    public convenience init() { self.init(home: ShiftPaths.root) }

    init(home: URL, attachments: URL = FileManager.default.temporaryDirectory.appendingPathComponent("shift-attachments")) {
        self.home = home
        self.attachments = attachments
        auth = RemoteAuth(home: home)
    }

    /// `<SHIFT_HOME>/remote-port`: this build's port, kept so that pairing outlives a restart. scripts/build.sh reads it
    /// (and may choose it for a build it hasn't launched yet).
    var portFile: URL { home.appendingPathComponent("remote-port") }

    /// SHIFT_SERVER for a simulator build, pointing at the Mac build that keeps its data in `home`, which may not be
    /// running yet: chooses its port and local token for it if it has none, as scripts/build.sh does.
    /// nil if they can't be written.
    static func localServer(home: URL, taskID: Int) -> String? {
        let files = FileManager.default
        let portFile = home.appendingPathComponent("remote-port"), tokenFile = home.appendingPathComponent("remote-dev-token")
        func read(_ file: URL) -> String? {
            (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        try? files.createDirectory(at: home, withIntermediateDirectories: true)
        if read(portFile) == nil { try? String(20000 + taskID % 20000).write(to: portFile, atomically: true, encoding: .utf8) }
        if read(tokenFile) == nil {
            files.createFile(atPath: tokenFile.path, contents: Data(RemoteAuth.newToken().utf8), attributes: [.posixPermissions: 0o600])
        }
        guard let port = read(portFile), let token = read(tokenFile) else { return nil }
        return "http://127.0.0.1:\(port)?token=\(token)"
    }

    /// Starts listening on the saved port, or else any free one, and saves it. nil if it could not listen at all.
    func start(_ handlers: Handlers) async -> Int? {
        let saved = (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var port = await listen(on: saved.flatMap { NWEndpoint.Port(rawValue: UInt16(clamping: $0)) } ?? .any, handlers)
        if port == nil, saved != nil { port = await listen(on: .any, handlers) } // Taken by now.
        guard let port else { return nil }
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try? String(port).write(to: portFile, atomically: true, encoding: .utf8)
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(on port: NWEndpoint.Port, _ handlers: Handlers) async -> Int? {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            self?.readHead(connection, Data(), handlers)
        }
        let result: Int? = await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(returning: listener?.port.map { Int($0.rawValue) })
                case .failed, .cancelled:
                    listener?.stateUpdateHandler = nil
                    continuation.resume(returning: nil)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        if result != nil { self.listener = listener } else { listener.cancel() }
        return result
    }

    // MARK: HTTP

    struct Head: Equatable {
        var method: String
        var path: String
        var query: [String: String]
        /// Lowercased names.
        var headers: [String: String]
    }

    static func parseHead(_ text: String) -> Head? {
        var lines = text.components(separatedBy: "\r\n")[...]
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, let target = URLComponents(string: String(parts[1])) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let query = (target.queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        return Head(method: String(parts[0]), path: target.path, query: query, headers: headers)
    }

    private func readHead(_ connection: NWConnection, _ received: Data, _ handlers: Handlers) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            let received = received + (data ?? Data())
            guard let end = received.firstRange(of: Data("\r\n\r\n".utf8)) else {
                if received.count > Self.maxHeaders || isComplete || error != nil {
                    Self.respond(connection, status: "400 Bad Request")
                } else {
                    self.readHead(connection, received, handlers)
                }
                return
            }
            guard end.lowerBound <= Self.maxHeaders,
                  let head = Self.parseHead(String(decoding: received[..<end.lowerBound], as: UTF8.self)) else {
                return Self.respond(connection, status: "400 Bad Request")
            }
            guard let caller = self.auth.caller(headers: head.headers) else {
                return Self.respond(connection, status: "401 Unauthorized")
            }
            let rest = Data(received[end.upperBound...])
            switch (head.method, head.path) {
            case ("GET", Wire.socketPath):
                self.upgrade(connection, head, caller: caller, rest: rest, handlers)
            case ("POST", Wire.attachmentsPath):
                guard let length = head.headers["content-length"].flatMap(Int.init), length >= 0, length <= Self.maxUpload else {
                    return Self.respond(connection, status: "413 Content Too Large")
                }
                self.readBody(connection, rest, length: length) { self.saveAttachment($0, name: head.query["name"], connection) }
            default:
                Self.respond(connection, status: "404 Not Found")
            }
        }
    }

    private func readBody(_ connection: NWConnection, _ received: Data, length: Int, _ done: @escaping @Sendable (Data) -> Void) {
        if received.count >= length { return done(Data(received.prefix(length))) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            let received = received + (data ?? Data())
            if received.count < length, isComplete || error != nil { return connection.cancel() }
            self?.readBody(connection, received, length: length, done)
        }
    }

    /// Named by the server: nothing from the client but a clean extension ends up in the path.
    private func saveAttachment(_ data: Data, name: String?, _ connection: NWConnection) {
        let ext = (name.map { ($0 as NSString).pathExtension } ?? "").filter { $0.isLetter || $0.isNumber }.prefix(8)
        let file = attachments.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "bin" : String(ext))
        do {
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            Self.respond(connection, status: "200 OK", body: Wire.encode(AttachmentUploaded(path: file.path)))
        } catch {
            Self.respond(connection, status: "500 Internal Server Error")
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: Data = Data()) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: WebSocket

    private func upgrade(_ connection: NWConnection, _ head: Head, caller: RemoteAuth.Caller, rest: Data, _ handlers: Handlers) {
        guard head.headers["upgrade"]?.lowercased() == "websocket", let key = head.headers["sec-websocket-key"] else {
            return Self.respond(connection, status: "400 Bad Request")
        }
        let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocketFrames.accept(key: key))\r\n\r\n"
        let remote = RemoteConnection(connection: connection, caller: caller)
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                connection.stateUpdateHandler = nil
                handlers.closed(remote)
            default: break
            }
        }
        handlers.opened(remote)
        readFrames(remote, rest, partial: Data(), handlers)
    }

    private func readFrames(_ remote: RemoteConnection, _ buffer: Data, partial: Data, _ handlers: Handlers) {
        var buffer = buffer, partial = partial
        do {
            while let frame = try WebSocketFrames.next(from: &buffer, limit: Self.maxInbound) {
                switch frame.opcode {
                case WebSocketFrames.close: return remote.close()
                case WebSocketFrames.ping: remote.write(WebSocketFrames.encode(opcode: WebSocketFrames.pong, payload: frame.payload))
                case WebSocketFrames.pong: break
                default:
                    partial += frame.payload
                    guard partial.count <= Self.maxInbound else { return remote.close() }
                    if frame.isFinal {
                        handlers.received(remote, partial)
                        partial = Data()
                    }
                }
            }
        } catch {
            return remote.close()
        }
        remote.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil { return remote.connection.cancel() }
            self?.readFrames(remote, buffer + (data ?? Data()), partial: partial, handlers)
        }
    }
}

/// One phone's socket.
final class RemoteConnection: Hashable, @unchecked Sendable {
    fileprivate let connection: NWConnection
    let caller: RemoteAuth.Caller

    fileprivate init(connection: NWConnection, caller: RemoteAuth.Caller) {
        self.connection = connection
        self.caller = caller
    }

    fileprivate func write(_ frame: Data) {
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Returns once the bytes are on their way, so that a large log is read no faster than the phone takes it.
    func send(_ message: ServerMessage) async {
        let frame = WebSocketFrames.encode(opcode: WebSocketFrames.text, payload: Wire.encode(message))
        await withCheckedContinuation { continuation in
            connection.send(content: frame, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    func post(_ message: ServerMessage) {
        write(WebSocketFrames.encode(opcode: WebSocketFrames.text, payload: Wire.encode(message)))
    }

    func close() {
        connection.send(content: WebSocketFrames.encode(opcode: WebSocketFrames.close),
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    static func == (a: RemoteConnection, b: RemoteConnection) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
