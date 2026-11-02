import CryptoKit
import Foundation

/// A phone that was shown a pairing code.
public struct RemoteDevice: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var pairedAt: Date
    /// nil: its code hasn't been used yet.
    public var lastSeen: Date?
    /// Only the token's hash is kept: agents run as the same user, and can read this file.
    var tokenHash: String
}

/// Who may talk to `RemoteServer`, in `<SHIFT_HOME>/remote.json`, and the checks every request goes through.
/// Safe from any thread: the listener asks from its own queue.
final class RemoteAuth: @unchecked Sendable {
    enum Caller: Equatable {
        case device(UUID)
        /// A local build reached straight over loopback, with the token scripts/build.sh left in SHIFT_HOME.
        case local
    }

    private let lock = NSLock()
    private let file: URL
    private let localTokenFile: URL
    private var stored: [RemoteDevice]
    private var owner: String?

    init(home: URL) {
        file = home.appendingPathComponent("remote.json")
        localTokenFile = home.appendingPathComponent("remote-dev-token")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stored = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([RemoteDevice].self, from: $0) } ?? []
    }

    var devices: [RemoteDevice] { lock.withLock { stored } }

    /// The login that owns this Mac on the tailnet. nil while unknown: nobody gets in through it.
    func setOwner(_ login: String?) { lock.withLock { owner = login } }

    /// Adds a device and returns the token to show it, once.
    func add() -> (device: RemoteDevice, token: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("No secure random numbers")
        }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let device = RemoteDevice(id: UUID(), name: "New device", pairedAt: .now, tokenHash: Self.hash(token))
        lock.withLock {
            stored.append(device)
            save()
        }
        return (device, token)
    }

    func remove(_ id: UUID) {
        lock.withLock {
            stored.removeAll { $0.id == id }
            save()
        }
    }

    func seen(_ id: UUID, name: String? = nil) {
        lock.withLock {
            guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
            stored[index].lastSeen = .now
            if let name, !name.isEmpty { stored[index].name = name }
            save()
        }
    }

    /// The caller of a request with these (lowercased) headers. nil: refused.
    /// `tailscale serve` adds X-Forwarded-For to everything it proxies, and Tailscale-User-Login to what comes from a
    /// person's device, so a token alone can't get in from elsewhere on the tailnet, nor a local token from outside.
    func caller(headers: [String: String]) -> Caller? {
        guard let authorization = headers["authorization"], authorization.lowercased().hasPrefix("bearer ") else { return nil }
        let hash = Self.hash(String(authorization.dropFirst("bearer ".count)))
        let login = headers["tailscale-user-login"]
        if login == nil, headers["x-forwarded-for"] == nil,
           let local = try? String(contentsOf: localTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !local.isEmpty, Self.hash(local) == hash {
            return .local
        }
        return lock.withLock {
            guard let owner, let login, login.caseInsensitiveCompare(owner) == .orderedSame,
                  let device = stored.first(where: { $0.tokenHash == hash }) else { return nil }
            return .device(device.id)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(stored).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
