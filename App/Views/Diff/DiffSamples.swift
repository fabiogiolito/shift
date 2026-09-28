#if DEBUG
import ShiftCore

/// Sample diffs for the preview: modified, added, renamed, deleted, binary and a file large enough to start collapsed.
extension FileDiff {
    static let samples: [FileDiff] = [
        FileDiff(change: FileChange(path: "src/components/Board.tsx", kind: .modified, additions: 4, deletions: 2), hunks: [
            DiffHunk(header: "@@ -10,7 +10,9 @@ export function Board({ items }: BoardProps) {", lines: [
                DiffLine(kind: .context, text: "  const columns = useColumns(items);", oldNumber: 10, newNumber: 10),
                DiffLine(kind: .context, text: "  // Spacing between board items", oldNumber: 11, newNumber: 11),
                DiffLine(kind: .removed, text: "  const gap = 8;", oldNumber: 12),
                DiffLine(kind: .removed, text: "  return <div className=\"board\" style={{ gap }}>", oldNumber: 13),
                DiffLine(kind: .added, text: "  const gap = 4;", newNumber: 12),
                DiffLine(kind: .added, text: "  const style = { \"--board-gap\": `${gap}px` } as React.CSSProperties;", newNumber: 13),
                DiffLine(kind: .added, text: "  if (columns.length === 0) return null;", newNumber: 14),
                DiffLine(kind: .added, text: "  return <div className=\"board\" style={style} data-columns={columns.length} data-description=\"A deliberately long line that has to wrap inside the diff viewer without breaking the gutter\">", newNumber: 15),
                DiffLine(kind: .context, text: "    {columns.map((column) => (", oldNumber: 14, newNumber: 16),
            ]),
            DiffHunk(header: "@@ -120,3 +122,3 @@ function useColumns(items: Item[]) {", lines: [
                DiffLine(kind: .context, text: "  /* group by status */", oldNumber: 120, newNumber: 122),
                DiffLine(kind: .context, text: "  return groupBy(items, 'status');", oldNumber: 121, newNumber: 123),
                DiffLine(kind: .context, text: "}", oldNumber: 122, newNumber: 124),
            ]),
        ]),
        FileDiff(change: FileChange(path: "scripts/spacing.py", kind: .added, additions: 5), hunks: [
            DiffHunk(header: "@@ -0,0 +1,5 @@", lines: [
                DiffLine(kind: .added, text: "# Prints the spacing scale", newNumber: 1),
                DiffLine(kind: .added, text: "def scale(base=4, steps=6):", newNumber: 2),
                DiffLine(kind: .added, text: "    return [base * 2 ** n for n in range(steps)]", newNumber: 3),
                DiffLine(kind: .added, text: "", newNumber: 4),
                DiffLine(kind: .added, text: "print(\"scale\", scale())", newNumber: 5),
            ]),
        ]),
        FileDiff(change: FileChange(path: "src/styles/board.css", oldPath: "src/styles/grid.css", kind: .renamed, additions: 1, deletions: 1), hunks: [
            DiffHunk(header: "@@ -1,4 +1,4 @@", lines: [
                DiffLine(kind: .context, text: ".board {", oldNumber: 1, newNumber: 1),
                DiffLine(kind: .removed, text: "  gap: 8px; /* old */", oldNumber: 2),
                DiffLine(kind: .added, text: "  gap: var(--board-gap, 4px);", newNumber: 2),
                DiffLine(kind: .context, text: "  color: #333;", oldNumber: 3, newNumber: 3),
                DiffLine(kind: .context, text: "}", oldNumber: 4, newNumber: 4),
            ]),
        ]),
        FileDiff(change: FileChange(path: "public/logo.png", kind: .modified, isBinary: true), hunks: []),
        FileDiff(change: FileChange(path: "NOTES.txt", kind: .deleted, deletions: 2), hunks: [
            DiffHunk(header: "@@ -1,2 +0,0 @@", lines: [
                DiffLine(kind: .removed, text: "let this = \"plain text, not highlighted\" // 42", oldNumber: 1),
                DiffLine(kind: .removed, text: "Remember to tighten the gap.", oldNumber: 2),
            ]),
        ]),
        FileDiff(change: FileChange(path: "Sources/Generated/Tokens.swift", kind: .modified, additions: 400, deletions: 0), hunks: [
            DiffHunk(header: "@@ -1,2 +1,402 @@", lines:
                [DiffLine(kind: .context, text: "import Foundation", oldNumber: 1, newNumber: 1)]
                + (2...401).map { (n: Int) in DiffLine(kind: .added, text: "let token\(n) = \"value-\(n)\" // generated", newNumber: n) }
                + [DiffLine(kind: .context, text: "// end", oldNumber: 2, newNumber: 402)]),
        ]),
        FileDiff(change: FileChange(path: "pnpm-lock.yaml", kind: .modified, additions: 2500, deletions: 0), hunks: [
            DiffHunk(header: "@@ -1,0 +1,2500 @@", lines:
                (1...2500).map { (n: Int) in DiffLine(kind: .added, text: "  package-\(n): 1.0.\(n)", newNumber: n) }),
        ]),
    ]

    /// A few thousand highlighted lines across several files, for measuring how the diff view opens.
    static let large: [FileDiff] = {
        let code = [
            "    let result = items.filter { $0.isVisible && $0.count > 42 } // keep visible",
            "    guard let value = cache[key] else { return nil }",
            "    const style = { gap: `${gap}px`, color: \"#333\" }; /* inline */",
            "    if (columns.length === 0) return null;",
            "    return [base * 2 ** n for n in range(steps)]  # scale",
            "    self.label = \"Item \\(index)\" + String(0x2A)",
            "",
            "    func update(_ id: Int, value: String) async throws -> Bool {",
        ]
        return ["swift", "tsx", "py", "ts", "swift", "js", "swift", "go"].enumerated().map { f, ext in
            let lines = (1...600).map { (n: Int) in
                DiffLine(kind: n % 5 == 0 ? .removed : n % 3 == 0 ? .context : .added,
                         text: code[(n + f) % code.count], oldNumber: n, newNumber: n)
            }
            let hunks = stride(from: 0, to: lines.count, by: 100).map {
                DiffHunk(header: "@@ -\($0 + 1),100 +\($0 + 1),100 @@", lines: Array(lines[$0..<$0 + 100]))
            }
            let added = lines.filter { $0.kind == .added }.count, removed = lines.filter { $0.kind == .removed }.count
            return FileDiff(change: FileChange(path: "Sources/Module\(f)/File\(f).\(ext)", kind: .modified,
                                               additions: added, deletions: removed), hunks: hunks)
        } + samples
    }()
}
#endif
