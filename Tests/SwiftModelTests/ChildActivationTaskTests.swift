import Testing
import SwiftModel

// MARK: - Models

/// Parent model that holds an array of child models, each with a quick async task.
/// Reproduces the SearchTests teardown race described below.
@Model private struct ChildTaskParent: Sendable {
    var items: [ChildTaskItem] = []
}

/// Child model that mirrors SearchResultItem.onActivate():
/// a short `node.task` tied to the item's lifetime.
///
/// Key: this task is created during GCD-drain activation, where no Swift Task is active,
/// so AnyCancellable.contexts is empty and the task is NOT keyed with .onActivate.
/// cancelAllRecursively(for: .onActivate) therefore does NOT cancel it; the task must
/// complete naturally before checkExhaustion reads Cancellations.registered.
///
/// The async work is a short on-executor `Task.yield` chain rather than a
/// `clock.sleep`. Both give the task "several suspension points then a write",
/// but they differ in *where* the suspensions park:
///
///   • A `clock.sleep` (even `ImmediateClock`) parks the continuation *off* the
///     per-test drain executor — invisible to the executor-drive's activity
///     accounting. While every child is parked off-executor at once, the drive
///     sees a no-activity window, and under `macOS (parallel)` saturation that
///     window stretched the test's wall-clock past the `.modelTesting` trait cap
///     (observed ~103 s on a constrained CI runner, > the 90 s scaled cap).
///   • `Task.yield` re-enqueues on the drain executor, so every suspension is
///     *on* the executor. The trait cap is an inactivity watchdog keyed on this
///     test's executor activity (executor-drive default, macOS 15+); continuous
///     on-executor progress keeps resetting it, so a slow-but-progressing run
///     under load never trips it — the load-independence the drive is built to
///     provide. This mirrors the validated `DrainItem` shape in
///     `ExecutorDrainSettleTests.settleIsLoadIndependentAcrossChildTasks` (run
///     60× under CPU load). See `Docs/test-determinism-executor-drain.md`.
///
/// The teardown race under test is unchanged: the task is still unkeyed and must
/// unregister() naturally around checkExhaustion — `Task.yield` vs `clock.sleep`
/// does not affect that.
@Model private struct ChildTaskItem: Sendable, Identifiable {
    let id: Int
    var loaded: Bool = false

    func onActivate() {
        node.task {
            for _ in 0..<6 { await Task.yield() }
            loaded = true
        }
    }
}

// MARK: - Tests

/// Regression suite for the "Active task still running at teardown" race.
///
/// Root cause: `node.task { }` called from onActivate() during a GCD drain is not keyed
/// with .onActivate. It completes quickly but its unregister() call races with
/// checkExhaustion reading Cancellations.registered.
///
/// Fix: checkExhaustion yields to the scheduler after cancelAllRecursively so naturally-
/// completing tasks can call unregister() before the exhaustion check runs.
@Suite(.modelTesting)
struct ChildActivationTaskTests {

    /// Sets children directly — mirrors `withActivationPrePopulatesResults` in SearchTests.
    /// Without the fix this fails ~2/100 runs with:
    ///   "Active task 'onActivate() @ ...' of `ChildTaskItem` still running"
    @Test func childTasksCompleteBeforeTeardown() async {
        let parent = ChildTaskParent().withAnchor()
        parent.items = (0..<5).map { ChildTaskItem(id: $0) }
        // Wait for all onActivate tasks to complete (loaded becomes true for each
        // item), then teardown runs checkExhaustion immediately after — the tight
        // window that exercises the unregister()-vs-checkExhaustion race. `expect`
        // (not `settle`) is deliberate: `settle` would wait for full drain
        // quiescence first, closing that window and neutering the regression.
        await expect(parent.items.count == 5 && parent.items.allSatisfy { $0.loaded })
    }
}
