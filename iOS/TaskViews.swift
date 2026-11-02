import PhotosUI
import SafariServices
import ShiftProtocol
import SwiftUI

struct ProjectsView: View {
    @Environment(RemoteModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        Group {
            if !model.hasState {
                ProgressView()
            } else if model.state.projects.isEmpty {
                EmptyState("No Projects", systemImage: "folder", description: Text("Add a project in Shift on your Mac."))
            } else {
                List(model.state.projects) { project in
                    NavigationLink(value: project.id) {
                        let tasks = model.tasks(in: project.id)
                        LabeledContent {
                            let waiting = tasks.filter(\.status.needsAttention).count
                            if waiting > 0 { Text(String(waiting)).monospacedDigit().foregroundStyle(.blue) }
                        } label: {
                            Text(project.name)
                            Text("\(tasks.filter { $0.status == .working }.count) working").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Forget This Mac", role: .destructive) { confirmingForget = true }
            }
        }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { model.forget() }
        } message: {
            Text("To connect again you'll need a new code from Shift on your Mac.")
        }
    }
}

struct TaskListView: View {
    @Environment(RemoteModel.self) private var model
    let projectID: UUID

    var body: some View {
        let tasks = model.tasks(in: projectID).sorted { $0.id > $1.id }
        let active = tasks.filter { $0.status != .merged }, merged = tasks.filter { $0.status == .merged }
        List {
            ForEach(active) { TaskRow(task: $0) }
            if !merged.isEmpty {
                Section("Merged") {
                    ForEach(merged) { TaskRow(task: $0) }
                }
            }
        }
        .overlay {
            if tasks.isEmpty { EmptyState("No Tasks", systemImage: "tray", description: Text("Start a task in Shift on your Mac.")) }
        }
        .navigationTitle(model.state.projects.first { $0.id == projectID }?.name ?? "Tasks")
    }
}

private struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        NavigationLink(value: task.id) {
            HStack(spacing: 12) {
                StatusIcon(status: task.status, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).lineLimit(2)
                    Text(task.status == .working ? task.activity ?? task.status.label : task.status.label)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct TaskDetailView: View {
    @Environment(RemoteModel.self) private var model
    let taskID: Int
    @State private var stream: LogStream?
    @State private var showsPreview = false

    var body: some View {
        if let task = model.task(taskID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Conversation(task: task, turns: stream?.turns ?? [])
                    TaskStatusView(task: task)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if task.status != .merged { PromptBar(taskID: taskID) }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.previewURL(task) != nil {
                    Button("Preview", systemImage: "safari") { showsPreview = true }
                }
                if task.status == .working || task.approvalRequest != nil {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop(taskID: taskID) } }
                }
            }
            .sheet(isPresented: $showsPreview) {
                if let url = model.previewURL(task) { SafariView(url: url).ignoresSafeArea() }
            }
            .task(id: taskID) {
                stream = model.openLog(.task(taskID), agent: task.agent)
            }
            .onDisappear { model.closeLog(.task(taskID)) }
        } else {
            EmptyState("Task Not Found", systemImage: "questionmark.folder", description: Text("It was deleted on your Mac."))
        }
    }
}

/// What the task is waiting for, and the way to answer it.
private struct TaskStatusView: View {
    @Environment(RemoteModel.self) private var model
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = task.approvalRequest {
                Label { Text(.init("Wants to \(request)")) } icon: { Image(systemName: "hand.raised.fill") }
                    .foregroundStyle(.blue)
                HStack {
                    Button("Allow") { Task { await model.answerApproval(taskID: task.id, allow: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { Task { await model.answerApproval(taskID: task.id, allow: false) } }
                        .buttonStyle(.bordered)
                }
            } else if task.status == .working {
                Label { Text(task.activity ?? "Working…") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            } else if task.status == .needsInput, let question = task.question {
                MarkdownText(text: question)
            } else if task.status == .blocked, let reason = task.blockedReason {
                Label(reason, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else if task.status == .conflict {
                Label("It doesn't merge cleanly into its base.", systemImage: "checkmark.circle.fill").foregroundStyle(.orange)
            } else if task.status == .completed || task.status == .merged, let summary = task.summary {
                Label { MarkdownText(text: summary) } icon: { StatusIcon(status: task.status) }
            }
            if task.canResume {
                Button("Resume") { Task { await model.resume(taskID: task.id) } }.buttonStyle(.borderedProminent)
            }
            if task.approvalRequest == nil, task.status == .needsInput || task.status == .blocked {
                ForEach(task.options ?? [], id: \.self) { option in
                    Button(option) { Task { await model.sendPrompt(taskID: task.id, text: option) } }.buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct PromptBar: View {
    @Environment(RemoteModel.self) private var model
    let taskID: Int
    @State private var text = ""
    @State private var pictures: [PhotosPickerItem] = []
    @State private var isSending = false

    private var canSend: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pictures.isEmpty) && !isSending && model.link == .online }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $pictures, matching: .images) {
                Image(systemName: pictures.isEmpty ? "photo" : "photo.badge.checkmark").accessibilityLabel("Attach pictures")
            }
            TextField("Message", text: $text, axis: .vertical).lineLimit(1...6)
            Button("Send", systemImage: isSending ? "ellipsis" : "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly).disabled(!canSend)
        }
        .padding(10)
        .background(.bar)
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                var paths: [String] = []
                for picture in pictures {
                    // JPEG whatever the library holds: agents can't read HEIC.
                    guard let data = try await picture.loadTransferable(type: Data.self),
                          let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.8) else { continue }
                    paths.append(try await model.upload(jpeg, name: "photo.jpg"))
                }
                await model.sendPrompt(taskID: taskID, text: text, attachments: paths)
                // ponytail: a command that fails after this clears the field; keep the draft if that loses work.
                text = ""
                pictures = []
            } catch {
                model.lastError = "Couldn't send the pictures to your Mac: \(error.localizedDescription)"
            }
        }
    }
}

/// The prompts in order, each with what the agent did about it.
private struct Conversation: View {
    let task: TaskItem
    let turns: [TranscriptTurn]

    var body: some View {
        let answered = Set(turns.flatMap(\.promptIDs))
        ForEach(turns) { turn in
            VStack(alignment: .leading, spacing: 12) {
                if let note = turn.note { Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                ForEach(task.prompts.filter { turn.promptIDs.contains($0.id) }) { PromptBubble(prompt: $0) }
                if let text = turn.text { Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
                ForEach(turn.sections) { SectionView(section: $0) }
            }
        }
        // Not reached the agent yet, or from a log that doesn't say.
        ForEach(task.prompts.filter { !answered.contains($0.id) }) { PromptBubble(prompt: $0).opacity($0.isPending ? 0.6 : 1) }
    }
}

private struct PromptBubble: View {
    let prompt: Prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !prompt.text.isEmpty { Text(prompt.text).textSelection(.enabled) }
            ForEach(prompt.attachments, id: \.self) { path in
                Label((path as NSString).lastPathComponent, systemImage: "paperclip").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 12))
    }
}

private struct SectionView: View {
    let section: TranscriptSection

    var body: some View {
        switch section {
        case .message(_, let text): MarkdownText(text: text)
        case .steps(_, let steps):
            DisclosureGroup {
                ForEach(steps) { StepRow(step: $0) }
            } label: {
                Text(TranscriptStep.summary(steps)).font(.footnote).foregroundStyle(.secondary)
            }
        case .error(_, let text): Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .approval(_, let summary):
            Label { Text(.init("Asked to \(summary)")) } icon: { Image(systemName: "hand.raised.fill") }.foregroundStyle(.blue)
        }
    }
}

private struct StepRow: View {
    let step: TranscriptStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.title).font(.footnote).foregroundStyle(step.failure == nil ? Color.secondary : .red)
            if !step.preview.isEmpty {
                Text(step.preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(12).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
