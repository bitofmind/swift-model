import Testing
@testable import SwiftModel
import ConcurrencyExtras
import Foundation
import IssueReporting

// Regression coverage for `Cancellations.register` silently dropping work started
// from an `onCancel` handler during teardown. `AnyContext.onRemoval` seals the
// task registry in the same locked scope that flips the model's lifetime to
// `.destructed`, then — in a deferred callback — drains it via
// `Cancellations.cancelAll()` / `cancelAll(for:)`, which runs every registered
// `onCancel` closure. If one of those closures itself starts new work
// (`node.task { }`, a nested `node.onCancel { }`, `forEach`, …), the new
// registration lands on the already-sealed store: `Cancellations.register`
// cancels it immediately, and — before this fix — silently, since the
// underlying `Task` is never even created (`TaskCancellable.init` sees
// `hasBeenCancelled == true` before it reaches the `task { }` call).
//
// The fix distinguishes that case from the legitimate, expected-silent one —
// a registration racing teardown from another thread, whose own context
// check simply lost the race — via a `@TaskLocal` (`Cancellations
// .isDrainingTeardown`) set only around the synchronous `onCancel()` drain.
struct OnCancelDuringTeardownRegistrationTests {
    // (1) RED→GREEN: an onCancel handler that starts a task during the sealed
    // teardown drain is reported, and the task body never runs.
    @Test func onCancelStartingTaskDuringTeardownReportsIssueAndNeverRuns() async {
        let testResult = TestResult()
        let reporter = CapturingIssueReporter()

        await withIssueReporters([reporter]) {
            await withModelTesting {
                _ = TeardownRegistrationModel().withAnchor {
                    $0.testResult = testResult
                }
            }
        }

        #expect(reporter.messages.contains {
            $0.contains("was registered while a model is being deactivated")
        })
        #expect(!testResult.value.contains("ran"))
    }

    // (2) The supported shape: a child's onCancel handler starts work on its
    // still-alive PARENT's node (an unsealed store) — this must succeed and run,
    // and must not be reported.
    @Test func onCancelStartingTaskOnAliveParentRunsAndIsNotReported() async {
        let reporter = CapturingIssueReporter()
        let ran = LockIsolated(false)

        await withIssueReporters([reporter]) {
            // `ran` is injected at construction (not assigned post-anchor): the
            // child's `onActivate()` snapshots its properties into the `onCancel`
            // closure when it runs, so a later `model.child?.ran = …` write would
            // be invisible to that already-formed closure.
            let model = ParentWithChildModel(child: ChildTeardownModel(ran: ran)).withAnchor()

            // Removes only the child; the parent stays alive/unsealed.
            model.removeChild()

            try? await waitUntil(ran.value, timeout: 5_000_000_000)
        }

        #expect(ran.value)
        #expect(reporter.messages.isEmpty)
    }

    // (3) The distinguisher itself, exercised directly and deterministically at
    // the `Cancellations` level (a genuine cross-thread race is not reliably
    // reproducible in a test): registering on a store that is sealed but NOT
    // currently being drained — i.e. `isDrainingTeardown` is false, exactly the
    // state the losing side of a cross-thread teardown race observes — cancels
    // immediately but stays silent, as documented at `Cancellations
    // .isDrainingTeardown`.
    @Test func registeringOnSealedStoreOutsideDrainStaysSilent() {
        let reporter = CapturingIssueReporter()
        let cancellations = Cancellations()
        cancellations.seal()
        let dummy = DummyCancellable(id: cancellations.nextId)

        withIssueReporters([reporter]) {
            cancellations.register(dummy)
        }

        #expect(dummy.wasCancelled.value)
        #expect(reporter.messages.isEmpty)
    }
}

private final class DummyCancellable: InternalCancellable {
    let id: Int
    let wasCancelled = LockIsolated(false)

    init(id: Int) {
        self.id = id
    }

    func onCancel() {
        wasCancelled.setValue(true)
    }
}

@Model
private struct TeardownRegistrationModel {
    func onActivate() {
        node.onCancel {
            node.task {
                node.testResult.add("ran")
            }
        }
    }
}

/// Starts work on a captured parent `ModelNode` — the supported way for a
/// child's teardown handler to hand off work to something that outlives it.
private final class ParentTaskStarter: @unchecked Sendable {
    private let node: ModelNode<ParentWithChildModel>

    init(node: ModelNode<ParentWithChildModel>) {
        self.node = node
    }

    func start(_ operation: @escaping @Sendable () -> Void) {
        node.task {
            operation()
        }
    }
}

@Model
private struct ChildTeardownModel {
    var starter: ParentTaskStarter?
    var ran: LockIsolated<Bool>

    init(starter: ParentTaskStarter? = nil, ran: LockIsolated<Bool> = LockIsolated(false)) {
        self.starter = starter
        self.ran = ran
    }

    func onActivate() {
        let starter = starter
        let ran = ran
        node.onCancel {
            starter?.start {
                ran.setValue(true)
            }
        }
    }
}

@Model
private struct ParentWithChildModel {
    var child: ChildTeardownModel?

    init(child: ChildTeardownModel) {
        self.child = child
    }

    // Parent activates before its child (verified elsewhere via the "PC0..."
    // activation-order logging convention), so by the time the child's
    // `onActivate()` snapshots `starter`, this write has already landed.
    func onActivate() {
        child?.starter = ParentTaskStarter(node: node)
    }

    func removeChild() {
        child = nil
    }
}
