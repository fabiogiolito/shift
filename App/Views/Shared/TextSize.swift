import SwiftUI

// Text size of what agents write and change, set from the View menu on the Mac (⌘+, ⌘−, ⌘0).
// macOS ignores `dynamicTypeSize`, so the views that scale ask for their fonts through `Font.scaled`.

extension EnvironmentValues {
    /// 1 is the system size. Always 1 on the phone, which has Dynamic Type.
    @Entry var textScale: Double = 1
}

enum TextScale {
    static let key = "textScale"
    static let steps: [Double] = [0.8, 0.9, 1, 1.15, 1.3, 1.5, 1.75, 2]

    /// The next step up or down from `scale`, or `scale` itself at either end.
    static func step(_ scale: Double, by direction: Int) -> Double {
        let index = steps.firstIndex { $0 >= scale - 0.001 } ?? steps.count - 1
        return steps[min(max(index + direction, 0), steps.count - 1)]
    }
}

extension Font {
    /// The text style at `scale` times its system size.
    static func scaled(_ style: Font.TextStyle, _ scale: Double, design: Font.Design = .default) -> Font {
        #if os(macOS)
        let size = NSFont.preferredFont(forTextStyle: style.appKit).pointSize * scale
        return .system(size: size, weight: style == .headline ? .bold : .regular, design: design)
        #else
        return .system(style, design: design)
        #endif
    }
}

#if os(macOS)
private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif
