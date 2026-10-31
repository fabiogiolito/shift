import SwiftUI
import ShiftCore

/// The row pinned to the top of the task list.
struct ChatRow: View {
    /// What selects the chat in the task list's selection: no task has this id.
    static let id: TaskItem.ID = -1

    let replying: Bool
    /// The agent waits for the user to allow something.
    var waiting = false

    var body: some View {
        // Same icon square and spacing as TaskRow's title line, so the icons and text line up down the list.
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .resizable().scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(.secondary)
            Text("Chat")
            Spacer()
            if waiting {
                Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
            } else if replying {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// The project's one conversation, oldest first and scrolled to the newest. Not a task.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var reader: TranscriptReader?
    @State private var turns: [TranscriptTurn] = []
    /// What the project's folder has checked out, which is what the agent works on.
    @State private var branch: String?
    @State private var confirmingNew = false

    private let bottom = "bottom"

    var body: some View {
        let chat = model.chat(projectID: project.id)
        let replying = model.replyingChats.contains(project.id)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(turns) { turn in
                        TurnView(turn: turn, prompts: chat?.prompts.filter { turn.promptIDs.contains($0.id) } ?? [], reader: reader).equatable()
                    }
                    // Sent, and not in the log yet or waiting for the agent to take them.
                    let shown = Set(turns.flatMap(\.promptIDs))
                    ForEach(chat?.prompts.filter { !shown.contains($0.id) } ?? []) { PromptBubble(prompt: $0) }
                    if replying {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Working…").foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.chatErrors[project.id] {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TaskDetailView.margin)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat?.prompts.count) { proxy.scrollTo(bottom, anchor: .bottom) }
            .overlay {
                if chat == nil {
                    ContentUnavailableView("Chat About \(project.name)", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("Ask questions, plan, or have the agent do something in the project's folder, like pull, push or release. It has the project's permissions."))
                }
            }
        }
        .safeAreaBar(edge: .top) { branchNote }
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .trailing, spacing: 8) {
                if let request = model.chatApprovalRequest(projectID: project.id) {
                    approval(request)
                }
                if replying {
                    Button("Stop", systemImage: "stop.fill") { model.stopChat(projectID: project.id) }.buttonStyle(.glass)
                }
                PromptField(placeholder: "Ask or tell the agent anything…", draftKey: "chat \(project.id)") {
                    model.sendChat(projectID: project.id, text: $0, attachments: $1)
                }
            }
            .padding(12)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .toolbar {
            ToolbarItem {
                Text("Chat").font(.title3).padding(.leading, TaskDetailView.margin - TaskDetailView.toolbarInset)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.flexible)
            if let branch {
                ToolbarItem {
                    Label(branch, systemImage: "arrow.triangle.branch").labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .help("The branch checked out in the project's folder, which the agent works on")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") { confirmingNew = true }
                    .disabled(chat == nil)
                    .help("Start a new conversation")
            }
        }
        .confirmationDialog("Start a new chat?", isPresented: $confirmingNew) {
            Button("New Chat", role: .destructive) {
                Task {
                    await model.newChat(projectID: project.id)
                    reader = nil
                    turns = []
                }
            }
        } message: {
            Text("This conversation is deleted, and the agent won't remember it.")
        }
        // The whole log the first time, then what's added, often: this is the reply arriving.
        .task(id: "\(String(describing: chat?.id))\(replying)") {
            if reader == nil { reader = model.chatTranscript(projectID: project.id) }
            repeat {
                if let new = await reader?.update() { turns = new }
                guard replying else { break }
                try? await Task.sleep(for: .milliseconds(300))
            } while !Task.isCancelled
        }
        .onAppearAndActivate(id: "\(project.id)\(replying)") { branch = await model.checkedOutBranch(projectID: project.id) }
    }

    /// What the agent wants to do, like a task's response panel.
    private func approval(_ request: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The agent wants to").font(.subheadline).foregroundStyle(.secondary)
                Text((try? AttributedString(markdown: request, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(request))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Deny") { model.answerChatApproval(projectID: project.id, allow: false) }.buttonStyle(.glass)
            Button("Allow") { model.answerChatApproval(projectID: project.id, allow: true) }.buttonStyle(.glassProminent)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    /// The agent works in the folder as it is: it matters when that isn't the project's base.
    @ViewBuilder private var branchNote: some View {
        if let branch, branch != project.baseBranch {
            Label("The project's folder is on \(branch), not \(project.baseBranch). The agent works on \(branch).", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, TaskDetailView.margin)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
