import SwiftUI

extension View {
    /// Secondary text; while `active`, a darker gray with a lighter band sweeping across, for "1 of 2 tasks running".
    func runningShimmer(_ active: Bool) -> some View { modifier(RunningShimmer(active: active)) }
}

private struct RunningShimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if !active {
            content.foregroundStyle(.secondary)
        } else if reduceMotion {
            content.foregroundStyle(Color.primary.opacity(0.7))
        } else {
            TimelineView(.animation) { context in
                // 0…1 every 2 seconds; the band travels from off the left edge to off the right.
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                let x = -1 + 2 * phase
                content.foregroundStyle(LinearGradient(
                    colors: [Color.primary.opacity(0.7), Color.primary.opacity(0.25), Color.primary.opacity(0.7)],
                    startPoint: UnitPoint(x: x, y: 0.5), endPoint: UnitPoint(x: x + 1, y: 0.5)))
            }
        }
    }
}
