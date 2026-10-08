import SwiftUI
import ShiftCore

struct DiffView: View {
    @Environment(AppModel.self) private var model
    private let taskID: TaskItem.ID?
    private let source: [FileDiff]?
    /// False while the view slides in. Loading starts right away, but the content only appears once the
    /// slide has finished, so the animation never waits on building and laying out thousands of rows.
    private let isSettled: Bool
    @State private var files: [PreparedFile]?
    @State private var selection: FileDiff.ID?
    @State private var loadError: String?
    /// Bumped by Try Again to load again.
    @State private var attempt = 0

    /// `selecting` is the path of the file to open at.
    init(taskID: TaskItem.ID, isSettled: Bool, selecting path: String? = nil) {
        self.taskID = taskID
        self.source = nil
        self.isSettled = isSettled
        _selection = State(initialValue: path)
    }

    /// For previews and UI work: renders the given files without asking the model.
    init(files: [FileDiff]) {
        self.taskID = nil
        self.source = files
        self.isSettled = true
    }

    var body: some View {
        let ready = isSettled ? files : nil
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes").font(.headline)
                // A blank line until then, so the header keeps its height.
                Text(ready.map(summary) ?? " ").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            if isSettled, let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        self.loadError = nil
                        attempt += 1
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let files = ready {
                if files.isEmpty {
                    ContentUnavailableView("No changes", systemImage: "doc.text.magnifyingglass",
                                           description: Text("This task has not changed any files."))
                } else {
                    content(files)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: attempt) {
            let result: Result<[FileDiff], Error> = if let source { .success(source) }
                else if let taskID { await model.loadDiff(taskID: taskID) } else { .success([]) }
            let diff: [FileDiff]
            switch result {
            case .success(let value): diff = value
            case .failure(let error): loadError = error.localizedDescription; return
            }
            // Highlighting is the expensive part: it runs once per line, off the main actor, a file per task.
            files = await withTaskGroup(of: PreparedFile.self) { group in
                for (index, file) in diff.enumerated() { group.addTask { PreparedFile(file, index: index) } }
                return await group.reduce(into: []) { $0.append($1) }.sorted { $0.index < $1.index }
            }
        }
    }

    private func content(_ files: [PreparedFile]) -> some View {
        ThirdSplitView {
            List(files, selection: $selection) { file in
                HStack {
                    Label(file.change.path, systemImage: fileSymbol(file.change.path))
                        .lineLimit(1).truncationMode(.head)
                        .help(file.change.path)
                    Spacer()
                    counts(file.change)
                }
            }
        } trailing: {
            // The reader wraps only the diff: the list's rows share the same ids.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(files) { file in
                            Section {
                                fileBody(file)
                            } header: {
                                fileHeader(file.change).id(file.id)
                            }
                        }
                    }
                }
                .onChange(of: selection, initial: true) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func summary(_ files: [PreparedFile]) -> String {
        let additions = files.reduce(0) { $0 + $1.change.additions }
        let deletions = files.reduce(0) { $0 + $1.change.deletions }
        return "\(files.count) \(files.count == 1 ? "file" : "files") · +\(additions) −\(deletions)"
    }

    private func counts(_ change: FileChange) -> some View {
        HStack(spacing: 4) {
            if change.isBinary {
                Text("Binary").foregroundStyle(.secondary)
            } else {
                Text(verbatim: "+\(change.additions)").foregroundStyle(.green)
                Text(verbatim: "−\(change.deletions)").foregroundStyle(.red)
            }
        }
        .font(.caption.monospaced())
    }

    private func fileHeader(_ change: FileChange) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(change.path, systemImage: fileSymbol(change.path)).fontWeight(.medium)
                    .textSelection(.enabled)
                switch change.kind {
                case .added: Text("Added").foregroundStyle(.green)
                case .deleted: Text("Deleted").foregroundStyle(.red)
                case .renamed: Text("Renamed from \(change.oldPath ?? "another path")").foregroundStyle(.secondary)
                case .modified: EmptyView()
                }
                Spacer()
                counts(change)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
    }

    @ViewBuilder
    private func fileBody(_ file: PreparedFile) -> some View {
        if file.change.isBinary {
            note("Binary file")
        } else if let collapsed = file.collapsed {
            HStack {
                Text(verbatim: "Large diff: \(file.change.additions + file.change.deletions) changed lines")
                    .foregroundStyle(.secondary)
                Button("Show") { show(collapsed, index: file.index) }
            }
            .padding()
        } else if file.rows.isEmpty {
            note("No content changes")
        } else {
            ForEach(file.rows) { row in
                if let line = row.line {
                    DiffLineRow(line: line, text: row.text, digits: file.digits)
                } else {
                    Text(row.text)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5))
                }
            }
            .font(.callout.monospaced())
        }
    }

    /// Highlights a collapsed file off the main actor, then swaps it in.
    private func show(_ file: FileDiff, index: Int) {
        Task {
            let prepared = await Task.detached(priority: .userInitiated) {
                PreparedFile(file, index: index, expand: true)
            }.value
            files?[index] = prepared
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding()
    }
}

/// A file ready to render: its rows already highlighted, so `body` does no regex work.
private struct PreparedFile: Identifiable, Sendable {
    /// Files with more changed lines than this start collapsed.
    static let collapseThreshold = 2000

    let change: FileChange
    let index: Int
    let rows: [Row]
    /// Width, in digits, of the widest line number.
    let digits: Int
    /// The unhighlighted file while it is collapsed; highlighted only if the user asks to see it.
    let collapsed: FileDiff?
    var id: String { change.path }

    init(_ file: FileDiff, index: Int, expand: Bool = false) {
        change = file.change
        self.index = index
        if !expand && file.change.additions + file.change.deletions > Self.collapseThreshold {
            rows = []; digits = 0; collapsed = file
            return
        }
        collapsed = nil
        let path = file.change.path
        // Ids unique across the whole diff, so the lazy stack can tell rows of different files apart.
        var next = index << 32
        func row(_ line: DiffLine?, _ text: AttributedString) -> Row {
            defer { next += 1 }
            return Row(id: next, line: line, text: text)
        }
        rows = file.hunks.flatMap { hunk in
            [row(nil, AttributedString(hunk.header))]
                // An empty Text has no line height of its own.
                + hunk.lines.map { row($0, $0.text.isEmpty ? AttributedString(" ")
                                         : SyntaxHighlighter.highlight($0.text, path: path)) }
        }
        let widest = file.hunks.flatMap(\.lines).map { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0
        digits = String(widest).count
    }
}

/// A hunk header (no `line`) or a diff line, with its text ready to draw.
private struct Row: Identifiable, Sendable {
    let id: Int
    let line: DiffLine?
    let text: AttributedString
}

private struct DiffLineRow: View {
    let line: DiffLine
    let text: AttributedString
    let digits: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(line.kind == .added ? Color.green.opacity(0.15)
                    : line.kind == .removed ? Color.red.opacity(0.15) : Color.clear)
    }

    /// Sized by an invisible placeholder so the gutter fits the widest line number without a hard-coded width.
    private func number(_ value: Int?) -> some View {
        Text(String(repeating: "0", count: digits)).hidden()
            .overlay(alignment: .trailing) {
                Text(value.map(String.init) ?? "").foregroundStyle(.tertiary)
            }
            .padding(.leading, 8)
    }
}

/// A resizable two-pane split whose leading pane starts at a third of the width, clamped to 160–280pt.
/// HSplitView ignores ideal widths (the list opened at its maximum), so this sets the divider on a native
/// NSSplitView once it first has a width.
private struct ThirdSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        let list = NSSplitViewItem(viewController: host(leading))
        list.minimumThickness = 160
        list.maximumThickness = 280
        list.holdingPriority = .defaultLow + 1 // the diff, not the list, takes up window resizes
        controller.addSplitViewItem(list)
        let diff = NSSplitViewItem(viewController: host(trailing))
        diff.minimumThickness = 320
        controller.addSplitViewItem(diff)
        return controller
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        (controller.splitViewItems[0].viewController as? NSHostingController<Leading>)?.rootView = leading
        (controller.splitViewItems[1].viewController as? NSHostingController<Trailing>)?.rootView = trailing
    }

    private func host<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [] // the split view sizes the panes, not their content
        return host
    }

    final class Controller: NSSplitViewController {
        private var placed = false

        override func viewDidLayout() {
            super.viewDidLayout()
            guard !placed, view.bounds.width > 0 else { return }
            placed = true
            splitView.setPosition(view.bounds.width / 3, ofDividerAt: 0) // clamped by the item's min and max
        }
    }
}

#if DEBUG // the samples are debug only
#Preview {
    SyntaxHighlighter.selfCheck()
    return DiffView(files: FileDiff.samples)
        .environment(AppModel.preview())
        .frame(width: 900, height: 600)
}

#Preview("Large") {
    DiffView(files: FileDiff.large)
        .environment(AppModel.preview())
        .frame(width: 900, height: 600)
}
#endif
