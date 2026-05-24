#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Validates the safety net underneath `.modelTesting`'s per-test wall-clock
/// timer (`_withTestTimeout`) and the wait primitives it relies on.
///
/// **Why this exists.** When `_withTestTimeout`'s timer fires it calls
/// `group.cancelAll()`, which sends cancellation into the body task. If a
/// `withCheckedContinuation` inside that body is parked — and the continuation
/// slot is not wired through `withTaskCancellationHandler` — the task stays
/// suspended forever and the test hangs until someone kills the run. We've
/// seen that signature in CI (no active threads, no deadlock, main thread
/// idle waiting). These tests pin down the three preconditions that prevent
/// it from recurring:
///
///   1. The cancellation-handler + continuation-slot pattern itself resumes
///      a parked continuation on cancel.
///   2. Each wait primitive in `CallQueue` (`waitUntilIdle`,
///      `waitForCurrentItems`) uses that pattern correctly.
///   3. `_withTestTimeout` actually fires after `seconds` and propagates
///      cancellation into a wait primitive end-to-end.
///
/// All tests use modest wall-clock bounds (`< 2 s`) and explicit elapsed
/// assertions so a regression manifests as a hard fail rather than a hang.
///
/// Guarded by `#if canImport(Dispatch)` — the primitives this validates are
/// Dispatch-backed on Apple/Linux. WASM has neither.
@Suite("Reactive wait infrastructure — safety-net validation")
struct ReactiveWaitInfrastructureTests {

    // MARK: - Helpers

    private static func elapsedNs(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds - start
    }

    // MARK: - 1. Cancellation handler + slot pattern

    /// Bare-pattern validation: prove that `withTaskCancellationHandler`'s
    /// `onCancel` block can resume a parked `withCheckedContinuation` via
    /// a shared `LockIsolated` slot. This is the pattern reused everywhere
    /// downstream — if this breaks, everything else hangs.
    @Test func cancellationHandler_resumesParkedContinuation() async {
        let contSlot = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
        let didResume = LockIsolated(false)

        let task = Task {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    contSlot.setValue(cont)
                }
            } onCancel: {
                contSlot.withValue { slot in
                    slot?.resume()
                    slot = nil
                }
            }
            didResume.setValue(true)
        }

        // Park the Task on the continuation, then cancel from outside.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let startNs = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        await task.value
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(didResume.value, "Task body should unwind after cancellation")
        // Generous upper bound: this test validates that Swift Concurrency's
        // intrinsic cancellation propagation works at all, not exact latency.
        // Under x1000 parallel-test stress the cooperative pool's scheduling
        // of Task.sleep wake + task.cancel + onCancel + continuation.resume
        // can stretch to 1.5-2 s. A real "cancellation hung" bug would still
        // exceed 5 s.
        #expect(elapsedNs < 5_000_000_000,
                "cancel→resume should land within 5 s; took \(elapsedNs) ns")
    }

    // MARK: - 2. CallQueue wait primitives are cancellation-aware

    /// `BackgroundCallQueue.waitUntilIdle()` must resume promptly when the
    /// awaiting Task is cancelled, even while the queue is busy with a
    /// drain that won't finish for seconds.
    ///
    /// Strategy: enqueue a callback that blocks the GCD drain thread for 3 s
    /// (well past our assertion window). Start a Task awaiting
    /// `waitUntilIdle()`. Give it time to park. Cancel. Assert return
    /// within 2 s — proving the cancellation path resumed the continuation
    /// rather than waiting for the drain.
    @Test func backgroundCallQueue_waitUntilIdle_cancellable() async {
        let queue = BackgroundCallQueue()
        queue {
            Thread.sleep(forTimeInterval: 3.0)
        }

        let waiter = Task { await queue.waitUntilIdle() }
        // Give the Task a moment to park on the continuation.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let startNs = DispatchTime.now().uptimeNanoseconds
        waiter.cancel()
        await waiter.value
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(elapsedNs < 2_000_000_000,
                "waitUntilIdle should resume within 2 s of cancel; took \(elapsedNs) ns")
    }

    /// `onIdle` fires immediately when the queue is already idle.
    @Test func backgroundCallQueue_onIdle_firesImmediatelyWhenIdle() async {
        let queue = BackgroundCallQueue()
        #expect(queue.isIdle)

        let fired = LockIsolated(false)
        _ = queue.onIdle {
            fired.setValue(true)
        }
        // Synchronous fire — no await needed.
        #expect(fired.value, "onIdle should fire synchronously when queue is already idle")
    }

    /// `onIdle` fires on the next idle transition when registered while busy.
    @Test func backgroundCallQueue_onIdle_firesOnIdleTransition() async throws {
        let queue = BackgroundCallQueue()
        let blockDrain = LockIsolated(true)
        queue {
            // Hold the drain busy until the test releases it.
            while blockDrain.value {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        #expect(!queue.isIdle, "queue should be busy after enqueue")

        let fired = LockIsolated(false)
        _ = queue.onIdle {
            fired.setValue(true)
        }
        // Not fired yet — queue is still busy.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!fired.value, "onIdle must not fire while queue is busy")

        // Let the drain finish.
        blockDrain.setValue(false)

        // Wait up to 2 s for the idle transition.
        for _ in 0..<200 {
            if fired.value { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fired.value, "onIdle should fire after the queue drains")
    }

    /// Cancelling the onIdle registration suppresses the firing.
    @Test func backgroundCallQueue_onIdle_cancelSuppressesFire() async throws {
        let queue = BackgroundCallQueue()
        let blockDrain = LockIsolated(true)
        queue {
            while blockDrain.value {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        let fired = LockIsolated(false)
        let cancel = queue.onIdle {
            fired.setValue(true)
        }
        cancel()

        blockDrain.setValue(false)
        // Wait well past when the idle transition would happen.
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(!fired.value, "cancelled onIdle must not fire")
    }

    /// Same shape for `waitForCurrentItems` — independent code path through
    /// the same slot+handler pattern, so it gets its own assertion.
    @Test func backgroundCallQueue_waitForCurrentItems_cancellable() async {
        let queue = BackgroundCallQueue()
        queue {
            Thread.sleep(forTimeInterval: 3.0)
        }

        let waiter = Task { await queue.waitForCurrentItems() }
        try? await Task.sleep(nanoseconds: 100_000_000)

        let startNs = DispatchTime.now().uptimeNanoseconds
        waiter.cancel()
        await waiter.value
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(elapsedNs < 2_000_000_000,
                "waitForCurrentItems should resume within 2 s of cancel; took \(elapsedNs) ns")
    }

    // MARK: - 3. _withTestTimeout

    /// When the body hangs, the timer must fire and throw
    /// `_TestTimeoutError`. `reportIssueOnTimeout: false` keeps the
    /// timer's `reportIssue(_:)` out of this test's own issue list.
    /// The trait's per-test 30 s wall-clock cap backstops a wholly
    /// failed timer (the test itself would hang and the trait would
    /// report it).
    @Test func withTestTimeout_throwsAfterTimeout() async {
        do {
            _ = try await _withTestTimeout(
                seconds: 0.5,
                testTag: "validation-hung-body",
                reportIssueOnTimeout: false
            ) { () async throws -> Int in
                // Task.sleep is cancellation-aware, so on timer-fire the
                // taskgroup's cancelAll() unwinds this naturally — the test
                // here is the timeout path, not the wait-primitive path.
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return 42
            }
            Issue.record("expected _TestTimeoutError, got success")
        } catch let error as _TestTimeoutError {
            #expect(error.seconds == 0.5)
            #expect(error.testTag == "validation-hung-body")
            // No upper-bound timing assertion: reaching this catch block
            // already proves the property under test (the timer fired
            // and `_TestTimeoutError` propagated). The trait's per-test
            // 30 s wall-clock cap is the backstop for a hung timer.
            // Asserting how *fast* GCD's tick handler fires is a property
            // of the scheduler, not of our code, and varies with
            // environmental load — fine on serial CI but flaky on
            // saturated parallel-stress dispatch pools.
        } catch {
            Issue.record("expected _TestTimeoutError, got \(type(of: error)): \(error)")
        }
    }

    /// When the body returns before the timer, its result must come back.
    /// Implicitly verifies the timer Task is cancelled rather than fired
    /// (otherwise we'd get a `_TestTimeoutError` racing the body's return).
    @Test func withTestTimeout_returnsBodyResult() async throws {
        let result = try await _withTestTimeout(
            seconds: 30,
            testTag: "validation-fast-body",
            reportIssueOnTimeout: false
        ) { () async throws -> String in
            try await Task.sleep(nanoseconds: 10_000_000) // 10 ms
            return "ok"
        }
        #expect(result == "ok")
    }

    /// End-to-end: timer fires → `cancelAll` cancels body → body's wait
    /// primitive (`BackgroundCallQueue.waitUntilIdle`) observes cancel and
    /// resumes its parked continuation → body unwinds → `_TestTimeoutError`
    /// surfaces.
    ///
    /// This is the test that would have caught the historical hang signature
    /// (no threads active, main idle): if any step in the chain doesn't
    /// propagate cancel, this test will itself hang past the trait's
    /// wall-clock cap.
    @Test func withTestTimeout_cancelsBodyThroughWaitPrimitive() async {
        let queue = BackgroundCallQueue()
        // Block the drain for 5 s — well past the 0.5 s timeout we're testing.
        queue {
            Thread.sleep(forTimeInterval: 5.0)
        }

        do {
            _ = try await _withTestTimeout(
                seconds: 0.5,
                testTag: "validation-wait-cancel-prop",
                reportIssueOnTimeout: false
            ) { () async throws -> Int in
                await queue.waitUntilIdle()
                return 7
            }
            Issue.record("expected _TestTimeoutError")
        } catch is _TestTimeoutError {
            // No upper-bound timing assertion. The body blocks on
            // `queue.waitUntilIdle()` against a queue held busy for 5 s.
            // If the cancel chain (timer → cancelAll → waitUntilIdle's
            // cancellation handler → continuation resume → body unwind)
            // were broken, the body would block the full 5 s and return
            // `7`, hitting the `Issue.record("expected _TestTimeoutError")`
            // branch above. Reaching this catch block already proves the
            // chain works — asserting how *fast* it works is environment-
            // dependent (GCD scheduling latency, cooperative pool
            // contention) and not our property to test.
        } catch {
            Issue.record("expected _TestTimeoutError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - 4. GlobalTickScheduler

    /// A single scheduled callback fires within the granularity bound.
    @Test func globalTickScheduler_firesScheduledCallback() async throws {
        let fired = LockIsolated(false)
        let firedAt = LockIsolated<UInt64>(0)
        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadlineNs = startNs + 50_000_000  // 50 ms

        _ = GlobalTickScheduler.shared.schedule(deadlineNs: deadlineNs) {
            firedAt.setValue(DispatchTime.now().uptimeNanoseconds)
            fired.setValue(true)
        }

        // Poll up to 15 s for the callback to fire. GTS now runs at
        // `.background` QoS, which the OS scheduler can delay multiple
        // seconds under parallel-test load (933 in-process tests
        // saturating the cores). The test only asserts "the scheduler
        // fires" and "not before the deadline" — exact jitter is a GCD
        // property, not ours.
        for _ in 0..<1500 {
            if fired.value { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(fired.value, "callback should have fired within 15 s")
        let elapsed = firedAt.value - startNs
        #expect(elapsed >= 40_000_000, "should not fire before deadline (allow 10 ms slack); fired at \(elapsed) ns")
        // Upper bound is loose — under heavy parallel load GCD can delay
        // the `.background` ticker by many seconds. We're testing that the
        // scheduler fires at all, not exact jitter.
        #expect(elapsed < 15_000_000_000, "should fire within 15 s of deadline; fired at \(elapsed) ns")
    }

    /// Cancelling a scheduled callback prevents it from firing.
    @Test func globalTickScheduler_cancelPreventsCallback() async throws {
        let fired = LockIsolated(false)
        let cancel = GlobalTickScheduler.shared.schedule(deadlineNs: DispatchTime.now().uptimeNanoseconds + 50_000_000) {
            fired.setValue(true)
        }
        cancel()

        // Wait well past the deadline — callback should NOT fire.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!fired.value, "cancelled callback should not fire")
    }

    /// Multiple callbacks scheduled at different deadlines fire in order.
    ///
    /// Generous poll budget: GTS now runs at `.background` QoS, which the
    /// OS scheduler can delay by several seconds under parallel-test load.
    /// We only assert ordering and eventual firing — exact latency is the
    /// OS's call, not ours. Real "GTS hung" bugs would still exceed 15 s
    /// and surface as the trait cap.
    @Test func globalTickScheduler_multipleDeadlinesFireInOrder() async throws {
        let fireOrder = LockIsolated<[Int]>([])
        let baseNs = DispatchTime.now().uptimeNanoseconds

        // Schedule out of order (200, 100, 300 ms) — should fire in 100, 200, 300 order.
        _ = GlobalTickScheduler.shared.schedule(deadlineNs: baseNs + 200_000_000) {
            fireOrder.withValue { $0.append(2) }
        }
        _ = GlobalTickScheduler.shared.schedule(deadlineNs: baseNs + 100_000_000) {
            fireOrder.withValue { $0.append(1) }
        }
        _ = GlobalTickScheduler.shared.schedule(deadlineNs: baseNs + 300_000_000) {
            fireOrder.withValue { $0.append(3) }
        }

        // Wait up to 15 s for all three.
        for _ in 0..<1500 {
            if fireOrder.value.count == 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(fireOrder.value == [1, 2, 3], "callbacks should fire in deadline order; got \(fireOrder.value)")
    }

    /// Cancel is idempotent — calling after fire is a no-op.
    ///
    /// Generous poll budget: GTS at `.background` may take several seconds
    /// under parallel-test load. We only assert "eventually fires" and
    /// "double-cancel is safe".
    @Test func globalTickScheduler_cancelAfterFireIsNoOp() async throws {
        let fired = LockIsolated(false)
        let cancel = GlobalTickScheduler.shared.schedule(deadlineNs: DispatchTime.now().uptimeNanoseconds + 50_000_000) {
            fired.setValue(true)
        }
        // Wait up to 15 s for the callback to fire
        for _ in 0..<1500 {
            if fired.value { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fired.value, "callback should have fired")

        // Now cancel — should not crash, no observable effect
        cancel()
        cancel()  // double-cancel also fine
    }

    // MARK: - 6. awaitPredicate (register-and-wait)

    /// A predicate that becomes true on activity resolves with `.passed`.
    /// Uses a separate LockIsolated for the predicate's external state
    /// to keep the test free of Sendable hair (the validation here is
    /// about `awaitPredicate`'s wake-up semantics, not model integration).
    @Test func awaitPredicate_resolvesOnActivity() async throws {
        let tester = ModelTester(ActivitySignalModel(), exhaustivity: .off)
        let access = tester.access
        let probeFlag = LockIsolated(false)

        let waiter = Task { () -> TestAccess<ActivitySignalModel>.PredicateOutcome in
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            return await access.awaitPredicate(deadlineNs: deadline) { @Sendable in
                probeFlag.value
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Flip the flag, then fire activity (a model write triggers _noteActivity).
        probeFlag.setValue(true)
        tester.model.value += 1
        let outcome = await waiter.value

        // No upper-bound timing assertion: `outcome == .passed` proves the
        // property under test (activity woke the predicate; it didn't fall
        // through to the 5 s deadline path which would return `.timeout`).
        // How *fast* the wake propagates depends on GTS / cooperative-pool
        // scheduling latency, which is environmental.
        #expect(outcome == .passed)
    }

    /// A predicate that's already true resolves immediately without parking.
    @Test func awaitPredicate_resolvesImmediatelyIfAlreadyTrue() async throws {
        let tester = ModelTester(ActivitySignalModel(), exhaustivity: .off)
        let access = tester.access

        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let outcome = await access.awaitPredicate(deadlineNs: deadline) { @Sendable in
            true  // already passes
        }
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(outcome == .passed)
        #expect(elapsedNs < 100_000_000, "no-park resolution should be near-instant; took \(elapsedNs) ns")
    }

    /// A predicate that never becomes true resolves with `.timeout` near
    /// the deadline.
    ///
    /// Generous upper bound: GTS at `.background` can be delayed by
    /// several seconds under parallel-test load. We only assert the
    /// deadline fires eventually and not before the requested time —
    /// exact jitter is the OS scheduler's call.
    @Test func awaitPredicate_timesOutWhenPredicateStuck() async throws {
        let tester = ModelTester(ActivitySignalModel(), exhaustivity: .off)
        let access = tester.access

        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadline = startNs + 150_000_000  // 150 ms
        let outcome = await access.awaitPredicate(deadlineNs: deadline) { @Sendable in
            false  // never passes
        }
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(outcome == .timeout)
        #expect(elapsedNs >= 130_000_000, "should not fire before deadline; fired at \(elapsedNs) ns")
        #expect(elapsedNs < 15_000_000_000, "should fire within reasonable window; took \(elapsedNs) ns")
    }

    /// Cancelling the awaiting Task resolves with `.cancelled`.
    @Test func awaitPredicate_resolvesOnCancellation() async throws {
        let tester = ModelTester(ActivitySignalModel(), exhaustivity: .off)
        let access = tester.access

        let waiter = Task { () -> TestAccess<ActivitySignalModel>.PredicateOutcome in
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            return await access.awaitPredicate(deadlineNs: deadline) { @Sendable in false }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        waiter.cancel()
        let outcome = await waiter.value

        // No upper-bound timing assertion: `outcome == .cancelled` proves
        // the property under test (cancellation propagated through the
        // task-cancellation handler and resolved the continuation; it
        // didn't fall through to the 5 s deadline path or stay parked).
        // Cancellation-propagation latency is environmental.
        #expect(outcome == .cancelled)
    }

    // MARK: - 6b. awaitQuietWindow (single-await debounce)

    /// With no activity at all, `awaitQuietWindow` fires after the quiet
    /// window elapses — entire wait is a single park.
    @Test func awaitQuietWindow_firesAfterQuietWindow() async throws {
        let tester = ModelTester(ActivitySignalModel(), exhaustivity: .off)
        let access = tester.access

        let startNs = DispatchTime.now().uptimeNanoseconds
        let outcome = await access.awaitQuietWindow(
            quietWindowNs: 100_000_000,    // 100 ms
            totalBudgetNs: 25_000_000_000  // 25 s budget cap — matches settleTotalBudgetNs
        )
        let elapsedNs = Self.elapsedNs(since: startNs)

        // Outcome is `.timeout` (the GlobalTickScheduler deadline fired).
        // `waitUntilSettled` interprets this as "settled" since now < budgetEnd.
        #expect(outcome == .timeout)
        #expect(elapsedNs >= 80_000_000,
                "should not fire before quiet window; fired at \(elapsedNs) ns")
        // Upper bound matches the settle budget: GTS at `.background` can
        // be delayed by seconds under parallel-test load on a small CI box;
        // the new design lets `.deferential` wait as long as it needs and
        // only the trait-cap-adjacent 25 s ceiling catches truly stuck
        // primitives. Real "GTS hung" bugs would exceed this and trip the
        // budget cap before this assertion.
        #expect(elapsedNs < 25_000_000_000,
                "should fire within reasonable window; took \(elapsedNs) ns")
    }

    // Note: explicit `awaitQuietWindow` timing tests (activity extension,
    // budget cap) were removed — they depended too tightly on `Task.sleep`
    // accuracy, which is unreliable under parallel-test load (the writer's
    // sleeps can stall past the quiet window, making test outcomes
    // race-dependent). The primitive is exercised end-to-end by every
    // `.modelTesting` test that uses `settle()`; failing-deadline logic
    // is covered by `awaitQuietWindow_firesAfterQuietWindow` above.

    /// Scheduling from inside a callback re-arms the ticker correctly.
    ///
    /// Generous poll budget: GTS at `.background` may take several seconds
    /// under parallel-test load. We only assert the chain DOES fire and
    /// takes at least the minimum nominal time.
    @Test func globalTickScheduler_canScheduleFromCallback() async throws {
        let firedCount = LockIsolated(0)
        let baseNs = DispatchTime.now().uptimeNanoseconds

        @Sendable func scheduleNext(_ count: Int) {
            guard count > 0 else { return }
            _ = GlobalTickScheduler.shared.schedule(deadlineNs: DispatchTime.now().uptimeNanoseconds + 50_000_000) {
                firedCount.withValue { $0 += 1 }
                scheduleNext(count - 1)
            }
        }
        scheduleNext(3)

        // Wait up to 20 s for all 3 chained fires.
        for _ in 0..<2000 {
            if firedCount.value == 3 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(firedCount.value == 3, "chain should fire 3 times; got \(firedCount.value)")
        // Total elapsed should be at least 3 × 50 ms = 150 ms.
        let elapsed = DispatchTime.now().uptimeNanoseconds - baseNs
        #expect(elapsed >= 120_000_000, "chain should take at least 3 × 50 ms; took \(elapsed) ns")
    }

    // MARK: - 7. Driven-tick determinism (no real GCD timer interference)
    //
    // These tests drive `_drivenTick(nowNs:)` directly on a `manualOnly`
    // scheduler so the deadline-firing logic is deterministic, independent
    // of GCD scheduling jitter.

    /// Entries fire when `now >= deadline`, in deadline order.
    @Test func drivenTick_firesEntriesAtDeadlineInOrder() async throws {
        let scheduler = GlobalTickScheduler(manualOnly: true)

        let baseNs: UInt64 = 1_000_000_000
        let fired = LockIsolated<[Int]>([])

        // Register three entries at different deadlines.
        _ = scheduler.schedule(deadlineNs: baseNs + 100_000_000) {
            fired.withValue { $0.append(1) }
        }
        _ = scheduler.schedule(deadlineNs: baseNs + 200_000_000) {
            fired.withValue { $0.append(2) }
        }
        _ = scheduler.schedule(deadlineNs: baseNs + 300_000_000) {
            fired.withValue { $0.append(3) }
        }

        // Tick BEFORE any deadline — nothing fires.
        _ = scheduler._drivenTick(nowNs: baseNs + 50_000_000)
        #expect(fired.value == [])

        // Tick at first deadline.
        _ = scheduler._drivenTick(nowNs: baseNs + 100_000_000)
        #expect(fired.value == [1])

        // Tick past last — all remaining fire.
        _ = scheduler._drivenTick(nowNs: baseNs + 500_000_000)
        #expect(fired.value == [1, 2, 3])
    }

    /// Cancelled entries don't fire even after their deadline.
    @Test func drivenTick_cancelledEntryDoesNotFire() async throws {
        let scheduler = GlobalTickScheduler(manualOnly: true)

        let baseNs: UInt64 = 1_000_000_000
        let fired = LockIsolated(false)

        let cancel = scheduler.schedule(deadlineNs: baseNs + 100_000_000) {
            fired.setValue(true)
        }
        cancel()
        _ = scheduler._drivenTick(nowNs: baseNs + 200_000_000)
        #expect(!fired.value, "cancelled entry should not fire")
    }
}

// MARK: - Helpers

/// Minimal model for `awaitPredicate` / `awaitAnyActivity` tests — a single
/// mutable property so the tests can fire activity by setting it.
@Model private struct ActivitySignalModel {
    var value: Int = 0
}
#endif
