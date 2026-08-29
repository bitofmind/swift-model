#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
@testable import SwiftModel

/// Regression coverage for the drive-path `settle()` cancellation conflation.
///
/// `_driveToStableFixpoint` returns `false` for BOTH the hang watchdog and
/// Task cancellation. `waitUntilSettled`'s drive path used to report
/// `settle() timed out: model never reached a fixpoint` for either — so when
/// the `.modelTesting` trait cap (or an external kill) cancelled a test with a
/// settle in flight, the genuine `[TRAIT timeout]` was buried under a
/// misleading secondary settle issue pointing at whatever task happened to be
/// active. (Observed in the wild: the parallel-apple ShowcaseTests flake
/// handover, where trait-cap cancellations surfaced as 7 recurring
/// "never reached a fixpoint" failures.) The wall-clock path always suppressed
/// its `.cancelled` outcome; the drive path now does the same.
///
/// Direct `ModelTester` + manual `_TestExecutorBox` installation (no
/// `.modelTesting` trait): the trait would wrap this test in its own drive
/// scope and cap, which is exactly the machinery under test.
@Suite("drive settle() cancellation reporting")
struct CancelledSettleReportingTests {

    @Test func cancelledSettleDoesNotReportFixpointFailure() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let tester = ModelTester(CancelledSettleModel(), exhaustivity: .off)
        let access = tester.access
        await _TestExecutorBox.$current.withValue(_makeTestExecutorBox()) {
            // Cancel from INSIDE the task, before the settle starts: the drive
            // then observes cancellation deterministically (no race against a
            // quiescent model settling before an external cancel lands) —
            // the same state a trait-cap `group.cancelAll()` puts an in-flight
            // settle into.
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await access.waitUntilSettled(
                    at: FileAndLine(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
                )
            }
            let reached = await task.value
            #expect(reached == false, "a cancelled settle must not claim the model settled")
            // The absence of a recorded issue IS the regression assertion:
            // pre-fix, the cancelled wait recorded "settle() timed out: model
            // never reached a fixpoint", which fails this test on its own.
        }
    }

    /// External cancellation of a `_withTestTimeout`-wrapped body (xcodebuild's
    /// per-test allowance, a parent teardown) must NEVER surface as a
    /// `[TRAIT timeout]`: the parked watchdog children also unpark on
    /// cancellation and used to race the body's slower unwind through
    /// `group.next()`, stamping a spurious timeout report (observed in the
    /// wild as an "ran 1500 s" ceiling message inside a 280 s test run). The
    /// probe returns `now` so no genuine window can elapse — only
    /// cancellation can unpark the watchdogs here.
    @Test func externallyCancelledTraitCapDoesNotReportTimeout() async {
        let task = Task {
            try await _withTestTimeout(
                seconds: 60,
                testTag: "cancel-race",
                activityProbe: { DispatchTime.now().uptimeNanoseconds }
            ) { () -> Int in
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                return 7
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        switch await task.result {
        case .success(let value):
            #expect(value == 7)
        case .failure(let error):
            #expect(!(error is _TestTimeoutError),
                    "external cancellation must not be reported as a trait timeout")
        }
        // The absence of a recorded `[TRAIT timeout]` issue is the other half
        // of the assertion — pre-fix, the racing watchdog's reportIssue fails
        // this test on its own.
    }

    /// CONTROL: the cancellation check must not suppress normal resolution — an
    /// uncancelled settle on a quiescent model still reaches its fixpoint.
    @Test func uncancelledSettleOnQuiescentModelSettles() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let tester = ModelTester(CancelledSettleModel(), exhaustivity: .off)
        let access = tester.access
        await _TestExecutorBox.$current.withValue(_makeTestExecutorBox()) {
            let reached = await access.waitUntilSettled(
                at: FileAndLine(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
            )
            #expect(reached == true)
        }
    }

    /// Pin the timeout orderings that keep the drive's bounds coherent at
    /// every `SWIFT_MODEL_TIMEOUT_SCALE`:
    ///   • `waitUntil`'s absolute backstop sits above the trait cap's
    ///     inactivity window (a busy test hasn't tripped that) and below the
    ///     trait's absolute ceiling (so a never-true `waitUntil` fails via the
    ///     catchable `WaitUntilTimeoutError` before the uncatchable trait
    ///     ceiling).
    ///   • The drive's last-resort termination ceiling sits ABOVE the trait's
    ///     absolute ceiling, so wherever the trait is present its more
    ///     specific diagnostics always fire first and the drive wait is
    ///     cancelled (reported silently) rather than racing it.
    @Test func driveBoundsKeepTheirOrderingAtEveryScale() {
        // `SWIFT_MODEL_TEST_TIMEOUT` overrides the trait window absolutely,
        // decoupling it from the scale these invariants are about.
        guard ProcessInfo.processInfo.environment["SWIFT_MODEL_TEST_TIMEOUT"] == nil else { return }
        let backstopSeconds = Double(_executorHangWindowNs()) / 1_000_000_000
        let traitWindowSeconds = ModelTestingTraitOptions.testWallClockSeconds
        let traitCeilingSeconds = traitWindowSeconds * Double(ModelTestingTraitOptions.absoluteCeilingMultiple)
        let driveCeilingSeconds = Double(_driveCeilingDeadlineNs() &- DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        #expect(backstopSeconds > traitWindowSeconds)
        #expect(backstopSeconds < traitCeilingSeconds)
        #expect(driveCeilingSeconds > traitCeilingSeconds)
    }
}

/// Regression coverage for the drive's **evidence-based runaway verdict**.
///
/// The drive never judges a wait on wall-clock: a healthy settle waits as long
/// as load requires, and the failure discriminator for "never reaches a
/// fixpoint" is WORK — one reactive call-site accumulating an unbounded number
/// of deliveries within a single wait (`_settleRunawayFireBound`). This suite
/// ignites a genuine feedback loop (an `onChange` that writes its own source)
/// and asserts settle fails on the fire evidence, promptly and with the
/// runaway wording — replacing the old fixed 120 s watchdog, which was both
/// too slow interactively and falsely trippable by a merely-starved healthy
/// wait under multi-process load.
@Suite("drive settle() runaway evidence")
struct DriveRunawaySettleTests {

    @Test func feedbackLoopFailsSettleOnFireEvidence() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        await TestAccessOverrides.$settleRunawayFireBound.withValue(200) {
            await withModelTesting(.off) {
                let model = RunawayFeedbackModel().withAnchor()
                await withKnownIssue {
                    model.count = 1   // ignite the feedback loop
                    // Bound the meta-test on REGRESSION only: if the runaway
                    // verdict never lands, cancel the settle (silent — the
                    // cancellation fix above) so `withKnownIssue` fails fast
                    // with "no known issue recorded" instead of parking on the
                    // drive's multi-minute termination ceiling. On the normal
                    // path the verdict arrives within ~a check interval and
                    // the guard never fires.
                    let settleTask = Task { await settle() }
                    let guardSeconds = 20 * ModelTestingTraitOptions.timeoutScale
                    let guardTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(guardSeconds * 1_000_000_000))
                        settleTask.cancel()
                    }
                    await settleTask.value
                    guardTask.cancel()
                } matching: { issue in
                    String(describing: issue).contains("runaway")
                }
                // Quench the loop before leaving the test so teardown (cleanup
                // settle, exhaustion diff) runs against a convergent model —
                // and prove settle recovers once the feedback is broken.
                model.stopped = true
                await settle()
            }
        }
    }
}

/// Feedback loop: every change to `count` re-fires the `onChange`, which
/// writes `count` again — the canonical non-converging reactive cascade
/// (Update 26's consumer-reported shape). `stopped` lets the test quench the
/// loop deterministically before teardown. Declared at file scope because
/// `@Model` cannot be applied to a nested type.
@Model private struct RunawayFeedbackModel {
    var count = 0
    var stopped = false
    func onActivate() {
        node.onChange(of: count, initial: false) { _, _ in
            if !stopped { count += 1 }
        }
    }
}

/// Unit coverage for the progress signals feeding the `.modelTesting` trait
/// cap's inactivity watchdog. The watchdog's probe is the union of executor
/// activity and the scope's `progressNs` (model activity + main/background
/// observation drains) — so a test legitimately parked on a slow main-thread
/// drain keeps resetting its window instead of being declared inactive (the
/// trait-timeout cascade observed under multi-process saturation).
@Suite("trait inactivity-probe progress signals")
struct TraitProgressSignalTests {

    @Test func mainQueueStampsProgressOnDrain() async {
        let q = MainCallQueue()
        #expect(q.lastProgressNs == 0)
        // Enqueue from off-main so the enqueue path (not the on-main inline
        // fast-path) is exercised — the case the drain stamp exists for.
        await Task.detached { q {} }.value
        await q.waitUntilIdle()
        #expect(q.lastProgressNs > 0)
    }

    @Test func backgroundQueueStampsProgressOnDrain() async {
        let q = BackgroundCallQueue()
        #expect(q.lastProgressNs == 0)
        q {}
        await q.waitUntilIdle()
        #expect(q.lastProgressNs > 0)
    }

    /// Model activity (`_noteActivity`: writes / events / probes / task
    /// starts) must surface through the scope's `progressNs`, which is what
    /// the trait's probe reads.
    @Test func modelActivityFeedsScopeProgress() async {
        let tester = ModelTester(CancelledSettleModel(), exhaustivity: .off)
        let scope = _ConcreteModelTestScope(tester: tester)
        tester.access._noteActivity()
        #expect(scope.progressNs > 0)
    }
}

/// Declared at file scope because `@Model` cannot be applied to a nested type.
@Model private struct CancelledSettleModel {
    var value: Int = 0
}
#endif
