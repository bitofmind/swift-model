import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

#if canImport(Darwin)
/// Regression for the drive's QoS floor. A drive job is submitted by whichever thread
/// resumes the task; before the queue carried its own QoS, a resumption from a
/// background-QoS thread produced a background-QoS job that a saturated machine could
/// leave unscheduled for minutes while it counted as executor activity — `settle()`
/// never reached its fixpoint and the trait's absolute ceiling fired with no lock in
/// sight. Every job must run at `.userInitiated` or better, whoever resumed it.
@Model private struct QoSProbeModel: Sendable {
    var resumedQoS: UInt32 = 0
    var done = false

    func onActivate() {
        node.task {
            // Park, then be resumed from a background-QoS GCD thread: the resumption
            // enqueues this task's next job on the drive from that thread.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .background).async { cont.resume() }
            }
            resumedQoS = qos_class_self().rawValue
            done = true
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct DriveJobQoSTests {
    @Test func jobResumedFromBackgroundThreadNeverRunsAtBackgroundQoS() async {
        let model = QoSProbeModel().withAnchor()
        await expect { model.done }
        let qos = model.resumedQoS
        // qos_class_t raw values: userInteractive 0x21, userInitiated 0x19, default 0x15,
        // utility 0x11, background 0x09 — higher is higher priority. The queue floor is
        // `.userInitiated`; once scheduled, the runtime runs the job at the task's own
        // priority (here the test task's, `.default`), which is the value observed. What
        // must never happen is the submitting thread's `.background` leaking in: before
        // the fix this read 9.
        #expect(qos >= QOS_CLASS_DEFAULT.rawValue,
                "drive job ran at QoS raw value \(qos); expected ≥ default (\(QOS_CLASS_DEFAULT.rawValue)) — background (\(QOS_CLASS_BACKGROUND.rawValue)) means the submitting thread's QoS leaked into the drive")
    }
}
#endif
