import Foundation

/// A formatting command on Markdown source, as the plan editor's shortcuts apply it: what to replace, and the selection
/// after. Ranges are UTF-16, as text views count.
public struct MarkdownEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }

    /// The block a line starts with.
    public enum Block: Equatable, Sendable {
        case paragraph, heading(Int), bullet, numbered, checklist, quote
    }

    /// Wraps the selection in `marker` (`**`, `_`, `~~`, `` ` ``), or unwraps it when it's already wrapped, inside or
    /// just around the selection. With nothing selected, puts the caret between a new pair.
    public static func toggle(_ marker: String, in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString, m = (marker as NSString).length
        let selected = ns.substring(with: selection)
        if selection.length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = (selected as NSString).substring(with: NSRange(location: m, length: selection.length - 2 * m))
            return MarkdownEdit(range: selection, replacement: inner,
                                selection: NSRange(location: selection.location, length: selection.length - 2 * m))
        }
        let around = NSRange(location: selection.location - m, length: selection.length + 2 * m)
        if selection.location >= m, NSMaxRange(around) <= ns.length,
           ns.substring(with: NSRange(location: around.location, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: m)) == marker {
            return MarkdownEdit(range: around, replacement: selected,
                                selection: NSRange(location: around.location, length: selection.length))
        }
        return MarkdownEdit(range: selection, replacement: marker + selected + marker,
                            selection: NSRange(location: selection.location + m, length: selection.length))
    }

    /// `[selection](url)`, with `url` selected to type over; with nothing selected, `[text](url)` with `text` selected.
    public static func link(in text: String, selection: NSRange) -> MarkdownEdit {
        let selected = (text as NSString).substring(with: selection)
        if selected.isEmpty {
            return MarkdownEdit(range: selection, replacement: "[text](url)", selection: NSRange(location: selection.location + 1, length: 4))
        }
        let label = "[\(selected)]("
        return MarkdownEdit(range: selection, replacement: label + "url)",
                            selection: NSRange(location: selection.location + (label as NSString).length, length: 3))
    }

    private static let blockPrefix = try! NSRegularExpression(pattern: #"^(\s*)(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+\. |> )?"#)

    /// Makes every line the selection touches `block`, or a paragraph if they all are that already. Indentation stays.
    public static func set(_ block: Block, in text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        var lines = ns.lineRange(for: selection)
        // The line's own newline stays out of it, so the next line is untouched.
        if lines.length > 0, ns.substring(with: NSRange(location: NSMaxRange(lines) - 1, length: 1)) == "\n" { lines.length -= 1 }
        let parsed = ns.substring(with: lines).components(separatedBy: "\n").map { line -> (indent: String, block: Block, body: String) in
            let match = blockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))!
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let prefix = match.range(at: 2).location == NSNotFound ? "" : (line as NSString).substring(with: match.range(at: 2))
            return (indent, kind(of: prefix), (line as NSString).substring(from: match.range.length))
        }
        let filled = parsed.filter { !$0.body.isEmpty || $0.block != .paragraph }
        let all = !filled.isEmpty && filled.allSatisfy { $0.block == block }
        let target = all ? Block.paragraph : block
        var number = 0
        let replacement = parsed.map { line -> String in
            if line.body.isEmpty && line.block == .paragraph && parsed.count > 1 { return line.indent }
            number += 1
            return line.indent + prefix(target, number: number) + line.body
        }.joined(separator: "\n")
        let length = (replacement as NSString).length
        return MarkdownEdit(range: lines, replacement: replacement,
                            selection: selection.length == 0 ? NSRange(location: lines.location + length, length: 0)
                                : NSRange(location: lines.location, length: length))
    }

    private static func kind(of prefix: String) -> Block {
        if prefix.hasPrefix("#") { return .heading(prefix.count - 1) }
        if prefix.hasPrefix(">") { return .quote }
        if prefix.contains("[") { return .checklist }
        if prefix.first?.isNumber == true { return .numbered }
        return prefix.isEmpty ? .paragraph : .bullet
    }

    private static func prefix(_ block: Block, number: Int) -> String {
        switch block {
        case .paragraph: ""
        case .heading(let level): String(repeating: "#", count: level) + " "
        case .bullet: "- "
        case .numbered: "\(number). "
        case .checklist: "- [ ] "
        case .quote: "> "
        }
    }
}
