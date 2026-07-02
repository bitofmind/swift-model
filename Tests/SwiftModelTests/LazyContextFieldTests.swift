import Testing
@testable import SwiftModel

/// Regression guards for the lazy-optional backing store optimisation (§25 Phase A).
///
/// The five formerly-eager `[K: V] = [:]` fields in `AnyContext` / `Context<M>` now
/// allocate only on first use. Tests here verify:
///
///  1. Each backing store is `nil` right after a model is anchored (no allocation yet).
///  2. Each backing store becomes non-nil on the first operation that requires it.
///
/// If any of these asserts fail, a formerly-lazy field has regressed to eager allocation.
@Suite(.modelTesting(exhaustivity: .off))
struct LazyContextFieldTests {

    // MARK: - Nil before first use

    @Test func memoizeCacheNilBeforeFirstMemoize() async {
        let model = LeafForLazyTests().withAnchor()
        #expect(model.context?.memoizeCacheStore == nil)
    }

    @Test func contextStorageNilBeforeFirstLocalWrite() async {
        let model = LeafForLazyTests().withAnchor()
        #expect(model.context?.contextStorageStore == nil)
    }

    @Test func preferenceStorageNilBeforeFirstPreferenceWrite() async {
        let model = LeafForLazyTests().withAnchor()
        #expect(model.context?.preferenceStorageStore == nil)
    }

    // MARK: - Allocates on first use

    @Test func memoizeCacheAllocatesOnFirstMemoize() async {
        let model = LeafForLazyTests().withAnchor()
        _ = model.node.memoize(for: "lazy-test") { 42 }
        #expect(model.context?.memoizeCacheStore != nil)
    }

    @Test func contextStorageAllocatesOnFirstLocalWrite() async {
        let model = LeafForLazyTests().withAnchor()
        model.node.local.lazyTestFlag = true
        #expect(model.context?.contextStorageStore != nil)
    }

    @Test func preferenceStorageAllocatesOnFirstPreferenceWrite() async {
        let model = LeafForLazyTests().withAnchor()
        model.node.preference.lazyTestCount = 5
        #expect(model.context?.preferenceStorageStore != nil)
    }

    // MARK: - ObservationRegistrar allocation

    /// The `RegistrarPair` (and its `background` registrar) is created EAGERLY with the
    /// `RegistrarBox` at root anchor time: the immutable box → pair → background `let`
    /// chain is what makes lock-free registrar reads race-free (the previous lazy
    /// `_pair` publication was double-checked locking without atomics — a data race).
    /// Only `_main` stays lazy (lock-published), so trees that never reach the main
    /// thread still save one `ObservationRegistrar` (plus its internal `Extent` heap
    /// object) per hierarchy.
    @Test func observationRegistrarBackgroundEagerMainLazyAtAnchor() async {
        let model = LeafForLazyTests().withAnchor()
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            #expect(model.context?.mainObservationRegistrarStore == nil)
            #expect(model.context?.backgroundObservationRegistrarStore != nil)
        }
    }

    /// An observation access on a non-main thread uses the `background` registrar and
    /// must NOT allocate the `main` registrar — trees on Linux/Android (where
    /// `useMainThreadObservation == false`) never trigger the main channel and so never
    /// pay its allocation.
    @Test func observationRegistrarMainStaysLazyOnNonMainAccess() async {
        let model = LeafForLazyTests().withAnchor()
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            // Force the access to run on a background thread so `isOnMainThread` is false
            // inside `willAccessDirect`. Swift Testing test bodies usually run on the
            // cooperative pool already, but `Task.detached` makes the thread choice
            // explicit and deterministic regardless of the runner.
            await Task.detached {
                withObservationTracking {
                    _ = model.value
                } onChange: {}
            }.value
            #expect(model.context?.backgroundObservationRegistrarStore != nil)
            #expect(model.context?.mainObservationRegistrarStore == nil)
        }
    }

    /// A first observation access on the main thread allocates the `main` registrar.
    /// Only Apple platforms reach this branch — on non-Apple (Linux/Android/WASM)
    /// `useMainThreadObservation` is forced off and `willAccessDirect` reroutes a
    /// main-thread access to `backgroundObservationRegistrar` instead. Compiled out
    /// entirely on non-Apple to avoid a meaningless assertion there.
    #if canImport(Darwin)
    @Test func observationRegistrarMainAllocatesOnFirstMainAccess() async {
        let model = LeafForLazyTests().withAnchor()
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            await MainActor.run {
                withObservationTracking {
                    _ = model.value
                } onChange: {}
            }
            #expect(model.context?.mainObservationRegistrarStore != nil)
        }
    }
    #endif

    // MARK: - Cancellations lazy allocation

    @Test func cancellationsNilBeforeFirstUse() async {
        let model = LeafForLazyTests().withAnchor()
        #expect(model.context?.cancellationsStore == nil)
    }

    @Test func cancellationsAllocatesOnFirstUse() async {
        let model = LeafForLazyTests().withAnchor()
        // Accessing `.cancellations` (not `.cancellationsStore`) triggers lazy creation.
        _ = model.context?.cancellations
        #expect(model.context?.cancellationsStore != nil)
    }
}

// MARK: - Helpers

@Model private struct LeafForLazyTests: Sendable {
    var value = 0
    // Intentionally empty onActivate: no tasks, events, or storage writes.
    // All lazy backing stores must remain nil unless explicitly triggered below.
}


private extension LocalKeys {
    var lazyTestFlag: LocalStorage<Bool> { .init(defaultValue: false) }
}

private extension PreferenceKeys {
    var lazyTestCount: PreferenceStorage<Int> {
        .init(defaultValue: 0, key: "lazyTestCount") { $0 += $1 }
    }
}
