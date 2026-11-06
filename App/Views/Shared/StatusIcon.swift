import SwiftUI
import ShiftProtocol

struct StatusIcon: View {
    let status: TaskStatus
    /// Every status, spinner included, fills the same square so rows line up whatever their state.
    /// nil keeps the surrounding font's size (e.g. in the toolbar).
    var size: CGFloat?
    /// The task's pull request is open: a finished task shows the pull request instead of a checkmark.
    var pullRequestOpen = false
    /// Merged through its pull request: the pull request icon, in the merged grey.
    var mergedByPullRequest = false

    var body: some View {
        if let size {
            icon.font(.system(size: size))
                .frame(width: size, height: size)
        } else {
            icon
        }
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .working:
            // The small spinner is 16pt; scale it into the square so it isn't bigger than the symbols.
            ProgressView().controlSize(.small).scaleEffect((size ?? 16) / 16)
        case .needsInput: Image(systemName: "questionmark.circle.fill").foregroundStyle(status.color)
        case .blocked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(status.color)
        case .completed where pullRequestOpen: pullRequestIcon
        case .merged where mergedByPullRequest: pullRequestIcon
        case .completed, .conflict, .merged: Image(systemName: "checkmark.circle.fill").foregroundStyle(status.color)
        case .archived: Image(systemName: "archivebox.circle.fill").foregroundStyle(status.color)
        }
    }

    /// As tall as the circle symbols' circle, so wider than the square: the square keeps its size and the badge
    /// overflows it evenly on both sides, centered with the circles, without pushing the text beside it.
    private var pullRequestIcon: some View {
        let height = (size ?? 16) * 0.96
        return Image("PullRequest").resizable()
            .frame(width: height * 18 / 14, height: height)
            .foregroundStyle(status.color)
    }
}

/// The task's number: a quick reference, not content.
struct TaskNumber: View {
    let task: TaskItem

    var body: some View {
        Text(String(task.id)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
    }
}

extension TaskStatus {
    /// The status icon's colour, for anything else that stands for the status.
    var color: Color {
        switch self {
        case .needsInput: .blue
        case .blocked: .red
        case .completed: .green
        case .conflict: .orange
        case .working, .merged, .archived: .secondary
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .needsInput: "Needs Input"
        case .blocked: "Blocked"
        case .completed: "Ready to Test"
        case .conflict: "Conflict"
        case .merged: "Merged"
        case .archived: "Archived"
        }
    }
}
