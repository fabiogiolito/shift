import SwiftUI
import AppKit
import ShiftCore

/// The project's own icon when it has one (web app icon or favicon, native app icon), else a folder.
/// Looked up again whenever `version` changes and whenever the app becomes active, so an icon that
/// appears or changes (e.g. merged in from a task) shows up without a restart.
struct ProjectIcon: View {
    let repoPath: String
    /// Anything that changes when the project's base may have changed, e.g. the latest merge date.
    var version: Date?
    @State private var image: NSImage?
    @State private var activations = 0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                // Smaller than the frame: an outline glyph filling 18pt reads heavier than a filled app icon.
                Image(systemName: "folder").font(.system(size: 12))
            }
        }
        .frame(width: 18, height: 18)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in activations += 1 }
        .task(id: "\(repoPath)|\(version?.timeIntervalSince1970 ?? 0)|\(activations)") {
            let path = repoPath
            image = await Task.detached(priority: .utility) { await ProjectIconFinder.icon(in: URL(fileURLWithPath: path)) }.value
        }
    }
}

