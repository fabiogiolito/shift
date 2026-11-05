import SwiftUI
import ShiftProtocol

/// An agent's message as formatted text: paragraphs, lists, tables, inline styles and code blocks.
struct MarkdownText: View {
    let text: String
    @Environment(\.textScale) private var textScale

    var body: some View {
        // Parsed here rather than kept: it is cheap, and a message that's arriving changes each time.
        let groups = Self.group(MarkdownBlock.parse(text), scale: textScale)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { group in
                if let prose = group.element.prose { LinkedText(string: prose) } else if let block = group.element.block { view(for: block) }
            }
        }
        .textSelection(.enabled)
    }

    /// Runs of paragraphs, headings and list items become one `Text`, since a selection can't cross from one `Text` to another.
    private struct Group { var prose: AttributedString?; var block: MarkdownBlock? }

    private static func group(_ blocks: [MarkdownBlock], scale: Double) -> [Group] {
        var groups: [Group] = []
        var previous: MarkdownBlock?
        for block in blocks {
            guard let piece = prose(block, scale: scale) else { groups.append(Group(block: block)); previous = nil; continue }
            if let last = groups.last?.prose, let previous {
                var gap = AttributedString("\n")
                if case .listItem = previous, case .listItem = block {} else {
                    var space = AttributedString("\n") // A short blank line, like the stack's spacing.
                    space.font = .system(size: 6 * scale)
                    gap += space
                }
                groups[groups.count - 1].prose = last + gap + piece
            } else {
                groups.append(Group(prose: piece))
            }
            previous = block
        }
        return groups
    }

    private static func prose(_ block: MarkdownBlock, scale: Double) -> AttributedString? {
        switch block {
        case .paragraph(let text):
            return inline(text, scale: scale)
        case .heading(let level, let text):
            var heading = inline(text, scale: scale)
            heading.font = .scaled(headingStyle(level), scale)
            return heading
        case .listItem(let level, let marker, let text):
            var bullet = AttributedString(String(repeating: "  ", count: level) + marker + " ")
            bullet.foregroundColor = .secondary
            return bullet + inline(text, scale: scale)
        default:
            return nil
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(.scaled(Self.headingStyle(level), textScale)).padding(.top, 4)
        case .listItem(let level, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(level) * 8)
        case .table(let header, let rows):
            #if os(iOS)
            // Too narrow a screen to squeeze every column in: the table scrolls sideways in its box, not the page.
            ScrollView(.horizontal) { table(header, rows) }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: .rect(cornerRadius: 8))
            #else
            table(header, rows)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: .rect(cornerRadius: 8))
            #endif
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.scaled(.callout, textScale, design: .monospaced)).padding(10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: 8))
        case .quote(let text):
            HStack(spacing: 8) {
                Divider()
                inline(text).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { cell($0.element).fontWeight(.semibold) }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                Divider()
                GridRow {
                    ForEach(Array(row.element.enumerated()), id: \.offset) { cell($0.element) }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true) // Otherwise long cells truncate instead of wrapping.
        .padding(10)
    }

    private func cell(_ text: String) -> some View {
        #if os(iOS)
        CappedWidth(max: 220) { inline(text) } // Given no width in the scroll view, long cells wrap here.
        #else
        inline(text)
        #endif
    }

    private static func headingStyle(_ level: Int) -> Font.TextStyle { level == 1 ? .title2 : level == 2 ? .title3 : .headline }

    private func inline(_ text: String) -> LinkedText { LinkedText(string: Self.inline(text, scale: textScale)) }

    private static func inline(_ text: String, scale: Double) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Monospaced at the text's own size looks larger than the prose around it: inline code gets the code blocks' size.
        let code = string.runs[\.inlinePresentationIntent].filter { $0.0?.contains(.code) == true }.map(\.1)
        for range in code { string[range].font = .scaled(.callout, scale, design: .monospaced) }
        return string
    }
}

#if os(iOS)
/// As wide as its content wants, up to `max`, wrapping beyond it.
private struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = min(proposal.width ?? view.sizeThatFits(.unspecified).width, max)
        return view.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif

/// Text whose links show the pointing hand on hover, as they do in a browser.
private struct LinkedText: View {
    let string: AttributedString
    @State private var links = LinkFrames.Box()
    @State private var overLink = false

    var body: some View {
        #if os(macOS)
        if string.runs[\.link].contains(where: { $0.0 != nil }) {
            // Rebuilt from pieces so the renderer can tell which runs are links.
            string.runs[\.link].reduce(Text("")) { text, run in
                let piece = Text(AttributedString(string[run.1]))
                return Text("\(text)\(run.0 == nil ? piece : piece.customAttribute(LinkRun()))")
            }
            .textRenderer(LinkFrames(box: links))
            .onContinuousHover { phase in
                if case .active(let point) = phase { overLink = links.rects.contains { $0.contains(point) } } else { overLink = false }
            }
            .pointerStyle(overLink ? .link : nil)
        } else {
            Text(string)
        }
        #else
        Text(string) // No pointer to show on a phone.
        #endif
    }
}

private struct LinkRun: TextAttribute {}

/// Draws text as usual, noting where its links ended up.
private struct LinkFrames: TextRenderer {
    final class Box { var rects: [CGRect] = [] }
    let box: Box

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        box.rects = layout.flatMap { $0 }.filter { $0[LinkRun.self] != nil }.map(\.typographicBounds.rect)
        for line in layout { context.draw(line) }
    }
}
