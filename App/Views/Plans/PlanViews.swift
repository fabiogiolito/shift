import SwiftUI
import AppKit
import MarkdownEngine
import ShiftCore

/// A plan in the task list's Plans group.
struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if model.isWriting(planID: plan.id) {
                    StatusIcon(status: .working, size: 14)
                } else {
                    Image(systemName: plan.error == nil ? "doc.text" : "exclamationmark.circle.fill")
                        .resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(plan.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                Text(plan.title).lineLimit(1)
                Spacer()
            }
            Text(model.planActivity[plan.id] ?? plan.error ?? "Ready to review")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .contextMenu { PlanActionItems(plan: plan) }
    }
}

/// Show in Finder and Delete: the plan's context menu and its page's More menu.
struct PlanActionItems: View {
    @Environment(AppModel.self) private var model
    let plan: Plan

    var body: some View {
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([plan.url]) }
        Divider()
        Button("Delete Plan", systemImage: "trash", role: .destructive) { model.deletePlan(plan.id) }
    }
}

/// The plan's document, styled as it's written and edited in place. Approve turns it into a task; Prompt asks the agent
/// for changes.
struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    let planID: Plan.ID
    @Binding var selection: TaskItem.ID?
    @State private var text = ""
    @State private var prompting = false
    @State private var approving = false
    /// The document is scrolled away from its top: the header gets an edge, as the toolbar does.
    @State private var scrolled = false
    /// The editor is made with the document already in it: text set after it's made counts as an edit, and it
    /// scrolls to the end.
    @State private var loaded = false
    /// Find on page: what's searched for, which match is current, and the editor it highlights in.
    @State private var find = ""
    @State private var findIndex = 0
    @State private var finder = EditorFinder()

    var body: some View {
        if let plan = model.plan(planID) {
            let writing = model.isWriting(planID: planID)
            VStack(alignment: .leading, spacing: 0) {
                header(plan, writing: writing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TaskDetailView.margin)
                    // Level with the task list's search field, and as much room under it as over it.
                    .padding(.vertical, 14)
                    // Opaque, and above the editor: the document draws past its top edge as it scrolls.
                    .background(.background)
                    .overlay(alignment: .bottom) { if scrolled { Divider() } }
                    .zIndex(1)
                if loaded {
                    NativeTextViewWrapper(text: $text,
                                          configuration: Self.editorConfiguration,
                                          fontName: NSFont.systemFont(ofSize: 0).fontName,
                                          fontSize: (NSFont.preferredFont(forTextStyle: .body).pointSize + 2) * textScale,
                                          documentId: plan.id.uuidString,
                                          isEditable: !writing)
                        .background { EditorScrollProbe(scrolled: $scrolled, finder: finder) }
                } else {
                    Spacer()
                }
            }
            .safeAreaBar(edge: .bottom) {
                if prompting {
                    PromptField(placeholder: "What should change in the plan?", focusOnAppear: true, draftKey: "plan \(planID)") {
                        model.revisePlan(planID, text: $0, attachments: $1)
                        prompting = false
                    }
                    .padding(12)
                }
            }
            .toolbar {
                ToolbarItem {
                    Text(plan.title).font(.title3).lineLimit(1)
                        .padding(.leading, TaskDetailView.margin - TaskDetailView.toolbarInset)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        PlanActionItems(plan: plan)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                text = model.planText(planID)
                loaded = true
            }
            .onChange(of: text) {
                model.savePlanText(planID, text)
                let count = findMatches.count
                if findIndex >= count { findIndex = max(count - 1, 0) }
                showFind(scroll: false)
            }
            .onChange(of: find) { findIndex = 0; showFind(scroll: true) }
            // What the agent has written so far, while it writes, then all of it.
            .task(id: writing) {
                repeat {
                    text = model.planText(planID)
                    guard writing else { break }
                    try? await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            }
            .modifier(FormattingShortcuts())
            // Edited in another app meanwhile.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                text = model.planText(planID)
            }
        } else {
            EmptyState("Plan Deleted", systemImage: "doc.text")
        }
    }

    private static let editorConfiguration: MarkdownEditorConfiguration = {
        var theme = MarkdownEditorTheme.default
        // `---` is drawn in this with its opacity set to 40%, so it must be opaque: a quarter of the way from the background
        // to the text, which at 40% is as light as the system's separator lines, in light and dark. Also strikes done
        // checklist items.
        theme.strikethroughColor = NSColor(name: nil) { appearance in
            var color = NSColor.gray
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.textBackgroundColor.blended(withFraction: 0.25, of: .labelColor) ?? .gray
            }
            return color
        }
        return MarkdownEditorConfiguration(theme: theme, textInsets: TextInsets(horizontal: TaskDetailView.margin, vertical: 12))
    }()

    /// Where `find` is in the document, ignoring case and accents.
    private var findMatches: [NSRange] {
        guard !find.isEmpty else { return [] }
        let string = text as NSString
        var matches: [NSRange] = []
        var rest = NSRange(location: 0, length: string.length)
        while true {
            let match = string.range(of: find, options: [.caseInsensitive, .diacriticInsensitive], range: rest)
            if match.location == NSNotFound { return matches }
            matches.append(match)
            rest = NSRange(location: NSMaxRange(match), length: string.length - NSMaxRange(match))
        }
    }

    private func showFind(scroll: Bool) {
        let matches = findMatches
        finder.show(matches, current: matches.isEmpty ? nil : findIndex, scroll: scroll)
    }

    /// Moves to the next match, or the previous one, wrapping around.
    private func step(_ by: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        findIndex = (findIndex + by + count) % count
        showFind(scroll: true)
    }

    private var findControls: some View {
        let count = findMatches.count
        return HStack(spacing: 8) {
            SearchField(text: $find, placeholder: "Find in Plan") { step($0 ? -1 : 1) }
                .frame(width: 180)
            if !find.isEmpty {
                Text(count == 0 ? "No results" : "\(findIndex + 1) of \(count)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Group {
                Button("Previous", systemImage: "chevron.left") { step(-1) }
                    .help("Previous match (⇧Return)")
                Button("Next", systemImage: "chevron.right") { step(1) }
                    .help("Next match (Return)")
            }
            .disabled(count == 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
    }

    private func header(_ plan: Plan, writing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Approve") {
                    approving = true
                    Task {
                        model.savePlanText(planID, text)
                        if let taskID = await model.approvePlan(planID) { selection = taskID }
                        approving = false
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(writing || approving)
                .help("Start a task that implements this plan")
                if writing {
                    Button("Stop") { model.stopPlan(planID) }.buttonStyle(.glass)
                } else {
                    Button("Prompt") { prompting.toggle() }
                        .buttonStyle(.glass)
                        .help("Ask the agent to change the plan")
                }
                Spacer()
                findControls
            }
            .buttonBorderShape(.roundedRectangle)
            if writing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.planActivity[planID] ?? "Writing the plan…")
                }
                .foregroundStyle(.secondary)
            } else if let error = plan.error {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            if let parent = plan.createdBy {
                Button("Created by #\(parent)") { selection = parent }
                    .buttonStyle(.link)
                    .disabled(model.task(parent) == nil)
                    .help("Open the task whose agent created this plan")
            }
        }
    }
}

/// The usual text editor shortcuts, as Markdown, while the plan's editor has the keyboard: ⌘B bold, ⌘I italic, ⇧⌘X
/// strikethrough, ⌘E code, ⌘K link, ⌥⌘1–3 headings, ⌥⌘0 body text, ⇧⌘7 numbered list, ⇧⌘8 bulleted list,
/// ⇧⌘9 checklist. Each one undoes with ⌘Z.
private struct FormattingShortcuts: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // The engine's editor is the only `NativeTextView` in the app.
                    guard let view = event.window?.firstResponder as? NSTextView, view.isEditable,
                          String(describing: type(of: view)) == "NativeTextView",
                          let edit = Self.edit(for: event, text: view.string, selection: view.selectedRange()) else { return event }
                    // Through the text view, so it's one undo step and the editor restyles and saves as after typing.
                    if view.shouldChangeText(in: edit.range, replacementString: edit.replacement) {
                        view.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
                        view.didChangeText()
                        view.setSelectedRange(edit.selection)
                    }
                    return nil
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private static func edit(for event: NSEvent, text: String, selection: NSRange) -> MarkdownEdit? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Digits by key code: with ⇧ their characters are symbols that depend on the layout.
        switch (flags, key, event.keyCode) {
        case ([.command], "b", _): return .toggle("**", in: text, selection: selection)
        case ([.command], "i", _): return .toggle("_", in: text, selection: selection)
        case ([.command], "e", _): return .toggle("`", in: text, selection: selection)
        case ([.command], "k", _): return .link(in: text, selection: selection)
        case ([.command, .shift], "x", _): return .toggle("~~", in: text, selection: selection)
        case ([.command, .option], _, 29): return .set(.paragraph, in: text, selection: selection)
        case ([.command, .option], _, 18): return .set(.heading(1), in: text, selection: selection)
        case ([.command, .option], _, 19): return .set(.heading(2), in: text, selection: selection)
        case ([.command, .option], _, 20): return .set(.heading(3), in: text, selection: selection)
        case ([.command, .shift], _, 26): return .set(.numbered, in: text, selection: selection)
        case ([.command, .shift], _, 28): return .set(.bullet, in: text, selection: selection)
        case ([.command, .shift], _, 25): return .set(.checklist, in: text, selection: selection)
        default: return nil
        }
    }
}

/// Whether the plan's editor is scrolled down. The editor is AppKit's, so its scroll view is found in the window and its
/// clip view watched.
private struct EditorScrollProbe: NSViewRepresentable {
    @Binding var scrolled: Bool
    let finder: EditorFinder

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = { value in if scrolled != value { scrolled = value } }
        probe.finder = finder
    }

    final class Probe: NSView {
        var onChange: (Bool) -> Void = { _ in }
        var finder: EditorFinder?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // After this pass, once the editor next to it is in the window too.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let root = window?.contentView, let scroll = Self.editorScrollView(in: root) else { return }
            finder?.textView = scroll.documentView.flatMap(Self.textView)
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange(clip.bounds.minY + clip.contentInsets.top > 1) }
            }
        }

        private static func editorScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let document = scroll.documentView, isEditor(document) { return scroll }
            return view.subviews.lazy.compactMap(editorScrollView).first
        }

        private static func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, String(describing: type(of: view)) == "NativeTextView" { return text }
            return view.subviews.lazy.compactMap(textView).first
        }

        /// The engine's text view, `NativeTextView`, is internal to it: known by name.
        private static func isEditor(_ view: NSView) -> Bool {
            String(describing: type(of: view)) == "NativeTextView" || view.subviews.contains(where: isEditor)
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

/// Find on page in the plan's editor: every match is highlighted, the current one in the system's find color, and
/// scrolled to. Rendering attributes, so the document's text isn't touched.
@MainActor final class EditorFinder {
    weak var textView: NSTextView?

    func show(_ matches: [NSRange], current: Int?, scroll: Bool) {
        guard let view = textView, let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
        let start = content.documentRange.location
        for (index, range) in matches.enumerated() {
            guard let from = content.location(start, offsetBy: range.location),
                  let to = content.location(from, offsetBy: range.length),
                  let textRange = NSTextRange(location: from, end: to) else { continue }
            let color = index == current ? NSColor.findHighlightColor : NSColor.findHighlightColor.withAlphaComponent(0.3)
            layout.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
        }
        if scroll, let current, matches.indices.contains(current) {
            view.scrollRangeToVisible(matches[current])
            view.showFindIndicator(for: matches[current])
        }
    }
}
