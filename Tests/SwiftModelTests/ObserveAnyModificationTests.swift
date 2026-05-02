import Testing
import AsyncAlgorithms
import Observation
@testable import SwiftModel
import SwiftModel

@Suite(.modelTesting)
struct ObserveModificationTests {

    // MARK: - Basic emission

    /// Mutating a property emits from observeModifications().
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

    /// Mutations in a child model are also visible from the parent's observeModifications().
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

    // MARK: - Scope filtering

    /// `scope: .self` — only this model's own changes trigger; child changes do not.
    @Test func testScopeSelfOnlyEmitsForSelf() async {
        let testResult = TestResult()
        let model = ScopeFilterModel(scope: .self).withAnchor {
            $0.testResult = testResult
        }

        await expect(model.value == 0)

        // Mutate the model itself — should emit
        model.value = 1

        await expect {
            model.value == 1
            testResult.value.contains("scope-hit")
        }

        let countBefore = testResult.value.components(separatedBy: "scope-hit").count

        // Mutate the child — should NOT emit for .self-scoped observer
        model.child.count = 99

        await expect(model.child.count == 99)

        // Give time for any unexpected emission
        let countAfter = testResult.value.components(separatedBy: "scope-hit").count
        #expect(countBefore == countAfter, "scope: .self should not fire for child mutations")
    }

    /// `scope: .children` — direct child changes trigger; self and grandchild changes do not.
    @Test func testScopeChildrenEmitsForDirectChildren() async {
        let testResult = TestResult()
        let model = ScopeFilterModel(scope: .children).withAnchor {
            $0.testResult = testResult
        }

        await expect(model.child.count == 0)

        // Mutate a direct child — should emit
        model.child.count = 10

        await expect {
            model.child.count == 10
            testResult.value.contains("scope-hit")
        }

        let countBefore = testResult.value.components(separatedBy: "scope-hit").count

        // Mutate self — should NOT emit for .children-scoped observer
        model.value = 5

        await expect(model.value == 5)

        let countAfter = testResult.value.components(separatedBy: "scope-hit").count
        #expect(countBefore == countAfter, "scope: .children should not fire for self mutations")
    }

    /// `scope: [.self, .descendants]` (default) — both self and all descendants trigger.
    @Test func testDefaultScopeEmitsSelfAndDescendants() async {
        let testResult = TestResult()
        let model = ParentTrackedModel().withAnchor {
            $0.testResult = testResult
        }

        model.value = 1
        await expect {
            model.value == 1
            testResult.value.contains("parent-modified")
        }

        model.child.count = 42
        await expect {
            model.child.count == 42
            testResult.value.components(separatedBy: "parent-modified").count - 1 == 2
        }
    }

    // MARK: - Kind filtering

    /// `kinds: .properties` — property changes emit; environment changes do not.
    @Test func testKindsPropertiesSkipsEnvironment() async {
        let testResult = TestResult()
        let model = KindFilterModel(kinds: .properties).withAnchor {
            $0.testResult = testResult
        }

        // Property change — should emit
        model.value = 1
        await expect {
            model.value == 1
            testResult.value.contains("kind-hit")
        }

        let countBefore = testResult.value.components(separatedBy: "kind-hit").count

        // Environment change — should NOT emit with kinds: .properties
        model.node.local.testEnvValue = "env-value"

        // Give time for any unexpected emission
        await expect(model.node.local.testEnvValue == "env-value")
        let countAfter = testResult.value.components(separatedBy: "kind-hit").count
        #expect(countBefore == countAfter, "kinds: .properties should not fire for environment changes")
    }

    /// `kinds: .environment` — environment changes emit; property changes do not.
    @Test func testKindsEnvironmentSkipsProperties() async {
        let testResult = TestResult()
        let model = KindFilterModel(kinds: .environment).withAnchor {
            $0.testResult = testResult
        }

        await expect(model.value == 0)

        let countBefore = testResult.value.components(separatedBy: "kind-hit").count

        // Property change — should NOT emit with kinds: .environment
        model.value = 1
        await expect(model.value == 1)

        let countAfterProp = testResult.value.components(separatedBy: "kind-hit").count
        #expect(countBefore == countAfterProp, "kinds: .environment should not fire for property changes")

        // Environment change — should emit
        model.node.local.testEnvValue = "env-value"
        await expect {
            model.node.local.testEnvValue == "env-value"
            testResult.value.contains("kind-hit")
        }
    }

    // MARK: - Model-type predicate

    /// `where:` predicate filters to the specified model type.
    @Test func testPredicateFiltersToModelType() async {
        let testResult = TestResult()
        let model = PredicateFilterModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.child.count == 0)

        // Mutation in the child (predicate accepts only ChildModel)
        model.child.count = 1
        await expect {
            model.child.count == 1
            testResult.value.contains("predicate-hit")
        }

        let countBefore = testResult.value.components(separatedBy: "predicate-hit").count

        // Mutation on the parent itself — predicate rejects ParentTrackedModel → no emit
        model.value = 99
        await expect(model.value == 99)
        let countAfter = testResult.value.components(separatedBy: "predicate-hit").count
        #expect(countBefore == countAfter, "predicate should filter out non-matching model type")
    }

    // MARK: - excludeFromModifications

    /// An excluded property does NOT trigger observeModifications() on an ancestor.
    @Test func testExcludedPropertyDoesNotTrigger() async {
        let testResult = TestResult()
        let model = ExclusionModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.important == 0)

        let countBefore = testResult.value.components(separatedBy: "exclude-hit").count

        // Mutate the excluded (volatile) property — should NOT trigger observer
        model.volatile = 42
        await expect(model.volatile == 42)

        let countAfterVolatile = testResult.value.components(separatedBy: "exclude-hit").count
        #expect(countBefore == countAfterVolatile, "excluded property should not trigger observeModifications()")

        // Mutate the non-excluded property — should trigger
        model.important = 7
        await expect {
            model.important == 7
            testResult.value.contains("exclude-hit")
        }
    }

    /// Excluded property on a child model does not trigger the parent's observeModifications().
    @Test func testExcludedPropertyOnChildDoesNotTriggerParent() async {
        let testResult = TestResult()
        let model = ExclusionParentModel().withAnchor {
            $0.testResult = testResult
        }

        await expect(model.child.important == 0)

        let countBefore = testResult.value.components(separatedBy: "parent-exclude-hit").count

        // Mutate the excluded property on child — should NOT trigger parent observer
        model.child.volatile = 99
        await expect(model.child.volatile == 99)

        let countAfter = testResult.value.components(separatedBy: "parent-exclude-hit").count
        #expect(countBefore == countAfter, "excluded child property should not trigger parent's observeModifications()")

        // Mutate non-excluded child property — should trigger parent observer
        model.child.important = 5
        await expect {
            model.child.important == 5
            testResult.value.contains("parent-exclude-hit")
        }
    }

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

/// A model that uses observeModifications() to log each change.
@Model private struct TrackedModel {
    var count: Int = 0

    func onActivate() {
        node.forEach(observeModifications()) { _ in
            node.testResult.add("modified")
        }
        node.onCancel {
            node.testResult.add("done")
        }
    }
}

/// A parent model that observes modifications across its child subtree.
@Model private struct ParentTrackedModel {
    var value: Int = 0
    var child: ChildModel = ChildModel()

    func onActivate() {
        node.forEach(observeModifications()) { _ in
            node.testResult.add("parent-modified")
        }
    }
}

/// A simple child model used in several tests.
@Model private struct ChildModel {
    var count: Int = 0
}

/// A model that observes with a configurable scope.
@Model private struct ScopeFilterModel {
    var value: Int = 0
    var child: ChildModel = ChildModel()
    @_ModelIgnored var scope: ModificationScope = [.self, .descendants]

    func onActivate() {
        node.forEach(observeModifications(scope: scope)) { _ in
            node.testResult.add("scope-hit")
        }
    }
}

/// A model that observes with a configurable kinds filter.
@Model private struct KindFilterModel {
    var value: Int = 0
    @_ModelIgnored var kinds: ModificationKind = .all

    func onActivate() {
        node.forEach(observeModifications(kinds: kinds)) { _ in
            node.testResult.add("kind-hit")
        }
    }
}

/// A model that filters via a `where:` predicate to only react to ChildModel changes.
@Model private struct PredicateFilterModel {
    var value: Int = 0
    var child: ChildModel = ChildModel()

    func onActivate() {
        node.forEach(observeModifications(where: { $0 is ChildModel })) { _ in
            node.testResult.add("predicate-hit")
        }
    }
}

/// A model that excludes a volatile property from observeModifications().
@Model private struct ExclusionModel {
    var important: Int = 0
    var volatile: Int = 0

    func onActivate() {
        node.excludeFromModifications(\.volatile)
        node.forEach(observeModifications()) { _ in
            node.testResult.add("exclude-hit")
        }
    }
}

/// A parent that observes modifications across its child; the child excludes a volatile property.
@Model private struct ExclusionParentModel {
    var child: ExclusionModel = ExclusionModel()

    func onActivate() {
        node.forEach(observeModifications()) { _ in
            node.testResult.add("parent-exclude-hit")
        }
    }
}

/// A model that uses observeModifications() for dirty tracking.
@Model private struct DirtyTrackingModel {
    var value: String = ""
    var isDirty: Bool = false

    func onActivate() {
        node.forEach(observeModifications()) { _ in
            isDirty = true
        }
    }
}

// MARK: - Environment key for testing

private extension LocalKeys {
    var testEnvValue: LocalStorage<String> { .init(defaultValue: "") }
}
