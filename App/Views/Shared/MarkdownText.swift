import SwiftUI
import ShiftProtocol

/// An agent's message as formatted text: paragraphs, lists, tables, inline styles and code blocks.
struct MarkdownText: View {
    let text: String
    @Environment(\.textScale) private var textScale

    var body: some View {
        #if os(macOS)
        // Runs of paragraphs, headings and lists in one text view each, so a selection can cross them.
        let runs = MarkdownBlock.parse(text).reduce(into: [[MarkdownBlock]]()) { runs, block in
            if ProseTextView.isProse(block), let last = runs.last?.last, ProseTextView.isProse(last) { runs[runs.count - 1].append(block) } else { runs.append([block]) }
        }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(runs.enumerated()), id: \.offset) { run in
                if let first = run.element.first, ProseTextView.isProse(first) {
                    // A heading after a table, code block or quote gets the room it has after a paragraph: 18 with the stack's 10.
                    ProseTextView(blocks: run.element, scale: textScale)
                        .padding(.top, run.offset > 0 && Self.isHeading(first) ? 18 * textScale - 10 : 0)
                } else if let block = run.element.first {
                    view(for: block)
                }
            }
        }
        .textSelection(.enabled)
        #else
        // Parsed here rather than kept: it is cheap, and a message that's arriving changes each time.
        let groups = Self.group(MarkdownBlock.parse(text), scale: textScale)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.offset) { group in
                let group = group.element
                if let prose = group.prose {
                    // A heading after a list, table or code block keeps its distance from it, as after a paragraph.
                    LinkedText(string: prose).padding(.top, group.startsWithHeading ? 6 : 0)
                } else if group.blocks.count > 1 || group.blocks.first.map(Self.isListItem) == true {
                    // Tighter than paragraphs, and indented, so a list reads as one block.
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(group.blocks.enumerated()), id: \.offset) { view(for: $0.element) }
                    }
                    .padding(.leading, 8)
                } else if let block = group.blocks.first {
                    view(for: block)
                }
            }
        }
        .textSelection(.enabled)
        #endif
    }

    /// Runs of paragraphs and headings become one `Text`, since a selection can't cross from one `Text` to another.
    /// List items stay views of their own: wrapped lines can only hang under the item's text that way.
    private struct Group { var prose: AttributedString?; var startsWithHeading = false; var blocks: [MarkdownBlock] = [] }

    private static func isListItem(_ block: MarkdownBlock) -> Bool { if case .listItem = block { true } else { false } }
    private static func isHeading(_ block: MarkdownBlock) -> Bool { if case .heading = block { true } else { false } }

    private static func group(_ blocks: [MarkdownBlock], scale: Double) -> [Group] {
        var groups: [Group] = []
        var previous: MarkdownBlock?
        for block in blocks {
            guard let piece = prose(block, scale: scale) else {
                if isListItem(block), let last = groups.last?.blocks.last, isListItem(last) {
                    groups[groups.count - 1].blocks.append(block)
                } else {
                    groups.append(Group(blocks: [block]))
                }
                previous = nil
                continue
            }
            if let last = groups.last?.prose, let previous {
                // A short blank line between paragraphs, like the stack's spacing; more above a heading, less below it.
                var space = AttributedString("\n")
                space.font = .system(size: (isHeading(block) ? 16 : isHeading(previous) ? 2 : 6) * scale)
                groups[groups.count - 1].prose = last + AttributedString("\n") + space + piece
            } else {
                groups.append(Group(prose: piece, startsWithHeading: isHeading(block)))
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
            heading.font = headingFont(level, scale)
            return heading
        default:
            return nil
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(Self.headingFont(level, textScale))
        case .listItem(let level, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(level) * 16)
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

    /// Bold, a step above the semibold of bold text, so a heading reads as one.
    private static func headingFont(_ level: Int, _ scale: Double) -> Font {
        .scaled(level == 1 ? .title2 : level == 2 ? .title3 : .headline, scale).weight(.bold)
    }

    private func inline(_ text: String) -> LinkedText { LinkedText(string: Self.inline(text, scale: textScale)) }

    private static func inline(_ text: String, scale: Double) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        // Bold text is semibold: full bold shouts in a long reply.
        let strong = string.runs[\.inlinePresentationIntent].filter { $0.0?.contains(.stronglyEmphasized) == true }
        for (intent, range) in strong {
            string[range].inlinePresentationIntent = intent?.subtracting(.stronglyEmphasized)
            string[range].font = .scaled(.body, scale).weight(.semibold)
        }
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

    var body: some View {
        #if os(macOS)
        if string.runs[\.link].contains(where: { $0.0 != nil }) {
            // Rebuilt from pieces so the renderer can tell which runs are links.
            string.runs[\.link].reduce(Text("")) { text, run in
                let piece = Text(AttributedString(string[run.1]))
                return Text("\(text)\(run.0 == nil ? piece : piece.customAttribute(LinkRun()))")
            }
            .textRenderer(LinkFrames(box: links))
            // Set directly on every move, not with `pointerStyle`: selectable text keeps its I-beam over that, and only
            // sets it itself when the pointer enters the text. Again on the next turn, since entering straight onto a
            // link, the text's I-beam lands after this one.
            .onContinuousHover { phase in
                guard case .active(let point) = phase else { return }
                let cursor: NSCursor = links.rects.contains { $0.contains(point) } ? .pointingHand : .iBeam
                cursor.set()
                DispatchQueue.main.async { cursor.set() }
            }
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
