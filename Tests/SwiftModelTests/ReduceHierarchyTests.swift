import Testing
import Observation
import ConcurrencyExtras
@testable import SwiftModel

// MARK: - Test Models

@Model private struct LeafModel {
    var value: Int = 0
}

@Model private struct ParentModel {
    var child = LeafModel()
    var name: String = "parent"
}

@Model private struct GrandparentModel {
    var parent = ParentModel()
    var name: String = "grandparent"
}

@Model private struct MultiChildParent {
    var childA = LeafModel(value: 1)
    var childB = LeafModel(value: 2)
    var childC = LeafModel(value: 3)
}

// Used in structural change tests — must be at file scope because @Model
// cannot be applied to local types inside a function.
@Model private struct DynamicParent {
    var children: [LeafModel] = []
}

/// A child model that computes its index within its parent's `children` array.
/// This is the canonical use-case for `reduceHierarchy` with `.parent`:
/// a child needs to know where it lives in its parent without the parent holding
/// a back-reference.
@Model private struct IndexedChild {
    var tag: Int = 0

    /// Computed index in parent's `children` array. Traverses one hop up.
    var indexInParent: Int? {
        node.mapHierarchy(for: .parent) {
            ($0 as? IndexedParent)?.children.firstIndex { $0.id == id }
        }.first ?? nil
    }

    /// Same, but memoized. Because memoize runs `produce()` inside `usingActiveAccess`,
    /// the AccessCollector observes every property accessed — including parent properties.
    var cachedIndexInParent: Int? {
        node.memoize(for: "indexInParent") { indexInParent }
    }
}

@Model private struct IndexedParent {
    var children: [IndexedChild] = []
}

/// Models for testing the "find nearest ancestor of a given type" pattern — the canonical
/// real-world use case (e.g. `var timelineModel: TimelineModel { node.memoize { ... } }`).
@Model private struct AncestorContainer {
    var leaves: [AncestorSearchLeaf] = []
}

@Model private struct AncestorSearchLeaf {
    var nearestContainer: AncestorContainer? {
        node.mapHierarchy(for: .ancestors) { $0 as? AncestorContainer }.first
    }

    var memoizedNearestContainer: AncestorContainer? {
        node.memoize(for: "memoizedNearestContainer") { nearestContainer }
    }
}

/// A permanent container that keeps `AncestorSearchLeaf` alive as a structural child.
/// Used by the "disappears" test so the leaf retains at least one parent after being
/// removed from `AncestorContainer`, preventing `onRemoval` from cancelling subscriptions.
@Model private struct AncestorSearchLeafContainer {
    var leaves: [AncestorSearchLeaf] = []
}

// MARK: - Tests

/// Tests for `node.reduceHierarchy` and `node.mapHierarchy`.
///
/// Coverage:
/// 1. Basic traversal — self, parent, ancestors, children, descendants, dependencies
/// 2. Deduplication — models reachable via multiple paths are visited once
/// 3. Type-casting in transform
/// 4. Observation via AccessCollector path (disableObservationRegistrar)
/// 5. Structural hierarchy changes — re-evaluated because `reduceHierarchy` uses `observedParents`
/// 6. withObservationTracking path (direct)
/// 7. Memoized ancestor-type search re-evaluates on structural changes
struct ReduceHierarchyTests {

    // MARK: - 1. Basic Traversal

    @Test func testSelfRelation() {
        let model = LeafModel(value: 42).withAnchor()
        let result = model.node.mapHierarchy(for: .self) { $0 as? LeafModel }
        #expect(result.count == 1)
        #expect(result.first?.value == 42)
    }

    @Test func testChildRelation() {
        let model = ParentModel().withAnchor()
        // From the parent: .children should yield the child
        let children = model.node.mapHierarchy(for: .children) { $0 as? LeafModel }
        #expect(children.count == 1)
        #expect(children.first?.value == 0)
    }

    @Test func testDescendantsRelation() {
        let model = GrandparentModel().withAnchor()
        // Grandparent has ParentModel as child, and LeafModel as grandchild
        let all = model.node.mapHierarchy(for: .descendants) { $0 }
        #expect(all.count == 2, "Should find ParentModel + LeafModel, got \(all.count)")
    }

    @Test func testSelfAndDescendantsRelation() {
        let model = GrandparentModel().withAnchor()
        let all = model.node.mapHierarchy(for: [.self, .descendants]) { $0 }
        // GrandparentModel + ParentModel + LeafModel
        #expect(all.count == 3, "Should find all 3 models, got \(all.count)")
    }

    @Test func testParentRelation() {
        let model = GrandparentModel().withAnchor()
        // From the leaf: .parent should yield just ParentModel
        let parents = model.parent.child.node.mapHierarchy(for: .parent) { $0 }
        #expect(parents.count == 1)
        #expect(parents.first is ParentModel, "Expected ParentModel, got \(type(of: parents.first!))")
    }

    @Test func testAncestorsRelation() {
        let model = GrandparentModel().withAnchor()
        // From the leaf: .ancestors should yield ParentModel and GrandparentModel
        let ancestors = model.parent.child.node.mapHierarchy(for: .ancestors) { $0 }
        #expect(ancestors.count == 2, "Expected 2 ancestors, got \(ancestors.count)")
        // Traversal order: direct parent first, then grandparent
        #expect(ancestors[0] is ParentModel)
        #expect(ancestors[1] is GrandparentModel)
    }

    @Test func testParentRelationIsOneHopOnly() {
        let model = GrandparentModel().withAnchor()
        // .parent (not .ancestors) from leaf should only yield direct parent, not grandparent
        let directParents = model.parent.child.node.mapHierarchy(for: .parent) { $0 }
        #expect(directParents.count == 1)
        #expect(directParents.first is ParentModel)
    }

    @Test func testChildrenRelationIsOneHopOnly() {
        let model = GrandparentModel().withAnchor()
        // .children (not .descendants) from grandparent should only yield ParentModel, not LeafModel
        let directChildren = model.node.mapHierarchy(for: .children) { $0 }
        #expect(directChildren.count == 1)
        #expect(directChildren.first is ParentModel)
    }

    @Test func testMultipleChildren() {
        let model = MultiChildParent().withAnchor()
        let children = model.node.mapHierarchy(for: .children) { $0 as? LeafModel }
        #expect(children.count == 3)
        let values = Set(children.map(\.value))
        #expect(values == [1, 2, 3])
    }

    @Test func testReduceAccumulator() {
        let model = MultiChildParent().withAnchor()
        let sum = model.node.reduceHierarchy(
            for: .children,
            transform: { ($0 as? LeafModel)?.value },
            into: 0
        ) { $0 += $1 }
        #expect(sum == 6, "Sum of [1,2,3] should be 6, got \(sum)")
    }

    @Test func testTransformNilFiltersModel() {
        let model = GrandparentModel().withAnchor()
        // Only pick LeafModel from descendants
        let leaves = model.node.mapHierarchy(for: .descendants) { $0 as? LeafModel }
        #expect(leaves.count == 1)
    }

    @Test func testEmptyDescendants() {
        let model = LeafModel(value: 5).withAnchor()
        let result = model.node.mapHierarchy(for: .descendants) { $0 as? LeafModel }
        #expect(result.isEmpty, "A leaf model has no descendants")
    }

    @Test func testUnanchoredReturnsEmpty() {
        let model = LeafModel(value: 99)
        let result = model.node.mapHierarchy(for: [.self, .descendants]) { $0 as? LeafModel }
        #expect(result.isEmpty, "Unanchored model should return empty")
    }

    // MARK: - 2. Deduplication

    @Test func testDeduplicationPreventsDoubleVisit() {
        // A model reachable via .self should not also appear via .children
        // when using combined relation.
        let model = GrandparentModel().withAnchor()
        var visitCount = 0
        model.node.reduceHierarchy(
            for: [.self, .descendants],
            transform: { _ -> Bool? in
                visitCount += 1
                return true
            },
            into: ()
        ) { _, _ in }
        // GrandparentModel + ParentModel + LeafModel = 3
        #expect(visitCount == 3, "Expected 3 distinct visits, got \(visitCount)")
    }

    // MARK: - 3. Property Access Observation (AccessCollector path)
    //
    // When reduceHierarchy is called inside an Observed closure, property accesses
    // inside the transform ARE tracked and should trigger re-evaluation when those
    // properties change.

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testPropertyAccessInSelfIsObserved(path: ObservationPath) async throws {
        let model = LeafModel(value: 0).withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.mapHierarchy(for: .self) { ($0 as? LeafModel)?.value }.first ?? -1
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

        model.value = 42
        try await waitUntil(values.value.contains(42), timeout: 3_000_000_000)
        #expect(values.value.contains(42), "Property change on self should trigger observation re-evaluation, got \(values.value)")
    }

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testPropertyAccessInChildIsObserved(path: ObservationPath) async throws {
        let model = ParentModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.mapHierarchy(for: [.self, .descendants]) { ($0 as? LeafModel)?.value }.first ?? -1
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

        model.child.value = 77
        try await waitUntil(values.value.contains(77), timeout: 3_000_000_000)
        #expect(values.value.contains(77), "Property change on child should trigger observation re-evaluation, got \(values.value)")
    }

    // MARK: - 4. Observation of Parent/Ancestor Properties
    //
    // When called from a child model, property accesses on ancestor models inside
    // the transform ARE tracked by both observation mechanisms:
    //
    // - AccessCollector path: ModelAccess.active is a @TaskLocal, so every property
    //   access on any model (including ancestors) calls activeAccess?.willAccess() and
    //   registers an onModify subscription on the ancestor's context.
    //
    // - withObservationTracking path: ObservationRegistrar.access() is called globally
    //   for any @Observable property access inside the withObservationTracking block,
    //   regardless of which model the property belongs to.
    //
    // NOTE: The withAccessIfPropagateToChildren mechanism does NOT propagate to ancestors
    // (it only propagates downward). However, this only affects access tracking via the
    // stored _access property (used by TestAccess/ViewAccess). For Observed and
    // withObservationTracking, the global mechanisms above are sufficient.

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testPropertyAccessInAncestorIsObserved(path: ObservationPath) async throws {
        let model = GrandparentModel().withAnchor(options: path.options)
        let leaf = model.parent.child

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            leaf.node.mapHierarchy(for: .ancestors) { ($0 as? GrandparentModel)?.name }.first ?? "none"
        }

        let values = LockIsolated<[String]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == "grandparent")

        model.name = "updated-grandparent"

        // Both observation paths correctly track ancestor property accesses.
        try await waitUntil(values.value.contains("updated-grandparent"), timeout: 2_000_000_000)
        #expect(values.value.contains("updated-grandparent"),
                "[\(path)] Ancestor property change should trigger re-evaluation, got: \(values.value)")
    }

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testPropertyAccessInParentIsObserved(path: ObservationPath) async throws {
        let model = GrandparentModel().withAnchor(options: path.options)
        let leaf = model.parent.child

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            leaf.node.mapHierarchy(for: .parent) { ($0 as? ParentModel)?.name }.first ?? "none"
        }

        let values = LockIsolated<[String]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == "parent")

        model.parent.name = "updated-parent"

        try await waitUntil(values.value.contains("updated-parent"), timeout: 2_000_000_000)
        #expect(values.value.contains("updated-parent"),
                "[\(path)] Parent property change should trigger re-evaluation, got: \(values.value)")
    }

    // MARK: - 5. Structural Hierarchy Changes (Parent Relationship)
    //
    // Adding a child to a parent fires observation on the child's `parents` relationship,
    // because `addParent` now calls `willModifyParents`/`didModifyParents`. Any Observed
    // block that reads `observedParents` (via `reduceHierarchy` with `.parent`/`.ancestors`)
    // will be re-evaluated when a parent is added or removed.

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testParentAdditionIsObserved(path: ObservationPath) async throws {
        // Start with the child unattached (no parent yet), then add it to a parent.
        let parent = IndexedParent().withAnchor(options: path.options)
        let orphan = IndexedChild(tag: 99).withAnchor(options: path.options)

        // Observe the child's parent relationship via reduceHierarchy.
        // Initially there is no parent, so mapHierarchy returns [].
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            orphan.node.mapHierarchy(for: .parent) { $0 as? IndexedParent }.first?.children.count ?? -1
        }

        let values = LockIsolated<[Int]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == -1, "No parent yet, should return -1")

        // Adding the child to the parent changes the parents relationship.
        parent.children.append(orphan)

        try await waitUntil(values.value.contains { $0 >= 0 }, timeout: 2_000_000_000)
        #expect(values.value.contains { $0 >= 0 },
                "[\(path)] Adding child to parent should trigger re-evaluation via parents observation, got \(values.value)")
    }

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testIndexInParentIsObserved(path: ObservationPath) async throws {
        // The canonical real-world use case: a child computing its own index in its parent.
        let parent = IndexedParent(children: [
            IndexedChild(tag: 0),
            IndexedChild(tag: 1),
            IndexedChild(tag: 2),
        ]).withAnchor(options: path.options)

        let middle = parent.children[1]

        // Observe the middle child's computed indexInParent.
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            middle.indexInParent ?? -1
        }

        let values = LockIsolated<[Int]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == 1, "Middle child should start at index 1")

        // Remove the first child — middle child should now be at index 0.
        parent.children.removeFirst()

        try await waitUntil(values.value.contains(0), timeout: 2_000_000_000)
        #expect(values.value.contains(0),
                "[\(path)] Removing earlier sibling should update indexInParent to 0, got \(values.value)")
    }

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testCachedIndexInParentIsObserved(path: ObservationPath) async throws {
        // Same as testIndexInParentIsObserved but using the memoized variant.
        let parent = IndexedParent(children: [
            IndexedChild(tag: 0),
            IndexedChild(tag: 1),
            IndexedChild(tag: 2),
        ]).withAnchor(options: path.options)

        let middle = parent.children[1]

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            middle.cachedIndexInParent ?? -1
        }

        let values = LockIsolated<[Int]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == 1, "Middle child should start at index 1")

        parent.children.removeFirst()

        try await waitUntil(values.value.contains(0), timeout: 2_000_000_000)
        #expect(values.value.contains(0),
                "[\(path)] Memoized indexInParent should re-evaluate when sibling is removed, got \(values.value)")
    }

    // MARK: - 6. withObservationTracking path (no ModelTester)
    //
    // Directly test that withObservationTracking sees property accesses made inside
    // reduceHierarchy for the standard registrar path.

    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testWithObservationTrackingSeesChildProperty() async throws {
        let model = ParentModel().withAnchor(options: []) // use ObservationRegistrar

        let fired = LockIsolated(false)

        withObservationTracking {
            // Access child.value via reduceHierarchy inside the tracking block
            _ = model.node.mapHierarchy(for: [.self, .descendants]) { ($0 as? LeafModel)?.value }
        } onChange: {
            fired.setValue(true)
        }

        #expect(!fired.value)
        model.child.value = 99

        // Give a short time for the onChange to fire
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fired.value, "withObservationTracking onChange should fire when child property accessed via mapHierarchy changes")
    }

    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testWithObservationTrackingSeesAncestorProperty() async throws {
        let model = GrandparentModel().withAnchor(options: []) // use ObservationRegistrar
        let leaf = model.parent.child

        let fired = LockIsolated(false)

        withObservationTracking {
            // Access ancestor name via reduceHierarchy inside the tracking block.
            // Because GrandparentModel is @Observable, its ObservationRegistrar receives
            // the access() call (via ModelContext.willAccess → observable.access(path:from:)),
            // and the withObservationTracking block captures it globally.
            _ = leaf.node.mapHierarchy(for: .ancestors) { ($0 as? GrandparentModel)?.name }
        } onChange: {
            fired.setValue(true)
        }

        model.name = "changed"

        // Give a short time for the onChange to fire
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(fired.value, "withObservationTracking onChange should fire when ancestor property accessed via mapHierarchy changes")
    }

    // MARK: - 7. Memoized ancestor-type search re-evaluates on structural changes
    //
    // The canonical real-world pattern: `node.memoize { node.mapHierarchy(for: .ancestors) { $0 as? T }.first }`.
    // Because `reduceHierarchy` uses `observedParents` for upward traversal, the memoized
    // result is properly invalidated whenever the ancestor chain changes structurally —
    // whether a new ancestor appears or an existing one disappears.

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testMemoizedAncestorTypeSearchReEvaluatesWhenAncestorAppears(path: ObservationPath) async throws {
        let target = AncestorContainer().withAnchor(options: path.options)
        let leaf = AncestorSearchLeaf().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            leaf.memoizedNearestContainer != nil
        }

        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == false, "No ancestor yet, memoized result should be nil")

        // Adding the leaf to target gives it an AncestorContainer ancestor.
        target.leaves.append(leaf)

        try await waitUntil(values.value.contains(true), timeout: 2_000_000_000)
        #expect(values.value.contains(true),
                "[\(path)] Memoized ancestor-type search should re-evaluate when ancestor appears, got \(values.value)")
    }

    @Test(arguments: [ObservationPath.accessCollector, .observationRegistrar])
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testMemoizedAncestorTypeSearchReEvaluatesWhenAncestorDisappears(path: ObservationPath) async throws {
        // `leafContainer` acts as a permanent structural parent for the leaf.
        // When the leaf is later removed from `target`, leafContainer remains its parent,
        // so `parents.isEmpty` stays false → `onRemoval` is NOT triggered → memoize
        // subscriptions survive → the async `performUpdate` can deliver the new nil value.
        let leafContainer = AncestorSearchLeafContainer().withAnchor(options: path.options)
        let target = AncestorContainer().withAnchor(options: path.options)
        leafContainer.leaves.append(AncestorSearchLeaf())
        let leaf = leafContainer.leaves[0]  // live reference; leafContainer is its structural parent
        target.leaves.append(leaf)          // leaf now has two parents: leafContainer + target

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            leaf.memoizedNearestContainer != nil
        }

        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == true, "Ancestor present, memoized result should be non-nil")

        // Remove the leaf from the container — it no longer has AncestorContainer as an ancestor.
        target.leaves.removeFirst()

        try await waitUntil(values.value.contains(false), timeout: 2_000_000_000)
        #expect(values.value.contains(false),
                "[\(path)] Memoized ancestor-type search should re-evaluate when ancestor disappears, got \(values.value)")
    }
}
