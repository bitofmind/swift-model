import Testing
import Observation
@testable import SwiftModel
import SwiftModel

struct UniquelyReferencedTests {

    // MARK: - isUniquelyReferenced (sync property)

    /// A model with a single parent is uniquely referenced.
    @Test func testIsUniquelyReferencedWithSingleParent() async {
        await withModelTesting {
            let model = SingleOwnerModel().withAnchor()
            // The child has only one parent (the root), so it is uniquely referenced.
            await expect(model.child.node.isUniquelyReferenced)
        }
    }

    /// A model referenced from two places is NOT uniquely referenced.
    @Test func testIsNotUniquelyReferencedWhenShared() async {
        await withModelTesting {
            let model = SharedOwnerModel().withAnchor()
            // Share the child by placing it in both `primary` and `secondary`
            model.secondary = model.primary

            await expect {
                model.secondary != nil
                !model.primary.node.isUniquelyReferenced
                !model.secondary!.node.isUniquelyReferenced
            }
        }
    }

    // MARK: - uniquelyReferenced() stream

    /// The stream emits `true` initially when there is only one owner.
    @Test func testUniquelyReferencedStreamEmitsTrueInitially() async {
        let testResult = TestResult()
        await withModelTesting {
            let _ = WatchedChildHost().withAnchor {
                $0.testResult = testResult
            }
            // Initial emission: child is uniquely referenced
            await expect(testResult.value.contains("unique:true"))
        }
    }

    /// When the same model instance is added to a second owner, the stream emits `false`.
    @Test func testUniquelyReferencedStreamEmitsFalseWhenShared() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = WatchedChildHost().withAnchor {
                $0.testResult = testResult
            }
            await expect(testResult.value.contains("unique:true"))

            // Share the child by adding it to the secondary slot
            model.secondary = model.primary

            await expect {
                model.secondary != nil
                testResult.value.contains("unique:false")
            }
        }
    }

    /// When sharing is removed, the stream emits `true` again.
    @Test func testUniquelyReferencedStreamEmitsTrueAfterSharingRemoved() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = WatchedChildHost().withAnchor {
                $0.testResult = testResult
            }
            await expect(testResult.value.contains("unique:true"))

            // Share the child
            model.secondary = model.primary

            await expect {
                model.secondary != nil
                testResult.value.contains("unique:false")
            }

            // Un-share: remove from secondary
            model.secondary = nil

            await expect {
                model.secondary == nil
                // The last emission should be true again
                testResult.value.hasSuffix("unique:true")
            }
        }
    }

    /// Consecutive duplicate values are NOT re-emitted (stream deduplicates).
    @Test func testUniquelyReferencedStreamDeduplicates() async {
        let testResult = TestResult()
        await withModelTesting(exhaustivity: .off) {
            let model = WatchedChildHost().withAnchor {
                $0.testResult = testResult
            }
            await expect(testResult.value.contains("unique:true"))

            // Mutate an unrelated property — uniqueness doesn't change
            model.unrelated += 1
            model.unrelated += 1

            await expect {
                model.unrelated == 2
                // No extra "unique:true" emission — still exactly one
                testResult.value.components(separatedBy: "unique:true").count - 1 == 1
            }
        }
    }
}

// MARK: - Supporting models

@Model private struct ChildModel {}

@Model private struct SingleOwnerModel {
    var child: ChildModel = ChildModel()
}

@Model private struct SharedOwnerModel {
    var primary: ChildModel = ChildModel()
    var secondary: ChildModel? = nil
}

/// A host that tracks `uniquelyReferenced()` emissions from its child into `testResult`.
@Model private struct WatchedChildHost {
    var primary: ChildModel = ChildModel()
    var secondary: ChildModel? = nil
    var unrelated: Int = 0

    func onActivate() {
        node.forEach(primary.node.uniquelyReferenced()) { isUnique in
            node.testResult.add("unique:\(isUnique)")
        }
    }
}
