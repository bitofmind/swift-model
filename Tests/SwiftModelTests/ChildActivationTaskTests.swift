import Testing
import SwiftModel
import Clocks

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
@Model private struct ChildTaskItem: Sendable, Identifiable {
    let id: Int
    var loaded: Bool = false

    func onActivate() {
        node.task {
            try await node.continuousClock.sleep(for: .milliseconds(200))
            loaded = true
        } catch: { _ in }
    }
}

// MARK: - Tests

/// Regression suite for the "Active task still running at teardown" race.
///
/// Root cause: `node.task { }` called from onActivate() during a GCD drain is not keyed
/// with .onActivate. It completes quickly (ImmediateClock) but its unregister() call on
/// the cooperative pool races with checkExhaustion reading Cancellations.registered.
///
/// Fix: checkExhaustion yields to the scheduler after cancelAllRecursively so naturally-
/// completing tasks can call unregister() before the exhaustion check runs.
@Suite(.modelTesting)
struct ChildActivationTaskTests {

    /// Sets children directly — mirrors `withActivationPrePopulatesResults` in SearchTests.
    /// Without the fix this fails ~2/100 runs with:
    ///   "Active task 'onActivate() @ ...' of `ChildTaskItem` still running"
    @Test func childTasksCompleteBeforeTeardown() async {
        let parent = ChildTaskParent().withAnchor {
            $0.continuousClock = ImmediateClock()
        }
        parent.items = (0..<5).map { ChildTaskItem(id: $0) }
        // Wait for all onActivate tasks to complete (loaded becomes true for each item).
        // checkExhaustion then verifies no tasks are still registered as running.
        await expect(parent.items.count == 5 && parent.items.allSatisfy { $0.loaded })
    }
}
