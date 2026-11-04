import Foundation
import Network

/// Whether the Mac can reach the internet, which the agents need for every turn.
public protocol ConnectivityChecking: Sendable {
    /// The Mac has a network connection at all. Cheap: asked every few seconds while something runs.
    var hasNetwork: Bool { get }
    /// A request out gets an answer. A network without internet (a router that lost its uplink) has a network.
    func reachesInternet() async -> Bool
}

public final class Connectivity: ConnectivityChecking, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock { self.satisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "Connectivity"))
    }

    deinit { monitor.cancel() }

    public var hasNetwork: Bool { lock.withLock { satisfied } }

    public func reachesInternet() async -> Bool {
        guard hasNetwork else { return false }
        // Apple's own captive-portal check: tiny, and answered from anywhere.
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse
        return response.map { (200..<400).contains($0.statusCode) } ?? false
    }
}
