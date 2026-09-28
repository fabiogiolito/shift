import SwiftUI

// ponytail: regex highlighting, swap for a real grammar engine if it looks wrong.
// Works one line at a time, so multi-line comments and strings are only coloured on lines
// that contain their delimiters.
enum SyntaxHighlighter {
    private enum Comments { case slash, hash, blockOnly, dashes, none }

    private static let families: [(Comments, [String])] = [
        (.slash, ["swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "java", "kt", "c", "h", "cpp", "hpp", "cc",
                  "m", "mm", "cs", "go", "rs", "php", "dart", "scss"]),
        (.hash, ["py", "rb", "sh", "bash", "zsh", "yml", "yaml", "toml"]),
        (.blockOnly, ["css"]),
        (.dashes, ["sql"]),
        (.none, ["json"]),
    ]

    private static let keywords = """
        as async await break case catch class const continue def default defer do elif else enum export extends \
        extension false final fn for from func function guard if impl implements import in init interface internal \
        is let match mut new nil none null package private protocol pub public return self static struct super \
        switch this throw throws true try type typealias undefined use var void where while yield \
        None True False Self
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: "|")

    private static let regexes: [String: NSRegularExpression] = {
        var result: [String: NSRegularExpression] = [:]
        for (comments, extensions) in families {
            let comment: String
            switch comments {
            case .slash: comment = #"//.*|/\*.*?(?:\*/|$)"#
            case .hash: comment = #"(?<![\w$])#.*"#
            case .blockOnly: comment = #"/\*.*?(?:\*/|$)"#
            case .dashes: comment = #"--.*"#
            case .none: comment = #"(?!)"#
            }
            let pattern = "(?<c>\(comment))"
                + #"|(?<s>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)"#
                + #"|(?<n>\b(?:0x[0-9a-fA-F]+|\d[\d_]*(?:\.\d+)?)\b)"#
                + "|(?<k>\\b(?:\(keywords))\\b)"
            // The patterns are constants; a failure here is a programming error caught by selfCheck.
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for ext in extensions { result[ext] = regex }
        }
        return result
    }()

    /// Unknown extensions render plain.
    static func highlight(_ line: String, path: String) -> AttributedString {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let regex = regexes[ext] else { return AttributedString(line) }
        let text = line as NSString
        var result = AttributedString()
        var cursor = 0
        for match in regex.matches(in: line, range: NSRange(location: 0, length: text.length)) {
            let range = match.range
            if range.location > cursor {
                result += AttributedString(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            var piece = AttributedString(text.substring(with: range))
            if match.range(withName: "c").location != NSNotFound { piece.foregroundColor = .secondary }
            else if match.range(withName: "s").location != NSNotFound { piece.foregroundColor = .orange }
            else if match.range(withName: "n").location != NSNotFound { piece.foregroundColor = .blue }
            else { piece.foregroundColor = .purple }
            result += piece
            cursor = range.location + range.length
        }
        if cursor < text.length { result += AttributedString(text.substring(from: cursor)) }
        return result
    }

    #if DEBUG
    /// The one runnable check for the highlighter (the app target has no test bundle). Called from the preview.
    static func selfCheck() {
        func colors(_ line: String, _ path: String) -> [String: Color] {
            var found: [String: Color] = [:]
            let text = highlight(line, path: path)
            for run in text.runs {
                if let color = run.foregroundColor { found[String(text[run.range].characters)] = color }
            }
            return found
        }
        assert(regexes.count == families.reduce(0) { $0 + $1.1.count }, "a pattern failed to compile")
        let swift = colors(#"let url = "http://x" + 42 // note"#, "a.swift")
        assert(swift["let"] == .purple && swift[#""http://x""#] == .orange && swift["42"] == .blue)
        assert(swift["// note"] == .secondary)
        assert(colors("x = 1 # if", "a.py")["# if"] == .secondary)
        assert(colors("color: #fff; /* c */", "a.css")["/* c */"] == .secondary)
        assert(colors("let x = 1", "a.unknown").isEmpty)
        assert(String(highlight("a \"b\" c", path: "a.ts").characters) == "a \"b\" c")
    }
    #endif
}
