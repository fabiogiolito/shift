import AppKit
import SwiftUI

/// Every command a prompt field can offer; each `PromptField` lists the ones its messages handle
/// (`AppModel.sendPrompt`, `sendChat`, and the New Task field in `TaskListView`).
enum SlashCommand: String, CaseIterable, Identifiable {
    case task, tag, schedule

    var id: String { rawValue }

    var usage: String {
        switch self {
        case .task: "/task <prompt>"
        case .tag: "/tag <name>"
        case .schedule: "/schedule"
        }
    }

    var symbol: String {
        switch self {
        case .task: "plus.circle"
        case .tag: "tag"
        case .schedule: "clock"
        }
    }

    var summary: String {
        switch self {
        case .task: "Start a new task"
        case .tag: "Tag this task"
        case .schedule: "Run a prompt on a schedule"
        }
    }

    /// The commands of `offered` that `text` could be the start of: text that is `/` and a partial name, nothing more.
    static func matches(_ text: String, in offered: [SlashCommand]) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(where: \.isWhitespace) else { return [] }
        let typed = text.dropFirst().lowercased()
        return offered.filter { $0.rawValue.hasPrefix(typed) }
    }
}

/// The commands matching what's typed, in a menu-like panel just above the field it sits behind.
/// A child window rather than an overlay, so no scroll view or panel around the field clips it,
/// and it never takes key: typing, ↑↓ and Return stay with the field.
struct SlashCommandMenu: NSViewRepresentable {
    let commands: [SlashCommand]
    let selected: Int
    let onHover: (Int) -> Void
    let onPick: (SlashCommand) -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.content = commands.isEmpty ? nil : AnyView(list)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator: ()) { anchor.content = nil }

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                let isSelected = index == selected
                HStack(spacing: 6) {
                    Image(systemName: command.symbol).frame(width: 16)
                    Text(command.usage)
                    Text(command.summary).foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    if isSelected { RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .selectedContentBackgroundColor)) }
                }
                .contentShape(.rect)
                .onHover { if $0 { onHover(index) } }
                .onTapGesture { onPick(command) }
            }
        }
        .padding(5)
    }

    final class Anchor: NSView {
        private var panel: NSPanel?
        var content: AnyView? { didSet { update() } }

        override func layout() {
            super.layout()
            update()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { content = nil } else { update() }
        }

        private func update() {
            guard let content, let window else {
                if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
                return
            }
            let panel = self.panel ?? makePanel()
            let host = panel.contentView!.subviews.first as! NSHostingView<AnyView>
            host.rootView = content
            // At least the field's width and wide enough for its rows, but inside the window; above the field,
            // or below it when the window has no room above.
            let field = window.convertToScreen(convert(bounds, to: nil)), fitting = host.fittingSize
            let size = CGSize(width: min(max(field.width, fitting.width), window.frame.width - 16), height: fitting.height)
            let x = max(window.frame.minX + 8, min(field.minX, window.frame.maxX - 8 - size.width))
            let gap: CGFloat = 4
            let y = field.maxY + gap + size.height <= window.frame.maxY ? field.maxY + gap : field.minY - gap - size.height
            panel.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
            if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        }

        private func makePanel() -> NSPanel {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            let background = NSVisualEffectView()
            background.material = .menu
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 10
            background.layer?.masksToBounds = true
            let host = FirstClickHostingView(rootView: AnyView(EmptyView()))
            host.frame = background.bounds
            host.autoresizingMask = [.width, .height]
            background.addSubview(host)
            panel.contentView = background
            self.panel = panel
            return panel
        }
    }

    /// The panel is never key, so a click on a row has to count the first time.
    private final class FirstClickHostingView: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
