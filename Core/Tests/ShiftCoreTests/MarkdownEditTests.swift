import XCTest
import ShiftProtocol

final class MarkdownEditTests: XCTestCase {
    private func apply(_ edit: MarkdownEdit, to text: String) -> (String, String) {
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, (result as NSString).substring(with: edit.selection))
    }

    func testToggleWrapsAndUnwraps() {
        let text = "make it bold"
        let wrapped = apply(MarkdownEdit.toggle("**", in: text, selection: NSRange(location: 8, length: 4)), to: text)
        XCTAssertEqual(wrapped.0, "make it **bold**")
        XCTAssertEqual(wrapped.1, "bold")
        // Again on the same word: back to plain.
        XCTAssertEqual(apply(MarkdownEdit.toggle("**", in: wrapped.0, selection: NSRange(location: 10, length: 4)), to: wrapped.0).0, text)
        // Markers selected too.
        XCTAssertEqual(apply(MarkdownEdit.toggle("**", in: wrapped.0, selection: NSRange(location: 8, length: 8)), to: wrapped.0).0, text)
        // Italic inside bold doesn't take a star from it.
        XCTAssertEqual(apply(MarkdownEdit.toggle("_", in: wrapped.0, selection: NSRange(location: 10, length: 4)), to: wrapped.0).0, "make it **_bold_**")
        // Nothing selected: a pair, caret inside.
        let empty = MarkdownEdit.toggle("`", in: "ab", selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(apply(empty, to: "ab").0, "a``b")
        XCTAssertEqual(empty.selection, NSRange(location: 2, length: 0))
    }

    func testLink() {
        let (text, selected) = apply(MarkdownEdit.link(in: "see docs", selection: NSRange(location: 4, length: 4)), to: "see docs")
        XCTAssertEqual(text, "see [docs](url)")
        XCTAssertEqual(selected, "url")
    }

    func testBlocks() {
        let text = "# Title\none\n\ntwo\nnext"
        // Lines 2–4 (one, blank, two) as a numbered list; the blank line stays blank, the line after is untouched.
        let numbered = apply(MarkdownEdit.set(.numbered, in: text, selection: NSRange(location: 8, length: 8)), to: text).0
        XCTAssertEqual(numbered, "# Title\n1. one\n\n2. two\nnext")
        // The same again turns them back into paragraphs.
        XCTAssertEqual(apply(MarkdownEdit.set(.numbered, in: numbered, selection: NSRange(location: 9, length: 1)), to: numbered).0,
                       "# Title\none\n\n2. two\nnext")
        // A heading replaces a heading, keeping its text.
        XCTAssertEqual(apply(MarkdownEdit.set(.heading(2), in: text, selection: NSRange(location: 2, length: 0)), to: text).0,
                       "## Title\none\n\ntwo\nnext")
        // Indentation stays; a bullet becomes a checklist item.
        XCTAssertEqual(apply(MarkdownEdit.set(.checklist, in: "  - item", selection: NSRange(location: 5, length: 0)), to: "  - item").0,
                       "  - [ ] item")
        // An empty line gets the prefix.
        XCTAssertEqual(apply(MarkdownEdit.set(.bullet, in: "", selection: NSRange(location: 0, length: 0)), to: "").0, "- ")
    }
}
