import SwiftUI
import ShiftCore

// What an agent did, shared by a task's Agent tab and the project chat.

/// A turn from top to bottom: the prompt, then what the agent did about it.
struct TurnView: View {
    let turn: TranscriptTurn
    /// The prompts the turn answers. Empty for logs from before Shift recorded which.
    let prompts: [Prompt]
    let reader: TranscriptReader?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = turn.note {
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(prompts) { PromptBubble(prompt: $0) }
            if let text = turn.text {
                // Shift's own instructions, not the user's words.
                Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            ForEach(turn.sections) { section in
                switch section {
                case .message(_, let text): MarkdownText(text: text)
                case .steps(_, let steps): StepsView(steps: steps, reader: reader)
                case .error(_, let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                case .approval(_, let summary):
                    Label {
                        Text(.init("Asked to \(summary)"))
                    } icon: {
                        Image(systemName: "hand.raised.fill")
                    }
                    .foregroundStyle(.blue).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PromptBubble: View {
    let prompt: Prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !prompt.text.isEmpty { Text(prompt.text).textSelection(.enabled) }
            if !prompt.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(prompt.attachments, id: \.self) { AttachmentChip(url: URL(fileURLWithPath: $0)) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}

/// Consecutive tool steps as one line that expands. Failures stay visible while it's closed.
private struct StepsView: View {
    let steps: [TranscriptStep]
    let reader: TranscriptReader?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup {
                ForEach(steps) { StepRow(step: $0, reader: reader) }
            } label: {
                Text(TranscriptStep.summary(steps)).foregroundStyle(.secondary)
            }
            ForEach(steps.filter { $0.failure != nil }) { step in
                Label {
                    Text("\(step.title): \(step.failure ?? "")").lineLimit(2).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.red)
            }
        }
    }
}

/// One step; opening it shows its output, the start of it until Show all is clicked.
private struct StepRow: View {
    /// More than this at once, in one piece of selectable text, stalls the window.
    private static let limit = 300_000

    let step: TranscriptStep
    let reader: TranscriptReader?
    @State private var full: String?
    @State private var isLoading = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let detail = step.detail, !detail.isEmpty, detail != step.title {
                    Text(detail).font(.callout.monospaced()).textSelection(.enabled)
                }
                if let output = full ?? (step.preview.isEmpty ? nil : step.preview) {
                    Text(String(output.prefix(Self.limit))).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if full == nil && step.isTruncated {
                        Button(isLoading ? "Loading…" : "Show all") {
                            isLoading = true
                            Task { full = await reader?.fullOutput(of: step) ?? step.preview }
                        }
                        .disabled(isLoading)
                    } else if output.count > Self.limit {
                        Text("The rest is in Agent Output.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label {
                Text(step.title).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: step.symbol)
            }
            .foregroundStyle(step.failure == nil ? .secondary : Color.red)
        }
    }
}

private extension TranscriptStep {
    var symbol: String {
        switch kind {
        case .command: "terminal"
        case .read: "doc.text"
        case .edit: "pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .agent: "person.2"
        case .other: "wrench.and.screwdriver"
        }
    }
}

/// An agent's message as formatted text: paragraphs, lists, inline styles and code blocks. Tables stay plain text.
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
        case .code(let text), .table(let text):
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
