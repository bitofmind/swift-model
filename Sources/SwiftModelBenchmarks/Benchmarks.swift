import SwiftModel
import IdentifiedCollections
import Foundation

// MARK: - 1. Activation / deactivation

/// Full lifecycle: create a Context, run onActivate, then tear it down.
/// Hot path: Context<M>.init, onActivate (pendingActivation), AnyContext.onRemoval.
func benchActivation() {
    printHeader("1. Activation / deactivation")

    measure("simpleModel activate+release", iterations: 10_000) {
        let (_, anchor) = BenchCounter().returningAnchor()
        withExtendedLifetime(anchor) {}
    }

    measure("parentChild activate+release", iterations: 10_000) {
        let (_, anchor) = BenchParent().returningAnchor()
        withExtendedLifetime(anchor) {}
    }

    // Wide hierarchy: 100 items
    measure("wideHierarchy (n=100) activate+release", iterations: 2_000) {
        var items: IdentifiedArrayOf<BenchItem> = []
        for i in 0..<100 { items.append(BenchItem(id: i)) }
        let (_, anchor) = BenchList(items: items).returningAnchor()
        withExtendedLifetime(anchor) {}
    }

    // Wide hierarchy: 1 000 items
    measure("wideHierarchy (n=1000) activate+release", iterations: 200) {
        var items: IdentifiedArrayOf<BenchItem> = []
        for i in 0..<1_000 { items.append(BenchItem(id: i)) }
        let (_, anchor) = BenchList(items: items).returningAnchor()
        withExtendedLifetime(anchor) {}
    }
}

// MARK: - 2. Property access

/// Read / write on a live model with no active observers.
/// Hot path: willAccessDirect → ModelContext.willAccess (nil-access fast path),
///           lock→state[keyPath:], didModify → buildPostLockCallbacks (empty).
func benchPropertyAccess() {
    printHeader("2. Property access (no observers)")

    let (counter, readAnchor) = BenchCounter().returningAnchor()

    measure("property read", iterations: 1_000_000) {
        blackhole &+= counter.count
    }

    measure("property write", iterations: 500_000) {
        counter.count &+= 1
    }

    withExtendedLifetime(readAnchor) {}
}

// MARK: - 3. Property access with observer

/// Read / write with an active onChange observer registered via BenchWatcher.onActivate().
/// Hot path: same as above, but also runs through modifyCallbacks dispatch and
///           the Observed stream machinery (coalescing, task scheduling).
func benchPropertyAccessWithObserver() {
    printHeader("3. Property access (with onChange observer)")

    let (watcher, watcherAnchor) = BenchWatcher().returningAnchor()

    measure("property write (onChange observer)", iterations: 100_000) {
        watcher.trigger &+= 1
    }

    withExtendedLifetime(watcherAnchor) {}
}

// MARK: - 4. Event dispatch

/// Send an event from a child to its parent with an active forEach listener on the parent.
/// Hot path: Context.sendEvent → AnyContext.sendEvent(to:ancestors) → eventContinuations
///           → AsyncStream continuation.yield (buffered, no immediate consumer).
func benchEventDispatch() {
    printHeader("4. Event dispatch")

    // No listeners
    let (child, childAnchor) = BenchChild().returningAnchor()
    measure("send event (no listeners)", iterations: 200_000) {
        child.node.send(.updated)
    }
    withExtendedLifetime(childAnchor) {}

    // With parent listener (forEach in BenchParent.onActivate).
    // NOTE: the async Task that processes events runs concurrently on the Swift
    // cooperative thread pool, contending for the same context lock as the send
    // loop. This intentionally measures real throughput under contention — it is
    // NOT comparable to the no-listener case which has zero contention.
    let (parent, parentAnchor) = BenchParent().returningAnchor()
    measure("send event (parent forEach listener)", iterations: 5_000) {
        parent.child.node.send(.updated)
    }
    withExtendedLifetime(parentAnchor) {}
}

// MARK: - 5. Hierarchy mutation (append/remove)

/// Append one item to a live list of N items, then remove it.
/// Hot path: Context.updateContext(for:at:) diff — prevRefs.subtracting(modelRefs),
///           child context creation, onRemoval for removed children.
func benchHierarchyMutation() {
    printHeader("5. Hierarchy mutation (append + remove)")

    for n in [0, 100, 500] {
        var items: IdentifiedArrayOf<BenchItem> = []
        for i in 0..<n { items.append(BenchItem(id: i)) }
        let (list, anchor) = BenchList(items: items).returningAnchor()
        let extraID = n  // unique id not in the list

        measure("append+remove item (base n=\(n))", iterations: 2_000) {
            list.items.append(BenchItem(id: extraID))
            list.items.remove(id: extraID)
        }

        withExtendedLifetime(anchor) {}
    }
}

// MARK: - 5b. Container value-update (ID-only fast path)

/// Write a container back with the same live elements (same References, same IDs).
/// With the structural-change fast path, updateContext and activate() are skipped entirely
/// because containerIsSame returns true before the O(N) traversal is reached.
/// Hot path: containerIsSame ID check, stateTransaction (isSame=true, no notifications).
func benchContainerValueUpdate() {
    printHeader("5b. Container value-update (same IDs, fast path)")

    for n in [0, 100, 500] {
        var items: IdentifiedArrayOf<BenchItem> = []
        for i in 0..<n { items.append(BenchItem(id: i)) }
        let (list, anchor) = BenchList(items: items).returningAnchor()
        let liveItems = list.items  // capture live References

        measure("value-update (n=\(n))", iterations: 2_000) {
            list.items = liveItems
        }

        withExtendedLifetime(anchor) {}
    }
}

// MARK: - 5b2. Array hierarchy mutation ([BenchItem: @Model])

/// Append one item to a live Array of N items, then remove it.
/// `[BenchItem]` conforms to `ModelContainer` via `extension Array: ModelContainer where Element: ModelContainer & Identifiable`.
/// Hot path: `MutableCollection.visit` with `shouldSkipElement` fast path (cursor skipped for existing elements).
/// NOT the same path as `IdentifiedArrayOf<BenchItem>` (which uses `visitCollection`).
func benchArrayHierarchyMutation() {
    printHeader("5b2. Array hierarchy mutation ([BenchItem: @Model] via ModelContainer.visit+shouldSkipElement)")

    for n in [0, 100, 500] {
        var items: [BenchItem] = []
        for i in 0..<n { items.append(BenchItem(id: i)) }
        let (list, anchor) = BenchArrayList(items: items).returningAnchor()
        let extraID = n  // unique id not in the list

        measure("append+remove item (base n=\(n))", iterations: 2_000) {
            list.items.append(BenchItem(id: extraID))
            list.items.removeLast()
        }

        withExtendedLifetime(anchor) {}
    }
}

// MARK: - 5c. ContainerCollection mutation (IdentifiedArray<@ModelContainer>)

/// Append one BenchPath element to a live IdentifiedArray of N elements, then remove it.
/// Hot path: Context.updateContextForContainerCollection diff — uses the cursor-free
/// `AnchorVisitorForContainerElement` with `ModelRef(\C.self, id)` sentinel keys.
func benchContainerCollectionMutation() {
    printHeader("5c. ContainerCollection mutation (IdentifiedArray<@ModelContainer>)")

    for n in [0, 100, 500] {
        var paths: IdentifiedArrayOf<BenchPath> = []
        for i in 0..<n { paths.append(.item(BenchItem(id: i))) }
        let (list, anchor) = BenchContainerList(paths: paths).returningAnchor()
        let extraID = n  // unique id not in the list

        measure("append+remove path (base n=\(n))", iterations: 2_000) {
            list.paths.append(.item(BenchItem(id: extraID)))
            list.paths.remove(id: extraID)
        }

        withExtendedLifetime(anchor) {}
    }

    // Value-update: write back same live elements (no structural change).
    for n in [0, 100, 500] {
        var paths: IdentifiedArrayOf<BenchPath> = []
        for i in 0..<n { paths.append(.item(BenchItem(id: i))) }
        let (list, anchor) = BenchContainerList(paths: paths).returningAnchor()
        let livePaths = list.paths  // capture live References

        measure("value-update (n=\(n))", iterations: 2_000) {
            list.paths = livePaths
        }

        withExtendedLifetime(anchor) {}
    }
}

// MARK: - 6. Dependency access

/// Access a dependency via `node.<name>` on a live model.
/// Hot path: context.capturedDependencies → DependencyValues subscript → closure call.
func benchDependencyAccess() {
    printHeader("6. Dependency access")

    let (counter, anchor) = BenchCounter().returningAnchor()

    measure("node.uuid() access", iterations: 500_000) {
        // Touch the dependency without retaining its output to avoid alloc overhead.
        _ = counter.node.date.now
    }

    withExtendedLifetime(anchor) {}
}

// MARK: - 7. Anchor overhead with dependencies override

/// Anchoring with a dependency override vs. the fast child-inherit path.
/// Hot path: Dependencies.withDependencies closure merging vs. COW parent copy.
func benchAnchorDependencies() {
    printHeader("7. Anchor with dependency overrides")

    measure("anchor (no overrides)", iterations: 10_000) {
        let (_, anchor) = BenchCounter().returningAnchor()
        withExtendedLifetime(anchor) {}
    }

    measure("anchor (with dependency override)", iterations: 10_000) {
        let (_, anchor) = BenchCounter().returningAnchor {
            $0.uuid = .incrementing
        }
        withExtendedLifetime(anchor) {}
    }
}
