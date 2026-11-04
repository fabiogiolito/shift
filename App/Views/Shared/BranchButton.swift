import AppKit
import SwiftUI

/// A branch name in a topbar, with room before the button that follows it: click to copy the name.
struct BranchButton: View {
    let branch: String
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(branch)
            copied = true
        } label: {
            // Not a Label: its icon column can't be tightened.
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").imageScale(.small)
                Text(branch).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
