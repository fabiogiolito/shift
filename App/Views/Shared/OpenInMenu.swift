import SwiftUI
import ShiftCore

/// "Open in" for a folder of `project`: its preferred editor (⇧⌘E) and terminal (⇧⌘T) from its settings first,
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
            if let editor { button(editor).keyboardShortcut("e", modifiers: [.command, .shift]) }
            if let terminal { button(terminal).keyboardShortcut("t", modifiers: [.command, .shift]) }
            if !preferred.isEmpty { Divider() }
            ForEach(editors.filter { !preferred.contains($0) }, id: \.self) { button($0) }
            Divider()
            ForEach(terminals.filter { !preferred.contains($0) }, id: \.self) { button($0) }
        }
    }

    /// What ⇧⌘E opens: the project's editor, or the first installed one other than Finder (⇧⌘O has Finder).
    static func editor(for project: Project) -> URL? {
        let apps = ExternalApps()
        let editors = apps.installedEditors().compactMap(apps.appURL)
        return editors.first { $0.path == project.editorPath }
            ?? apps.installedEditors().first { $0 != .finder }.flatMap(apps.appURL)
    }

    /// What ⇧⌘T opens: the project's terminal, or the first installed one.
    static func terminal(for project: Project) -> URL? {
        let terminals = ExternalApps().installedTerminals()
        return terminals.first { $0.path == project.terminalPath } ?? terminals.first
    }

    private func button(_ app: URL) -> some View {
        Button { apps.open(directory, withApp: app) } label: {
            Label { Text(apps.name(of: app)) } icon: { Image(nsImage: apps.icon(of: app)) }
        }
        // Menus show a label's title only by default.
        .labelStyle(.titleAndIcon)
    }
}
