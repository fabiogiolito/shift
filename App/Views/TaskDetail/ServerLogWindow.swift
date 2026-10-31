import SwiftUI
import ShiftCore

/// A task's server log in its own window, titled with the server's address. Follows the log while it is open.
struct ServerLogWindow: View {
    @Environment(AppModel.self) private var model
    let taskID: TaskItem.ID
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(text.map { $0.isEmpty ? "No output." : $0 } ?? "Loading…")
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        // The latest output, where errors are, is at the end.
        .defaultScrollAnchor(.bottom)
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 480, minHeight: 240)
        .navigationTitle(model.task(taskID)?.port.map { "localhost:\(String($0))" } ?? "Server Log")
        .toolbar {
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text ?? "", forType: .string)
            }
            .disabled(text?.isEmpty ?? true)
        }
        .task {
            while !Task.isCancelled {
                text = await model.serverLog(taskID: taskID)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
