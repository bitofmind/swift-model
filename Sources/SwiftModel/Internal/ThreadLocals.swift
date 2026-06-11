import Foundation

@usableFromInline
final class ThreadLocals: @unchecked Sendable {
    var postTransactions: [(inout [() -> Void]) -> Void]? = nil
    @usableFromInline var forceDirectAccess = false
    /// Set by the public `withUntrackedModelReads { }` scope. While `true`, the
    /// `_ModelSourceBox` read subscripts skip `willAccessDirect` entirely (no
    /// ObservationRegistrar access, no `ModelAccess.willAccess` dispatch, no child
    /// access stamping) and `willAccessSyntheticPath` / `ModelContext.willAccess`
    /// return early — so reads register no observation dependencies anywhere.
    ///
    /// Unlike `forceDirectAccess`, reads still route through the context subscript
    /// and therefore still take the context lock — untracked reads stay memory-safe
    /// against concurrent writers; only the observation machinery is bypassed.
    ///
    /// Framework-driven dependency collection (`update()` in ObservationTracking,
    /// used by `node.memoize` and `Observed`) explicitly clears this flag around its
    /// `access()` evaluations so that a memoize/observer set up inside an untracked
    /// scope still registers its own dependencies.
    @usableFromInline var untrackedReads = false
    var didReplaceModelWithDestructedOrFrozenCopy = false
    var includeImplicitIDInMirror = false
    var includeChildrenInMirror = false
    /// When non-nil, `ModelContext.mirror(of:children:)` operates in shallow snapshot mode.
    /// `0` means this is the root model — show its direct properties.
    /// Any positive value means this is a descendant model — return an empty mirror (type name only).
    /// Set via `threadLocals.withValue(0 as Int?, at: \.shallowMirrorDepth)` to scope to one snapshot.
    var shallowMirrorDepth: Int? = nil
    var isRestoringState = false
    /// Closures registered to run after the current postLockCallbacks pass completes.
    /// Non-nil only while postLockCallbacks are executing. Use this to schedule work
    /// that must run after ALL per-property onModify callbacks in a transaction batch.
    var postLockFlushes: [() -> Void]? = nil
    /// When non-nil, `TestAccess.didModify` and `willAccess` tag their `ValueUpdate`/`Access`
    /// entries with this area instead of the default `.state`. Set by `Context<M>` around
    /// the typed context storage path calls so context changes are reported under `.local`.
    var modificationArea: _ExhaustivityBits? = nil
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
    /// When non-nil, the TestAccess `willAccess`/`didModify` closures for a context/preference
    /// storage path (_metadata / _preference stub subscripts) should use this pre-computed value
    /// instead of calling the `fatalError()` stub getter on `M._ModelState`.
    /// Set by `Context.willAccessStorage`/`didModifyStorage` before invoking the TestAccess closure.
    var precomputedStorageValue: Any? = nil
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
    /// Set to `true` immediately before `observe()` is called inside `performUpdate` for the
    /// `withObservationTracking` path. Allows memoize's inner access closure to detect that it
    /// is being called from an async `performUpdate` (rather than from `forceObserver` setup or
    /// the dirty-path synchronous read), so it can always call `produce()` and re-register
    /// `withObservationTracking` tracking — even when `isDirty=false` due to a concurrent
    /// `onUpdate` clearing it before this `performUpdate`'s `observe()` runs.
    var isInsideAsyncPerformUpdate = false
    /// When non-nil, the Context subscript `_read` returns this value instead of the live
    /// model value. Set by `TestAccess.willAccess` in transitions mode so that predicate
    /// evaluation sees the front-of-queue historical value (or the expectedState baseline)
    /// rather than the current live state.
    /// Consumed by the `willAccess` returned closure after the Context subscript yields.
    @usableFromInline var transitionOverrideValue: Any? = nil
    /// Monotonically incrementing counter set when an outer `node.transaction { }` begins.
    /// Each outer transaction gets a new unique ID; nested transactions see the outer ID.
    /// `TestAccess.didModify` captures this at write time so multiple writes to the same
    /// path within one transaction can be coalesced into a single `valueUpdates` entry.
    /// Zero means the write occurred outside any transaction.
    var currentTransactionID: UInt = 0
    /// `true` while a debug-side `customDump` is walking a model value (e.g. inside
    /// `emitDebugTrigger`'s `dumpForDebug`, or the initial-value capture in
    /// `ViewAccess.willAccess`). Read by `ViewAccess.willAccess` to skip BOTH
    /// dependency registration *and* `captureAccessStack` capture for property reads
    /// originating from the dump itself — otherwise every `.withValue` emit walks the
    /// model tree, registers each traversed property as a tracked dep, and pollutes
    /// the captured access-stack with the dump path (not user code). Scoped via
    /// `threadLocals.withValue(true, at: \.isInsideDebugDump) { … }` at every dump
    /// site that runs through stamped `ViewAccess`. Has no effect outside `#if DEBUG`.
    var isInsideDebugDump = false

    /// `true` while memoize's **dirty-recompute** path is calling `produce()`
    /// directly (not through `update()`'s `observe()` wrap). Read by
    /// `Context.willAccessDirect` and `Context.willAccessSyntheticPath` to skip
    /// BOTH the swift-model `ModelAccess.willAccess` dispatch and Apple's
    /// `registrar.access(...)` — so reads inside the synchronous dirty recompute
    /// don't leak to whatever outer observation is active (a SwiftUI body's
    /// `withObservationTracking`, a `ViewAccess` from `$model.debug`, a debug
    /// collector, etc.).
    ///
    /// Memoize's *own* dependency tracking is unaffected because the dirty-
    /// recompute branch doesn't need to re-track: the AccessCollector path's
    /// onModify subscriptions stay live across recomputes, and the
    /// `withObservationTracking` path re-tracks via the async `performUpdate`
    /// (which goes through `observe()`, not this flag). The cache-miss /
    /// first-access path also goes through `observe()` and isn't flagged.
    var isInsideMemoizeProduce = false

    /// Sibling of `isInsideMemoizeProduce`, set during the *async* memoize
    /// `observe()` path (registrar / `withObservationTracking` branch). Unlike
    /// `isInsideMemoizeProduce`, this flag only suppresses the SwiftModel-side
    /// `ViewAccess`/`TestAccess`/`DebugAccessCollector` dispatch — Apple's
    /// `registrar.access(...)` calls upstream still run so memoize's own
    /// `withObservationTracking` continues to capture the inner reads.
    ///
    /// Without this, every read inside the memoize body still fires through the
    /// model value's stamped access (the `accessBox._reference?.access` branch
    /// of `Context.willAccessDirect`, which `usingActiveAccess(nil)` does NOT
    /// clear). On a debug-tracked view the parent's `ViewAccess` then registers
    /// dependencies for whatever the memoize body touches and the trigger log
    /// attributes those reads to the parent — the very leakage the memoize
    /// is supposed to prevent.
    var isInsideMemoizeObserve = false

    /// When non-nil, `ObservationTracking.onObservedChange` defers its
    /// `backgroundCallQueue(performUpdate)` enqueue into this array instead
    /// of enqueuing inline. Used by all write paths (`Context.subscript._modify`,
    /// `Context.stateTransaction`, `Context.transaction(at:...)` and
    /// `Context.transaction(writeLockHolder:_:)`) to ensure that `performUpdate`
    /// does not start running on the cooperative pool until after the writer's
    /// lock-held + post-callback phases have completed.
    ///
    /// **The race this closes** — the `withObservationTracking` observation path
    /// has two listeners that both schedule `performUpdate` on the same writer:
    ///
    ///   1. Apple's `withObservationTracking.onChange` (one-shot) — fires
    ///      synchronously inside `invokeDidModifyDirect` (registrar.willSet
    ///      callback dispatch) while the writer holds the context lock.
    ///   2. The shadow `AccessCollector` (gap-race detector, persistent
    ///      per-(context, path) subscription) — registered as a `context.onModify`
    ///      modifyCallback; fires as a *post-callback* via `runPostLockCallbacks`
    ///      *after* the writer releases the lock.
    ///
    /// Both call `onObservedChange`, which dedups via a shared `hasPendingUpdate`
    /// flag. If `performUpdate` starts running on the cooperative pool between
    /// Apple's onChange and the shadow's post-callback (a tight window that opens
    /// the moment Apple's onChange enqueues), it can clear `hasPendingUpdate=false`
    /// (it must clear BEFORE the next `observe()` re-registration to avoid losing
    /// the next write — see the comment in `performUpdate`). The shadow's
    /// post-callback then reads the just-cleared flag and schedules a duplicate
    /// `performUpdate` for the same write Apple already handled.
    ///
    /// Deferring the enqueue serialises both schedules against the writer's
    /// lock-held + post-callback window — by the time `performUpdate` can start,
    /// every `onObservedChange` for the current write has already made its dedup
    /// decision against the same `hasPendingUpdate` snapshot. This matches what
    /// the `AccessCollector` observation path already does naturally: its
    /// `onModify` returns the `backgroundCallQueue(performUpdate)` as a
    /// post-callback that `runPostLockCallbacks` invokes after lock release, so
    /// `performUpdate` never starts mid-write.
    ///
    /// Drained on the same thread, at the end of the outermost write, after the
    /// lock has been released and `runPostLockCallbacks` has finished. Nested
    /// writes share the outer scope's array — they append but don't drain. Items
    /// are invoked in registration order.
    var lockHeldBackgroundCalls: [() -> Void]? = nil

    /// When non-nil, `Context.willAccessDirect` ALSO dispatches `willAccess`
    /// to this collector (in addition to the existing `activeAccess` / Apple
    /// registrar paths), giving observe()'s gap-race fix a way to register
    /// per-(context, path) `context.onModify` subscriptions synchronously
    /// with each read.
    ///
    /// Set by `ObservationTracking.observe()` for the `withObservationTracking`
    /// branch only. Outside that scope this is `nil` and incurs zero cost.
    /// Dispatched separately from `ModelAccess.active` because that task-local
    /// is intentionally kept `nil` inside observe() (see the comment block in
    /// `observe()` for why) — overriding it would inadvertently suppress
    /// Apple's `registrar.access(...)` via the
    /// `!(isInsideAsyncPerformUpdate && cachedActive != nil)` guard.
    var gapShadowCollector: ModelAccess? = nil

    var pendingStack = _PendingStackBox()

    fileprivate init() {}

    deinit {
        // Defensively clear the pending stack on thread exit. GCD threads can be
        // recycled many times across tests before the OS terminates them; any stale
        // pre-anchor Reference left in `latest` is released here explicitly rather
        // than as part of the implicit _PendingStackBox field release. `stack` is
        // also cleared to drain any incomplete model-init entries.
        pendingStack.latest = nil
        pendingStack.stack.removeAll()
    }

    func withValue<Value, T>(_ value: Value, at path: ReferenceWritableKeyPath<ThreadLocals, Value>, perform: () throws -> T) rethrows -> T {
        let prevValue = self[keyPath: path]
        defer {
            self[keyPath: path] = prevValue
        }
        self[keyPath: path] = value
        return try perform()
    }
}

#if os(WASI)
// WASI is single-threaded; a plain global suffices in place of pthread TLS.
private let _wasiThreadLocals = ThreadLocals()
@usableFromInline var threadLocals: ThreadLocals { _wasiThreadLocals }
#else
@usableFromInline var threadLocals: ThreadLocals {
    if let state = pthread_getspecific(threadLocalsKey) {
        return Unmanaged<ThreadLocals>.fromOpaque(state).takeUnretainedValue()
    }
    let state = ThreadLocals()
    pthread_setspecific(threadLocalsKey, Unmanaged.passRetained(state).toOpaque())
    return state
}

private let threadLocalsKey: pthread_key_t = {
    var key: pthread_key_t = 0
    // pthread_key_create's destructor parameter is annotated _Nonnull on Apple platforms
    // but remains nullable (void *) on Linux and Android, so the Swift signatures differ.
    #if os(Linux) || os(Android)
    let cleanup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { state in
        guard let state else { return }
        Unmanaged<ThreadLocals>.fromOpaque(state).release()
    }
    #else
    let cleanup: @convention(c) (UnsafeMutableRawPointer) -> Void = { state in
        Unmanaged<ThreadLocals>.fromOpaque(state).release()
    }
    #endif
    pthread_key_create(&key, cleanup)
    return key
}()
#endif
