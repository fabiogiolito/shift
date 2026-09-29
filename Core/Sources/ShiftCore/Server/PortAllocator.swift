import Foundation

public struct PortAllocator: PortAllocating {
    public init() {}

    public func allocate(preferred: Int, reserved: Set<Int>) async -> Int {
        guard (1...65535).contains(preferred) else { return preferred }
        for port in preferred...65535 where !reserved.contains(port) && Self.isFree(port) {
            return port
        }
        return preferred
    }

    public func isListening(_ port: Int) async -> Bool { !Self.isFree(port) }

    /// Free means we can bind it on both IPv4 and IPv6 loopback. No SO_REUSEADDR on purpose:
    /// with it, a bind next to a wildcard listener would succeed. A port whose server just
    /// stopped also refuses the bind for a while (connections in TIME_WAIT), so a refused bind
    /// only counts when something actually answers on the port, on either family: a listener on
    /// one family alone still takes `localhost` away from us in the browser.
    static func isFree(_ port: Int) -> Bool {
        var v4 = sockaddr_in()
        v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        v4.sin_family = sa_family_t(AF_INET)
        v4.sin_port = in_port_t(port).bigEndian
        v4.sin_addr.s_addr = inet_addr("127.0.0.1")

        var v6 = sockaddr_in6()
        v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        v6.sin6_family = sa_family_t(AF_INET6)
        v6.sin6_port = in_port_t(port).bigEndian
        v6.sin6_addr = in6addr_loopback

        if canBind(AF_INET, &v4) && canBind(AF_INET6, &v6) { return true }
        return !answers(AF_INET, &v4) && !answers(AF_INET6, &v6)
    }

    /// False only when the address is in use; any other failure means nothing can listen there.
    private static func canBind<T>(_ family: Int32, _ address: inout T) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return true } // family unavailable: nothing can be listening on it
        defer { close(fd) }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<T>.size)) == 0
            }
        }
        return ok || errno != EADDRINUSE
    }

    /// Whether something accepts connections at the address.
    private static func answers<T>(_ family: Int32, _ address: inout T) -> Bool {
        // Non-blocking: a listener with a full backlog would hold a plain connect for a minute.
        let probe = socket(family, SOCK_STREAM, 0)
        guard probe >= 0 else { return false } // family unavailable: nothing listens on it
        defer { close(probe) }
        guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else { return true }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<T>.size)) == 0
            }
        }
        if connected { return true }
        if errno == ECONNREFUSED || errno == EADDRNOTAVAIL || errno == ENETUNREACH { return false }
        guard errno == EINPROGRESS else { return true }
        var waiting = pollfd(fd: probe, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, 200) == 1 else { return true }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(probe, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure != ECONNREFUSED
    }
}
