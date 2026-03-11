import Testing
import ConcurrencyExtras
import Observation
import Dependencies
@testable import SwiftModel

// MARK: - Keys

private extension PreferenceKeys {
    /// Sum of integer contributions from self and all descendants.
    var totalCount: PreferenceStorage<Int> {
        .init(defaultValue: 0, key: "totalCount") { $0 += $1 }
    }

    /// Collects string tags from self and all descendants.
    var tags: PreferenceStorage<[String]> {
        .init(defaultValue: [], key: "tags") { $0 += $1 }
    }

    /// Boolean "any active" flag — true if any descendant contributes true.
    var anyActive: PreferenceStorage<Bool> {
        .init(defaultValue: false, key: "anyActive") { $0 = $0 || $1 }
    }
}

// MARK: - Models

@Model
private struct LeafModel {
    var label: String = "leaf"
}

@Model
private struct BranchModel {
    var leaf: LeafModel = LeafModel()
    var count: Int = 0
}

@Model
private struct RootModel {
    var branch: BranchModel = BranchModel()
}

// Models used for dependency preference exhaustivity tests.

@Model
private struct WorkerModel {
    var status: String = "idle"
}

extension WorkerModel: DependencyKey {
    static let liveValue = WorkerModel()
    static let testValue = WorkerModel()
}

@Model
private struct CoordinatorModel {
    @ModelDependency var worker: WorkerModel
}

// MARK: - PreferenceStorageTests

struct PreferenceStorageTests {

    // MARK: - Basic read/write

    @Test func defaultValue() {
        let model = LeafModel().withAnchor()
        #expect(model.node.preference.totalCount == 0)
    }

    @Test func writeSelf() {
        let model = LeafModel().withAnchor()
        model.node.preference.totalCount = 5
        #expect(model.node.preference.totalCount == 5)
    }

    @Test func writeDoesNotAffectParent() {
        let parent = BranchModel().withAnchor()
        parent.leaf.node.preference.totalCount = 7
        // Parent should aggregate: includes self (0) + leaf (7) = 7
        #expect(parent.node.preference.totalCount == 7)
    }

    // MARK: - Bottom-up aggregation

    @Test func aggregatesDescendants() {
        let root = RootModel().withAnchor()
        root.branch.leaf.node.preference.totalCount = 3
        root.branch.node.preference.totalCount = 10

        // root aggregate: root(0) + branch(10) + leaf(3) = 13
        #expect(root.node.preference.totalCount == 13)
        // branch aggregate: branch(10) + leaf(3) = 13
        #expect(root.branch.node.preference.totalCount == 13)
        // leaf aggregate: leaf(3) only
        #expect(root.branch.leaf.node.preference.totalCount == 3)
    }

    @Test func aggregatesWithNoContributions() {
        let root = RootModel().withAnchor()
        // No one has written — should return defaultValue everywhere
        #expect(root.node.preference.totalCount == 0)
        #expect(root.branch.node.preference.totalCount == 0)
        #expect(root.branch.leaf.node.preference.totalCount == 0)
    }

    @Test func aggregatesMultipleContributions() {
        let root = RootModel().withAnchor()
        root.node.preference.totalCount = 1
        root.branch.node.preference.totalCount = 2
        root.branch.leaf.node.preference.totalCount = 4

        #expect(root.node.preference.totalCount == 7)
    }

    @Test func collectTags() {
        let root = RootModel().withAnchor()
        root.node.preference.tags = ["root"]
        root.branch.node.preference.tags = ["branch"]
        root.branch.leaf.node.preference.tags = ["leaf"]

        #expect(root.node.preference.tags.sorted() == ["branch", "leaf", "root"])
        #expect(root.branch.node.preference.tags.sorted() == ["branch", "leaf"])
        #expect(root.branch.leaf.node.preference.tags == ["leaf"])
    }

    @Test func anyActivePropagates() {
        let root = RootModel().withAnchor()
        #expect(root.node.preference.anyActive == false)

        root.branch.leaf.node.preference.anyActive = true
        #expect(root.node.preference.anyActive == true)
        #expect(root.branch.node.preference.anyActive == true)
        #expect(root.branch.leaf.node.preference.anyActive == true)
    }

    // MARK: - Preference does not flow downward

    @Test func preferenceDoesNotFlowDownward() {
        let root = RootModel().withAnchor()
        root.node.preference.totalCount = 99

        // The leaf should only see its own contribution (0), not the ancestor's
        #expect(root.branch.leaf.node.preference.totalCount == 0)
    }

    // MARK: - Remove preference contribution

    @Test func removeContributionFallsBackToDefault() {
        let model = LeafModel().withAnchor()
        model.node.preference.totalCount = 5
        #expect(model.node.preference.totalCount == 5)

        model.node.removePreference(\.totalCount)
        #expect(model.node.preference.totalCount == 0)
    }

    @Test func removeContributionReducesAncestorAggregate() {
        let parent = BranchModel().withAnchor()
        parent.node.preference.totalCount = 10
        parent.leaf.node.preference.totalCount = 5
        #expect(parent.node.preference.totalCount == 15)

        parent.leaf.node.removePreference(\.totalCount)
        #expect(parent.node.preference.totalCount == 10)
    }

    @Test func removeOnNodeWithNoContributionIsNoop() {
        let model = LeafModel().withAnchor()
        model.node.removePreference(\.totalCount)
        #expect(model.node.preference.totalCount == 0)
    }

    // MARK: - Observation

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func childWriteNotifiesAncestorObserver(path: ObservationPath) async throws {
        let root = RootModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.node.preference.totalCount
        }

        let values = LockIsolated<[Int]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == 0)

        // Child writes contribution — root aggregate should update
        root.branch.leaf.node.preference.totalCount = 7
        try await waitUntil(values.value.contains(7), timeout: 3_000_000_000)
        #expect(values.value.contains(7), "[\(path)] Child write should notify ancestor observer, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func selfWriteNotifiesSelfObserver(path: ObservationPath) async throws {
        let model = LeafModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.preference.totalCount
        }

        let values = LockIsolated<[Int]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == 0)

        model.node.preference.totalCount = 42
        try await waitUntil(values.value.contains(42), timeout: 3_000_000_000)
        #expect(values.value.contains(42), "[\(path)] Self write should notify self observer, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func removeNotifiesAncestorObserver(path: ObservationPath) async throws {
        let root = RootModel().withAnchor(options: path.options)
        root.branch.leaf.node.preference.totalCount = 5

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.node.preference.totalCount
        }

        let values = LockIsolated<[Int]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.contains(5))

        root.branch.leaf.node.removePreference(\.totalCount)
        try await waitUntil(values.value.contains(0), timeout: 3_000_000_000)
        #expect(values.value.contains(0), "[\(path)] Remove should notify ancestor observer, got \(values.value)")
    }

    // MARK: - tester.assert integration

    @Test func testerAssertPreference() async {
        let (model, tester) = LeafModel().andTester()
        model.node.preference.totalCount = 5
        await tester.assert { model.node.preference.totalCount == 5 }
    }

    @Test func testerAssertAggregatedPreference() async {
        let (model, tester) = BranchModel().andTester()
        model.node.preference.totalCount = 10
        model.leaf.node.preference.totalCount = 3
        await tester.assert {
            model.node.preference.totalCount == 13 &&
            model.leaf.node.preference.totalCount == 3
        }
    }

    @Test func testerAssertRemovePreference() async {
        let (model, tester) = LeafModel().andTester()
        model.node.preference.totalCount = 5
        await tester.assert { model.node.preference.totalCount == 5 }
        model.node.removePreference(\.totalCount)
        await tester.assert { model.node.preference.totalCount == 0 }
    }

    // MARK: - .preference exhaustivity option

    @Test func preferenceExhaustivityIsSeparateFromState() async {
        // With only .state exhaustivity (no .preference), unasserted preference writes should NOT fail.
        let (model, tester) = LeafModel().andTester()
        tester.exhaustivity = .state

        // Write preference without asserting it.
        model.node.preference.totalCount = 5

        // Write a regular property and assert only it — exhaustion check runs but should
        // NOT complain about the unasserted preference write.
        model.label = "updated"
        await tester.assert { model.label == "updated" }
    }

    @Test func preferenceExhaustivityCatchesUnassertedWrites() async {
        // With .preference in exhaustivity, unasserted preference writes SHOULD be caught.
        let (model, tester) = LeafModel().andTester()
        tester.exhaustivity = .preference

        model.node.preference.totalCount = 5
        // Assert something unrelated — exhaustion should report "Preference not exhausted".
        await withKnownIssue {
            await tester.assert { model.label == "leaf" }
        }
    }

    @Test func stateExhaustivityDoesNotCoverPreference() async {
        // With only .preference exhaustivity (no .state), unasserted state changes should NOT fail.
        let (model, tester) = LeafModel().andTester()
        tester.exhaustivity = .preference

        // Write a regular property without asserting it.
        model.label = "changed"

        // Assert preference (unchanged) — exhaustion should NOT complain about unasserted state.
        await tester.assert { model.node.preference.totalCount == 0 }
    }

    @Test func fullExhaustivityCatchesPreference() async {
        // .full includes .preference, so an unasserted preference write is caught.
        let (model, tester) = LeafModel().andTester()
        tester.exhaustivity = .full

        model.node.preference.totalCount = 5
        await withKnownIssue {
            await tester.assert { model.label == "leaf" }
        }
    }

    // MARK: - Preference exhaustivity via dependency models

    @Test func preferenceOnDependencyModelIsAssertable() async {
        let (model, tester) = CoordinatorModel().andTester()
        model.worker.node.preference.totalCount = 3
        await tester.assert { model.worker.node.preference.totalCount == 3 }
    }

    @Test func unassertedPreferenceOnDependencyModelIsCaught() async {
        let (model, tester) = CoordinatorModel().andTester()
        tester.exhaustivity = .preference
        model.worker.node.preference.totalCount = 3
        await withKnownIssue {
            await tester.assert { model.worker.status == "idle" }
        }
    }

    @Test func preferenceOnDependencyModelSeparateFromState() async {
        let (model, tester) = CoordinatorModel().andTester()
        tester.exhaustivity = .state
        model.worker.node.preference.totalCount = 3
        model.worker.status = "running"
        await tester.assert { model.worker.status == "running" }
    }
}
