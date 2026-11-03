import SwiftUI
import ShiftProtocol

/// An agent's message as formatted text: paragraphs, lists, tables, inline styles and code blocks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        // Parsed here rather than kept: it is cheap, and a message that's arriving changes each time.
        let groups = Self.group(MarkdownBlock.parse(text))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { group in
                if let prose = group.element.prose { Text(prose) } else if let block = group.element.block { view(for: block) }
            }
        }
        .textSelection(.enabled)
    }

    /// Runs of paragraphs, headings and list items become one `Text`, since a selection can't cross from one `Text` to another.
    private struct Group { var prose: AttributedString?; var block: MarkdownBlock? }

    private static func group(_ blocks: [MarkdownBlock]) -> [Group] {
        var groups: [Group] = []
        var previous: MarkdownBlock?
        for block in blocks {
            guard let piece = prose(block) else { groups.append(Group(block: block)); previous = nil; continue }
            if let last = groups.last?.prose, let previous {
                var gap = AttributedString("\n")
                if case .listItem = previous, case .listItem = block {} else {
                    var space = AttributedString("\n") // A short blank line, like the stack's spacing.
                    space.font = .system(size: 4)
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

    private static func prose(_ block: MarkdownBlock) -> AttributedString? {
        switch block {
        case .paragraph(let text):
            return inline(text)
        case .heading(let level, let text):
            var heading = inline(text)
            heading.font = level == 1 ? .title2 : level == 2 ? .title3 : .headline
            return heading
        case .listItem(let level, let marker, let text):
            var bullet = AttributedString(String(repeating: "  ", count: level) + marker + " ")
            bullet.foregroundColor = .secondary
            return bullet + inline(text)
        default:
            return nil
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            inline(text).font(level == 1 ? .title2 : level == 2 ? .title3 : .headline).padding(.top, 4)
        case .listItem(let level, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(level) * 8)
        case .table(let header, let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { inline($0.element).fontWeight(.semibold) }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { row in
                    Divider()
                    GridRow {
                        ForEach(Array(row.element.enumerated()), id: \.offset) { inline($0.element) }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true) // Otherwise long cells truncate instead of wrapping.
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: 8))
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.callout.monospaced()).padding(10)
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

    private func inline(_ text: String) -> Text { Text(Self.inline(text)) }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
