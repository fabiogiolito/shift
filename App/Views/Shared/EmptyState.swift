import SwiftUI

/// `ContentUnavailableView` with the colors and description size it has on iOS, which on the Mac it greys out and
/// sets larger.
struct EmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var description: Text?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
        } description: {
            description?.font(.callout).foregroundStyle(.secondary)
        } actions: {
            actions()
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}
