import Foundation
import CryptoKit
import ShiftCore

/// Anonymous usage counts, sent to TelemetryDeck at launch and once a day while Shift stays open.
/// One random ID per Mac (hashed before it leaves), the app and macOS versions, and how many projects, tasks, plans
/// and schedules there are by status. Never names, paths, prompts, branches or anything else from a project.
/// Off when `ShiftTelemetryAppID` (project.yml) is empty, or with Settings › General › Share anonymous usage turned off.
@MainActor
enum Analytics {
    static let enabledKey = "shareAnonymousUsage"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The window's `.task` runs again when it is reopened.
    private static var started = false
    private static let appID = Bundle.main.object(forInfoDictionaryKey: "ShiftTelemetryAppID") as? String ?? ""

    /// Sends at launch, then every 24 hours.
    static func start(model: AppModel) {
        guard !started, !appID.isEmpty, ProcessInfo.processInfo.environment["SHIFT_PREVIEW"] == nil else { return }
        started = true
        let launches = UserDefaults.standard.integer(forKey: "analyticsLaunches") + 1
        UserDefaults.standard.set(launches, forKey: "analyticsLaunches")
        Task {
            send("App.launched", payload(model: model, launches: launches))
            while (try? await Task.sleep(for: .seconds(24 * 60 * 60))) != nil {
                send("App.daily", payload(model: model, launches: launches))
            }
        }
    }

    /// Only counts. Keys follow TelemetryDeck's `Scope.key`.
    static func payload(model: AppModel, launches: Int) -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var payload: [String: Any] = [
            "Shift.version": info["CFBundleShortVersionString"] as? String ?? "",
            "Shift.build": info["CFBundleVersion"] as? String ?? "",
            "Shift.macOS": "\(os.majorVersion).\(os.minorVersion)",
            "Shift.launches": launches,
            "Shift.projects": model.projects.count,
            "Shift.tasks": model.tasks.count,
            "Shift.plans": model.plans.count,
            "Shift.schedules": model.schedules.count,
            "Shift.schedulesPaused": model.schedules.filter(\.paused).count,
            "Shift.scheduleRuns": model.schedules.reduce(0) { $0 + $1.runs.count },
        ]
        for status in [TaskStatus.working, .needsInput, .blocked, .completed, .conflict, .merged, .archived] {
            payload["Tasks.\(status.rawValue)"] = model.tasks.filter { $0.status == status }.count
        }
        for agent in AgentKind.allCases {
            payload["Tasks.agent.\(agent.rawValue)"] = model.tasks.filter { $0.agent == agent }.count
        }
        return payload
    }

    private static func send(_ type: String, _ payload: [String: Any]) {
        guard isEnabled else { return }
        var signal: [String: Any] = ["appID": appID, "clientUser": clientUser, "type": type, "payload": payload]
        #if DEBUG
        signal["isTestMode"] = true
        #endif
        guard let body = try? JSONSerialization.data(withJSONObject: [signal]) else { return }
        var request = URLRequest(url: URL(string: "https://nom.telemetrydeck.com/v2/namespace/com.shiftapp/")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Fire and forget: a missed day is fine.
        URLSession.shared.dataTask(with: request).resume()
    }

    /// A random ID made on first launch, kept across updates, hashed so not even it leaves the Mac.
    private static var clientUser: String {
        let id = UserDefaults.standard.string(forKey: "analyticsID") ?? {
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "analyticsID")
            return id
        }()
        return SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
