import SwiftModel
import IdentifiedCollections
import Foundation
import Observation  // For `withObservationTracking` used by the read-path benchmarks.
import Dependencies  // For `DependencyKey` / `DependencyValues` used by the dep-override benchmark.

// A custom dep key used solely by the "anchor (with dependency override)" benchmark below.
// Defined here rather than reusing `\.uuid` / `\.date` for clarity and to avoid any
// ambiguity about which swift-dependencies traits are active.
private enum BenchDepKey: DependencyKey {
    static let liveValue: Int = 0
}
extension DependencyValues {
    fileprivate var benchValue: Int {
        get { self[BenchDepKey.self] }
        set { self[BenchDepKey.self] = newValue }
    }
}

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

// MARK: - 2b. Read path variants (tracked vs untracked vs raw)

/// Per-read cost across observation modes. The interesting comparisons:
///   raw struct          — lower bound (no SwiftModel involved)
///   tracked, no listener — the default cost every `@Model` property read pays
///   tracked, inside withObservationTracking — what a SwiftUI body read pays
///   untracked            — `withUntrackedModelReads`: lock-protected raw state read
func benchReadPath() {
    printHeader("2b. Read path (tracked vs untracked vs raw)")

    struct RawCounter { var count = 0 }
    let raw = RawCounter()
    measure("raw struct read", iterations: 1_000_000) {
        blackhole &+= raw.count
    }

    let (counter, anchor) = BenchCounter().returningAnchor()

    measure("tracked read (no listener)", iterations: 1_000_000) {
        blackhole &+= counter.count
    }

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        // One tracking scope around all reads — models a body/scan that reads
        // repeatedly while SwiftUI's withObservationTracking is active.
        _ = withObservationTracking {
            measure("tracked read (inside withObservationTracking)", iterations: 1_000_000) {
                blackhole &+= counter.count
            }
        } onChange: {}
    }

    // Scope entered once, reads inside — the intended bulk-scan shape.
    _ = withUntrackedModelReads {
        measure("untracked read (inside scope)", iterations: 1_000_000) {
            blackhole &+= counter.count
        }
    }

    // Scope per read — shows the enter/exit overhead of the scope itself.
    measure("withUntrackedModelReads { single read }", iterations: 1_000_000) {
        blackhole &+= withUntrackedModelReads { counter.count }
    }

    withExtendedLifetime(anchor) {}
}

// MARK: - 2c. O(N) scan over live child models

/// The client-app workload that motivated `withUntrackedModelReads`: an O(N)
/// traversal reading a couple of properties from each of N live child models
/// (hit-testing, snapping, validation passes). n=120 matches the editor probe
/// scenario this was first measured in.
func benchModelScan() {
    printHeader("2c. O(N) scan over live child models (n=120, 2 properties each)")

    var items: IdentifiedArrayOf<BenchItem> = []
    for i in 0..<120 { items.append(BenchItem(id: i, value: i, label: "seg\(i)")) }
    let (list, anchor) = BenchList(items: items).returningAnchor()

    measure("tracked scan (no listener)", iterations: 2_000) {
        for item in list.items { blackhole &+= item.value &+ item.label.count }
    }

    measure("untracked scan", iterations: 2_000) {
        withUntrackedModelReads {
            for item in list.items { blackhole &+= item.value &+ item.label.count }
        }
    }

    // Pre-extracted value snapshot — the workaround apps used before
    // withUntrackedModelReads existed. Lower bound for any scan.
    let snapshot: [(Int, String)] = withUntrackedModelReads { list.items.map { ($0.value, $0.label) } }
    measure("value-snapshot scan", iterations: 2_000) {
        for (value, label) in snapshot { blackhole &+= value &+ label.count }
    }

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        // NOTE: each iteration installs a fresh withObservationTracking registration
        // that never fires; registrar state grows over the run. Kept last and at
        // moderate iteration counts on purpose.
        measure("tracked scan (inside withObservationTracking)", iterations: 2_000) {
            withObservationTracking {
                for item in list.items { blackhole &+= item.value &+ item.label.count }
            } onChange: {}
        }
    }

    withExtendedLifetime(anchor) {}
}

// MARK: - 2d. Parallel tracked reads (lock-contention probe)

/// Eight threads reading concurrently. With distinct models this probes
/// process-global serialization points in the read path (e.g. the observer-KP
/// cache lock) — perfect scaling shows the single-thread cost, full
/// serialization shows ~8x. With one shared model all threads serialize on
/// that model's context lock regardless, which bounds what any cache-level
/// improvement can show.
func benchParallelReads() {
    printHeader("2d. Parallel tracked reads (8 threads)")

    let threads = 8
    let perThread = 200_000

    var anchors: [Any] = []
    var models: [BenchCounter] = []
    for _ in 0..<threads {
        let (model, anchor) = BenchCounter().returningAnchor()
        models.append(model)
        anchors.append(anchor)
    }
    for model in models { blackhole &+= model.count }  // warmup

    let distinctModels = models
    let startDistinct = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: threads) { i in
        let model = distinctModels[i]
        var sink = 0
        for _ in 0..<perThread { sink &+= model.count }
        blackhole &+= sink
    }
    let elapsedDistinct = DispatchTime.now().uptimeNanoseconds &- startDistinct
    printResult(BenchmarkResult(name: "8-thread tracked read (distinct models)", iterations: perThread, nanos: elapsedDistinct))

    let shared = models[0]
    let startShared = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: threads) { _ in
        var sink = 0
        for _ in 0..<perThread { sink &+= shared.count }
        blackhole &+= sink
    }
    let elapsedShared = DispatchTime.now().uptimeNanoseconds &- startShared
    printResult(BenchmarkResult(name: "8-thread tracked read (one shared model)", iterations: perThread, nanos: elapsedShared))

    withExtendedLifetime(anchors) {}
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

    measure("node.dependency access", iterations: 500_000) {
        // Touch the dependency without retaining its output to avoid alloc overhead.
        // Uses `BenchDepKey` (defined at top) so this is trait-independent — was
        // `counter.node.date.now`, but `\.date` is Foundation-trait-gated in
        // swift-dependencies and not available with `traits: ["Clocks"]`.
        _ = counter.node.benchValue
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
            // Trait-independent dep override (see `BenchDepKey` at the top of this file).
            // The specific key is irrelevant to what's being measured — we just need ONE
            // override to take the with-overrides anchor path.
            $0.benchValue = 42
        }
        withExtendedLifetime(anchor) {}
    }
}

// TEMP PROBE — compares in-module (WMO-specialized) read cost against the
// cross-module numbers in section 2b. See ReadPathProbe.swift in SwiftModel.
func benchInModuleProbe() {
    printHeader("2e. In-module read probe (WMO upper bound for @inlinable)")
    let r = _readPathProbe(iterations: 1_000_000)
    print(String(format: "  in-module tracked read:   %8.1f ns/op", r.tracked))
    print(String(format: "  in-module untracked read: %8.1f ns/op", r.untracked))
}
