import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Tests that pin how `node.memoize { … }` interacts with an outer active
/// `ModelAccess`. The behaviour matters because the outer access models the
/// SwiftUI / Observed / debug-collector observers that drive view invalidation;
/// if reads inside `produce` propagate to that outer access, view bodies end up
/// depending on the underlying state (e.g. `items`) rather than only on the
/// memoize sentinel key.
///
/// ## Background
///
/// Memoize calls into the internal `update()` helper, which selects one of two
/// observation paths:
///
/// - **`AccessCollector` path** (iOS 16 / macOS 13, or `disableMemoizeCoalescing`):
///   wraps `produce` in `usingActiveAccess(collector)`, hiding any outer
///   `ModelAccess` for the duration. The outer never sees the inner reads.
///
/// - **`withObservationTracking` path** (iOS 17+ default): wraps `produce` in
///   Apple's `withObservationTracking`. Apple's machinery is independent of
///   swift-model's active-access thread-local, so without an explicit
///   `usingActiveAccess(nil)` wrap the outer `ModelAccess` *also* sees every
///   property read inside `produce`.
///
/// The fix lives in `update()`'s `withObservationTracking` branch — it now
/// wraps `access()` in `usingActiveAccess(nil)` so the outer is shielded the
/// same way as the `AccessCollector` path. Apple's `_AccessList` tracking
/// (used by SwiftUI's body wrapper) is independent and continues to see the
/// reads at the registrar level; we can't suppress that from outside Apple's
/// API, but the swift-model-side leak is now closed.
@Suite(.modelTesting(exhaustivity: .off))
struct MemoizeIsolationTests {

    @Test(arguments: UpdatePath.allCases)
    func produceReadsAreShieldedFromOuterAccess(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { IsolationModel().withAnchor() }
        let recorder = RecordingAccess()

        // Simulate an outer observer (e.g. a `ViewAccess` from `$model.debug`,
        // a debug collector, or a test access) running during a read of the
        // memoized property. We expect the recorder to see ONLY the memoize
        // sentinel — not `value`, which is read inside `produce`.
        usingActiveAccess(recorder) {
            _ = model.doubled
        }

        // The recorder should have seen exactly one IsolationModel read — the
        // memoize sentinel — not the underlying `value` access inside produce.
        // (We tolerate >=1 because `_ModelStateType` synthetic key paths fire
        // alongside writable ones; the relevant invariant is that no
        // *writable* IsolationModel state path was registered.)
        let writableHits = recorder.recordedWritablePaths.value
        #expect(
            writableHits.isEmpty,
            "Outer access saw \(writableHits) — memoize did not isolate produce's reads on \(updatePath)."
        )
    }

    /// Same property as the previous test, but exercising the **dirty-recompute**
    /// path: read once to establish the cache, mutate the dependency *outside*
    /// the recorder scope (so the mutation itself doesn't pollute the recorder),
    /// then read again under the recorder. The second read hits the dirty branch
    /// in `memoize`, which calls `produce` directly — without going through
    /// `update()`'s `observe()` wrap. This is the path the lazy-cache scheme
    /// requires to return a fresh value synchronously, and is where the iOS 17+
    /// registrar leak originates in practice (the cache-miss path is already
    /// isolated by Apple's `withObservationTracking` nesting inside `observe()`).
    @Test(arguments: UpdatePath.allCases)
    func dirtyRecomputeReadsAreShieldedFromOuterAccess(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { IsolationModel().withAnchor() }
        // Establish the cache (first access).
        _ = model.doubled
        // Mutate the dependency — marks the cache dirty.
        model.value = 5

        let recorder = RecordingAccess()
        usingActiveAccess(recorder) {
            _ = model.doubled   // hits the dirty-recompute path
        }

        let writableHits = recorder.recordedWritablePaths.value
        #expect(
            writableHits.isEmpty,
            "Outer access saw \(writableHits) — dirty-recompute path leaked produce's reads on \(updatePath)."
        )
    }

    /// `produce`'s OWN dependency tracking must continue to work — when the
    /// underlying property changes, the memoize cache invalidates and the next
    /// read recomputes. The isolation fix should not break this.
    @Test(arguments: UpdatePath.allCases)
    func memoizeInternalTrackingStillWorks(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { IsolationModel().withAnchor() }

        #expect(model.doubled == 0)
        #expect(model.computes.value == 1)

        model.value = 5

        // After the dependency mutates, the next read recomputes.
        await settle(model.doubled == 10)
        #expect(model.computes.value >= 2)
    }

    /// Stamped-access path — the scenario `@ObservedModel` actually drives in
    /// production. `usingActiveAccess(recorder)` (used by the tests above) sets
    /// only the task-local `ModelAccess.active`; `withAccess(recorder)` instead
    /// stamps the access onto the model value's `accessBox._reference?.access`,
    /// which `Context.willAccessDirect` consults as a fallback when no active
    /// task-local is set. The `usingActiveAccess(nil)` wrap in `observe()`
    /// clears only the task-local; the stamped reference still propagates and
    /// would fire the outer access for every read inside `produce` — that's
    /// the actual production leak `$model.debug(...)` on iOS 17+ hit when a
    /// memoized property's body touched other tracked state.
    ///
    /// The `isInsideMemoizeObserve` thread-local short-circuits the swift-model
    /// dispatch in `Context.willAccessDirect` regardless of which path the
    /// active access came from, closing the stamped variant of the leak as
    /// well.
    @Test(arguments: UpdatePath.allCases)
    func produceReadsAreShieldedFromStampedAccess(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { IsolationModel().withAnchor() }
        let recorder = RecordingAccess()
        // Stamp the recorder onto the model the same way `@ObservedModel.update`
        // does. Subsequent reads through `stamped.doubled` route through the
        // stamped reference — which is the path the `usingActiveAccess(nil)`
        // wrap in `observe()` cannot clear.
        let stamped = model.withAccess(recorder)

        _ = stamped.doubled

        let writableHits = recorder.recordedWritablePaths.value
        #expect(
            writableHits.isEmpty,
            "Stamped access saw \(writableHits) — memoize leaked produce's reads via the stamped chain on \(updatePath)."
        )
    }

    /// Same as the stamped-access test above but exercising the **dirty-recompute**
    /// branch. Mirror of `dirtyRecomputeReadsAreShieldedFromOuterAccess` for the
    /// `withAccess`-stamped path. Confirms `isInsideMemoizeProduce` (the
    /// dirty-path sibling of `isInsideMemoizeObserve`) also closes the leak
    /// when the stamped reference is the active-access source.
    @Test(arguments: UpdatePath.allCases)
    func dirtyRecomputeIsShieldedFromStampedAccess(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { IsolationModel().withAnchor() }
        // Establish the cache (first access) — no recorder yet.
        _ = model.doubled
        // Mutate the dependency outside the stamped scope — marks dirty.
        model.value = 5

        let recorder = RecordingAccess()
        let stamped = model.withAccess(recorder)

        _ = stamped.doubled    // hits the dirty-recompute path under stamping

        let writableHits = recorder.recordedWritablePaths.value
        #expect(
            writableHits.isEmpty,
            "Stamped access saw \(writableHits) — dirty-recompute leaked produce's reads via the stamped chain on \(updatePath)."
        )
    }
}

/// A minimal `ModelAccess` subclass that records which `(Model, path)` pairs
/// fire `willAccess`. Used by the isolation tests to verify the outer access
/// is not informed of reads inside `produce`.
private final class RecordingAccess: ModelAccess, @unchecked Sendable {
    let recordedWritablePaths = LockIsolated<[String]>([])

    init() {
        super.init(useWeakReference: false)
    }

    override var shouldPropagateToChildren: Bool { true }

    override func willAccess<M: Model, Value>(
        from context: Context<M>,
        at path: KeyPath<M._ModelState, Value> & Sendable
    ) -> (() -> Void)? {
        // Only count real writable state paths — synthetic key paths
        // (`[memoizeKey:]`, `[environmentKey:]`, etc.) have `fatalError()`
        // getters and don't represent "the user read this property of the
        // model." This mirrors the filter the debug collector applies.
        if path is WritableKeyPath<M._ModelState, Value> {
            recordedWritablePaths.withValue { $0.append("\(M.self).<\(Value.self)>") }
        }
        return nil
    }
}

@Model private struct IsolationModel {
    var value: Int = 0
    let computes = LockIsolated(0)

    var doubled: Int {
        node.memoize(for: "doubled") {
            computes.withValue { $0 += 1 }
            return value * 2
        }
    }
}
