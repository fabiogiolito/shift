import SwiftUI
import ShiftCore

/// "Open in" for a folder, as menu items: the preferred editor and terminal from Settings first, straight in the menu,
/// then an "Open in" submenu with the other editors and the other terminals. Each with its app's icon.
struct OpenInMenu: View {
    let directory: URL
    @AppStorage(AppSettingsView.preferredEditorKey) private var preferredEditor = ""
    @AppStorage(AppSettingsView.preferredTerminalKey) private var preferredTerminal = ""
    private let apps = ExternalApps()

    var body: some View {
        let editors = apps.installedEditors().compactMap(apps.appURL)
        let terminals = apps.installedTerminals()
        let preferred = [preferredEditor, preferredTerminal].compactMap { path in
            (editors + terminals).first { $0.path == path }
        }
        ForEach(preferred, id: \.self) { app in button(app, title: "Open in \(apps.name(of: app))") }
        Menu(preferred.isEmpty ? "Open in" : "Open in Other") {
            ForEach(editors.filter { !preferred.contains($0) }, id: \.self) { button($0) }
            Divider()
            ForEach(terminals.filter { !preferred.contains($0) }, id: \.self) { button($0) }
        }
    }

    private func button(_ app: URL, title: String? = nil) -> some View {
        Button { apps.open(directory, withApp: app) } label: {
            Label { Text(title ?? apps.name(of: app)) } icon: { Image(nsImage: apps.icon(of: app)) }
        }
    }
}
