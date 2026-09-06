import Foundation

public extension ModelNode {
    /// Excludes one or more properties from ``observeModifications()`` notifications.
    ///
    /// Call this from `onActivate()` to mark specific properties of this model as "transient"
    /// — changes to them will not trigger any ``observeModifications()`` stream registered on
    /// this model or any of its ancestors.
    ///
    /// This is useful for volatile or cache-like properties (search results, UI state, scroll
    /// positions) that change frequently but whose changes are not meaningful to observers of
    /// the model tree as a whole.
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Autosave triggers on real content changes, not on UI-only state
    ///     node.excludeFromModifications(\.cachedResults, \.scrollOffset)
    /// }
    /// ```
    ///
    /// > Note: Exclusions only affect ``observeModifications()``. Other observation mechanisms
    /// > (SwiftUI `@Observable`, ``Observed``, ``ModelNode/memoize(for:produce:)``,
    /// > ``ModelNode/trackUndo(_:)``) are unaffected.
    func excludeFromModifications<each PathValue: Sendable>(
        _ paths: repeat WritableKeyPath<M, each PathValue> & Sendable
    ) {
        guard let context = enforcedContext() else { return }

        // Use BackingPathCollector to map each user-visible computed path to its underlying
        // @_ModelTracked backing storage path — the same technique used by trackUndo(_ paths:).
        let collector = BackingPathCollector<M>()
        usingActiveAccess(collector) {
            func collect<PV>(_ path: WritableKeyPath<M, PV> & Sendable) {
                _ = context.model[keyPath: path]
            }
            repeat collect(each paths)
        }

        context.lock {
            // Map each backing path to its property index ONCE, here; the write path checks
            // the exclusion by index and never hashes a key path.
            let newIndices = Set(collector.paths.compactMap { context.trackedIndex(of: $0) })
            if context.modificationExcludedIndices == nil {
                context.modificationExcludedIndices = newIndices
            } else {
                context.modificationExcludedIndices!.formUnion(newIndices)
            }
        }
    }
}
