import SwiftUI
import AppKit
import ShiftProtocol

/// A run of a message's paragraphs, headings and list items in one AppKit text view, so a selection can go from one
/// to the next. It also gives list items wrapped lines that hang under their text, and the pointing hand over links.
struct ProseTextView: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let scale: Double

    func makeNSView(context: Context) -> TextView {
        let view = TextView(usingTextLayoutManager: false) // TextKit 1: its height for a width is one call.
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true // The drawn width follows the frame SwiftUI gives it.
        view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        let string = Self.string(blocks, scale: scale)
        if view.textStorage?.isEqual(to: string) != true { view.textStorage?.setAttributedString(string) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // SwiftUI probes other widths too (narrow ones while a disclosure above animates). Put the drawn width back after
        // measuring, or the text stays wrapped to the last probe, one word a line, spilling over what's below it.
        let drawn = container.size
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height)
        container.size = drawn
        return CGSize(width: width, height: height)
    }

    final class TextView: NSTextView {
        /// One selection on screen at a time, as with SwiftUI text: clicking into another message clears this one.
        override func resignFirstResponder() -> Bool {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            return super.resignFirstResponder()
        }
    }

    // MARK: - Building the text

    static func string(_ blocks: [MarkdownBlock], scale: Double) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var previous: MarkdownBlock?
        for block in blocks {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2 * scale // As the SwiftUI text around it.
            // Like the gap between blocks; more above a heading, less below it, and tighter between list items.
            style.paragraphSpacingBefore = previous == nil ? 0 : (isHeading(block) ? 18 : previous.map(isHeading) == true ? 4
                : isListItem(block) && previous.map(isListItem) == true ? 5 : 9) * scale
            let piece: NSMutableAttributedString
            switch block {
            case .paragraph(let text):
                piece = inline(text, size: bodySize(scale))
            case .heading(let level, let text):
                let style: NSFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
                piece = inline(text, size: NSFont.preferredFont(forTextStyle: style).pointSize * scale)
                piece.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize * scale, weight: .bold),
                                   range: NSRange(location: 0, length: piece.length))
            case .listItem(let level, let marker, let itemText):
                let size = bodySize(scale)
                let markerFont = NSFont.systemFont(ofSize: size)
                // Markers right-aligned in a column as wide as the level's widest one, a small gap from the text.
                let column = blocks.reduce(CGFloat(0)) { widest, block in
                    guard case .listItem(level, let other, _) = block else { return widest }
                    return max(widest, (other as NSString).size(withAttributes: [.font: markerFont]).width)
                }
                let indent = (8 + CGFloat(level) * 16) * scale
                let text = indent + column + 5 * scale
                style.firstLineHeadIndent = indent
                style.headIndent = text
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent + column), NSTextTab(textAlignment: .left, location: text)]
                piece = NSMutableAttributedString(string: "\t" + marker + "\t", attributes: [.font: markerFont, .foregroundColor: NSColor.secondaryLabelColor])
                piece.append(inline(itemText, size: size))
            default:
                continue
            }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
            previous = block
        }
        return result
    }

    static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block { case .paragraph, .heading, .listItem: true; default: false }
    }

    private static func isListItem(_ block: MarkdownBlock) -> Bool { if case .listItem = block { true } else { false } }
    private static func isHeading(_ block: MarkdownBlock) -> Bool { if case .heading = block { true } else { false } }
    private static func bodySize(_ scale: Double) -> CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize * scale }

    /// Inline markdown as AppKit attributes: semibold for bold, italics, strikethrough, links, and code at the code blocks' size.
    private static func inline(_ text: String, size: CGFloat) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize * size / bodySize(1), weight: .regular)
                : NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor.tertiarySystemFill }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
