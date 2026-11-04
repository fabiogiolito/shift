import SwiftUI
import ShiftCore

/// "Open in" for a folder of `project`: its preferred editor (⇧⌘O) and terminal (⇧⌘T) from its settings first,
/// then the other editors, then the other terminals. Each with its app's icon.
struct OpenInMenu: View {
    let directory: URL
    let project: Project
    private let apps = ExternalApps()

    var body: some View {
        let editors = apps.installedEditors().compactMap(apps.appURL)
        let terminals = apps.installedTerminals()
        let editor = editors.first { $0.path == project.editorPath }
        let terminal = terminals.first { $0.path == project.terminalPath }
        let preferred = [editor, terminal].compactMap { $0 }
        Menu("Open in") {
            if let editor { button(editor).keyboardShortcut("o", modifiers: [.command, .shift]) }
            if let terminal { button(terminal).keyboardShortcut("t", modifiers: [.command, .shift]) }
            if !preferred.isEmpty { Divider() }
            ForEach(editors.filter { !preferred.contains($0) }, id: \.self) { button($0) }
            Divider()
            ForEach(terminals.filter { !preferred.contains($0) }, id: \.self) { button($0) }
        }
    }

    private func button(_ app: URL) -> some View {
        Button { apps.open(directory, withApp: app) } label: {
            Label { Text(apps.name(of: app)) } icon: { Image(nsImage: apps.icon(of: app)) }
        }
        // Menus show a label's title only by default.
        .labelStyle(.titleAndIcon)
    }
}
