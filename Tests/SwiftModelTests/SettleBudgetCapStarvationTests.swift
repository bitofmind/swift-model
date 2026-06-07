#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Regression coverage for the `settle()` budget-cap starvation bug.
///
/// **The bug.** In-test `settle()` arms its quiet-window deadline with
/// `.deferential` priority (`waitUntilSettled` →
/// `awaitSettled(priority: .deferential)`). In `GlobalTickScheduler.fire()`
/// a `.deferential` callback is NOT run inline — it is dispatched to
/// `DispatchQueue.global(qos: .background)`. The settle total-budget cap
/// (the `pastBudget` check) lives *inside* `_fireDeadline`, which only runs
/// once that `.background` callback gets a slot.
///
/// Under executor saturation (a loaded CI host) the `.background` slot may
/// never run within the budget, so `_fireDeadline` never runs and the cap
/// never trips. `settle()` then only unblocks ~30 s later at the
/// `.modelTesting` trait wall-clock cap, surfacing a misleading
/// `settle() timed out: model still has active tasks.` (the active-task list
/// is actually empty).
///
/// **The fix.** `_awaitPending` arms a SECOND, `.responsive` (inline,
/// never-starved) `GlobalTickScheduler` entry at the fixed total-budget
/// deadline alongside the `.deferential` quiet-window entry. The
/// `.responsive` budget entry fires on the timer's `.userInitiated` GCD
/// queue regardless of `.background` pressure, so the cap always trips on
/// time.
///
/// **How these tests stay deterministic.** Rather than racing the OS
/// scheduler, the starvation test floods `DispatchQueue.global(qos:
/// .background)` with far more long-blocking work items than any plausible
/// `.background` thread-pool width, then arms an `awaitSettled` whose `bg`
/// is busy forever (so the only way out is the budget cap). With the fix,
/// the `.responsive` backstop resolves it within ~the (short) budget; a
/// regression would block until the flooded `.background` queue drains
/// (multiple seconds), failing the bounded assertion. The control test
/// exercises the `.responsive` (inline, never-backstopped) settle path to
/// confirm the fix is correctly scoped and leaves normal settle timing
/// untouched.
///
/// Guarded by `#if canImport(Dispatch)` — the scheduler and these
/// priorities are Dispatch-backed (Apple/Linux). WASM has neither.
/// `.serialized` so the starvation tests' `.background`-queue flood does not
/// bleed into the unloaded control test (the global `.background` queue is
/// process-wide; concurrent flooding would starve the control's quiet-window
/// callback and make it resolve at the budget cap, defeating the assertion).
@Suite("settle() budget-cap starvation", .serialized)
struct SettleBudgetCapStarvationTests {

    private static func elapsedNs(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds - start
    }

    /// Floods `DispatchQueue.global(qos: .background)` with `count` work
    /// items that each block until `release` flips, then waits for them all
    /// to actually start running (so the pool is genuinely saturated before
    /// the test proceeds). Returns the release flag — set it to `true` in a
    /// `defer` so the blocked threads unwind after the test.
    @discardableResult
    private static func saturateBackgroundQueue(count: Int, release: LockIsolated<Bool>) -> LockIsolated<Int> {
        let started = LockIsolated(0)
        for _ in 0..<count {
            DispatchQueue.global(qos: .background).async {
                started.withValue { $0 += 1 }
                while !release.value {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
        }
        // Wait until a healthy fraction of the items are running — enough
        // that the pool's spare capacity is exhausted. We don't require all
        // `count` to start (GCD caps the pool well below `count`); we only
        // need the queue backlogged so a freshly-dispatched `.deferential`
        // callback can't get a slot.
        let target = max(8, count / 8)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while started.value < target, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return started
    }

    /// THE REGRESSION: with the `.background` queue saturated and `bg` busy
    /// forever, an in-test (`.deferential`) `awaitSettled` must still resolve
    /// at the total-budget cap promptly — proving the `.responsive` budget
    /// backstop fired on the unstarved inline path.
    ///
    /// Before the fix this hangs until the flooded `.background` queue drains
    /// (the blocked items only release at end-of-test), so it would blow past
    /// the bounded assertion / the trait wall-clock cap.
    @Test func budgetCapFiresWhenBackgroundQueueStarved() async {
        let release = LockIsolated(false)
        defer { release.setValue(true) }   // let the flood threads unwind
        Self.saturateBackgroundQueue(count: 256, release: release)

        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off)
        let access = tester.access

        // A bg queue that is busy for the whole test, so `.settled` mode can
        // NEVER resolve on the bg-idle path — the budget cap is the only way
        // out. (Released via the same flag in the deferred cleanup.)
        let bg = BackgroundCallQueue()
        bg {
            while !release.value {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        // Short budget. The `.deferential` quiet-window callback is starved
        // on the flooded `.background` queue; only the `.responsive` budget
        // backstop can resolve us.
        let budgetNs: UInt64 = 500_000_000   // 500 ms
        let quietNs: UInt64 = 50_000_000     // 50 ms

        let startNs = DispatchTime.now().uptimeNanoseconds
        let outcome = await access.awaitSettled(
            quietWindowNs: quietNs,
            totalBudgetNs: budgetNs,
            bg: bg,
            priority: .deferential
        )
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(outcome == .timeout, "budget cap should resolve the entry (.timeout)")
        // The cap is 500 ms. Allow generous slack for GCD timer jitter, but
        // stay far below the multi-second drain a regression would incur and
        // the 30 s trait cap. A missing backstop blocks the full bg-drain
        // (release only flips at end-of-test), so it would exceed this bound.
        #expect(elapsedNs < 5_000_000_000,
                "budget cap must fire on the inline path despite .background starvation; took \(elapsedNs) ns")
        // Should not resolve before the budget — proves we waited for the cap,
        // not some spurious early fire.
        #expect(elapsedNs >= 400_000_000,
                "should not resolve before the budget cap; resolved at \(elapsedNs) ns")
    }

    /// Same starvation, but driven through the real `.predicate`-free
    /// `.debounce` path (`awaitQuietWindow`, also `.deferential`) to confirm
    /// the backstop covers every debounced in-test wait, not just `.settled`.
    @Test func quietWindowBudgetCapFiresWhenBackgroundQueueStarved() async {
        let release = LockIsolated(false)
        defer { release.setValue(true) }
        Self.saturateBackgroundQueue(count: 256, release: release)

        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off)
        let access = tester.access

        let budgetNs: UInt64 = 500_000_000
        let quietNs: UInt64 = 50_000_000

        let startNs = DispatchTime.now().uptimeNanoseconds
        let outcome = await access.awaitQuietWindow(
            quietWindowNs: quietNs,
            totalBudgetNs: budgetNs
        )
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(outcome == .timeout)
        #expect(elapsedNs < 5_000_000_000,
                "quiet-window budget cap must fire on the inline path despite .background starvation; took \(elapsedNs) ns")
    }

    /// CONTROL: the backstop must NOT change normal settle behaviour.
    ///
    /// We test the `.responsive` settle path (the cleanup-settle priority),
    /// which runs the quiet-window callback INLINE on the timer's
    /// `.userInitiated` GCD queue — never on the starvable `.background`
    /// queue. Two things make this the right control:
    ///
    ///   1. It is reliably prompt regardless of host `.background` load, so
    ///      it can carry a tight upper bound without flaking (the
    ///      `.deferential` quiet-window callback's latency is unbounded under
    ///      load — that is the very bug — so it cannot).
    ///   2. The backstop is armed ONLY for `.deferential` entries (see
    ///      `_awaitPending`). So a `.responsive` settle resolves on the pure
    ///      quiet window with NO backstop in play — proving the fix is
    ///      correctly scoped and leaves the inline path's timing untouched.
    @Test func responsiveSettleResolvesOnQuietWindowUnchanged() async {
        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off)
        let access = tester.access

        let bg = BackgroundCallQueue()   // idle the whole time
        #expect(bg.isIdle)

        let scale = ModelTestingTraitOptions.timeoutScale
        let quietNs: UInt64 = 100_000_000                 // 100 ms
        let budgetNs = UInt64(5_000_000_000 * scale)      // 5 s
        let upperBoundNs = UInt64(4_500_000_000 * scale)  // 4.5 s

        let startNs = DispatchTime.now().uptimeNanoseconds
        let outcome = await access.awaitSettled(
            quietWindowNs: quietNs,
            totalBudgetNs: budgetNs,
            bg: bg,
            priority: .responsive
        )
        let elapsedNs = Self.elapsedNs(since: startNs)

        #expect(outcome == .timeout)
        // Resolved on the quiet window — lower bound proves we actually
        // waited it (no premature fire), upper bound proves we resolved far
        // below the 5 s budget cap (the inline quiet-window callback fired,
        // not the budget backstop).
        #expect(elapsedNs >= 80_000_000,
                "should wait the quiet window; resolved at \(elapsedNs) ns")
        #expect(elapsedNs < upperBoundNs,
                "responsive settle should resolve on the quiet window, not the budget cap; took \(elapsedNs) ns (scale=\(scale))")
    }
}

// MARK: - Helpers

/// Minimal model so the tests can build a `ModelTester` (and thus a real
/// per-test `TestAccess`). Declared at file scope because `@Model` cannot be
/// applied to a `private` nested type.
@Model private struct BudgetCapSignalModel {
    var value: Int = 0
}
#endif
