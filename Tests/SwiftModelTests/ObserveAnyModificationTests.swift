import Testing
import AsyncAlgorithms
import Observation
@testable import SwiftModel
import SwiftModelTesting

@Suite(.modelTesting)
struct ObserveAnyModificationTests {

    // MARK: - Basic emission

    /// Mutating a property emits from observeAnyModification().
    @Test func testEmitsOnPropertyMutation() async {
        let testResult = TestResult()
        let model = TrackedModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.count == 0)

        model.count = 1

        await expect {
            model.count == 1
            testResult.value.contains("modified")
        }
    }

    /// A single mutation emits exactly once.
    @Test func testSingleMutationEmitsOnce() async {
        let testResult = TestResult()
        let model = TrackedModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.count == 0)

        model.count = 42

        await expect {
            model.count == 42
            testResult.value.components(separatedBy: "modified").count - 1 == 1
        }
    }

    /// Each individual mutation outside a transaction produces its own emission.
    @Test func testEachMutationEmitsSeparately() async {
        let testResult = TestResult()
        let model = TrackedModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.count == 0)

        model.count = 1
        model.count = 2
        model.count = 3

        await expect {
            model.count == 3
            // Three separate mutations → three emissions
            testResult.value.components(separatedBy: "modified").count - 1 == 3
        }
    }

    // MARK: - Descendant propagation

    /// Mutations in a child model are also visible from the parent's observeAnyModification().
    @Test func testEmitsForDescendantMutation() async {
        let testResult = TestResult()
        let model = ParentTrackedModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.child.count == 0)

        model.child.count = 42

        await expect {
            model.child.count == 42
            testResult.value.contains("parent-modified")
        }
    }

    // MARK: - Stream lifetime

    // Note: testStreamFinishesOnDeactivation is in a separate struct below because it
    // requires actual model deallocation (to test stream termination on deactivation),
    // which is incompatible with @Suite(.modelTesting) — the suite scope holds a strong
    // reference to the context for the full test duration, preventing deallocation.

    // MARK: - Dirty-tracking pattern

    /// A typical dirty-tracking pattern: set a flag whenever anything changes.
    @Test func testDirtyTrackingPattern() async {
        let testResult = TestResult()
        let model = DirtyTrackingModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(!model.isDirty)

        model.value = "changed"

        await expect {
            model.value == "changed"
            model.isDirty
        }
    }
}

// MARK: - Stream lifetime (separate struct — requires actual deallocation)

/// These tests verify stream lifetime and deactivation behavior.
/// They use `withModelTesting` (not `@Suite(.modelTesting)`) because the scope must tear
/// down the model before the test returns, allowing post-scope assertions on lifecycle state.
struct ObserveAnyModificationLifetimeTests {

    /// The stream finishes when the model is deactivated (node goes out of scope).
    @Test func testStreamFinishesOnDeactivation() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = TrackedModel().withAnchor {
                $0.testResult = testResult
            }
            await expect(model.count == 0)
        }
        // After deactivation the stream should have finished — onCancel records "done"
        #expect(testResult.value.contains("done"))
    }
}

// MARK: - Supporting models

/// A model that uses observeAnyModification() to log each change.
@Model private struct TrackedModel {
    var count: Int = 0

    func onActivate() {
        node.forEach(observeAnyModification()) { _ in
            node.testResult.add("modified")
        }
        node.onCancel {
            node.testResult.add("done")
        }
    }
}

/// A parent model that observes modifications across its child subtree.
@Model private struct ParentTrackedModel {
    var child: TrackedModel = TrackedModel()

    func onActivate() {
        node.forEach(observeAnyModification()) { _ in
            node.testResult.add("parent-modified")
        }
    }
}

/// A model that uses observeAnyModification() for dirty tracking.
@Model private struct DirtyTrackingModel {
    var value: String = ""
    var isDirty: Bool = false

    func onActivate() {
        node.forEach(observeAnyModification()) { _ in
            isDirty = true
        }
    }
}
