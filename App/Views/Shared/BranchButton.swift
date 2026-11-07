import AppKit
import SwiftUI

/// A branch name in a topbar, with room before the button that follows it: click to copy the name.
/// With a base, shown the way GitHub shows a pull request's branches: "main ← shift/3018", the base dimmed.
struct BranchButton: View {
    let branch: String
    var base: String? = nil
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(branch)
            copied = true
        } label: {
            // Not a Label: its icon column can't be tightened.
            HStack(spacing: 3) {
                // Through NSImage: in a toolbar, Image("Branch") draws nothing for a custom symbol.
                Image(nsImage: NSImage(named: "Branch")!).imageScale(.small)
                if let base {
                    Text(base).lineLimit(1)
                    Image(systemName: "arrow.left").imageScale(.small).foregroundStyle(.tertiary)
                }
                Text(branch).lineLimit(1).truncationMode(.middle)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.accessoryBar)
        .help(help)
        .popover(isPresented: $copied, arrowEdge: .bottom) {
            Text("Copied").padding(.horizontal, 10).padding(.vertical, 6)
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { copied = false }
        }
        .padding(.trailing, 8)
    }
}

func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
