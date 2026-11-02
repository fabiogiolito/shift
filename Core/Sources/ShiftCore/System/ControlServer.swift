import Foundation
import Network

public struct ControlReply: Equatable, Sendable {
    public var ok: Bool
    public var text: String

    public init(ok: Bool, text: String) {
        self.ok = ok
        self.text = text
    }
}

/// Lets the project chat's agent run Shift: `shiftctl <command> <arguments>` is a POST to this server, on
/// loopback only, with the arguments as NUL-terminated strings. Agents can all run commands, and a
/// command shows up readably when Manual permissions ask for it, so nothing is needed from either agent.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ token: String, _ arguments: [String]) async -> ControlReply

    static let maxRequest = 1 << 20
    private let script: URL
    private let queue = DispatchQueue(label: "shift.control")
    private var listener: NWListener?

    public init(script: URL = ShiftPaths.controlScript) {
        self.script = script
    }

    static let scriptText = #"""
    #!/bin/sh
    # Runs Shift from its project chat. Shift writes this file. See `shiftctl help`.
    if [ -z "$SHIFT_URL" ] || [ -z "$SHIFT_ACCESS" ]; then
        echo "shiftctl only works in a Shift project chat, and Shift could not set it up for this one." >&2
        exit 2
    fi
    printf '%s\0' "$@" | curl -sS --fail-with-body --max-time 600 -H "Authorization: Bearer $SHIFT_ACCESS" --data-binary @- "$SHIFT_URL"
    """# + "\n"

    /// Installs `shiftctl` and starts listening. The port, nil if it could not.
    public func start(_ handler: @escaping Handler) async -> Int? {
        let files = FileManager.default
        try? files.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.scriptText.write(to: script, atomically: true, encoding: .utf8)
        try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.receive(connection, Data(), handler)
        }
        return await withCheckedContinuation { continuation in
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
    }

    private static func receive(_ connection: NWConnection, _ received: Data, _ handler: @escaping Handler) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            let received = received + (data ?? Data())
            if let (token, arguments) = parse(received) {
                Task { respond(connection, await handler(token, arguments)) }
            } else if received.count > maxRequest || isComplete || error != nil {
                respond(connection, ControlReply(ok: false, text: "Bad request."))
            } else {
                receive(connection, received, handler)
            }
        }
    }

    private static func respond(_ connection: NWConnection, _ reply: ControlReply) {
        let body = Data((reply.text + "\n").utf8)
        let head = "HTTP/1.1 \(reply.ok ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The bearer token and arguments of a whole request. nil until all of it arrived, or if it never will make sense.
    static func parse(_ request: Data) -> (token: String, arguments: [String])? {
        guard let end = request.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        var token: String?, length: Int?
        for line in String(decoding: request[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("authorization: bearer ") {
                token = String(line.dropFirst("authorization: bearer ".count))
            } else if lower.hasPrefix("content-length:") {
                length = Int(lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let token, let length, request.count - end.upperBound >= length else { return nil }
        let body = request[end.upperBound...].prefix(length)
        let arguments = body.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        return (token, arguments.map { String(decoding: $0, as: UTF8.self) })
    }
}
