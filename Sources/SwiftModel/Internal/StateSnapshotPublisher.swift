import Foundation
import Synchronization

// SPIKE (not for merge): snapshot-published (RCU-style) reads of `@Model` state.
//
// Each live `Reference` publishes an immutable copy of its `_State` in a heap box through
// an atomically swapped pointer. Readers on a live model project the current box WITHOUT
// taking the hierarchy lock; writers keep the hierarchy lock, mutate the working copy in
// `Reference._stateStorage` exactly as before, and publish a fresh box at the end of every
// `Reference.state` mutation (per write, not per transaction — see `Reference.state`).
//
// Reclamation. A reader that has loaded the box pointer but not yet finished projecting
// from it must not have the box freed under it. The spike uses the simplest correct
// scheme: a per-Reference reader count.
//
//   reader:  readers += 1 (seq_cst);  p = load(seq_cst);  project(p);  readers -= 1 (release)
//   writer:  old = exchange(new, seq_cst);  if load(readers, seq_cst) == 0 { release(old) }
//            else { retire(old) — released by a later writer that observes readers == 0 }
//
// Why this is sound (Dekker-style, all four operations are in the single seq_cst order):
// if the writer's `readers` load returns 0, then every reader increment is either ordered
// AFTER that load — and therefore after the exchange, so that reader loads the NEW pointer —
// or its matching decrement is ordered BEFORE the load, so that reader is done with the box.
// Retired boxes are drained only after a re-check of `readers == 0` taken UNDER the retire
// lock, so a retire that lands between another writer's `readers` load and its drain cannot
// have its box freed early.
//
// Cost model. The reader count is one cache line per Reference: private for the
// "children of ONE tree" rows (each child has its own Reference), shared for the
// "ONE shared model" rows (where it bounces between cores like any shared counter —
// the same order of cost as `Reference.lock`, which that row still takes for the
// registrar token). A real implementation would replace the count with per-thread
// hazard slots (readers then write only thread-private lines) — see the report.
//
// Memory. A box holds a full `_State` copy: a removed child model, or an old value of a
// large collection, stays alive until the NEXT publish after the last reader drops it
// (one write later in the common case; unboundedly for a reader parked mid-projection).

/// Immutable heap box for one published `_State` value. `let` so a projection can borrow
/// the struct in place rather than copy it out first.
final class _StateSnapshotBox<State> {
    let value: State
    init(_ value: State) { self.value = value }
}

/// The lock-free publish/read pair for one `Reference`. Needs `Synchronization.Atomic`
/// (macOS 15 / iOS 18): the spike raises the package floor to that so the publisher can be
/// stored typed and un-gated. (A first cut kept the macOS 11 floor and reached the
/// publisher through `AnyObject` + `#available` + `unsafeDowncast`; the
/// `_StateSnapshotPublisher<M._ModelState>.self` metatype that downcast needs is a
/// `swift_getGenericMetadata` call on every read and cost ~170 ns — more than the lock
/// it replaced.) A real implementation must supply the pre-macOS-15 fallback.
final class _StateSnapshotPublisher<State>: @unchecked Sendable {
    private let _published = Atomic<Unmanaged<_StateSnapshotBox<State>>?>(nil)
    private let _readers = Atomic<Int>(0)
    private let _retiredLock = NSLock()
    private var _retired: [Unmanaged<_StateSnapshotBox<State>>] = []
    private let _retiredCount = Atomic<Int>(0)

    /// True between `publish` and `unpublish`: exactly the window in which the Reference
    /// has a live context. Relaxed: only a hint for the writer (whether to bother copying).
    @inline(__always)
    var isPublished: Bool { _published.load(ordering: .relaxed) != nil }

    /// Reader side: projects `get` out of the current snapshot, or nil when nothing is
    /// published. Never blocks, never takes a lock; the box is pinned by `_readers`, not
    /// retained (a retain would be a shared-line RMW on the box itself).
    ///
    /// Non-optional on purpose: this runs as unspecialised generic code (`State` and `T` are
    /// address-only there), where every extra `Optional` injection / projection and every
    /// intermediate is a value-witness copy. `unpublished` is the caller's locked fallback.
    @inline(__always)
    func read<T>(_ get: (State) -> T, unpublished: () -> T) -> T {
        _readers.wrappingAdd(1, ordering: .sequentiallyConsistent)
        guard let p = _published.load(ordering: .sequentiallyConsistent) else {
            _readers.wrappingSubtract(1, ordering: .releasing)
            return unpublished()
        }
        let value: T = p._withUnsafeGuaranteedRef { get($0.value) }
        _readers.wrappingSubtract(1, ordering: .releasing)
        return value
    }

    /// Writer side: publishes a copy of `state` as the new snapshot.
    func publish(_ state: State) {
        let new = Unmanaged.passRetained(_StateSnapshotBox(state))
        let old = _published.exchange(new, ordering: .sequentiallyConsistent)
        reclaim(old)
    }

    /// Clears the snapshot (the Reference lost its last live context).
    func unpublish() {
        let old = _published.exchange(nil, ordering: .sequentiallyConsistent)
        reclaim(old)
    }

    private func reclaim(_ old: Unmanaged<_StateSnapshotBox<State>>?) {
        if _readers.load(ordering: .sequentiallyConsistent) == 0 {
            old?.release()
            if _retiredCount.load(ordering: .relaxed) > 0 { drainRetired() }
        } else if let old {
            _retiredLock.lock()
            _retired.append(old)
            _retiredCount.wrappingAdd(1, ordering: .relaxed)
            _retiredLock.unlock()
        }
    }

    private func drainRetired() {
        _retiredLock.lock()
        // Re-check under the lock: a concurrent writer may have retired a box between our
        // `_readers` load and this point, and a reader may still hold THAT box.
        if _readers.load(ordering: .sequentiallyConsistent) == 0 {
            let boxes = _retired
            _retired.removeAll(keepingCapacity: true)
            _retiredCount.store(0, ordering: .relaxed)
            _retiredLock.unlock()
            for box in boxes { box.release() }
        } else {
            _retiredLock.unlock()
        }
    }

    deinit {
        // No reader can be active: readers reach this object through a Reference they hold.
        _published.load(ordering: .relaxed)?.release()
        for box in _retired { box.release() }
    }
}
