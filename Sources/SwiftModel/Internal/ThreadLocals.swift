import Foundation

final class ThreadLocals: @unchecked Sendable {
    var postTransactions: [(inout [() -> Void]) -> Void]? = nil
    var forceDirectAccess = false
    var didReplaceModelWithDestructedOrFrozenCopy: () -> Void = {}
    var includeInMirror = false
    var includeChildrenInMirror = false
    var isRestoringState = false
    /// Closures registered to run after the current postLockCallbacks pass completes.
    /// Non-nil only while postLockCallbacks are executing. Use this to schedule work
    /// that must run after ALL per-property onModify callbacks in a transaction batch.
    var postLockFlushes: [() -> Void]? = nil
    /// When non-nil, `TestAccess.didModify` and `willAccess` tag their `ValueUpdate`/`Access`
    /// entries with this area instead of the default `.state`. Set by `Context<M>` around
    /// the typed context storage path calls so context changes are reported under `.context`.
    var modificationArea: Exhaustivity? = nil
    /// Guards against infinite recursion in `willAccessStorage`/`didModifyStorage`.
    /// Reading `readModel[keyPath: \M[_metadata: storage]]` inside the TestAccess closure
    /// re-enters `willAccessStorage` through the context getter. This flag breaks that cycle.
    var isAccessingMetadataStorage = false
    /// Set while `TestAccess` is applying `Access.apply` closures to snapshot copies inside
    /// the `isEqualIncludingIds` lock. Writing through a `_preference` or `_metadata` keypath
    /// triggers `willAccessPreference`/`willAccessStorage`, which tries to create new keypaths
    /// via `_swift_getKeyPath` — a Swift-runtime operation that can deadlock when another
    /// runtime lock is already held. This flag causes those re-entrant `willAccess*` calls
    /// to return early, since snapshot comparison has no need for observation side effects.
    var isApplyingSnapshot = false
    /// When non-nil, the TestAccess `willAccess` closure for a preference keypath should use
    /// this pre-computed aggregated value instead of re-reading via `model.context![path]`.
    /// Set by `Context.willAccessPreferenceValue` before invoking the TestAccess closure,
    /// avoiding re-entry into `preferenceValue` (which would acquire child locks and deadlock).
    var precomputedPreferenceValue: Any? = nil
    /// The human-readable property name of the context or preference storage key currently
    /// being accessed/modified. Set by `Context<M>` around typed storage path calls so
    /// `TestAccess` can use it in `debugInfo` messages (e.g. `"context.isDarkMode"`)
    /// instead of falling back to `propertyName(from:path:)` which returns nil for synthetic paths.
    var storageName: String? = nil
    /// When `true`, the `update(with:index:)` function skips the `isSame` duplicate-suppression
    /// check and always fires `onUpdate`. Set by `Context.touch()` so that `Observed` callbacks
    /// re-emit the current value even when it hasn't changed.
    var forceObservation = false
    /// When non-nil, `invokeDidModify` defers `ObservationRegistrar` `willSet`/`didSet`
    /// notifications into this array instead of firing them inline. Drained at `withBatchedUpdates`
    /// scope exit. Non-nil only while a `withBatchedUpdates` scope is active on this thread.
    var pendingObservationNotifications: [() -> Void]? = nil

    fileprivate init() {}

    func withValue<Value, T>(_ value: Value, at path: ReferenceWritableKeyPath<ThreadLocals, Value>, perform: () throws -> T) rethrows -> T {
        let prevValue = self[keyPath: path]
        defer {
            self[keyPath: path] = prevValue
        }
        self[keyPath: path] = value
        return try perform()
    }
}

var threadLocals: ThreadLocals {
    if let state = pthread_getspecific(threadLocalsKey) {
        return Unmanaged<ThreadLocals>.fromOpaque(state).takeUnretainedValue()
    }
    let state = ThreadLocals()
    pthread_setspecific(threadLocalsKey, Unmanaged.passRetained(state).toOpaque())
    return state
}

private let threadLocalsKey: pthread_key_t = {
    var key: pthread_key_t = 0
    let cleanup: @convention(c) (UnsafeMutableRawPointer) -> Void = { state in
        Unmanaged<ThreadLocals>.fromOpaque(state).release()
    }
    pthread_key_create(&key, cleanup)
    return key
}()
