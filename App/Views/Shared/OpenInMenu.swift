import SwiftUI
import ShiftCore

/// "Open in" for a folder: the preferred editor and terminal from Settings first, then the other editors, then the
/// other terminals. Each with its app's icon.
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
        Menu("Open in") {
            if !preferred.isEmpty {
                ForEach(preferred, id: \.self, content: button)
                Divider()
            }
            ForEach(editors.filter { !preferred.contains($0) }, id: \.self, content: button)
            Divider()
            ForEach(terminals.filter { !preferred.contains($0) }, id: \.self, content: button)
        }
    }

    private func button(_ app: URL) -> some View {
        Button { apps.open(directory, withApp: app) } label: {
            Label { Text(apps.name(of: app)) } icon: { Image(nsImage: apps.icon(of: app)) }
        }
    }
}
