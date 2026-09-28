import SwiftUI
import ShiftCore

/// The bottom bar of a task waiting on the user: what the agent asks, wants to do or couldn't do, and the ways to answer.
struct ResponsePanel: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    /// The tallest the panel gets before its content scrolls.
    let maxHeight: CGFloat

    /// Index into the options; `options.count` is "Something else". Nothing is chosen at first.
    @State private var choice: Int?
    @State private var text = ""
    @State private var contentHeight: CGFloat = 0
    @FocusState private var choicesFocused: Bool
    @FocusedValue(\.editingNewTask) private var editingNewTask

    /// Every task that needs the user gets the panel instead of the plain prompt field.
    static func shows(_ task: TaskItem) -> Bool {
        task.status == .blocked || (task.status == .needsInput && (task.question != nil || task.approvalRequest != nil))
    }

    private var options: [String] { task.options ?? [] }
    private var hasChoices: Bool { !options.isEmpty && task.approvalRequest == nil }
    private var somethingElse: Bool { choice == options.count }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var reply: String? {
        guard let choice else { return nil }
        return choice < options.count ? options[choice] : (trimmed.isEmpty ? nil : trimmed)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    message.frame(maxWidth: .infinity, alignment: .leading)
                    trailingActions
                }
                if hasChoices {
                    choices
                } else {
                    PromptField(placeholder: placeholder, focusOnAppear: true) { model.sendPrompt(taskID: task.id, text: $0) }
                }
            }
            .padding(16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        // Blue or red like the task's status icon: the task is waiting on this.
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(task.status.color, lineWidth: 1.5))
        .padding(12)
    }

    private var label: String {
        if task.approvalRequest != nil { "The agent wants to" }
        else if task.status == .blocked { "Couldn't continue" }
        else { "The agent needs a decision" }
    }

    private var placeholder: String {
        if task.approvalRequest != nil { "Or tell the agent something else…" }
        else if task.status == .blocked { "Give instructions…" }
        else { "Answer…" }
    }

    /// Long reasons (e.g. tool output) keep their first line as the message and the rest as detail under it.
    private var message: some View {
        let text = task.approvalRequest ?? task.question ?? task.blockedReason ?? ""
        let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
        let first = lines.first ?? text
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text((try? AttributedString(markdown: first, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(first))
                .textSelection(.enabled)
            if lines.count > 1 {
                ScrollView {
                    Text(lines[1].trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 64) // about 4 lines
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var trailingActions: some View {
        if task.approvalRequest != nil {
            Button("Deny") { model.answerApproval(taskID: task.id, allow: false) }.buttonStyle(.glass)
            Button("Allow") { model.answerApproval(taskID: task.id, allow: true) }.buttonStyle(.glassProminent)
        } else if task.canResume {
            Button("Continue") { model.resume(taskID: task.id) }.buttonStyle(.glassProminent)
        }
    }

    /// Suggested replies as a radio group, the last row opening a field for anything else, and one Send.
    private var choices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Reply", selection: $choice) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag(Optional($0)) }
                Text("Something else").tag(Optional(options.count))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .focused($choicesFocused)
            if somethingElse {
                PromptField(placeholder: task.status == .blocked ? "Give instructions…" : "Answer…", focusOnAppear: true,
                            externalText: $text)
            }
            HStack {
                Spacer()
                Button("Send") {
                    guard let reply else { return }
                    model.sendPrompt(taskID: task.id, text: reply)
                    choice = nil
                    text = ""
                }
                .buttonStyle(.glassProminent)
                .disabled(reply == nil)
                .keyboardShortcut(editingNewTask == true ? nil : KeyboardShortcut(.return, modifiers: .command))
                .help("Send (⌘↩)")
            }
        }
        .onAppear { choicesFocused = true }
    }
}
