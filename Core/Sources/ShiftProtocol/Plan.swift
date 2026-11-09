import Foundation

/// Where a project's plans are written (docs/specs/plans.md).
public enum PlanStorage: String, Codable, CaseIterable, Identifiable, Sendable {
    /// In Shift's own data, outside the repository: the same whatever branch is checked out.
    case shift
    /// In a folder of the repository, to be committed. An approved plan goes into its task's branch.
    case repository
    /// In a folder of the repository that Git ignores (a `.gitignore` of `*` inside it).
    case ignored

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .shift: "In Shift"
        case .repository: "In the project, committed"
        case .ignored: "In the project, ignored by Git"
        }
    }

    public init(from decoder: Decoder) throws {
        self = PlanStorage(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .shift
    }
}

/// A pre-task: a Markdown document the agent drafts from an idea and the user reviews and edits. No worktree, branch,
/// server or port. Approving it starts a task that implements it, and the plan leaves the list.
public struct Plan: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: Project.ID
    /// The document's first `# ` heading, as of the last time Shift read it.
    public var title: String
    /// The Markdown file, absolute. Kept where it was created if the project's storage setting changes later.
    public var path: String
    public var createdAt: Date
    /// The agent `sessionID` belongs to.
    public var agent: AgentKind?
    public var sessionID: String?
    /// The idea, then each change asked for, oldest first.
    public var prompts: [Prompt]
    /// Why the agent's last pass failed, until the next one.
    public var error: String?

    public init(id: UUID = UUID(), projectID: Project.ID, title: String, path: String, createdAt: Date = Date(),
                prompts: [Prompt] = []) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.path = path
        self.createdAt = createdAt
        self.prompts = prompts
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// The text of the first `# ` heading, if there is one.
    public static func title(of markdown: String) -> String? {
        for line in markdown.split(whereSeparator: \.isNewline) where line.hasPrefix("# ") {
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// The first paragraph after the title: the plan's summary, by the format its agent is given.
    public static func summary(of markdown: String) -> String? {
        let body = markdown.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n")
        let paragraphs = body.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") }
        return paragraphs.first
    }
}
