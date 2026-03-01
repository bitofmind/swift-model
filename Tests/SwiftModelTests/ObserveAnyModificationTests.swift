import Testing
import AsyncAlgorithms
import Observation
@testable import SwiftModel

struct ObserveAnyModificationTests {

    // MARK: - Basic emission

    /// Mutating a property emits from observeAnyModification().
    @Test func testEmitsOnPropertyMutation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = TrackedModel().andTester {
                $0.testResult = testResult
            }

            await tester.assert {
                model.count == 0
            }

            model.count = 1

            await tester.assert {
                model.count == 1
                testResult.value.contains("modified")
            }

            return model
        }
        #expect(testResult.value.contains("modified"))
    }

    /// A single mutation emits exactly once.
    @Test func testSingleMutationEmitsOnce() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = TrackedModel().andTester {
                $0.testResult = testResult
            }

            await tester.assert {
                model.count == 0
            }

            model.count = 42

            await tester.assert {
                model.count == 42
                testResult.value.components(separatedBy: "modified").count - 1 == 1
            }

            return model
        }
    }

    /// Each individual mutation outside a transaction produces its own emission.
    @Test func testEachMutationEmitsSeparately() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = TrackedModel().andTester {
                $0.testResult = testResult
            }

            await tester.assert { model.count == 0 }

            model.count = 1
            model.count = 2
            model.count = 3

            await tester.assert {
                model.count == 3
                // Three separate mutations → three emissions
                testResult.value.components(separatedBy: "modified").count - 1 == 3
            }

            return model
        }
    }

    // MARK: - Descendant propagation

    /// Mutations in a child model are also visible from the parent's observeAnyModification().
    @Test func testEmitsForDescendantMutation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = ParentTrackedModel().andTester {
                $0.testResult = testResult
            }

            await tester.assert { model.child.count == 0 }

            model.child.count = 42

            await tester.assert {
                model.child.count == 42
                testResult.value.contains("parent-modified")
            }

            return model
        }
        #expect(testResult.value.contains("parent-modified"))
    }

    // MARK: - Stream lifetime

    /// The stream finishes when the model is deactivated (node goes out of scope).
    @Test func testStreamFinishesOnDeactivation() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = TrackedModel().andTester {
                $0.testResult = testResult
            }

            await tester.assert { model.count == 0 }
            return model
        }
        // After deactivation the stream should have finished — onCancel records "done"
        #expect(testResult.value.contains("done"))
    }

    // MARK: - Dirty-tracking pattern

    /// A typical dirty-tracking pattern: set a flag whenever anything changes.
    @Test func testDirtyTrackingPattern() async {
        let testResult = TestResult()
        await waitUntilRemoved {
            let (model, tester) = DirtyTrackingModel().andTester {
                $0.testResult = testResult
            }

            await tester.assert { !model.isDirty }

            model.value = "changed"

            await tester.assert {
                model.value == "changed"
                model.isDirty
            }

            return model
        }
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
