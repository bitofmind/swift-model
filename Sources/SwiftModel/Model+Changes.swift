import Foundation
import CustomDump
import Dependencies
import Observation

public extension ModelNode {
    /// Caches the result of an expensive computation and automatically recomputes when dependencies change.
    ///
    /// Memoization is useful for computed properties that depend on model state and are expensive to calculate
    /// (e.g., sorting, filtering, complex calculations). The memoized value is cached and only recomputed when
    /// the properties accessed within `produce` change.
    ///
    /// - Parameters:
    ///   - key: A unique key identifying this memoized computation. Must be unique within the model.
    ///   - produce: A closure that computes the value. Any model properties accessed within this closure
    ///              will be automatically tracked as dependencies.
    ///
    /// - Returns: The cached value, or the result of `produce()` if not yet cached or if dependencies changed.
    ///
    /// ## Basic Usage
    ///
    /// ```swift
    /// @Model struct DataModel {
    ///     var items: [Item] = []
    ///
    ///     var sortedItems: [Item] {
    ///         node.memoize(for: "sorted") {
    ///             items.sorted { $0.name < $1.name }
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// ## Automatic Dependency Tracking
    ///
    /// The `produce` closure is executed once on first access, and SwiftModel tracks which properties
    /// are read during execution. When any of those properties change, the cached value is invalidated
    /// and recomputed on the next access:
    ///
    /// ```swift
    /// let sorted = model.sortedItems  // Computes and caches
    /// let again = model.sortedItems   // Returns cached value (fast!)
    ///
    /// model.items.append(newItem)     // Invalidates cache
    /// let updated = model.sortedItems // Recomputes with new item
    /// ```
    ///
    /// ## Performance Characteristics
    ///
    /// - **First access**: O(n) where n is the complexity of `produce()`
    /// - **Cache hit**: O(1) with lock acquisition overhead
    /// - **After change**: Recomputes on next access (lazy evaluation)
    ///
    /// **Note**: Currently, each property mutation triggers an immediate recomputation. For bulk updates,
    /// wrap modifications in `node.transaction { }` to batch changes (optimization in progress).
    ///
    /// ## When to Use Memoization
    ///
    /// **Good candidates:**
    /// - Sorting/filtering large collections
    /// - Complex calculations (aggregations, statistics)
    /// - Expensive transformations (JSON parsing, formatting)
    /// - Frequently accessed computed properties
    ///
    /// **Avoid for:**
    /// - Trivial computations (simple arithmetic, property access)
    /// - Rarely accessed values
    /// - Computations with no dependencies on model state
    ///
    /// ## Manual Cache Control
    ///
    /// You can explicitly invalidate the cache using `resetMemoization(for:)`:
    ///
    /// ```swift
    /// node.resetMemoization(for: "sorted")
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// Memoize is thread-safe and can be called from any thread. The cache is protected by locks
    /// to ensure consistency across concurrent access.
    ///
    /// - Note: For `Equatable` types, use the overload that accepts `isSame` to avoid recomputing
    ///         when the value hasn't actually changed.
    func memoize<T: Sendable>(for key: some Hashable&Sendable, debug: DebugOptions? = nil, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: buildObservationIsSame(T.self), debug: debug)
    }

    /// Caches the result of an expensive computation with automatic duplicate detection.
    ///
    /// This overload is optimized for `Equatable` types and only triggers observer notifications
    /// when the recomputed value differs from the cached value.
    ///
    /// - Parameters:
    ///   - key: A unique key identifying this memoized computation.
    ///   - produce: A closure that computes the value.
    ///
    /// - Returns: The cached value, or the result of `produce()` if not cached or dependencies changed.
    ///
    /// ## Example: Avoiding Unnecessary Updates
    ///
    /// ```swift
    /// @Model struct SearchModel {
    ///     var query: String = ""
    ///     var items: [Item] = []
    ///
    ///     var hasResults: Bool {
    ///         node.memoize(for: "hasResults") {
    ///             !items.filter { $0.matches(query) }.isEmpty
    ///         }
    ///     }
    /// }
    ///
    /// // If query changes but results remain empty, observers are NOT notified
    /// model.query = "abc"  // hasResults: false → false (no notification)
    /// model.query = "xyz"  // hasResults: false → false (no notification)
    /// model.items = [...]  // hasResults: false → true (notification sent!)
    /// ```
    func memoize<T: Sendable&Equatable>(for key: some Hashable&Sendable, debug: DebugOptions? = nil, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: buildObservationIsSame(T.self), debug: debug)
    }

    /// Caches a tuple computation with automatic duplicate detection for each element.
    ///
    /// - Parameters:
    ///   - key: A unique key identifying this memoized computation.
    ///   - produce: A closure that computes the tuple value.
    ///
    /// - Returns: The cached tuple, or the result of `produce()` if not cached or dependencies changed.
    func memoize<each T: Sendable&Equatable>(for key: some Hashable&Sendable, debug: DebugOptions? = nil, produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
        memoize(for: key, produce: produce, isSame: isSame, debug: debug)
    }

    /// Caches a computation using source location as the cache key.
    ///
    /// This convenience overload automatically generates a unique key based on the call site's
    /// file, line, and column. Useful when you don't want to manually specify keys:
    ///
    /// ```swift
    /// var sortedItems: [Item] {
    ///     node.memoize {  // Key is auto-generated from call site
    ///         items.sorted()
    ///     }
    /// }
    /// ```
    ///
    /// **Warning**: If you have multiple memoize calls on the same line (e.g., in a multi-line
    /// expression), they will share the same key and conflict. Use explicit keys in such cases.
    ///
    /// - Parameter produce: A closure that computes the value.
    /// - Returns: The cached value, or the result of `produce()` if not cached or dependencies changed.
    func memoize<T: Sendable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, debug: DebugOptions? = nil, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), debug: debug, produce: produce)
    }

    /// Caches an `Equatable` computation using source location as the cache key.
    ///
    /// Combines automatic key generation with duplicate value detection.
    ///
    /// - Parameter produce: A closure that computes the value.
    /// - Returns: The cached value, or the result of `produce()` if not cached or dependencies changed.
    func memoize<T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, debug: DebugOptions? = nil, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), debug: debug, produce: produce)
    }

    /// Caches a tuple computation using source location as the cache key.
    ///
    /// - Parameter produce: A closure that computes the tuple value.
    /// - Returns: The cached tuple, or the result of `produce()` if not cached or dependencies changed.
    func memoize<each T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, debug: DebugOptions? = nil, produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), debug: debug, produce: produce)
    }

    /// Explicitly clears the cached value for a memoized computation.
    ///
    /// Use this to manually invalidate a cache when you know the value should be recomputed,
    /// even if SwiftModel hasn't detected a change in dependencies.
    ///
    /// ```swift
    /// @Model struct CacheModel {
    ///     var data: [Item] = []
    ///
    ///     var processed: [ProcessedItem] {
    ///         node.memoize(for: "processed") {
    ///             expensiveProcessing(data)
    ///         }
    ///     }
    ///
    ///     func forceRefresh() {
    ///         node.resetMemoization(for: "processed")
    ///     }
    /// }
    /// ```
    ///
    /// **Note**: This cancels the dependency tracking subscription and removes the cached value.
    /// The next access will recompute and re-establish tracking.
    ///
    /// - Parameter key: The key used when creating the memoized computation.
    func resetMemoization(for key: some Hashable&Sendable) {
        guard let context = enforcedContext() else { return }

        let key = AnyHashableSendable(key)
        context.lock {
            context._memoizeCache[key]?.cancellable?()
            context._memoizeCache.removeValue(forKey: key)
        }
    }
}

extension Observed {
    init(access: @Sendable @escaping () -> Element, initial: Bool = true, isSame: (@Sendable (Element, Element) -> Bool)?, coalesceUpdates: Bool = false, debug: DebugOptions? = nil) {
        stream = AsyncStream { cont in
            // Detect whether accessed models use ObservationRegistrar.
            // If any accessed model was created with .disableObservationRegistrar, the
            // withObservationTracking path won't fire (the model's access(path:from:) is a no-op).
            // In that case we fall back to AccessCollector which works on all configurations.
            let useWithObservationTracking: Bool
            if coalesceUpdates {
                let detector = RegistrarDetector()
                _ = usingActiveAccess(detector) { access() }
                useWithObservationTracking = detector.allHaveRegistrar
            } else {
                useWithObservationTracking = false
            }

#if DEBUG
            if let debug {
                let cancel = debugObserve(
                    options: debug,
                    label: debug.name ?? "Observed",
                    access: access,
                    onUpdate: { value in cont.yield(value) }
                ) { wrappedAccess, wrappedOnUpdate in
                    let (cancellable, _) = update(initial: initial, isSame: isSame, useWithObservationTracking: useWithObservationTracking, useCoalescing: coalesceUpdates) {
                        wrappedAccess()
                    } onUpdate: { value in wrappedOnUpdate(value) }
                    return cancellable
                }
                cont.onTermination = { _ in cancel() }
            } else {
                let (cancellable, _) = update(initial: initial, isSame: isSame, useWithObservationTracking: useWithObservationTracking, useCoalescing: coalesceUpdates) {
                    access()
                } onUpdate: { value in
                    cont.yield(value)
                }
                cont.onTermination = { _ in cancellable() }
            }
#else
            let (cancellable, _) = update(initial: initial, isSame: isSame, useWithObservationTracking: useWithObservationTracking, useCoalescing: coalesceUpdates) {
                access()
            } onUpdate: { value in
                cont.yield(value)
            }
            cont.onTermination = { _ in cancellable() }
#endif
        }
    }
}

/// Probes the `access` closure to determine whether all accessed model contexts have
/// an `ObservationRegistrar`. Used by `Observed.init` to select the correct observation path.
private final class RegistrarDetector: ModelAccess, @unchecked Sendable {
    /// `true` if every accessed context has an `ObservationRegistrar` (or no model was accessed).
    var allHaveRegistrar = true

    init() {
        super.init(useWeakReference: false)
    }

    override func willAccess<M: Model, T>(from context: Context<M>, at path: KeyPath<M._ModelState, T> & Sendable) -> (() -> Void)? {
        if !context.hasObservationRegistrar {
            allHaveRegistrar = false
        }
        return nil
    }
}

private extension ModelNode {
    /// Memoize implementation with two-layer observation tracking:
    ///
    /// **Internal Tracking (dependency tracking):**
    /// - Uses `update()` function to track which properties the computation depends on (e.g., model.value)
    /// - When dependencies change, `update()`'s onChange fires → calls onUpdate callback
    /// - Can use either withObservationTracking (iOS 17+) or AccessCollector (pre-iOS 17)
    /// - Uses withObservationTracking if ObservationRegistrar exists, otherwise falls back to AccessCollector
    ///
    /// **External Tracking (memoize property tracking):**
    /// - Observers can track the memoized property itself via \Model[memoizeKey: key]
    /// - willAccess() call allows ViewAccess (SwiftUI) to register onModify callbacks
    /// - ObservationRegistrar willSet/didSet notify @Observable observers (iOS 17+)
    /// - This is what SwiftUI uses to detect when to re-render views
    ///
    /// The dirty tracking optimization provides immediate fresh values when cache is dirty,
    /// while still ensuring all external observers are notified via the onUpdate callback.
    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T, isSame: (@Sendable (T, T) -> Bool)?, debug: DebugOptions? = nil) -> T {
        guard let context = enforcedContext() else { return produce() }

        let key = AnyHashableSendable(key)
        let path: KeyPath<M._ModelState, AnyHashableSendable>&Sendable = \M._ModelState[memoizeKey: key]

#if DEBUG
        // Set up debug observation once (only on first access, when cache entry doesn't yet exist).
        // We do this before the external willAccess so that the debug collector can intercept
        // property reads inside produce() during the first update() call.
        // When debug == [] (the default), memoizeDebugSetup returns nils for zero overhead.
        let debugLabel = debug?.name ?? "\(String(describing: M.self))[memoize: \"\(key.base)\"]"
        let (debugPrint, debugPreviousValue, debugCollectorBox) = memoizeDebugSetup(
            options: debug,
            label: debugLabel
        ) as ((@Sendable (T, T?) -> Void)?, LockIsolated<T?>?, LockIsolated<DebugAccessCollector?>?)
#endif

        // External tracking: notify observers that this property is being accessed.
        // Registrar call uses _StateObserver (no Model Observable conformance needed).
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            context.willAccessSyntheticPath(\_StateObserver<M._ModelState>[memoizeKey: key])
        }
        // ViewAccess/AccessCollector/TestAccess tracking via active access:
        _$modelContext.willAccess(at: path)?()

        // Box that will hold the `forceNextUpdate` closure returned by `update()`.
        // Used so that `didModifyCallback` can call it when a forced (touch) change arrives,
        // ensuring memoize's own update() instance bypasses isSame and propagates downstream.
        let forceNextBox = LockIsolated<(@Sendable () -> Void)?>(nil)

        // Create didModify callback that marks cache as dirty and, when the change is forced
        // (e.g. via node.touch()), signals memoize's update() to bypass isSame on its next run.
        // (Outside the main lock to avoid type inference issues.)
        let didModifyCallback: @Sendable (Bool) -> Void = { @Sendable force in
            context.lock {
                if var entry = context._memoizeCache[key] {
                    entry.isDirty = true
                    context._memoizeCache[key] = entry
                }
            }
            if force {
                forceNextBox.value?()
            }
        }

        // Check for cached value with dirty flag
        // ATOMICALLY check and clear isDirty to prevent race with backgroundCall
        let (cachedEntry, shouldRecompute): (AnyContext.MemoizeCacheEntry?, Bool) = context.lock {
            guard let entry = context._memoizeCache[key] else {
                return (nil, false)
            }

            let shouldRecompute = entry.isDirty

            if shouldRecompute {
                // For sync tracking (AccessCollector): clear isDirty to prevent double computation
                // For async tracking (withObservationTracking): keep isDirty so performUpdate can re-track
                if !entry.usesAsyncTracking {
                    var freshEntry = entry
                    freshEntry.isDirty = false
                    context._memoizeCache[key] = freshEntry
                }
            }

            return (entry, shouldRecompute)
        }

        if let entry = cachedEntry {
            // If dirty tracking enabled and cache WAS dirty, recompute and return fresh value
            if shouldRecompute {
                // Compute fresh value (needed for immediate return)
                let fresh: T = produce()

                // For synchronous tracking (AccessCollector), update cache and notify
                // This works because AccessCollector tracks via willAccess() callbacks
                if !entry.usesAsyncTracking {
                    // Call the stored onUpdate callback to trigger all observation notifications
                    // This ensures external observers (SwiftUI, @Observable, etc.) are notified
                    // The onUpdate callback handles:
                    // - isSame duplicate checking
                    // - Cache updating (sets isDirty: false)
                    // - modifyCallbacks (ViewAccess for pre-iOS 17)
                    // - willSet/didSet (ObservationRegistrar for iOS 17+)
                    entry.onUpdate?(fresh)
                }
                // For async tracking (withObservationTracking):
                // DO NOT notify here - let the scheduled performUpdate handle it.
                // Notifying here would trigger the onChange callback, which would re-access the property,
                // hitting the dirty path again (infinite loop).
                // The performUpdate will:
                // 1. See isDirty: true
                // 2. Call observe() -> withObservationTracking {} -> access() -> produce()
                // 3. Recompute and re-establish tracking
                // 4. Call onUpdate to notify observers

                return fresh
            }

            // Not dirty, use cached value
            return entry.value as! T
        }

        // First access: set up tracking
        return context.lock {

            // Double-check: another thread may have set up tracking between our nil check above
            // and acquiring the lock here.
            if let existingEntry = context._memoizeCache[key] {
                assert(existingEntry.typeID == ObjectIdentifier(T.self), "memoize key '\(key.base)' was previously used with a different type")
                return existingEntry.value as! T
            }

            // First access: set up tracking with didModify callback
            let (cancellable, forceNextUpdate) = context.transaction {
                // Enable coalescing by default to batch multiple dependency changes during transactions
                // Can be disabled via ModelOption.disableMemoizeCoalescing for testing
                let useCoalescing = !context.options.contains(.disableMemoizeCoalescing)

                // Determine which observation path to use:
                // - withObservationTracking requires coalescing (async execution via backgroundCall)
                // - When coalescing is disabled, must use AccessCollector for synchronous observation
                let useWithObservationTracking = context.hasObservationRegistrar && useCoalescing
                let usesAsyncTracking = useWithObservationTracking  // Capture for cache entry

                return update(
                    initial: true,
                    isSame: nil,
                    useWithObservationTracking: useWithObservationTracking,
                    useCoalescing: useCoalescing,
                    didModify: didModifyCallback
                ) {
                    // When called from a coalesced performUpdate (either the withObservationTracking
                    // or AccessCollector path): always call produce() so that dependency tracking
                    // is re-registered.
                    //
                    // Race this fixes: onUpdate() can clear isDirty before a subsequently-scheduled
                    // performUpdate's access() runs (backgroundCall executes concurrently with
                    // mutations on Swift's cooperative thread pool). If we short-circuit to the
                    // cached value, withObservationTracking/AccessCollector tracks nothing and the
                    // subscription is silently lost for all remaining mutations.
                    //
                    // We detect "called from coalesced performUpdate" via
                    // threadLocals.isInsideAsyncPerformUpdate, set to true only around the
                    // performUpdate's access() call. This avoids spurious extra computes from
                    // other access() call sites (forceObserver setup, initial registration,
                    // dirty-path sync reads).
                    if threadLocals.isInsideAsyncPerformUpdate {
                        return produce()
                    }
                    let entry = context.lock({ context._memoizeCache[key] })
                    if let entry = entry, !entry.isDirty {
                        return entry.value as! T
                    }
                    return produce()
                } onUpdate: { @Sendable (value: T) in
                    var postLockCallbacks: [() -> Void] = []

                    // Build type-erased isSame once for cache entry storage.
                    // onUpdate is the initial callback called exactly once by update(); wrappedOnUpdate
                    // (stored as entry.onUpdate) handles all subsequent dirty-path updates.
                    let typeErasedIsSame: (@Sendable (Any, Any) -> Bool)?
                    if let typed = isSame {
                        typeErasedIsSame = { @Sendable (l: Any, r: Any) in
                            guard let l = l as? T, let r = r as? T else { return false }
                            return typed(l, r)
                        }
                    } else {
                        typeErasedIsSame = nil
                    }
                    let typeID = ObjectIdentifier(T.self)
                    let hasInitialized = LockIsolated(false)

                    context.lock {
                        let entry = context._memoizeCache[key]
                        let prevValue = entry?.value as? T
                        let prevCancellable = entry?.cancellable

                        // After initial setup, if the entry was removed (by resetMemoization),
                        // don't recreate a stale entry with no active subscription.
                        if hasInitialized.value, entry == nil {
                            return
                        }
                        hasInitialized.setValue(true)

                        // Bypass isSame when forceObservation is set (e.g. from node.touch()
                        // propagating through memoize). Without this bypass, a touch on a dependency
                        // would be silently swallowed even though memoize's update() already decided
                        // to fire onUpdate due to forceNext.
                        if let isSame, let prevValue, !threadLocals.forceObservation, isSame(value, prevValue) {
                            // Value is unchanged, but we still need to clear isDirty so the cache
                            // is clean after performUpdate re-establishes tracking via observe().
                            // Without this, isDirty stays true indefinitely when the recomputed value
                            // equals the cached value, causing every subsequent performUpdate to see
                            // isDirty=true and call produce() again, but never clearing the flag.
                            if var currentEntry = context._memoizeCache[key], currentEntry.isDirty {
                                currentEntry.isDirty = false
                                context._memoizeCache[key] = currentEntry
                            }
                            return
                        }

                        // Store wrapped onUpdate callback that can be called from dirty path
                        let wrappedOnUpdate: @Sendable (Any) -> Void = { @Sendable anyValue in
                            guard let typedValue = anyValue as? T else { return }
                            var postCallbacks: [() -> Void] = []

                            context.lock {
                                guard let currentEntry = context._memoizeCache[key] else {
                                    // Entry was removed by resetMemoization; don't re-create
                                    // a stale entry with no observation subscription.
                                    return
                                }
                                let currentPrevValue = currentEntry.value as? T
                                let currentCancellable = currentEntry.cancellable
                                let currentOnUpdate = currentEntry.onUpdate

                                if let isSame, let currentPrevValue, isSame(typedValue, currentPrevValue) {
                                    return
                                }

                                // Preserve isDirty if a concurrent mutation set it between
                                // produce() and this lock acquisition.
                                context._memoizeCache[key] = AnyContext.MemoizeCacheEntry(
                                    value: typedValue,
                                    cancellable: currentCancellable,
                                    isDirty: currentEntry.isDirty,
                                    onUpdate: currentOnUpdate,
                                    usesAsyncTracking: usesAsyncTracking,
                                    isSame: typeErasedIsSame,
                                    typeID: typeID
                                )

                                if currentPrevValue != nil {
                                    context.onPostTransaction(callbacks: &postCallbacks) { callbacks in
                                        if let modifyCallbacks = context.modifyCallbacks[path] {
                                            for callback in modifyCallbacks.values {
                                                if let postCallback = callback(false, false) {
                                                    callbacks.append(postCallback)
                                                }
                                            }
                                        }

                                        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                                            callbacks.append {
                                                context.invokeDidModifySyntheticPath(\_StateObserver<M._ModelState>[memoizeKey: key])
                                            }
                                        }
                                    }
                                }
                            }

                            for callback in postCallbacks { callback() }

#if DEBUG
                            if let debugPrint, let debugPreviousValue {
                                let prevForDirtyDebug = debugPreviousValue.withValue { prev -> T? in
                                    defer { prev = typedValue }
                                    return prev
                                }
                                // Skip if no previous value (initial setup hasn't run yet).
                                if let prevForDirtyDebug {
                                    debugPrint(typedValue, prevForDirtyDebug)
                                }
                            }
#endif
                        }

                        context._memoizeCache[key] = AnyContext.MemoizeCacheEntry(
                            value: value,
                            cancellable: prevCancellable ?? {},
                            isDirty: usesAsyncTracking && (entry?.isDirty ?? false),
                            onUpdate: wrappedOnUpdate,
                            usesAsyncTracking: usesAsyncTracking,
                            isSame: typeErasedIsSame,
                            typeID: typeID
                        )

                        if prevValue != nil {
                            context.onPostTransaction(callbacks: &postLockCallbacks) { postCallbacks in
                                if let modifyCallbacks = context.modifyCallbacks[path] {
                                    for callback in modifyCallbacks.values {
                                        if let postCallback = callback(false, false) {
                                            postCallbacks.append(postCallback)
                                        }
                                    }
                                }

                                if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                                    postCallbacks.append {
                                        context.invokeDidModifySyntheticPath(\_StateObserver<M._ModelState>[memoizeKey: key])
                                    }
                                }
                            }
                        }
                    }

                    for plc in postLockCallbacks { plc() }

#if DEBUG
                    // Debug: print trigger and change info after each update.
                    // `prevValue` here is the value before this update (may be nil on first call).
                    if let debugPrint, let debugPreviousValue {
                        let prevForDebug = debugPreviousValue.withValue { prev -> T? in
                            defer { prev = value }
                            return prev
                        }
                        // Skip the initial memoize setup call (prevForDebug == nil means
                        // this is the first time we've seen a value — not a real update).
                        // debugPreviousValue has now been set to `value` so the next call
                        // will see the previous value correctly.
                        if let prevForDebug {
                            debugPrint(value, prevForDebug)
                        }
                    }
#endif
                }
            }

            // Wire up the forceNext box so that didModifyCallback can signal memoize's update()
            // to bypass isSame when a forced (touch) change arrives.
            forceNextBox.setValue(forceNextUpdate)

#if DEBUG
            // Register debug subscriptions for trigger tracking.
            // We run produce() through the DebugAccessCollector separately (after update() has
            // already run produce() via the AccessCollector) so that both collectors register
            // onModify callbacks for the same set of dependencies.
            if let collector = debugCollectorBox?.value {
                _ = usingActiveAccess(collector) { produce() }
            }
#endif

            // Get the cached value that should have been set by onUpdate
            // In rare cases (e.g., if produce() calls resetMemoization), the entry might not exist
            guard var entry = context._memoizeCache[key] else {
                // Fallback: compute without tracking if cache wasn't set
                return produce()
            }

            let value = entry.value as! T
            entry.cancellable = cancellable
            context._memoizeCache[key] = entry

            return value
        }
    }
}

private extension Model {
    subscript<Value: Sendable>(memoizeKey key: some Hashable&Sendable) -> Value {
        context!.lock {
            context!._memoizeCache[AnyHashableSendable(key)]?.value as! Value
        }
    }
}
