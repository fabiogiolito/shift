import Foundation

/// Runs iOS apps on a simulator with `simctl`.
public struct Simulators: SimulatorRunning {
    public init() {}

    private struct Failure: LocalizedError {
        var errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    struct Device: Equatable {
        var udid: String
        var isBooted: Bool
    }

    public func run(app: URL, environment: [String: String]) async throws {
        let list = try await xcrun(["simctl", "list", "devices", "available", "-j"])
        guard let device = Self.pickDevice(listJSON: Data(list.utf8)) else {
            throw Failure("No iPhone simulator is available. Add one in Xcode, under Window > Devices and Simulators.")
        }
        guard let bundleID = Self.bundleID(ofApp: app) else {
            throw Failure("Could not read the bundle identifier of \(app.lastPathComponent).")
        }
        // Waits for it to finish booting, which installing needs.
        if !device.isBooted { _ = try await xcrun(["simctl", "bootstatus", device.udid, "-b"]) }
        _ = try await xcrun(["simctl", "install", device.udid, app.path])
        _ = try await xcrun(["simctl", "launch", "--terminate-running-process", device.udid, bundleID], environment: environment)
        _ = try await runShellCommand("open -a Simulator", directory: app.deletingLastPathComponent(), environment: [:])
    }

    /// The booted iOS simulator, else the newest available iPhone, from `simctl list devices available -j`.
    // ponytail: "newest" within a runtime is the highest number in the name (simctl's order says nothing), so an
    // iPhone Air or 16e counts as oldest; compare device type release dates if that ever picks badly.
    static func pickDevice(listJSON: Data) -> Device? {
        let list = (try? JSONSerialization.jsonObject(with: listJSON)) as? [String: Any]
        let runtimes = (list?["devices"] as? [String: [[String: Any]]] ?? [:])
            .filter { $0.key.contains(".iOS-") }
            .sorted { $0.key.compare($1.key, options: .numeric) == .orderedDescending }
        func device(_ entry: [String: Any]) -> Device? {
            (entry["udid"] as? String).map { Device(udid: $0, isBooted: entry["state"] as? String == "Booted") }
        }
        if let booted = runtimes.lazy.flatMap(\.value).compactMap(device).first(where: \.isBooted) { return booted }
        for runtime in runtimes {
            let iPhones = runtime.value.filter { ($0["name"] as? String)?.hasPrefix("iPhone") == true }
            func model(_ entry: [String: Any]) -> Int {
                ((entry["name"] as? String)?.split(separator: " ").dropFirst().first).flatMap { Int($0) } ?? 0
            }
            if let newest = iPhones.max(by: { model($0) < model($1) }).flatMap(device) { return newest }
        }
        return nil
    }

    /// iOS apps keep their Info.plist at the top of the bundle.
    static func bundleID(ofApp app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    private func xcrun(_ arguments: [String], environment: [String: String] = [:]) async throws -> String {
        let command = "xcrun " + arguments.map(ProjectSetup.quoted).joined(separator: " ")
        let result = try await runShellCommand(command, directory: FileManager.default.temporaryDirectory, environment: environment)
        guard result.exitCode == 0 else { throw Failure(result.output.isEmpty ? "\(command) failed (exit code \(result.exitCode))." : result.output) }
        return result.output
    }
}
