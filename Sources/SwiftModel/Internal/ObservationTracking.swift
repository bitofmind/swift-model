import Foundation
import CustomDump
import Dependencies
import Observation

/// Sentinel type used as the subscript index for the parents observation key path.
/// Using a dedicated type (rather than Void or Int) guarantees no collision with
/// user-defined subscripts on Model types.
struct _ParentsObservationKey: Hashable, Sendable {}

extension Model {
    // Synthetic key path used to make the `parents` relationship observable.
    // The obscure name and subscript form guarantee no collision with user-defined properties.
    // Never called directly — it exists solely so that `\M[_parentsObservationKey:]` is a valid
    // typed KeyPath<M, [ModelID]> that can be passed to willAccess / willSet / didSet.
    subscript(_parentsObservationKey _: _ParentsObservationKey) -> [ModelID] {
        context!.lock {
            context!.parents.map { $0.anyModelID }
        }
    }
}

extension Model {
    // Synthetic key path used to make environment values observable per-context.
    // The subscript uses `AnyHashableSendable` as both key and return type so the path is
    // always `KeyPath<M, AnyHashableSendable>` regardless of the stored value type.
    // Never called for its value — it exists solely so that `\M[environmentKey: key]` is a
    // valid typed KeyPath that can be passed to willAccess / willSet / didSet / modifyCallbacks.
    subscript(environmentKey key: AnyHashableSendable) -> AnyHashableSendable {
        key
    }
}

extension Model {
    // Synthetic key path used to make preference contributions observable per-context.
    // Analogous to `environmentKey` for context storage, but for bottom-up preferences.
    // Never called for its value — it exists solely so that `\M[preferenceKey: key]` is a
    // valid typed KeyPath that can be passed to willAccess / willSet / didSet / modifyCallbacks.
    subscript(preferenceKey key: AnyHashableSendable) -> AnyHashableSendable {
        key
    }
}

/// Internal update function for testing with explicit path control.
///
/// This function establishes observation tracking for a value accessed via the `access` closure
/// and calls `onUpdate` whenever the dependencies change. It supports both AccessCollector
/// (default, works on all OS versions) and withObservationTracking (macOS 14+, opt-in) observation paths.
///
/// ## Coalescing Behavior
///
/// When `useCoalescing` is enabled, multiple rapid dependency changes are batched into a single
/// update callback:
///
/// ```swift
/// // Without coalescing: 100 mutations → 100 onUpdate calls
/// for i in 1...100 { model.value = i }  // 100 updates fired
///
/// // With coalescing: 100 mutations → 1-3 onUpdate calls
/// for i in 1...100 { model.value = i }  // 1-3 updates fired (coalesced)
/// ```
///
/// ### Transaction Handling
///
/// Coalescing behavior changes based on whether mutations occur inside or outside a transaction:
///
/// **Inside Transaction** (`node.transaction { }`):
/// - Updates are **deferred until transaction completes** (queued in `threadLocals.postTransactions`)
/// - Coalescing still applies: `hasPendingUpdate` flag prevents duplicate scheduling
/// - All mutations complete, then single coalesced update fires
/// - Result: 10 mutations → 0 updates during transaction → 1 update after
///
/// **Outside Transaction**:
/// - Updates are **deferred to background** using `backgroundCall`
/// - Uses `Task.detached` with cooperative yielding for responsiveness
/// - First mutation sets `hasPendingUpdate = true`, schedules coalesced update
/// - Subsequent mutations skip scheduling (update already pending)
/// - Coalesced update clears `hasPendingUpdate` flag when complete
/// - Result: 10 mutations → 1-3 background updates (coalesced)
///
/// This ensures:
/// - Transactions are atomic: no partial state visible to observers during transaction
/// - Background updates don't block the calling thread
/// - Coalescing benefits (100x fewer updates) apply in both scenarios
///
/// ## Observation Paths
///
/// ### withObservationTracking (default on supported platforms)
/// - Requires macOS 14.0+, iOS 17.0+, watchOS 10.0+, tvOS 17.0+
/// - Uses Swift's native `@Observable` and `withObservationTracking`
/// - Better integration with SwiftUI's observation system
/// - Completely rebuilds tracking on each update (by design of Swift's API)
///
/// ### AccessCollector (fallback and opt-in via `.disableObservationRegistrar`)
/// - Works on all OS versions (no macOS 14+ requirement)
/// - Uses custom dependency tracking with incremental updates
/// - **Optimization**: Reuses subscriptions when dependencies remain stable
/// - More efficient for high-frequency updates with stable observation patterns
///
/// ## Coalescing
///
/// When `useCoalescing` is enabled, the `update` mechanism uses two techniques to reduce redundant recomputations:
///
/// ### 1. hasPendingUpdate Flag (Both paths)
/// - Tracks whether an update is already scheduled for this observer
/// - When a dependency changes while an update is pending, skip scheduling another update
/// - Result: Multiple rapid mutations are coalesced into a single recomputation
///
/// ### 2. BackgroundCalls Batching
/// - Updates go through `backgroundCall()` which batches callbacks using `Task.yield()`
/// - Works both inside and outside transactions
/// - When used with `didModify` callback and dirty tracking:
///   - `didModify` marks cache dirty immediately (synchronous)
///   - Cache access checks dirty flag and recomputes on-demand if needed
///   - `backgroundCall` batches the `onUpdate` notifications
///   - This ensures fresh values are always available while reducing redundant recomputations
///
/// ### Performance Impact
/// - With coalescing + dirty tracking: 100 mutations → 1-2 recomputes (regardless of transaction)
/// - Without coalescing: 100 mutations → 100 recomputes
/// - The `didModify` callback enables coalescing to work safely inside transactions by providing
///   immediate dirty flag updates, while `backgroundCall` batches the observation notifications
///
/// ## Parameters
///
/// - Parameters:
///   - initial: Whether to call `onUpdate` with the initial value immediately
///   - isSame: Optional equality check to skip duplicate updates (nil = always update)
///   - useWithObservationTracking: Which observation path to use (true = withObservationTracking [default], false = AccessCollector)
///   - useCoalescing: Enable update coalescing (default: false for backward compatibility)
///   - didModify: Optional callback fired immediately when ANY dependency changes (before coalescing). Receives `true` when the change was forced (e.g. via `node.touch()`). Used by memoize for dirty tracking.
///   - access: Closure that accesses the value and establishes dependencies
///   - onUpdate: Callback fired when dependencies change (or immediately if `initial` is true)
///
/// - Returns: Cancellation function that tears down observation tracking
///
/// ## Thread Safety
///
/// This function is thread-safe and can be called from any thread. The observation tracking
/// and coalescing mechanisms are protected by appropriate synchronization primitives.
///
/// ## Example
///
/// ```swift
/// let model = MyModel().withAnchor()
/// 
/// let cancel = update(
///     initial: true,
///     isSame: { $0 == $1 },
///     useWithObservationTracking: false,
///     useCoalescing: true,
///     access: { model.computedValue },
///     onUpdate: { value in
///         print("Value changed to: \(value)")
///     }
/// )
///
/// // Later: cancel observation
/// cancel()
/// ```
/// Returns a `(cancel, forceNextUpdate)` pair.
/// - `cancel`: Call to unsubscribe from observations.
/// - `forceNextUpdate`: Call to set the `forceNext` flag so the next `update(with:)` call
///   bypasses `isSame`, even when the value hasn't changed. Used by `node.touch()`.
internal func update<T: Sendable>(
    initial: Bool,
    isSame: (@Sendable (T, T) -> Bool)?,
    useWithObservationTracking: Bool,
    useCoalescing: Bool = false,
    didModify: (@Sendable (Bool) -> Void)? = nil,
    backgroundCallQueue: BackgroundCallQueue = backgroundCall,
    access: @Sendable @escaping () -> T,
    onUpdate: @Sendable @escaping (T) -> Void
) -> (cancel: @Sendable () -> Void, forceNextUpdate: @Sendable () -> Void) {
    // Versioning for stale update detection
    // `index` is incremented before each recomputation to invalidate in-flight updates
    let last = LockIsolated((value: T?.none, index: 0))
    
    // updateLock ensures only one update processes at a time, preventing race conditions
    // when multiple threads trigger updates simultaneously
    let updateLock = NSRecursiveLock()

    // Shared force flag for this observer. Set to true by node.touch() (via either the
    // threadLocals.forceObservation thread-local for the synchronous AccessCollector path,
    // or the forceNext flag for the asynchronous withObservationTracking path).
    let forceNext = LockIsolated(false)
    
    /// Core update logic that:
    /// 1. Checks if this update is stale (index mismatch) - prevents out-of-order updates
    /// 2. Applies isSame check to skip duplicate values
    /// 3. Calls onUpdate if the value actually changed
    ///
    /// This function is called AFTER recomputation, either:
    /// - Immediately (when coalescing disabled)
    /// - Asynchronously via backgroundCall (when coalescing enabled)
    @Sendable func update(with value: T, index: Int) {
        updateLock.withLock {
            let (shouldUpdate, wasForced): (Bool, Bool) = last.withValue { last in
                // Stale update check: if index doesn't match, this update is outdated
                // A newer recomputation has started, so skip this one
                guard index == last.index else {
                    return (false, false)
                }

                // isSame check: skip if value hasn't actually changed.
                // Bypass when:
                // - threadLocals.forceObservation is set (synchronous AccessCollector path)
                // - forceNext is set (asynchronous withObservationTracking path, set by touch)
                let forced = threadLocals.forceObservation || forceNext.withValue { force in
                    defer { force = false }
                    return force
                }
                if let isSame, !forced {
                    if let last = last.value, isSame(last, value) {
                        return (false, false)  // Value unchanged, skip onUpdate
                    } else {
                        last.value = value  // Value changed, update cache
                    }
                }

                return (true, forced)
            }

            if shouldUpdate {
                if wasForced && !threadLocals.forceObservation {
                    // Propagate the force flag into the onUpdate call so that any nested
                    // observers (e.g. Observed { c } watching a memoized property) also
                    // bypass their own isSame checks and re-emit the current value.
                    threadLocals.withValue(true, at: \.forceObservation) {
                        onUpdate(value)
                    }
                } else {
                    onUpdate(value)
                }
            }
        }
    }

    @Sendable func updateInitial(with value: T) {
        last.withValue { last in
            if last.value == nil {
                last.value = value
            }
        }

        if initial {
            onUpdate(value)
        }
    }

    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), useWithObservationTracking {
        // withObservationTracking path (opt-in)
        // Uses Swift's native Observable tracking with main thread bridging for SwiftUI compatibility
        let hasBeenCancelled = LockIsolated(false)
        let hasPendingUpdate = LockIsolated(false)

        // Box for performUpdate so observe()'s onChange closure can reference it
        let performUpdateBox = LockIsolated<(@Sendable () -> Void)?>(nil)



        // Shared change handler used by withObservationTracking.onChange.
        @Sendable func onObservedChange() {
            if hasBeenCancelled.value { return }
            didModify?(false)

            let shouldSchedule = hasPendingUpdate.withValue { pending in
                if pending {
                    return false
                } else {
                    pending = true
                    return true
                }
            }

            guard shouldSchedule, let performUpdate = performUpdateBox.value else { return }

            if threadLocals.postTransactions != nil {
                threadLocals.postTransactions!.append { _ in
                    backgroundCallQueue(performUpdate)
                }
            } else {
                backgroundCallQueue(performUpdate)
            }
        }

        @Sendable func observe() -> T {
            let value = withObservationTracking {
                access()
            } onChange: {
                // Call didModify immediately when dependency changes (for dirty tracking).
                // onChange fires on the withObservationTracking path, which is always asynchronous,
                // so threadLocals.forceObservation is never set here. Pass false for now;
                // the async path uses ForceObserver + forceNext for touch propagation.
                onObservedChange()
            }
            return value
        }

        let performUpdate: @Sendable () -> Void = {
            // Guard against executing after cancellation (e.g. when the model has been
            // removed from the hierarchy). The onChange handler also checks this flag,
            // but there is a race window where:
            //   1. onChange fires and sees hasBeenCancelled=false → schedules performUpdate
            //   2. Model is deactivated → cancellable() sets hasBeenCancelled=true
            //   3. drainLoop executes the already-queued performUpdate
            // Without this guard, step 3 would call access() on a deactivated model,
            // potentially walking freed ancestor contexts (use-after-free in reduceHierarchy).
            if hasBeenCancelled.value { return }

            let (value, index) = last.withValue { last in
                last.index = last.index &+ 1

                // Clear hasPendingUpdate BEFORE observe() re-registers tracking.
                // Holding last's lock here ensures only one performUpdate runs at
                // a time, so clearing here is safe. Any mutation that fires onChange
                // during observe() will see hasPendingUpdate=false and schedule a new
                // performUpdate, which will block on last's lock until we finish.
                // Without this, the following race loses updates:
                //   1. observe() re-registers tracking
                //   2. Mutation fires the newly registered onChange
                //   3. onChange sees hasPendingUpdate=true (stale) → skips scheduling
                //   4. This performUpdate clears hasPendingUpdate → no new performUpdate
                //   5. Observer never gets the update
                hasPendingUpdate.setValue(false)

                // Signal to memoize's inner access closure that this observe() call is
                // coming from performUpdate. The closure uses this to always call produce()
                // and re-register withObservationTracking — even when isDirty=false — to
                // prevent the race where onUpdate clears isDirty before observe() runs,
                // which would cause withObservationTracking to track nothing (lost subscription).
                let v = threadLocals.withValue(true, at: \.isInsideAsyncPerformUpdate) {
                    observe()
                }
                return (v, last.index)
            }

            // update() compares value to last.value using isSame, which catches
            // any changes that happened during the gap between observations
            update(with: value, index: index)
        }
        performUpdateBox.setValue(performUpdate)

        updateInitial(with: observe())

        // node.touch() support for the withObservationTracking path:
        // withObservationTracking's onChange fires only on actual value changes and is
        // not triggered by touch(). We register secondary onModify callbacks (via a
        // ForceObserver) that react only to force=true, set forceNext, and schedule
        // performUpdate so the observer fires even without a value change.
        // Run AFTER updateInitial so that any cache-based access() is warm and
        // does not trigger extra recomputation in memoized properties.
        let forceObserver = ForceObserver(onForce: { [weak performUpdateBox] in
            forceNext.setValue(true)
            guard let performUpdate = performUpdateBox?.value else { return }
            backgroundCallQueue(performUpdate)
        })
        usingActiveAccess(forceObserver) { _ = access() }

        return (
            cancel: {
                hasBeenCancelled.withValue { $0 = true }
                // Nil out the box so no new performUpdate can be scheduled by
                // onObservedChange, and so the box no longer retains the
                // performUpdate closure. Any already-queued performUpdate on the
                // GCD backgroundCallQueue will early-return via hasBeenCancelled
                // and release its captured references on the GCD thread alone —
                // no concurrent release from _memoizeCache.removeAll().
                performUpdateBox.setValue(nil)
                forceObserver.cancel()
            },
            forceNextUpdate: {
                forceNext.setValue(true)
            }
        )
    } else {
        // AccessCollector path (default, works on all OS versions and threads)
        let hasPendingUpdate = LockIsolated(false)
        
        let collector = AccessCollector { collector, force in
            // Call didModify immediately when dependency changes (for dirty tracking).
            // `force` is true when the change was triggered by node.touch().
            didModify?(force)
            if force {
                forceNext.setValue(true)
            }

            // Coalescing: skip if update already pending
            if useCoalescing {
                let shouldSchedule = hasPendingUpdate.withValue { pending in
                    if pending {
                        return false  // Already have pending update
                    } else {
                        pending = true
                        return true
                    }
                }

                guard shouldSchedule else { return nil }
            }

            let performUpdate: @Sendable () -> Void = {
                let (value, index) = last.withValue { last in
                    last.index = last.index &+ 1

                    // Clear hasPendingUpdate BEFORE collector.reset() re-registers callbacks.
                    // Holding last's lock ensures only one performUpdate runs at a time.
                    // Any mutation firing onModify during re-registration sees hasPendingUpdate=false
                    // and schedules a new performUpdate, which blocks on last's lock until we finish.
                    // Same race as the withObservationTracking path — see comment there.
                    if useCoalescing {
                        hasPendingUpdate.setValue(false)
                    }

                    // Signal to memoize's inner access closure that this access() call is coming
                    // from a coalesced performUpdate. See the withObservationTracking path for
                    // the full explanation — the same race (isDirty cleared before performUpdate's
                    // access() runs) applies here with the AccessCollector coalescing path.
                    let value = collector.reset {
                        usingActiveAccess(collector) {
                            threadLocals.withValue(true, at: \.isInsideAsyncPerformUpdate) {
                                access()
                            }
                        }
                    }

                    return (value, last.index)
                }

                update(with: value, index: index)
            }

            if useCoalescing {
                // backgroundCallQueue schedules on next runloop iteration, allowing multiple
                // mutations to coalesce into a single update callback.
                return {
                    backgroundCallQueue(performUpdate)
                }
            } else {
                // Coalescing disabled: return callback to execute via context
                // The callback will be deferred if inside a transaction, or executed
                // immediately otherwise, based on context.onModify behavior
                return performUpdate
            }
        }

        let value = collector.reset {
            usingActiveAccess(collector) {
                access()
            }
        }

        updateInitial(with: value)

        return (
            cancel: {
                collector.reset { }
            },
            forceNextUpdate: {
                forceNext.setValue(true)
            }
        )
    }
}

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let onModify: @Sendable (AccessCollector, Bool) -> (@Sendable () -> Void)?
    let active = LockIsolated<(active: [Key: @Sendable () -> Void], added: Set<Key>)>(([:], []))

    struct Key: Hashable, @unchecked Sendable {
        var id: ModelID
        var path: AnyKeyPath
    }

    init(onModify: @Sendable @escaping (AccessCollector, Bool) -> (@Sendable () -> Void)?) {
        self.onModify = onModify
        super.init(useWeakReference: false)
    }

    deinit {
        for cancel in active.value.active.values {
            cancel()
        }
    }

    func reset<Value>(_ access: () -> Value) -> Value {
        let keys = active.withValue {
            $0.added.removeAll(keepingCapacity: true)
            return Set($0.active.keys)
        }

        let value = access()

        let cancels = active.withValue { active in
            let noLongerActive = keys.subtracting(active.added)
            let cancels = active.active.filter { noLongerActive.contains($0.key) }.map(\.value)
            defer {
                for key in noLongerActive {
                    active.active.removeValue(forKey: key)
                }
            }
            return cancels
        }

        for cancel in cancels {
            cancel()
        }

        return value
    }

    override var shouldPropagateToChildren: Bool { false }

    override func willAccess<M: Model, T>(from context: Context<M>, at path: KeyPath<M._ModelState, T>&Sendable) -> (() -> Void)? {
        let key = Key(id: context.anyModelID, path: path)

        let isActive = active.withValue {
            $0.added.insert(key)
            return $0.active[key] != nil
        }

        if !isActive {
            // Make sure to call this outside active lock to avoid dead-locks with context lock.
            let cancellation = context.onModify(for: path) { finished, force in
                if finished { return {} }
                return self.onModify(self, force)
            }

            active.withValue {
                $0.active[key] = cancellation
            }
        }

        return nil
    }
}

/// A `ModelAccess` subclass used by the `withObservationTracking` path to support
/// `node.touch()`. Registers `onModify` callbacks for each accessed path, but only
/// invokes `onForce` when the callback is called with `force=true`. Normal writes
/// (force=false) are ignored — they are already handled by `withObservationTracking`.
private final class ForceObserver: ModelAccess, @unchecked Sendable {
    let onForce: @Sendable () -> Void
    let cancels = LockIsolated<[@Sendable () -> Void]>([])

    init(onForce: @Sendable @escaping () -> Void) {
        self.onForce = onForce
        super.init(useWeakReference: false)
    }

    deinit { cancel() }

    func cancel() {
        let cs = cancels.withValue { cs in
            defer { cs = [] }
            return cs
        }
        for c in cs { c() }
    }

    override var shouldPropagateToChildren: Bool { false }

    override func willAccess<M: Model, T>(from context: Context<M>, at path: KeyPath<M._ModelState, T> & Sendable) -> (() -> Void)? {
        let cancellation = context.onModify(for: path) { [weak self] finished, force in
            if finished { return {} }
            guard force, let self else { return nil }
            self.onForce()
            return nil
        }
        cancels.withValue { $0.append(cancellation) }
        return nil
    }
}

/// Returns true if `lhs` and `rhs` represent the same value based on identity semantics:
/// - Model with Equatable: compared by == (respects user-defined equality)
/// - Model without Equatable: compared by ModelID (identity)
/// - ModelContainer (Array, Optional, …): compared by element ModelIDs (containerIsSame)
/// - Equatable (non-model types): compared by ==
/// - Otherwise: always returns false (always trigger)
///
/// Ordering matters for two reasons:
/// 1. `Model` before `ModelContainer` — `Model: ModelContainer`, so a plain model would be
///    caught by the ModelContainer branch, where `containerIsSame` falls through to `false`
///    (always-trigger) instead of comparing by identity.
/// 2. `ModelContainer` before `Equatable` — `Array<M>: Equatable when M: Equatable`, so an
///    array of equatable models would use `Array.==` (value comparison) instead of element identity.
func dynamicEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    if let l = lhs as? any Model {
        if let le = l as? any Equatable {
            return _dynamicEquatableEqual(le, rhs)
        }
        return l.modelID == (rhs as! any Model).modelID
    }
    if let l = lhs as? any ModelContainer {
        return _dynamicContainerEqual(l, rhs)
    }
    if let l = lhs as? any Equatable {
        return _dynamicEquatableEqual(l, rhs)
    }
    return false
}

private func _dynamicContainerEqual<T: ModelContainer>(_ lhs: T, _ rhs: Any) -> Bool {
    guard let r = rhs as? T else { return false }
    return containerIsSame(lhs, r)
}

func _dynamicEquatableEqual<T: Equatable>(_ lhs: T, _ rhs: Any) -> Bool {
    guard let r = rhs as? T else { return false }
    return lhs == r
}

/// Builds a typed isSame closure once (for memoize first-access setup) based on the type's identity semantics.
/// Uses the same ordering as `dynamicEqual` — see that function's doc comment for the rationale.
/// Uses existential casting inside closures because Swift cannot infer static conformance from a runtime `is` check.
func buildObservationIsSame<T>(_ type: T.Type) -> (@Sendable (T, T) -> Bool)? {
    if T.self is any Model.Type {
        if T.self is any Equatable.Type {
            return { l, r in
                guard let le = l as? any Equatable else { return false }
                return _dynamicEquatableEqual(le, r as Any)
            }
        }
        return { l, r in (l as! any Model).modelID == (r as! any Model).modelID }
    }
    if T.self is any ModelContainer.Type {
        return { l, r in
            guard let lc = l as? any ModelContainer else { return false }
            return _dynamicContainerEqual(lc, r as Any)
        }
    }
    if T.self is any Equatable.Type {
        return { l, r in
            guard let le = l as? any Equatable else { return false }
            return _dynamicEquatableEqual(le, r as Any)
        }
    }
    return nil
}

protocol _Optional {
    associatedtype Wrapped
    var isNil: Bool { get }

    var wrappedValue: Wrapped? { get }
}

extension Optional: _Optional {
    var isNil: Bool { self == nil }

    var wrappedValue: Wrapped? {
        self
    }
}

private func isNil<T>(_ value: T) -> Bool {
    (value as? any _Optional)?.isNil ?? false
}

