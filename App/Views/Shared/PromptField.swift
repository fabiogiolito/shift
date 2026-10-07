import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Multi-line text field with a send button inside it. Return adds a line; ⌘↩ submits while the field is focused.
/// Files and images dropped on it become attachments, sent as their paths.
struct PromptField: View {
    let placeholder: String
    var submitTitle = "Send"
    /// Makes File → New Task (⌘N) focus this field.
    var isNewTaskField = false
    /// Takes focus when it appears, for a field the user is expected to answer in.
    var focusOnAppear = false
    /// Set when the caller owns the text and sends it with its own button: the field then has none.
    var externalText: Binding<String>?
    /// The caller's attachments, alongside `externalText`.
    var externalAttachments: Binding<[URL]>?
    /// Keeps what's typed and attached under this key after the field is gone, so it's back when the user
    /// returns to the project or task it belongs to.
    var draftKey: String?
    var onSubmit: (String, [String]) -> Void = { _, _ in }

    @State private var ownText = ""
    @State private var ownAttachments: [URL] = []
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    private var text: String {
        get { externalText?.wrappedValue ?? draftKey.map { PromptDrafts.shared.drafts[$0]?.text ?? "" } ?? ownText }
        nonmutating set {
            if let externalText { externalText.wrappedValue = newValue }
            else if let draftKey { PromptDrafts.shared.drafts[draftKey, default: PromptDraft()].text = newValue }
            else { ownText = newValue }
        }
    }
    private var attachments: [URL] {
        get { externalAttachments?.wrappedValue ?? draftKey.map { PromptDrafts.shared.drafts[$0]?.attachments ?? [] } ?? ownAttachments }
        nonmutating set {
            if let externalAttachments { externalAttachments.wrappedValue = newValue }
            else if let draftKey { PromptDrafts.shared.drafts[draftKey, default: PromptDraft()].attachments = newValue }
            else { ownAttachments = newValue }
        }
    }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { url in
                            AttachmentChip(url: url) { attachments.removeAll { $0 == url } }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            editor
        }
        .font(.body)
        .padding(10)
        .padding(.trailing, externalText == nil ? 32 : 0) // room for the send button
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        // TextEditor draws no focus ring of its own, so the field draws the system one around its edge.
        // A drag over the field shows it too.
        .overlay {
            if focused || dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if externalText == nil { sendButton }
        }
        .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
            for provider in providers { Task { await add(provider) } }
            return true
        }
        .focusedSceneValue(\.focusNewTask, isNewTaskField ? { focused = true } : nil)
        .focusedValue(\.editingNewTask, isNewTaskField && focused ? true : nil)
        .onAppear { if focusOnAppear { focused = true } }
    }

    private var editor: some View {
        // TextEditor, unlike a vertical TextField, keeps Return for new lines. It doesn't size to its text,
        // so a hidden Text with the same content sets the height: 2 to 8 lines.
        Text(text.isEmpty ? " " : text + " ")
            .lineLimit(2...8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5)
            .hidden()
            .overlay {
                TextEditor(text: Binding(get: { text }, set: { text = $0 }))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .background(TextViewDropsAndPaste(onPaste: paste))
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5).allowsHitTesting(false)
                }
            }
    }

    private func attach(_ url: URL) {
        if !attachments.contains(url) { attachments.append(url) }
    }

    /// A dropped file as is; a dropped image with no file behind it (from a browser, say) saved as a PNG;
    /// dropped text typed in. Finder's files come typed as what they are (public.png, com.adobe.pdf), their item the file's URL.
    private func add(_ provider: NSItemProvider) async {
        for type in provider.registeredTypeIdentifiers.compactMap(UTType.init) {
            guard let item = try? await provider.loadItem(forTypeIdentifier: type.identifier) else { continue }
            let data = item as? Data
            let url = item as? URL ?? (type.conforms(to: .fileURL) ? data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) } : nil)
            if let url, url.isFileURL {
                // Finder may give a file reference (file:///.file/id=…); the agent needs the path.
                return attach((url as NSURL).filePathURL ?? url)
            }
            if type.conforms(to: .image), let image = Self.savePNG(data) { return attach(image) }
            if type.conforms(to: .plainText), let string = item as? String ?? data.flatMap({ String(data: $0, encoding: .utf8) }) {
                text += string
                return
            }
        }
    }

    /// Pasted files and images become attachments, like dropped ones. False leaves the paste to the text view.
    private func paste(from pasteboard: NSPasteboard) -> Bool {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let image = Self.savePNG(NSImage(pasteboard: pasteboard)?.tiffRepresentation) { urls = [image] }
        urls.forEach(attach)
        return !urls.isEmpty
    }

    private static func savePNG(_ data: Data?) -> URL? {
        guard let data, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shift Attachments")
        let url = folder.appendingPathComponent("Image \(UUID().uuidString.prefix(8)).png")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? png.write(to: url)) != nil ? url : nil
    }

    @ViewBuilder private var sendButton: some View {
        let send = Button {
            onSubmit(trimmed, attachments.map(\.path))
            text = ""
            attachments = []
        } label: {
            Label(submitTitle, systemImage: "arrow.up").labelStyle(.iconOnly)
        }
        Group {
            if trimmed.isEmpty && attachments.isEmpty { send.buttonStyle(.glass).disabled(true) } else { send.buttonStyle(.glassProminent) }
        }
        .buttonBorderShape(.circle)
        // Only the focused field owns ⌘↩, so two fields can be on screen.
        .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .help("\(submitTitle) (⌘↩)")
        .padding(6)
    }
}

/// A prompt not sent yet: what's typed in a field and dropped on it.
struct PromptDraft {
    var text = ""
    var attachments: [URL] = []
}

/// Unsent prompts by `PromptField.draftKey`. Here rather than in the views that show the fields, so typing
/// redraws only the fields. Kept until the app quits.
@MainActor @Observable final class PromptDrafts {
    static let shared = PromptDrafts()
    var drafts: [String: PromptDraft] = [:]
}

extension FocusedValues {
    /// True while the New task field has focus, so other ⌘↩ buttons stand aside.
    @Entry var editingNewTask: Bool?
}

/// A dropped file: its icon, name, and a remove button when `onRemove` is given; an image shows only its thumbnail,
/// with its name on hover and the remove button in its corner. Clicking it opens Quick Look.
struct AttachmentChip: View {
    let url: URL
    var onRemove: (() -> Void)?
    @State private var preview: URL?
    @State private var hovering = false

    var body: some View {
        Group {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { icon }
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay(alignment: .topTrailing) {
                        if let onRemove, hovering { removeButton(onRemove).background(.background, in: .circle).padding(3) }
                    }
                    .help(url.lastPathComponent)
            } else {
                HStack(spacing: 6) {
                    icon.frame(width: 24, height: 24)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160, alignment: .leading)
                    if let onRemove { removeButton(onRemove) }
                }
                .font(.callout)
                .padding(4)
                .padding(.trailing, 4)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .help(url.path)
            }
        }
        .contentShape(.rect(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture { preview = url }
        .quickLookPreview($preview)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button("Remove", systemImage: "xmark.circle.fill", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
    }

    private var icon: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
    }
}

/// TextEditor's text view sits in front of the field's drop handler and would take every drop itself: file drags
/// carry plain text too, so accepting only text still caught them. Accepting no drags lets them all through.
/// It also pastes images as nothing and files as their names, so `onPaste` gets a paste first; false lets the text view have it.
/// Sits behind the editor to find the text view there.
private struct TextViewDropsAndPaste: NSViewRepresentable {
    let onPaste: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Finder)?.paste.handle = onPaste }

    final class PasteHandler {
        var handle: (NSPasteboard) -> Bool = { _ in false }
    }

    final class Finder: NSView {
        let paste = PasteHandler()
        nonisolated(unsafe) static var pasteKey = 0

        override func layout() {
            super.layout()
            guard let window, bounds.width > 0 else { return }
            let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
            // The text view with this view's center in its scroll view is the editor this sits behind.
            var ancestor = superview
            while let view = ancestor {
                if let textView = Self.textViews(in: view).first(where: {
                    let frame = $0.enclosingScrollView ?? $0
                    return frame.convert(frame.bounds, to: nil).contains(center)
                }) {
                    objc_setAssociatedObject(textView, &Self.pasteKey, paste, .OBJC_ASSOCIATION_RETAIN)
                    Self.subclass(textView)
                    return
                }
                ancestor = view === window.contentView ? nil : view.superview
            }
        }

        /// Gives the text view a subclass with no drag types, whose paste (enabled for images and files too) asks the view's `PasteHandler` first.
        /// It re-registers its drag types now and then, so unregistering them once doesn't last.
        private static func subclass(_ textView: NSTextView) {
            guard let base = object_getClass(textView) else { return }
            let prefix = "ShiftPromptTextView_"
            guard !NSStringFromClass(base).hasPrefix(prefix) else { return }
            let name = prefix + NSStringFromClass(base)
            let subclass: AnyClass? = NSClassFromString(name) ?? {
                let dragTypes = #selector(getter: NSTextView.acceptableDragTypes), paste = #selector(NSText.paste(_:))
                guard let subclass = objc_allocateClassPair(base, name, 0),
                      let dragTypesMethod = class_getInstanceMethod(base, dragTypes),
                      let pasteMethod = class_getInstanceMethod(base, paste) else { return nil }
                let types: @convention(block) (NSTextView) -> [NSPasteboard.PasteboardType] = { _ in [] }
                class_addMethod(subclass, dragTypes, imp_implementationWithBlock(types), method_getTypeEncoding(dragTypesMethod))
                typealias Paste = @convention(c) (NSTextView, Selector, Any?) -> Void
                let superPaste = unsafeBitCast(method_getImplementation(pasteMethod), to: Paste.self)
                let pasteBlock: @convention(block) (NSTextView, Any?) -> Void = { textView, sender in
                    let handler = objc_getAssociatedObject(textView, &Finder.pasteKey) as? PasteHandler
                    if handler?.handle(.general) != true { superPaste(textView, paste, sender) }
                }
                class_addMethod(subclass, paste, imp_implementationWithBlock(pasteBlock), method_getTypeEncoding(pasteMethod))
                // Paste is only enabled for what the text view can read, plain text; images and files must enable it too.
                let readable = #selector(getter: NSTextView.readablePasteboardTypes)
                if let readableMethod = class_getInstanceMethod(base, readable) {
                    typealias Types = @convention(c) (NSTextView, Selector) -> [NSPasteboard.PasteboardType]
                    let superReadable = unsafeBitCast(method_getImplementation(readableMethod), to: Types.self)
                    let readableBlock: @convention(block) (NSTextView) -> [NSPasteboard.PasteboardType] = {
                        superReadable($0, readable) + [.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
                    }
                    class_addMethod(subclass, readable, imp_implementationWithBlock(readableBlock), method_getTypeEncoding(readableMethod))
                }
                objc_registerClassPair(subclass)
                return subclass
            }()
            guard let subclass else { return }
            object_setClass(textView, subclass)
            textView.updateDragTypeRegistration()
        }

        private static func textViews(in view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
    }
}
