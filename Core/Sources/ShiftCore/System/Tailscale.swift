import Foundation

/// Shares task dev servers on the tailnet with `tailscale serve`, so a task can be opened from any device on it.
/// Every call is a no-op (nil) when Tailscale is not installed or not running.
public struct Tailscale: Sendable {
    public init() {}

    /// The standalone app's CLI, Homebrew's, or the one inside the App Store app.
    static let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                             "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]

    /// Serves `https://<this machine>.<tailnet>.ts.net:<port>` from the server on `localhost:<port>`.
    /// Returns the machine's tailnet host name, nil if it could not be shared.
    public func serve(port: Int) async -> String? {
        guard let status = await run(["status", "--json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any],
              json["BackendState"] as? String == "Running",
              let me = json["Self"] as? [String: Any],
              let dns = (me["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !dns.isEmpty,
              await run(["serve", "--bg", "--https=\(port)", "http://127.0.0.1:\(port)"]) != nil
        else { return nil }
        return dns
    }

    public func unserve(port: Int) async {
        _ = await run(["serve", "--https=\(port)", "off"])
    }

    /// stdout if the command exited 0.
    private func run(_ arguments: [String]) async -> String? {
        guard let cli = Self.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cli)
                process.arguments = arguments
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                // `serve` waits for the user to enable HTTPS on a tailnet that has it off: give up instead.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if process.isRunning { process.terminate() } }
                // Read before waiting: `status --json` can outgrow the pipe's buffer.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}
