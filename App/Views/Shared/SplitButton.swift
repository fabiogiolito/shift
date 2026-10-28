import AppKit
import SwiftUI

/// A button with a chevron beside it that drops down more actions. Both halves are plain Buttons, so they
/// take the surrounding button style and size like any other button (a SwiftUI Menu ignores both).
struct SplitButton<Label: View>: View {
    let items: [(title: String, action: () -> Void)]
    let action: () -> Void
    @ViewBuilder let label: Label
    var labelHeight: CGFloat = 20

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) { label.frame(minHeight: labelHeight) }
            Button { showMenu() } label: {
                Image(systemName: "chevron.down").imageScale(.small).frame(minHeight: labelHeight)
            }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        for item in items { menu.addItem(ClosureMenuItem(item.title, item.action)) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
