import Foundation

extension AppModel {
    /// Sample data covering every state a task or project can be in, for previews and UI work.
    /// Run the app with SHIFT_PREVIEW=1 to browse it.
    public static func preview() -> AppModel {
        let zen = Project(name: "UI Zen Garden", repoPath: "/Users/me/Sites/uizg", baseBranch: "main",
                          serverCommand: "pnpm dev --port $PORT")
        let fin = Project(name: "Fin.com", repoPath: "/Users/me/Sites/fin", baseBranch: "main",
                          defaultAgent: .codex, permissions: .manual)
        let tribe = Project(name: "Tribe.AI", repoPath: "/Users/me/Sites/tribe", baseBranch: "develop")

        func task(_ id: Int, _ title: String, _ status: TaskStatus, in project: Project = zen, prompts: [String],
                  description: String? = nil, summary: String? = nil, question: String? = nil,
                  blocked: String? = nil, activity: String? = nil, minutes: Double = 4) -> TaskItem {
            var task = TaskItem(id: id, projectID: project.id, title: title, status: status, agent: project.defaultAgent,
                                branch: "shift/\(id)", worktreePath: "/Users/me/.shift/worktrees/preview/\(id)",
                                sessionID: "preview", port: status == .merged ? nil : id,
                                prompts: prompts.map { Prompt(text: $0) }, summary: summary, question: question,
                                blockedReason: blocked, activity: activity,
                                workingSince: status == .working ? Date().addingTimeInterval(-60 * minutes) : nil,
                                mergedAt: status == .merged ? Date().addingTimeInterval(-3600) : nil)
            task.description = description
            return task
        }

        var tasks = [
            // Review: ready to test, and done but no longer merging cleanly.
            task(3001, "Tighter board item gap", .completed,
                 prompts: ["Board items are too far apart. Set the gap between items to 4px.", "Actually make it 8px"],
                 description: "Tightens the space between board items and makes the gap a single variable.",
                 summary: "Changed the spacing between board items from 16px to 8px and introduced --board-gap so spacing can be adjusted consistently."),
            task(3002, "Focused board column stays expanded", .conflict,
                 prompts: ["Keep the focused board column expanded when another column is hovered."],
                 description: "Keeps the focused column wide while you hover its neighbours.",
                 summary: "Focused column now keeps its expanded width while siblings are hovered."),

            // Working, including a follow-up the agent hasn't received yet, and a conflict being resolved.
            task(3003, "ListItem primary color", .working,
                 prompts: ["ListItem only has a danger boolean. Add color?: \"primary\" | \"danger\", keeping danger as an alias for color=\"danger\".",
                           "Don't touch the ListItem stories, I'll update them myself."],
                 description: "Lets ListItem take a primary colour alongside danger, without breaking existing uses.",
                 activity: "Updating ListItem styles…"),
            task(3007, "Card hover shadow", .working,
                 prompts: ["Cards need a subtle shadow on hover."],
                 description: "Adds a soft shadow to cards on hover, matching the design tokens.",
                 activity: "Merging main into the task branch…", minutes: 1),

            // Needs you: a decision, and (Manual permissions) an approval.
            task(3004, "Empty state behavior", .needsInput,
                 prompts: ["Add an empty state to the search results list."],
                 description: "Shows a friendly empty state in search results.",
                 question: "Should the empty state appear when there are no results at all, or also when filters produce zero matches?"),
            task(3006, "Relative comment dates", .needsInput,
                 prompts: ["Show relative dates on comments."],
                 description: "Shows comment dates as \"2 hours ago\" instead of timestamps."),

            // Blocked: environment problem, failed setup, interrupted by quitting, stopped by you.
            task(3005, "Fix OAuth callback", .blocked,
                 prompts: ["The OAuth callback 500s after login. Fix it."],
                 description: "Fixes the server error users hit right after signing in.",
                 blocked: "The development environment can't start because STRIPE_SECRET_KEY is unavailable in this worktree."),
            task(3008, "Upgrade to React 19", .blocked,
                 prompts: ["Upgrade the app to React 19."],
                 description: "Moves the app to React 19 and updates the libraries that depend on it.",
                 blocked: "Setup failed (exit code 1).\nERR_PNPM_OUTDATED_LOCKFILE  Cannot install with \"frozen-lockfile\" because pnpm-lock.yaml is not up to date with package.json"),
            task(3009, "Search keyboard shortcuts", .blocked,
                 prompts: ["Add ⌘K to open search and Esc to close it."],
                 description: "Opens search with ⌘K and closes it with Esc from anywhere in the app.",
                 blocked: TaskItem.interruptedReason),
            task(3010, "Table column resizing", .blocked,
                 prompts: ["Let users resize table columns by dragging the header edge."],
                 description: "Lets table columns be resized by dragging their header edge.",
                 blocked: TaskItem.stoppedReason),

            // History.
            task(2998, "SideNav rail polish", .merged,
                 prompts: ["SideNav: long labels overflow instead of truncating. Make every label truncate with an ellipsis."],
                 description: "Truncates long SideNav labels instead of letting them overflow.",
                 summary: "SideNav labels now truncate with an ellipsis."),

            // Second project (Codex, Manual permissions).
            task(4001, "Invoice PDF export", .working, in: fin,
                 prompts: ["Add a Download PDF button to invoices."],
                 description: "Adds a PDF download to each invoice.", activity: "Running tests…", minutes: 12),
            task(4002, "Currency formatting", .completed, in: fin,
                 prompts: ["Amounts should use the user's locale for currency formatting."],
                 description: "Formats amounts in the user's locale.",
                 summary: "Amounts now use Intl.NumberFormat with the user's locale; tests cover EUR, USD and JPY."),
            task(4003, "Stripe webhooks", .needsInput, in: fin,
                 prompts: ["Handle Stripe's invoice.paid webhook."],
                 description: "Marks invoices as paid when Stripe confirms payment."),
        ]
        tasks[4].options = ["Only when there are no results", "Also when filters match nothing"]
        tasks[6].options = ["Copy .env from the main repo in the setup command", "Use a test key from .env.example"]
        tasks[7].options = ["Run pnpm install without --frozen-lockfile in setup", "Update pnpm-lock.yaml as part of this task"]
        tasks[2].prompts[1].isPending = true
        tasks[3].isResolvingConflict = true
        tasks[5].approvalRequest = "Run `pnpm add date-fns`"
        tasks[13].approvalRequest = "Fetch https://docs.stripe.com/api/events/types"
        let model = AppModel(previewProjects: [zen, fin, tribe], tasks: tasks)
        model.pushStates = [zen.id: .init(remote: "origin", unpushed: 3), fin.id: .init(remote: "origin", unpushed: 0)]
        return model
    }

    /// Upbeat sample data for promotional screenshots: busy, healthy projects.
    /// Run the app with SHIFT_PREVIEW=promo to browse it.
    public static func promo() -> AppModel {
        let store = Project(name: "Storefront", repoPath: "/Users/sam/Sites/storefront", baseBranch: "main",
                            serverCommand: "pnpm dev --port $PORT")
        let api = Project(name: "Checkout API", repoPath: "/Users/sam/Sites/checkout-api", baseBranch: "main",
                          defaultAgent: .codex)
        let docs = Project(name: "Docs", repoPath: "/Users/sam/Sites/docs", baseBranch: "main")

        func task(_ id: Int, _ title: String, _ status: TaskStatus, in project: Project = store, prompt: String,
                  description: String, summary: String? = nil, question: String? = nil,
                  activity: String? = nil, minutes: Double = 4) -> TaskItem {
            var task = TaskItem(id: id, projectID: project.id, title: title, status: status, agent: project.defaultAgent,
                                branch: "shift/\(id)", worktreePath: "/Users/sam/.shift/worktrees/storefront/\(id)",
                                sessionID: "preview", port: status == .merged ? nil : 3000 + id % 100,
                                prompts: [Prompt(text: prompt)], summary: summary, question: question, activity: activity,
                                workingSince: status == .working ? Date().addingTimeInterval(-60 * minutes) : nil,
                                mergedAt: status == .merged ? Date().addingTimeInterval(-3600 * minutes) : nil)
            task.description = description
            return task
        }

        var tasks = [
            task(101, "Tighter board spacing", .completed,
                 prompt: "Board items feel too far apart. Tighten the gap and make it a single variable.",
                 description: "Tightens the space between board items and makes the gap one variable.",
                 summary: "Changed the gap between board items from 16px to 8px and introduced --board-gap, so spacing is adjusted in one place."),
            task(102, "Dark mode for product pages", .completed,
                 prompt: "Product pages ignore dark mode. Make them follow the system appearance.",
                 description: "Product pages now follow the system's light or dark appearance.",
                 summary: "Product pages use the theme tokens and follow the system appearance; images get a subtle border in dark mode."),
            task(103, "Wishlist button", .working,
                 prompt: "Add a heart button to product cards that saves the item to the wishlist.",
                 description: "Lets shoppers save any product to their wishlist from the grid.",
                 activity: "Writing tests for WishlistButton…", minutes: 6),
            task(104, "Faster hero images", .working,
                 prompt: "The home page hero loads slowly. Serve responsive AVIF images with a blurred placeholder.",
                 description: "Serves smaller, responsive hero images with a blurred placeholder.",
                 activity: "Converting hero images to AVIF…", minutes: 3),
            task(105, "Saved addresses at checkout", .working,
                 prompt: "Returning customers should be able to pick a saved address at checkout.",
                 description: "Lets returning customers pick a saved address at checkout.",
                 activity: "Running the test suite…", minutes: 11),
            task(106, "⌘K product search", .working,
                 prompt: "Add a ⌘K command palette that searches products and categories.",
                 description: "Opens a quick product search from anywhere with ⌘K.",
                 activity: "Adding keyboard navigation to results…", minutes: 2),
            task(107, "Empty cart illustration", .needsInput,
                 prompt: "The empty cart page is just text. Make it friendlier.",
                 description: "Replaces the plain empty cart message with an illustration and suggestions.",
                 question: "Should the empty cart suggest recently viewed products, or this week's bestsellers?"),
            task(98, "Sticky header on scroll", .merged,
                 prompt: "Keep the header visible when scrolling down long pages.",
                 description: "Keeps the header pinned while scrolling.", minutes: 2),
            task(97, "Fix cart total rounding", .merged,
                 prompt: "Cart totals are sometimes a cent off. Fix the rounding.",
                 description: "Totals are computed in cents, so they're never a cent off.", minutes: 5),

            task(201, "Retry failed webhooks", .working, in: api,
                 prompt: "Retry failed outgoing webhooks with exponential backoff.",
                 description: "Retries failed webhooks with backoff instead of dropping them.",
                 activity: "Updating the delivery worker…", minutes: 8),
            task(202, "Rate limit by API key", .completed, in: api,
                 prompt: "Rate limit requests per API key, 100 per minute.",
                 description: "Limits each API key to 100 requests a minute.",
                 summary: "Added a per-key token bucket in Redis; responses include RateLimit headers and 429s when exceeded."),

            task(301, "Search across all guides", .working, in: docs,
                 prompt: "Add full-text search across every guide.",
                 description: "Adds full-text search across every guide.",
                 activity: "Building the search index…", minutes: 5),
        ]
        tasks[6].options = ["Recently viewed products", "This week's bestsellers"]
        let model = AppModel(previewProjects: [store, api, docs], tasks: tasks)
        model.pushStates = [store.id: .init(remote: "origin", unpushed: 2), api.id: .init(remote: "origin", unpushed: 0)]
        return model
    }

    /// Preview servers: blocked tasks show a stopped server, to show that state.
    static func previewServerRunning(_ task: TaskItem?) -> Bool {
        guard let task, task.port != nil else { return false }
        return task.status != .blocked
    }

    static let previewServerLog = """
        > uizg@0.1.0 dev
        > vite --port 3005

        Error: Missing environment variable STRIPE_SECRET_KEY
            at loadConfig (src/server/config.ts:14:11)
        Process exited with code 1
        """

    /// A small diff for finished preview tasks: modified files, an added file and a binary one.
    static func previewDiff(_ task: TaskItem?) -> [FileDiff] {
        guard let task, [.completed, .conflict, .merged].contains(task.status) else { return [] }
        let css = FileDiff(change: FileChange(path: "src/styles/board.css", kind: .modified, additions: 4, deletions: 1), hunks: [
            DiffHunk(header: "@@ -1,3 +1,6 @@", lines: [
                DiffLine(kind: .added, text: ":root {", newNumber: 1),
                DiffLine(kind: .added, text: "  --board-gap: 8px;", newNumber: 2),
                DiffLine(kind: .added, text: "}", newNumber: 3),
                DiffLine(kind: .context, text: ".board {", oldNumber: 1, newNumber: 4),
                DiffLine(kind: .removed, text: "  gap: 16px;", oldNumber: 2),
                DiffLine(kind: .added, text: "  gap: var(--board-gap);", newNumber: 5),
                DiffLine(kind: .context, text: "}", oldNumber: 3, newNumber: 6),
            ]),
        ])
        let tsx = FileDiff(change: FileChange(path: "src/components/BoardItem.tsx", kind: .modified, additions: 2, deletions: 2), hunks: [
            DiffHunk(header: "@@ -8,4 +8,4 @@ export function BoardItem({ item }: Props) {", lines: [
                DiffLine(kind: .context, text: "  return (", oldNumber: 8, newNumber: 8),
                DiffLine(kind: .removed, text: "    <div className=\"board-item\" style={{ margin: 8 }}>", oldNumber: 9),
                DiffLine(kind: .removed, text: "      {item.title}", oldNumber: 10),
                DiffLine(kind: .added, text: "    <div className=\"board-item\">", newNumber: 9),
                DiffLine(kind: .added, text: "      <span className=\"board-item__title\">{item.title}</span>", newNumber: 10),
                DiffLine(kind: .context, text: "    </div>", oldNumber: 11, newNumber: 11),
            ]),
        ])
        let doc = FileDiff(change: FileChange(path: "docs/spacing.md", kind: .added, additions: 3), hunks: [
            DiffHunk(header: "@@ -0,0 +1,3 @@", lines: [
                DiffLine(kind: .added, text: "# Spacing", newNumber: 1),
                DiffLine(kind: .added, text: "", newNumber: 2),
                DiffLine(kind: .added, text: "Board spacing is controlled by `--board-gap`.", newNumber: 3),
            ]),
        ])
        let image = FileDiff(change: FileChange(path: "public/board-preview.png", kind: .added, isBinary: true), hunks: [])
        return [css, tsx, doc, image]
    }
}
