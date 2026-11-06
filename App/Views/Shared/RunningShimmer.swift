import SwiftUI

extension View {
    /// Secondary text; while `active`, a darker gray with a light band sweeping across, for "1 of 2 tasks running".
    func runningShimmer(_ active: Bool) -> some View { modifier(RunningShimmer(active: active)) }
}

private struct RunningShimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active {
            content
                .foregroundStyle(.primary.opacity(0.75))
                .overlay {
                    if !reduceMotion {
                        TimelineView(.animation) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                            content
                                .foregroundStyle(.tertiary)
                                .mask {
                                    GeometryReader { geo in
                                        let band = geo.size.width * 0.5
                                        LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                            .frame(width: band)
                                            .offset(x: -band + (geo.size.width + band) * phase)
                                    }
                                }
                        }
                    }
                }
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}
