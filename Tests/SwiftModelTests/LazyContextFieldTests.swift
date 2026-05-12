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

    // MARK: - ObservationRegistrar lazy allocation

    /// With `RegistrarBox`, the `RegistrarPair` is created lazily on first observation
    /// access. The box itself is allocated cheaply at root anchor time. Inside the pair,
    /// `background` is created eagerly when the pair is first needed; `main` is created
    /// lazily on first main-channel use, so trees that never reach the main thread save
    /// one `ObservationRegistrar` (plus its internal `Extent` heap object) per hierarchy.
    @Test func observationRegistrarNilBeforeFirstAccess() async {
        let model = LeafForLazyTests().withAnchor()
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            #expect(model.context?.mainObservationRegistrarStore == nil)
            #expect(model.context?.backgroundObservationRegistrarStore == nil)
        }
    }

    /// A first observation access on a non-main thread allocates only the `background`
    /// registrar. The `main` registrar remains lazy until a main-thread access happens —
    /// trees on Linux/Android (where `useMainThreadObservation == false`) never trigger
    /// this branch and so never pay the main-channel allocation.
    @Test func observationRegistrarBackgroundAllocatesOnFirstNonMainAccess() async {
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
    /// The `background` registrar also exists as a side-effect of allocating the
    /// `RegistrarPair`, even though it isn't touched on this code path. Only Apple
    /// platforms reach this branch — on non-Apple `useMainThreadObservation` is forced
    /// off and the main-channel access is rerouted to `backgroundObservationRegistrar`.
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
