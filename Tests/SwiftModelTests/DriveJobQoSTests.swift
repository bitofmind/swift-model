import Testing
import Foundation
@testable import SwiftModel

#if canImport(Dispatch)
import Dispatch

/// Pins the executor drive's QoS floor.
///
/// The drive runs every test's jobs on one process-wide GCD concurrent queue. A
/// concurrent queue with no QoS of its own runs each block at the QoS of the thread
/// that submitted it, and a drive job is submitted by whichever thread resumes the
/// task — so a resumption from a background-QoS thread used to produce a background-QoS
/// job that a saturated machine could leave unscheduled for minutes while it counted as
/// executor activity: `settle()` never reached its fixpoint and the trait's absolute
/// ceiling fired with no lock in sight. With the queue's QoS set to `.userInitiated`,
/// such a job is raised to that floor (measured: the resumed job read
/// `qos_class_self()` = background (9) before, the task's own priority after).
///
/// This test asserts the configuration rather than re-measuring the behaviour: a
/// behavioural check needs a background-QoS block to get scheduled inside the test's
/// budget, which is precisely what a saturated CI runner does not guarantee — the
/// first cut of this test timed out under the TSan job for that reason.
struct DriveJobQoSTests {
    @Test func drainQueueCarriesAUserInitiatedFloor() {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        #expect(_drainQueueQoS == .userInitiated,
                "the drive's drain queue must carry a .userInitiated QoS floor; got \(_drainQueueQoS)")
    }
}
#endif
