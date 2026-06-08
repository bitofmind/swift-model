#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
@testable import SwiftModel

/// Regression coverage for the `settle()` budget-cap starvation bug.
///
/// **The bug.** In-test `settle()` arms its quiet-window deadline with
/// `.deferential` priority (`waitUntilSettled` →
/// `awaitSettled(priority: .deferential)`; `awaitQuietWindow` likewise). In
/// `GlobalTickScheduler.fire()` a `.deferential` callback is NOT run inline —
/// it is dispatched to `DispatchQueue.global(qos: .background)`. The settle
/// total-budget cap (the `pastBudget` check) lives *inside* `_fireDeadline`,
/// which only runs once that `.background` callback gets a slot.
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
/// `.responsive` budget entry fires on the timer's `.userInitiated` GCD queue
/// regardless of `.background` pressure, so the cap always trips on time.
///
/// **How these tests stay deterministic — and why they don't pollute.** An
/// earlier version of this suite simulated starvation by flooding the
/// process-global `DispatchQueue.global(qos: .background)` with hundreds of
/// blocking work items. That queue is the SAME one every `.deferential` GTS
/// callback in every concurrently-running test hops to, so the flood starved
/// sibling tests' settle / quiet-window callbacks (making them resolve at
/// their budget cap instead of their quiet window) and, on macOS where
/// `.background` QoS is heavily throttled, lingered long enough to push the
/// serial job past its 15-minute cap. It broke CI.
///
/// Instead, each test here injects its OWN `GlobalTickScheduler(manualOnly:)`
/// into a `ModelTester` (via `TestAccess.tickScheduler`) and drives deadlines
/// with `_drivenTick`. Starvation is simulated *faithfully and locally* by
/// `_drivenTick(fireDeferential: false)`: the `.deferential` primary deadline
/// elapses but its callback is never delivered (exactly what an infinitely-
/// starved `.background` slot does), while the `.responsive` backstop fires
/// inline. No real GCD timer, no process-global `.background` queue, no
/// cross-test interference — so the suite is fully parallel-safe.
///
/// Guarded by `#if canImport(Dispatch)` — `GlobalTickScheduler` and these
/// priorities are Dispatch-backed (Apple/Linux). WASM has neither.
@Suite("settle() budget-cap backstop")
struct SettleBudgetCapStarvationTests {

    /// Poll until `scheduler` has at least `target` pending entries (the
    /// `awaitSettled` / `awaitQuietWindow` Task arms them asynchronously once
    /// it starts running on the cooperative pool), or `seconds` elapse.
    private static func waitForPending(
        _ scheduler: GlobalTickScheduler,
        atLeast target: Int,
        within seconds: Double = 5
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while scheduler._pendingCount < target {
            if DispatchTime.now().uptimeNanoseconds > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)   // 1 ms
        }
        return true
    }

    /// A `nowNs` guaranteed to be at/after a just-armed `budgetNs` deadline,
    /// so `_drivenTick(nowNs:)` treats the backstop entry as expired. The
    /// extra second swamps any skew between the scheduler's internal `now`
    /// and the test's clock.
    private static func pastBudgetNowNs(_ budgetNs: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + budgetNs + 1_000_000_000
    }

    /// THE REGRESSION, `.settled` path (the real-world in-test `settle()`
    /// route). With the `.deferential` primary starved, the `.responsive`
    /// budget backstop must reach `_fireDeadline` and resolve the wait. An
    /// idle `bg` keeps resolution independent of the real-clock `pastBudget`
    /// check, so the assertion is deterministic — what's under test is that
    /// the *backstop* is the firing source once the primary is starved.
    ///
    /// Before the fix there is no second entry, so a never-delivered primary
    /// leaves the wait parked forever (here: until the test's safety polling
    /// gives up).
    @Test func settledBudgetBackstopResolvesWhenDeferentialPrimaryStarved() async {
        let scheduler = GlobalTickScheduler(manualOnly: true)
        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off, tickScheduler: scheduler)
        let access = tester.access

        let bg = BackgroundCallQueue()        // idle the whole time
        let quietNs: UInt64 = 50_000_000      // 50 ms
        let budgetNs: UInt64 = 500_000_000    // 500 ms

        let task = Task {
            await access.awaitSettled(
                quietWindowNs: quietNs,
                totalBudgetNs: budgetNs,
                bg: bg,
                priority: .deferential
            )
        }

        #expect(await Self.waitForPending(scheduler, atLeast: 2),
                "primary .deferential deadline + .responsive budget backstop should both be armed")
        #expect(scheduler._pendingCount == 2)

        // Starve the `.deferential` primary; deliver ONLY the `.responsive`
        // backstop, past the budget.
        let fired = scheduler._drivenTick(nowNs: Self.pastBudgetNowNs(budgetNs), fireDeferential: false)
        #expect(fired == 1, "only the .responsive budget backstop should fire; fired \(fired)")

        let outcome = await task.value
        #expect(outcome == .timeout, "the budget backstop must resolve the settle on the inline path")
        #expect(scheduler._pendingCount == 0, "resolution must tear down the still-pending starved primary")
    }

    /// Same regression through the `.debounce` path (`awaitQuietWindow`, also
    /// `.deferential`). `.debounce` resolution in `_fireDeadline` is
    /// unconditional (no `bg`, no real-clock `pastBudget` gate), so this is
    /// the purest deterministic proof that the backstop carries the
    /// resolution under primary starvation.
    @Test func quietWindowBudgetBackstopResolvesWhenDeferentialPrimaryStarved() async {
        let scheduler = GlobalTickScheduler(manualOnly: true)
        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off, tickScheduler: scheduler)
        let access = tester.access

        let quietNs: UInt64 = 50_000_000
        let budgetNs: UInt64 = 500_000_000

        let task = Task {
            await access.awaitQuietWindow(quietWindowNs: quietNs, totalBudgetNs: budgetNs)
        }

        #expect(await Self.waitForPending(scheduler, atLeast: 2),
                "primary .deferential deadline + .responsive budget backstop should both be armed")
        #expect(scheduler._pendingCount == 2)

        let fired = scheduler._drivenTick(nowNs: Self.pastBudgetNowNs(budgetNs), fireDeferential: false)
        #expect(fired == 1, "only the .responsive budget backstop should fire; fired \(fired)")

        let outcome = await task.value
        #expect(outcome == .timeout, "the budget backstop must resolve the quiet-window wait on the inline path")
        #expect(scheduler._pendingCount == 0, "resolution must tear down the still-pending starved primary")
    }

    /// CONTROL: the backstop must not change normal (unstarved) settle
    /// behaviour. When the `.deferential` primary IS delivered at the quiet
    /// window, the settle resolves there — and resolving must CANCEL the
    /// backstop, so a fast normal settle leaves no lingering inline timer.
    @Test func normalDeferentialSettleResolvesOnQuietWindowAndCancelsBackstop() async {
        let scheduler = GlobalTickScheduler(manualOnly: true)
        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off, tickScheduler: scheduler)
        let access = tester.access

        let bg = BackgroundCallQueue()        // idle
        let quietNs: UInt64 = 50_000_000
        let budgetNs: UInt64 = 5_000_000_000  // 5 s — far past the quiet window

        let task = Task {
            await access.awaitSettled(
                quietWindowNs: quietNs,
                totalBudgetNs: budgetNs,
                bg: bg,
                priority: .deferential
            )
        }

        #expect(await Self.waitForPending(scheduler, atLeast: 2))
        #expect(scheduler._pendingCount == 2)

        // Deliver the primary at the quiet window. The backstop's deadline
        // (now + 5 s) is far in the future, so this tick fires ONLY the
        // primary — not the backstop.
        let fired = scheduler._drivenTick(
            nowNs: DispatchTime.now().uptimeNanoseconds + quietNs + 1_000_000,
            fireDeferential: true
        )
        #expect(fired == 1, "only the primary quiet-window deadline should fire; fired \(fired)")

        let outcome = await task.value
        #expect(outcome == .timeout)
        #expect(scheduler._pendingCount == 0,
                "quiet-window resolution must cancel the backstop — no lingering inline timer")
    }

    /// SCOPING CONTROL: the backstop is armed ONLY for `.deferential`
    /// entries. A `.responsive` settle (the cleanup-settle priority) must arm
    /// exactly ONE entry — its primary — proving the fix doesn't touch the
    /// already-unstarved inline path.
    @Test func responsivePrioritySettleArmsNoBackstop() async {
        let scheduler = GlobalTickScheduler(manualOnly: true)
        let tester = ModelTester(BudgetCapSignalModel(), exhaustivity: .off, tickScheduler: scheduler)
        let access = tester.access

        let bg = BackgroundCallQueue()
        let quietNs: UInt64 = 50_000_000
        let budgetNs: UInt64 = 5_000_000_000

        let task = Task {
            await access.awaitSettled(
                quietWindowNs: quietNs,
                totalBudgetNs: budgetNs,
                bg: bg,
                priority: .responsive
            )
        }

        #expect(await Self.waitForPending(scheduler, atLeast: 1))
        #expect(scheduler._pendingCount == 1, "a .responsive settle must not arm a budget backstop")

        // Resolve to clean up the parked Task.
        scheduler._drivenTick(nowNs: DispatchTime.now().uptimeNanoseconds + quietNs + 1_000_000)
        _ = await task.value
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
