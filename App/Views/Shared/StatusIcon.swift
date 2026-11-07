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

/// A task's `/tag` tags as small capsules in their project's colors, on one line. Nothing when it has none.
/// ponytail: one line, tags past the row's width are clipped; a wrapping layout if tasks get many tags.
struct TaskTags: View {
    let tags: [String]?
    let project: Project?
    /// Given, right-clicking a tag offers to remove it from this task.
    var onRemove: ((String) -> Void)?
    /// Given, right-clicking a tag that `isShared` also offers to delete it from every task in the project.
    var onDelete: ((String) -> Void)?
    /// Whether another task in the project has the tag.
    var isShared: (String) -> Bool = { _ in false }
    /// Given, right-clicking a tag offers to change its color, for every task in the project.
    var onColor: ((String, TagColor) -> Void)?
    /// Bigger capsules, for a task's own page rather than a list row.
    var large = false
    @State private var deleting: String?

    var body: some View {
        HStack(spacing: large ? 6 : 4) {
            ForEach(tags ?? [], id: \.self) { tag in
                TagCapsule(name: tag, color: project?.color(ofTag: tag) ?? .gray, large: large)
                    .contextMenu {
                        if let onColor {
                            // Names only: menus show no colors, and drop the checkmark of an item with an icon.
                            Picker("Color", selection: Binding { project?.color(ofTag: tag) ?? .gray } set: { onColor(tag, $0) }) {
                                ForEach(TagColor.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                        if let onRemove { Button("Remove Tag") { onRemove(tag) } }
                        if onDelete != nil, isShared(tag) { Button("Delete Tag…", role: .destructive) { deleting = tag } }
                    }
            }
        }
        .confirmationDialog("Delete “\(deleting ?? "")”?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete Tag", role: .destructive) { if let deleting { onDelete?(deleting) } }
        } message: {
            Text("It is removed from every task in the project.")
        }
    }

}

/// One tag. Its text is the color mixed toward the label color, so light colors like yellow stay readable.
struct TagCapsule: View {
    let name: String
    let color: TagColor
    var large = false

    private var font: Font {
        #if os(macOS)
        large ? .callout : .caption2
        #else
        large ? .subheadline : .caption2
        #endif
    }

    var body: some View {
        Text(name).font(font).fontWeight(.medium).fixedSize()
            .foregroundStyle(color.color.mix(with: .primary, by: 0.45))
            .padding(.horizontal, large ? 8 : 5).padding(.vertical, large ? 3 : 1)
            .background(color.color.opacity(0.22), in: .capsule)
    }
}

extension TagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }
}
