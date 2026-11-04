import SwiftUI
import ShiftCore

/// Settings for all of Shift. Preferences are app paths, so any installed app can be one.
struct AppSettingsView: View {
    static let windowID = "app-settings"
    static let preferredEditorKey = "preferredEditor"
    static let preferredTerminalKey = "preferredTerminal"

    @AppStorage(preferredEditorKey) private var preferredEditor = ""
    @AppStorage(preferredTerminalKey) private var preferredTerminal = ""
    private let apps = ExternalApps()

    var body: some View {
        Form {
            Section {
                picker("Code editor", selection: $preferredEditor,
                       options: apps.installedEditors().filter { $0 != .finder }.compactMap(apps.appURL))
                picker("Terminal", selection: $preferredTerminal, options: apps.installedTerminals())
            } footer: {
                Text("Shown first in Open in.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func picker(_ title: String, selection: Binding<String>, options: [URL]) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag("")
            ForEach(options, id: \.self) { app in
                Label { Text(apps.name(of: app)) } icon: { Image(nsImage: apps.icon(of: app)) }
                    .tag(app.path)
            }
        }
    }
}
