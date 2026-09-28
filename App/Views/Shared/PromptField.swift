import SwiftUI

/// Multi-line text field with a send button inside it. Return adds a line; ⌘↩ submits while the field is focused.
struct PromptField: View {
    let placeholder: String
    var submitTitle = "Send"
    /// Makes File → New Task (⌘N) focus this field.
    var isNewTaskField = false
    /// Takes focus when it appears, for a field the user is expected to answer in.
    var focusOnAppear = false
    /// Set when the caller owns the text and sends it with its own button: the field then has none.
    var externalText: Binding<String>?
    var onSubmit: (String) -> Void = { _ in }

    @State private var ownText = ""
    @FocusState private var focused: Bool

    private var text: String {
        get { externalText?.wrappedValue ?? ownText }
        nonmutating set { if let externalText { externalText.wrappedValue = newValue } else { ownText = newValue } }
    }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
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
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 5).allowsHitTesting(false)
                }
            }
        .font(.body)
        .padding(10)
        .padding(.trailing, externalText == nil ? 32 : 0) // room for the send button
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        // TextEditor draws no focus ring of its own, so the field draws the system one around its edge.
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if externalText == nil { sendButton }
        }
        .focusedSceneValue(\.focusNewTask, isNewTaskField ? { focused = true } : nil)
        .focusedValue(\.editingNewTask, isNewTaskField && focused ? true : nil)
        .onAppear { if focusOnAppear { focused = true } }
    }

    @ViewBuilder private var sendButton: some View {
        let send = Button {
            onSubmit(trimmed)
            text = ""
        } label: {
            Label(submitTitle, systemImage: "arrow.up").labelStyle(.iconOnly)
        }
        Group {
            if trimmed.isEmpty { send.buttonStyle(.glass).disabled(true) } else { send.buttonStyle(.glassProminent) }
        }
        .buttonBorderShape(.circle)
        // Only the focused field owns ⌘↩, so two fields can be on screen.
        .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .help("\(submitTitle) (⌘↩)")
        .padding(6)
    }
}

extension FocusedValues {
    /// True while the New task field has focus, so other ⌘↩ buttons stand aside.
    @Entry var editingNewTask: Bool?
}
