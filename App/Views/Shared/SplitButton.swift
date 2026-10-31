import SwiftUI

/// One glass button with two targets: the label runs `action`, the chevron drops down `menu`. Drawn by
/// hand because a SwiftUI Menu with a primary action ignores button styles (it can't be prominent).
/// As tall as a large glass button.
struct SplitButton<Label: View, MenuContent: View>: View {
    var prominent = false
    /// The background when prominent.
    var tint: Color = .accentColor
    let action: () -> Void
    @ViewBuilder let label: Label
    @ViewBuilder let menu: MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                label.lineLimit(1).fixedSize()
                    .padding(.leading, 14).padding(.trailing, 10)
                    .frame(maxHeight: .infinity).contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider().padding(.vertical, 7)
            Menu {
                menu
            } label: {
                Image(systemName: "chevron.down").imageScale(.small)
                    .padding(.leading, 8).padding(.trailing, 11)
                    .frame(maxHeight: .infinity).contentShape(.rect)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(prominent ? .white : .primary)
        .frame(height: 28)
        .glassEffect(prominent ? .regular.tint(tint).interactive() : .regular.interactive(), in: .rect(cornerRadius: 8))
    }
}
