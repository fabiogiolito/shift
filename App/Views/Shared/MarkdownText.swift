import SwiftUI
import ShiftProtocol

/// An agent's message as formatted text: paragraphs, lists, tables, inline styles and code blocks.
struct MarkdownText: View {
    let text: String

    var body: some View {
        // Parsed here rather than kept: it is cheap, and a message that's arriving changes each time.
        let blocks = MarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { view(for: $0.element) }
        }
        .textSelection(.enabled)
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

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
    }
}
