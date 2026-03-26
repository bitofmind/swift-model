import Testing
@testable import SwiftModel
import SwiftModel
import Observation

@Suite(.modelTesting)
struct UpdateStreamTests {
    @Test(arguments: ObservationPath.allCases)
    func testChangeOf(observationPath: ObservationPath) async throws {
        let model = observationPath.withOptions { ValuesModel(initial: false, recursive: false).withAnchor() }

        model.count += 5
        await expect {
            model.count == 5
            model.counts == [5]
        }

        model.count += 3
        await expect {
            model.count == 8
            model.counts == [5, 8]
        }
    }

    @Test(arguments: ObservationPath.allCases)
    func testChangeOfConcurrency(observationPath: ObservationPath) async throws {
        let model = observationPath.withOptions { ValuesModel(initial: false, recursive: false).withAnchor() }

        let range = 1...10
        await Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in range {
                    group.addTask {
                        model.count += 1
                    }
                }
                
                await group.waitForAll()
            }
        }.value

        // Give time for background observation callbacks to process
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        await expect {
            model.count == range.count
            model.counts.count > 0
            model.counts == model.counts.sorted()
            model.counts.last == range.count
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testChangeOfChild(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { ValuesModel(child: ChildModel(count: 2), initial: true, recursive: false).withAnchor() }

        await expect {
            model.child.count == 2
            model.childCounts == [2]
            model.counts == [0]
            model.optChildCounts == [nil]
        }

        model.child.count += 5
        await expect {
            model.child.count == 7
            model.childCounts == [2, 7]
        }

        model.child.count += 3
        await expect {
            model.child.count == 10
            model.childCounts == [2, 7, 10]
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testChangeOfChildWhereChildIsUpdated(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { ValuesModel(child: ChildModel(count: 2), initial: true, recursive: false).withAnchor() }

        await expect {
            model.child.count == 2
            model.childCounts == [2]
            model.counts == [0]
            model.optChildCounts == [nil]
        }

        model.child = ChildModel(count: 4)
        await expect {
            model.child.count == 4
            model.childCounts == [2, 4]
        }
    }

    @Test
    func testChangeOfChildConcurrency() async throws {
        let model = ValuesModel(child: ChildModel(count: 0), initial: false, recursive: false).withAnchor()

        let range = 1...10
        await Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for _ in range {
                    group.addTask {
                        model.transaction {
                            model.child = ChildModel(count: model.child.count + 1)
                        }
                    }
                }

                await group.waitForAll()
            }
        }.value

        // Give time for background observation callbacks to process
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        await expect {
            model.child.count == range.count
            model.childCounts.count > 0
            model.childCounts == model.childCounts.sorted()
            model.childCounts.last == range.count
        }
    }

    @Test func testChangeOfOptChildWhereChildIsUpdated() async throws {
        let model = ValuesModel(initial: false, recursive: false).withAnchor()

        model.optChild = ChildModel(count: 4)
        await expect {
            model.optChild?.count == 4
            model.optChildCounts == [4]
        }

        model.optChild = nil
        await expect {
            model.optChild?.count == nil
            model.optChildCounts == [4, nil]
        }

        model.optChild = ChildModel(count: 7)
        await expect {
            model.optChild?.count == 7
            model.optChildCounts == [4, nil, 7]
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testRace() async throws {
        let model = RaceModel().withAnchor()

        Task {
            model.count = 7
        }

        model.collectCounts()

        await expect {
            model.counts.last == 7
            model.count == 7
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testRaceVariant() async throws {
        let model = RaceModel().withAnchor()

        Task {
            model.count = 7
        }

        Task {
            model.collectCounts()
        }
        
        await expect {
            model.counts.last == 7
            model.count == 7
        }
    }

    @Test func testRecursiveChild() async throws {
        let model = ValuesModel(initial: false, recursive: true).withAnchor()

        await expect {
            model.child.count == 0
            model.childChanges == []
        }

        model.child.count += 1

        await expect {
            model.child.count == 1
            model.childCounts == [1]
            model.childChanges == [1]
        }

        model.child.count += 5

        await expect {
            model.child.count == 6
            model.childCounts == [1, 6]
            model.childChanges == [1, 6]
        }
    }

    @Test func testRecursiveOptChild() async throws {
        let model = ValuesModel(initial: false, recursive: true).withAnchor()

        await expect {
            model.optChild == nil
            model.opChildChanges == []
        }

        model.optChild = ChildModel(count: 5)

        await expect {
            model.optChild?.count == 5
            model.optChildCounts == [5]
            model.opChildChanges == [5]
        }

        model.optChild?.count += 1

        await expect {
            model.optChild?.count == 6
            model.optChildCounts == [5, 6]
            model.opChildChanges == [5, 6]
        }

        model.optChild = nil

        await expect {
            model.optChild == nil
            model.optChildCounts == [5, 6, nil]
            model.opChildChanges == [5, 6, nil]
        }
    }

    @Test func testRecursiveChildren() async throws {
        let model = ValuesModel(initial: false, recursive: true).withAnchor()

        await expect(model.childrenCounts == [])

        model.children.append(ChildModel(count: 5))

        await expect {
            model.children.count == 1
            model.childrenCounts == [[5]]
        }

        model.children[0].count += 1

        await expect {
            model.children[0].count == 6
            model.childrenCounts == [[5], [6]]
        }

        model.children.append(ChildModel(count: 10))

        await expect {
            model.children.count == 2
            model.childrenCounts == [[5], [6], [6, 10]]
        }

        model.children.remove(at: 0)

        await expect {
            model.children.count == 1
            model.childrenCounts == [[5], [6], [6, 10], [10]]
        }

        model.children.removeAll()

        await expect {
            model.children.count == 0
            model.childrenCounts == [[5], [6], [6, 10], [10], []]
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testComputed() async throws {
        let model = ComputedModel().withAnchor()

        model.count1 = 7
        model.count2 = 4

        await expect {
            model.computes == [3, 9, 11]
            model.squareds == [1, 49]
            model.count1 == 7
            model.count2 == 4
        }
    }

    @Test(.modelTesting(exhaustivity: .off))
    func testNestedComputed() async throws {
        let model = NestedComputedModel().withAnchor()

        model.computed = ComputedModel(count1: 4, count2: 8)
        model.computed?.count1 = 5
        model.computed = ComputedModel()
        model.computed?.count2 = 5
        model.computed = nil

        await expect {
            model.computes == [nil, 12, 13, 3, 6, nil]
            model.squareds == [nil, 16, 25, 1, nil]
        }
    }

    @Test(.modelTesting(exhaustivity: .full.subtracting(.tasks)))
    func testMemoize() async throws {
        let model = withModelOptions([.disableMemoizeCoalescing]) { ComputedModel().withAnchor() }

        #expect(model.memoizeComputed == 3)
        #expect(model.memoizeSquared == 1)

        model.count1 = 7
        #expect(model.memoizeComputed == 9)
        #expect(model.memoizeSquared == 49)

        model.count2 = 4
        #expect(model.memoizeComputed == 11)
        #expect(model.memoizeSquared == 49)

        await expect {
            model.computes == [3, 9, 11]
            model.squareds == [1, 49]
            model.count1 == 7
            model.count2 == 4
        }
    }

    // MARK: - Returning model structs directly from Observed closure

    /// Observed { child } (returns model struct, not a property read) should fire when any
    /// property of child changes, using onAnyModification as the subscription fallback.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturningChildModelDirectly(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { ReturnModelModel().withAnchor() }

        await expect { model.childSnapshots.count == 1 }

        model.child.count = 5
        await expect { model.childSnapshots.last?.count == 5 }

        model.child.count = 10
        await expect { model.childSnapshots.last?.count == 10 }
    }

    /// Observed { observed } — property changes on the returned model do NOT trigger; only
    /// replacing the model (writing to the parent property) fires a new emission.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturningSelf(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { SelfObserverParent().withAnchor() }

        await expect { model.observedCounts.count == 1 }

        // Property change does NOT trigger re-emission
        model.observed.count = 7
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.observedCounts.count == 1, "Property change on returned model should not trigger")

        // Model replacement DOES trigger (new identity)
        model.observed = SelfObservingModel()
        await expect { model.observedCounts.count == 2 }
        #expect(model.observedCounts.last == 0)
    }

    /// Observed { (a, b) } — property changes on the returned models do NOT trigger; only
    /// replacing a model (writing to the parent property) fires a new emission.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturningTupleOfModels(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { TupleObserverModel().withAnchor() }

        await expect { model.snapshots.count == 1 }

        // Property changes do NOT trigger re-emission
        model.a.count = 3
        model.b.count = 7
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshots.count == 1, "Property changes should not trigger Observed { (a, b) }")

        // Replacing a triggers; the snapshot captures current counts of both models
        model.a = ChildModel()
        await expect { model.snapshots.count == 2 }
        // b.count is 7 (mutated above but not yet snapshotted until the replacement fires)
        #expect(model.snapshots.last?.1 == 7)
    }

    /// Observed { optionalChild } — identity transitions (nil→Some, Some→nil, Some→other Some)
    /// trigger re-emission; property changes on the wrapped model do NOT.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturningOptionalModel(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { OptionalObserverModel().withAnchor() }

        // nil → Some triggers (different identity)
        model.child = ChildModel()
        await expect { model.observedCounts.last == 0 }

        // Property change does NOT trigger
        model.child!.count = 5
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.observedCounts.count == 1, "Property change should not trigger Observed { child }")

        // Some → nil triggers (different identity)
        model.child = nil
        await expect { model.observedCounts.last == -1 }
    }

    /// Observed { children } — property changes on array elements do NOT trigger; adding or
    /// removing elements (changing array composition) DOES trigger.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturningArrayOfModels(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { ArrayObserverModel().withAnchor() }

        // Initial: 2 children
        await expect { model.snapshots.count == 1 }

        // Property changes do NOT trigger
        model.children[0].count = 10
        model.children[1].count = 20
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshots.count == 1, "Property changes on array elements should not trigger")

        // Adding a new element changes array composition — triggers
        model.children.append(ChildModel())
        await expect { model.snapshots.count == 2 }
        // Snapshot captures current counts: [10, 20, 0]
        #expect(model.snapshots.last?.count == 3)
    }

    /// Observed { child } only fires when the child model is replaced (different identity);
    /// neither direct property changes nor descendant changes trigger re-evaluation.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturnedModelIgnoresDescendantChanges(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { DescendantObserverModel().withAnchor() }

        await expect { model.snapshots.count == 1 }

        // Direct property change on returned model does NOT trigger
        model.child.direct = 5
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshots.count == 1, "Direct property change should not trigger Observed { child }")

        // Descendant (grandchild) change also does NOT trigger
        model.child.grandchild.value = 42
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshots.count == 1, "Descendant change should not trigger Observed { child }")

        // Model replacement DOES trigger (new identity)
        model.child = DeepChildModel()
        await expect { model.snapshots.count == 2 }
    }

    /// Observed { active } fires when the identity of the returned model changes (swap);
    /// property changes on the currently active model do NOT trigger.
    @Test(.modelTesting(exhaustivity: .off), arguments: UpdatePath.allCases)
    func testObservedReturningSwappedModel(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { SwapObserverModel().withAnchor() }

        await expect { model.snapshots.count == 1 }
        #expect(model.snapshots.last == 0)

        // Property change does NOT trigger
        model.active.count = 5
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshots.count == 1, "Property change on active should not trigger")

        // Swap to a different model DOES trigger (new identity returned by closure)
        model.useSecond = true
        await expect { model.snapshots.count == 2 }
        #expect(model.snapshots.last == 0)

        // Property change on new active also does NOT trigger
        model.active.count = 9
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshots.count == 2, "Property change on new active should not trigger")
    }
}

/// Observes a child model returned directly (not via property read) from the Observed closure.
@Model private struct ReturnModelModel {
    var child = ChildModel()
    var childSnapshots: [ChildModel] = []

    func onActivate() {
        node.forEach(Observed(initial: true) { child }) { snap in
            childSnapshots.append(snap)
        }
    }
}

/// A simple observable model used as the child in self-observation tests.
@Model private struct SelfObservingModel {
    var count = 0
}

/// A parent model that observes its child by returning it directly from the Observed closure
/// (equivalent to `Observed { self }` but from outside, avoiding self-modification loops).
@Model private struct SelfObserverParent {
    var observed = SelfObservingModel()
    var observedCounts: [Int] = []

    func onActivate() {
        node.forEach(Observed(initial: true) { observed }) { snap in
            observedCounts.append(snap.count)
        }
    }
}

@Model private struct ValuesModel {
    var count = 0
    var counts: [Int] = []
    var childCounts: [Int] = []
    var childChanges: [Int] = []
    var optChildCounts: [Int?] = []
    var opChildChanges: [Int?] = []
    var child = ChildModel()
    var optChild: ChildModel? = nil
    var children: [ChildModel] = []
    var childrenCounts: [[Int]] = []
    let initial: Bool
    let recursive: Bool

    func onActivate() {
        node.forEach(Observed(initial: initial, coalesceUpdates: false) { count }) { count in
            counts.append(count)
        }

        node.forEach(Observed(initial: initial, coalesceUpdates: false) { child.count }) { count in
            childCounts.append(count)
        }

        if recursive {
            node.forEach(Observed(initial: initial, coalesceUpdates: false) { child.count }) { count in
                childChanges.append(count)
            }

            node.forEach(Observed(initial: initial, coalesceUpdates: false) { optChild?.count }) { count in
                opChildChanges.append(count)
            }

            node.forEach(Observed(initial: initial, coalesceUpdates: false) { children.map(\.count) }) { counts in
                childrenCounts.append(counts)
            }
        }

        node.forEach(Observed(initial: initial, coalesceUpdates: false) { optChild?.count }) { count in
            optChildCounts.append(count)
        }
    }
}

@Model private struct ChildModel: Equatable {
    var count: Int = 0
}

@Model private struct RaceModel {
    var count: Int = 0
    var counts: [Int] = []

    func collectCounts() {
        node.forEach(Observed(coalesceUpdates: false) { count }) { count in
            counts.append(count)
        }
    }
}

@Model private struct ComputedModel: Equatable {
    var count1: Int = 1
    var count2: Int = 2
    var computed: Int { count1 + count2 }
    var squared: Int { count1 * count1 }


    var memoizeComputed: Int {
        node.memoize { computed }
    }

    var memoizeSquared: Int {
        node.memoize { squared }
    }

    var computes: [Int] = []
    var squareds: [Int] = []

    func onActivate() {
        node.forEach(Observed(coalesceUpdates: false) { computed }) {
            computes.append($0)
        }

        node.forEach(Observed(coalesceUpdates: false) { squared }) {
            squareds.append($0)
        }
    }
}

@Model private struct NestedComputedModel: Equatable {
    var computed: ComputedModel?

    var computes: [Int?] = []
    var squareds: [Int?] = []

    func onActivate() {
        node.forEach(Observed(coalesceUpdates: false) { computed?.computed }) {
            computes.append($0)
        }
        node.forEach(Observed(coalesceUpdates: false) { computed?.squared }) {
            squareds.append($0)
        }
    }
}
/// Observes a tuple of two child models returned directly from the Observed closure.
@Model private struct TupleObserverModel {
    var a = ChildModel()
    var b = ChildModel()
    /// Stores (a.count, b.count) — plain Int values so assertions read captured values,
    /// not live-context reads that would pass regardless of whether the closure fired.
    var snapshots: [(Int, Int)] = []

    func onActivate() {
        node.forEach(Observed(initial: true) { (a, b) }) { snap in
            snapshots.append((snap.0.count, snap.1.count))
        }
    }
}

/// Observes an optional child model returned directly from the Observed closure.
@Model private struct OptionalObserverModel {
    var child: ChildModel? = nil
    var observedCounts: [Int] = []

    func onActivate() {
        node.forEach(Observed(initial: false) { child }) { snap in
            observedCounts.append(snap?.count ?? -1)
        }
    }
}

/// Observes an array of child models returned directly from the Observed closure.
@Model private struct ArrayObserverModel {
    var children: [ChildModel] = [ChildModel(), ChildModel()]
    /// Stores [child.count] — plain Int arrays so assertions read captured values,
    /// not live-context reads that would pass regardless of whether the closure fired.
    var snapshots: [[Int]] = []

    func onActivate() {
        node.forEach(Observed(initial: true) { children }) { snap in
            snapshots.append(snap.map(\.count))
        }
    }
}

/// Regression: verifies that Observed { child } does not fire when a grandchild (descendant)
/// property changes — only direct property changes on the returned model should trigger.
@Model private struct GrandchildModel {
    var value = 0
}

@Model private struct DeepChildModel {
    var direct = 0
    var grandchild = GrandchildModel()
}

@Model private struct DescendantObserverModel {
    var child = DeepChildModel()
    var snapshots: [DeepChildModel] = []

    func onActivate() {
        node.forEach(Observed(initial: true) { child }) { snap in
            snapshots.append(snap)
        }
    }
}

/// Observes a child that can be swapped at runtime, verifying that old subscriptions
/// are cancelled and new ones established when the returned model changes.
@Model private struct SwapObserverModel {
    var first = ChildModel()
    var second = ChildModel()
    var useSecond = false
    /// Stores snap.count — plain Int values so assertions read captured values,
    /// not live-context reads that would pass regardless of whether the closure fired.
    var snapshots: [Int] = []

    var active: ChildModel {
        get { useSecond ? second : first }
        set { if useSecond { second = newValue } else { first = newValue } }
    }

    func onActivate() {
        node.forEach(Observed(initial: true) { active }) { snap in
            snapshots.append(snap.count)
        }
    }
}

