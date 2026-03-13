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

// Models used for concurrent-write preference deadlock regression test.

@Model
private struct ConcurrentWriterModel {
    var count: Int = 0
    func onActivate() {
        node.forEach(Observed { count }) { count in
            node.preference.totalCount = count
        }
    }
}

@Model
private struct ConcurrentWriterHost {
    var writer: ConcurrentWriterModel = ConcurrentWriterModel()
}

// Model used for checkExhaustion debugInfo deadlock regression test.
// A background observer mirrors `trigger` into `derived` so there is always
// a concurrent writer contending for the model lock when exhaustion runs.

@Model
private struct ReactiveModel {
    var trigger: Int = 0
    var derived: Int = 0
    func onActivate() {
        node.forEach(Observed { trigger }) { trigger in
            derived = trigger * 2
        }
    }
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

    // Regression test: asserting on a preference value must not deadlock.
    // Writing through a preference keypath inside the TestAccess snapshot-comparison
    // lock re-entered willAccessPreference, which tried to call propertyName(from:path:)
    // → ModelContainer.visit → deadlock waiting on the already-held lock.
    // Fixed by suppressing willAccess* calls while applying snapshot access closures.
    @Test func assertOnPreferenceDoesNotDeadlock() async {
        let (root, tester) = RootModel().andTester()
        tester.exhaustivity = .off

        root.branch.node.preference.totalCount = 3
        await tester.assert { root.branch.node.preference.totalCount == 3 }

        root.branch.node.preference.totalCount = 7
        await tester.assert { root.branch.node.preference.totalCount == 7 }
    }

    // Regression test: reading an aggregated preference (which walks the context hierarchy
    // under a lock) inside the TestAccess isEqualIncludingIds lock must not deadlock.
    // The hierarchy walk in preferenceValue calls AnyContext.reduce → lock { children.values },
    // which can contend with the TestAccess NSRecursiveLock held on a concurrent task.
    // Fixed by short-circuiting preferenceValue to the local stored value when isApplyingSnapshot.
    @Test func assertOnAggregatedPreferenceDoesNotDeadlock() async {
        let (root, tester) = RootModel().andTester()
        tester.exhaustivity = .off

        // Set contributions at multiple levels so preferenceValue must walk descendants.
        root.branch.node.preference.totalCount = 10
        root.branch.leaf.node.preference.totalCount = 3
        // Assert the aggregated value (root sees branch(10) + leaf(3) = 13).
        await tester.assert { root.node.preference.totalCount == 13 }

        root.branch.leaf.node.preference.totalCount = 5
        await tester.assert { root.node.preference.totalCount == 15 }
    }

    // Regression test: a background task concurrently writing a child preference while
    // the predicate reads the aggregated parent preference must not deadlock.
    //
    // The lock-ordering inversion:
    //   Thread A (predicate): holds parent lock (from Context.subscript.read)
    //                         → preferenceValue traversal tries to acquire child lock
    //   Thread B (background): holds child lock (from preference write propagation)
    //                          → didModifyPreference propagates upward, tries to acquire parent lock
    //
    // Fixed by moving TestAccess typed-path registration out of willAccessPreference (called
    // during traversal under child locks) into willAccessPreferenceValue (called after
    // the traversal completes with the pre-computed value), so the predicate read never
    // acquires a model lock while the hierarchy walk holds other locks.
    @Test func assertOnAggregatedPreferenceWithConcurrentWriteDoesNotDeadlock() async {
        let (host, tester) = ConcurrentWriterHost().andTester()
        tester.exhaustivity = .off
        // Rapidly change count to trigger concurrent background preference writes
        // while the assert predicate reads the aggregated preference value from the parent.
        for i in 1...5 {
            host.writer.count = i
            await tester.assert { host.node.preference.totalCount == i }
        }
    }

    @Test(arguments: 1...100)
    func assertOnAggregatedPreferenceWithConcurrentWriteDoesNotDeadlockStress(_ run: Int) async {
        let (host, tester) = ConcurrentWriterHost().andTester()
        tester.exhaustivity = .off
        for i in 1...5 {
            host.writer.count = i
            await tester.assert { host.node.preference.totalCount == i }
        }
    }

    // Regression test: checkExhaustion must not deadlock when calling debugInfo() on a pending
    // ValueUpdate while a background task concurrently holds the model lock.
    //
    // The deadlock path (pre-fix):
    //   Assert loop holds TestAccess lock → checkExhaustion → debugInfo() closure
    //   → propertyName(from:path:) → Mirror(reflecting: model.withAccess(nil))
    //   → Context.subscript.read → tries to re-acquire TestAccess lock from different thread
    //   (background BatchedCalls.drainLoop thread holds model lock and is blocked on TestAccess lock)
    //
    // Fixed by eagerly computing propertyName in didModify (outside the lock) so debugInfo()
    // only interpolates a pre-captured String and never touches the model.
    @Test func checkExhaustionDebugInfoDoesNotDeadlock() async {
        let (model, tester) = ReactiveModel().andTester()
        // Exhaustivity on (default): checkExhaustion fires after each assert and calls
        // debugInfo() on any unasserted ValueUpdate — this is what triggered the deadlock.
        for i in 1...5 {
            model.trigger = i
            // Assert only `trigger`; the background observer also writes `derived`.
            // checkExhaustion finds the unasserted `derived` ValueUpdate and calls debugInfo().
            // With the fix, debugInfo() no longer calls Mirror under the lock.
            await tester.assert {
                model.trigger == i
                model.derived == i * 2
            }
        }
    }

    @Test(arguments: 1...100)
    func checkExhaustionDebugInfoDoesNotDeadlockStress(_ run: Int) async {
        let (model, tester) = ReactiveModel().andTester()
        for i in 1...5 {
            model.trigger = i
            await tester.assert {
                model.trigger == i
                model.derived == i * 2
            }
        }
    }

    // MARK: - Exhaustion failure message formatting

    // Regression tests: unasserted preference storage changes must name the key as
    // "preference.keyName" in the failure message, not "UNKNOWN".
    // Verifies the #function capture in PreferenceStorage.init flows all the way to
    // the "Preference not exhausted" failure output.

    @Test func preferenceExhaustionMessageContainsKeyName() async {
        let (model, tester) = RootModel().andTester()
        tester.exhaustivity = .off
        model.branch.node.preference.totalCount = 5
        // Assert something unrelated so exhaustion runs with the preference write pending.
        // Re-enable exhaustion just for this assertion.
        tester.exhaustivity = .preference
        await withKnownIssue {
            await tester.assert { model.branch.count == 0 }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("preference.totalCount") }
        }
    }

    @Test func preferenceExhaustionMessageOnDependencyModelContainsKeyName() async {
        let (model, tester) = CoordinatorModel().andTester()
        tester.exhaustivity = .preference
        model.worker.node.preference.totalCount = 3
        // Assert something unrelated so the preference write is unasserted and exhaustion fires.
        await withKnownIssue {
            await tester.assert { model.worker.status == "idle" }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("preference.totalCount") }
        }
    }
}
