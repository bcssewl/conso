import Foundation
import Observation
import IOKit.pwr_mgt

/// Keeps the display awake by holding an IOKit power assertion — a real, non-root
/// system integration (no special permissions). Releasing the assertion (or the
/// process exiting) restores normal sleep behaviour.
@MainActor
@Observable
public final class KeepAwake {
    public private(set) var isActive = false
    @ObservationIgnored private var assertionID: IOPMAssertionID = 0

    public init() {}

    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "conso — Keep Awake" as CFString,
                &id)
            guard result == kIOReturnSuccess else { return }
            assertionID = id
            isActive = true
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isActive = false
        }
    }

    public func toggle() { setActive(!isActive) }
}
