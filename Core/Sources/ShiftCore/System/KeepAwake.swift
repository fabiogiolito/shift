import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep by itself, so a phone can still reach it. The display may sleep;
/// closing the lid on battery still sleeps the Mac, which no assertion can stop.
@MainActor
final class KeepAwake {
    private var assertion: IOPMAssertionID?
    private let reason: String

    init(reason: String = "Shift is running a task") { self.reason = reason }

    var isHeld: Bool { assertion != nil }

    func set(_ held: Bool) {
        if held, assertion == nil {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString, &id)
            if result == kIOReturnSuccess { assertion = id }
        } else if !held, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }

    deinit {
        if let assertion { IOPMAssertionRelease(assertion) }
    }
}
