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

    /// The hang watchdog now scales with `SWIFT_MODEL_TIMEOUT_SCALE`; pin the
    /// ordering that makes that safe at every scale: above the trait cap's
    /// inactivity window (a busy-but-healthy test is judged by the watchdog,
    /// not the cap) and below the trait's absolute deadlock ceiling (a
    /// never-quiescent wait still fails via the watchdog's catchable report
    /// before the ceiling tears the test down).
    @Test func hangWatchdogStaysBetweenTraitWindowAndCeiling() {
        // `SWIFT_MODEL_TEST_TIMEOUT` overrides the trait window absolutely,
        // decoupling it from the scale this invariant is about.
        guard ProcessInfo.processInfo.environment["SWIFT_MODEL_TEST_TIMEOUT"] == nil else { return }
        let watchdogSeconds = Double(_executorHangWindowNs()) / 1_000_000_000
        let traitWindowSeconds = ModelTestingTraitOptions.testWallClockSeconds
        #expect(watchdogSeconds > traitWindowSeconds)
        #expect(watchdogSeconds < traitWindowSeconds * Double(_traitAbsoluteCeilingMultiple))
    }
}

/// Declared at file scope because `@Model` cannot be applied to a nested type.
@Model private struct CancelledSettleModel {
    var value: Int = 0
}
#endif
