#if DEBUG
import Foundation

/// What a development build of Shift always has to test with: a Next.js project with two finished tasks, so the
/// servers on main and on each task, and their previews, can be tried on Mac and iOS without spending an agent run.
/// Added next to whatever else the build's data holds. Start over: remove the project and relaunch; merging all its
/// tasks does the same.
/// ponytail: every checkout installs its own node_modules (about 400 MB), in each build's own SHIFT_HOME.
public enum DemoProject {
    static let name = "Shift Demo"
    static let base = "main"
    static let page = "app/page.js"

    public static func seed() async {
        do {
            try await seed(root: ShiftPaths.root, git: GitService())
        } catch {
            NSLog("Shift: could not set up \(name): \(error)")
        }
    }

    static func seed(root: URL, git: GitServicing) async throws {
        let store = JSONStateStore(root: root)
        var state = await store.load()
        let repo = root.appendingPathComponent("demo/shift-demo")
        let existing = state.projects.first { $0.repoPath == repo.path }
        if let existing, state.tasks.contains(where: { $0.projectID == existing.id && $0.status != .merged }) { return }

        let worktrees = root.appendingPathComponent("worktrees")
        var project = Project(name: name, repoPath: repo.path, baseBranch: base, type: .dynamicWebsite,
                              serverCommand: "npm install && npm run dev")
        if let existing {
            project.id = existing.id
            state.projects.removeAll { $0.id == existing.id }
            state.tasks.removeAll { $0.projectID == existing.id }
            state.chats.removeAll { $0.projectID == existing.id }
        }
        let fm = FileManager.default
        try? fm.removeItem(at: repo)
        try? fm.removeItem(at: ShiftPaths.worktree(project: project, taskID: 0, root: worktrees).deletingLastPathComponent())

        for (path, contents) in files {
            let file = repo.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        // Not left to the machine's init.defaultBranch: `git init` keeps the branch this names.
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "ref: refs/heads/\(base)\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        try await git.initRepository(repo)

        var id = max(state.nextTaskID, (state.tasks.map(\.id).max() ?? 0) + 1)
        var tasks: [TaskItem] = []
        for change in changes {
            let worktree = ShiftPaths.worktree(project: project, taskID: id, root: worktrees)
            try await git.createWorktree(repo: repo, branch: "shift/\(id)", base: base, at: worktree)
            let file = worktree.appendingPathComponent(page)
            let source = try String(contentsOf: file, encoding: .utf8)
            try source.replacingOccurrences(of: change.from, with: change.to).write(to: file, atomically: true, encoding: .utf8)
            try await git.commitAll(worktree: worktree, message: change.title)
            tasks.append(TaskItem(id: id, projectID: project.id, title: change.title, status: .completed, agent: project.defaultAgent,
                                  branch: "shift/\(id)", baseBranch: base, worktreePath: worktree.path,
                                  prompts: [Prompt(text: change.title)], summary: change.summary))
            id += 1
        }
        state.projects.append(project)
        state.tasks += tasks
        state.nextTaskID = id
        await store.save(state)
    }

    private static let changes = [
        (title: "Change the background to blue", from: #"background: "white""#, to: #"background: "blue""#,
         summary: "The page background is now blue."),
        (title: "Change the text color to red", from: #"color: "black""#, to: #"color: "red""#,
         summary: "The text is now red."),
    ]

    // JavaScript, because Next rewrites a TypeScript project's files when it starts, and that would show up as changes.
    // The styles are inline so they show even if the dev server refuses a phone its assets, with lines in between so
    // that both tasks can merge.
    private static let files = [
        "package.json": """
            {
              "name": "shift-demo",
              "private": true,
              "scripts": { "dev": "next dev" },
              "dependencies": { "next": "16.4.4", "react": "19.3.1", "react-dom": "19.3.1" }
            }

            """,
        // No lockfile: tasks would each commit their own.
        ".npmrc": "package-lock=false\naudit=false\nfund=false\n",
        ".gitignore": "node_modules/\n.next/\n",
        // A phone reaches a task's server through the tailnet, an origin Next doesn't allow by default.
        // Without agentRules: false Next writes an AGENTS.md, which each task would commit as its own change.
        "next.config.mjs": #"export default { allowedDevOrigins: ["*.ts.net"], agentRules: false };"# + "\n",
        "app/layout.js": """
            export const metadata = { title: "Shift Demo" };

            export default function RootLayout({ children }) {
              return (
                <html lang="en">
                  <body style={{ margin: 0 }}>{children}</body>
                </html>
              );
            }

            """,
        page: """
            export default function Home() {
              return (
                <main
                  style={{
                    background: "white",
                    minHeight: "100vh",
                    display: "grid",
                    placeItems: "center",
                    color: "black",
                    fontFamily: "system-ui, sans-serif",
                    fontSize: 48,
                  }}
                >
                  Hello World
                </main>
              );
            }

            """,
    ]
}
#endif
