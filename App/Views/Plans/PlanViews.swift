import SwiftUI
import AppKit
import MarkdownEngine
import ShiftCore

/// A plan in the task list's Plans group.
struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if model.isWriting(planID: plan.id) {
                    StatusIcon(status: .working, size: 14)
                } else {
                    Image(systemName: plan.error == nil ? "doc.text" : "exclamationmark.circle.fill")
                        .resizable().scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(plan.error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
                Text(plan.title).lineLimit(1)
                Spacer()
            }
            Text(model.planActivity[plan.id] ?? plan.error ?? "Ready to review")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
        .contextMenu { PlanActionItems(plan: plan) }
    }
}

/// Show in Finder and Delete: the plan's context menu and its page's More menu.
struct PlanActionItems: View {
    @Environment(AppModel.self) private var model
    let plan: Plan

    var body: some View {
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([plan.url]) }
        Divider()
        Button("Delete Plan", systemImage: "trash", role: .destructive) { model.deletePlan(plan.id) }
    }
}

/// The plan's document, styled as it's written and edited in place. Approve turns it into a task; Prompt asks the agent
/// for changes.
struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    let planID: Plan.ID
    @Binding var selection: TaskItem.ID?
    @State private var text = ""
    @State private var prompting = false
    @State private var approving = false

    var body: some View {
        if let plan = model.plan(planID) {
            let writing = model.isWriting(planID: planID)
            VStack(alignment: .leading, spacing: 0) {
                header(plan, writing: writing)
                    .padding([.horizontal, .top], TaskDetailView.margin)
                    .padding(.bottom, 8)
                NativeTextViewWrapper(text: $text,
                                      configuration: MarkdownEditorConfiguration(textInsets: TextInsets(horizontal: TaskDetailView.margin, vertical: 12)),
                                      fontName: NSFont.systemFont(ofSize: 0).fontName,
                                      fontSize: (NSFont.preferredFont(forTextStyle: .body).pointSize + 2) * textScale,
                                      documentId: plan.id.uuidString,
                                      isEditable: !writing)
            }
            .safeAreaBar(edge: .bottom) {
                if prompting {
                    PromptField(placeholder: "What should change in the plan?", focusOnAppear: true, draftKey: "plan \(planID)") {
                        model.revisePlan(planID, text: $0, attachments: $1)
                        prompting = false
                    }
                    .padding(12)
                }
            }
            .toolbar {
                ToolbarItem {
                    Text(plan.title).font(.title3).lineLimit(1)
                        .padding(.leading, TaskDetailView.margin - TaskDetailView.toolbarInset)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        PlanActionItems(plan: plan)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear { text = model.planText(planID) }
            .onChange(of: text) { model.savePlanText(planID, text) }
            // What the agent has written so far, while it writes, then all of it.
            .task(id: writing) {
                repeat {
                    text = model.planText(planID)
                    guard writing else { break }
                    try? await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            }
            // Edited in another app meanwhile.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                text = model.planText(planID)
            }
        } else {
            EmptyState("Plan Deleted", systemImage: "doc.text")
        }
    }

    private func header(_ plan: Plan, writing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Approve") {
                    approving = true
                    Task {
                        model.savePlanText(planID, text)
                        if let taskID = await model.approvePlan(planID) { selection = taskID }
                        approving = false
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(writing || approving)
                .help("Start a task that implements this plan")
                if writing {
                    Button("Stop") { model.stopPlan(planID) }.buttonStyle(.glass)
                } else {
                    Button("Prompt") { prompting.toggle() }
                        .buttonStyle(.glass)
                        .help("Ask the agent to change the plan")
                }
                Spacer()
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle)
            if writing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.planActivity[planID] ?? "Writing the plan…")
                }
                .foregroundStyle(.secondary)
            } else if let error = plan.error {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
    }
}
