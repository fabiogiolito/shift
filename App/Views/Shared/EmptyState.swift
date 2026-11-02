import SwiftUI

/// `ContentUnavailableView` looking the same on the Mac and iOS, where its own colors and description size differ.
struct EmptyState<Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    var description: Text?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label {
                // iOS ignores the `.secondary` style here, but not the color.
                Text(title).foregroundStyle(Color.secondary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
        } description: {
            #if os(macOS)
            description?.font(.callout).foregroundStyle(.secondary)
            #else
            description?.font(.subheadline).foregroundStyle(.secondary)
            #endif
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
