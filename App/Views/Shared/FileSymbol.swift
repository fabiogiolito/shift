import UniformTypeIdentifiers

/// SF Symbol for a file path, from its type.
func fileSymbol(_ path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    // In a code repo .ts is TypeScript, not the MPEG transport stream the system maps it to.
    if ext == "ts" { return "curlybraces" }
    guard let type = UTType(filenameExtension: ext) else { return "doc" }
    if type.conforms(to: .image) { return "photo" }
    if type.conforms(to: .movie) { return "film" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .archive) { return "doc.zipper" }
    if type.conforms(to: .sourceCode) { return "curlybraces" }
    if type.conforms(to: .plainText) { return "doc.text" }
    // Structured text: HTML, CSS, JSON, YAML, XML.
    if type.conforms(to: .text) { return "curlybraces" }
    return "doc"
}
