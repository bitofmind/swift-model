import Foundation
import CustomDump
import ConcurrencyExtras

/// A stream for observing changes to model properties.
///
///     let countChanges = Observed { model.count }
///     let sumChanges = Observed { model.counts.reduce(0, +) }
///
/// An observation can be to any number of properties or models, and the stream will re-calculated it's value if any of the observed values are changed.
/// Observation are typically iterated using the a model's node `forEach` helper, often set up in the `onActive()` callback:
///
///     func onActivate() {
///       node.forEach(Observed { count }) {
///         print("count did update to", $0)
///       }
///     }
public struct Observed<Element: Sendable>: AsyncSequence, Sendable {
    let stream: AsyncStream<Element>

    /// Create as Observed stream observing updates of the values provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    @_disfavoredOverload
    public init(initial: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions = [], _ access: @Sendable @escaping () -> Element) {
        self.init(access: access, initial: initial, isSame: nil, coalesceUpdates: coalesceUpdates, debug: debug)
    }

    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        stream.makeAsyncIterator()
    }
}

public extension Observed where Element: Equatable {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    init(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions = [], _ access: @Sendable @escaping () -> Element) {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? (==) : nil, coalesceUpdates: coalesceUpdates, debug: debug).stream
    }
}

public extension Observed {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions = [], _ access: @Sendable @escaping () -> (repeat each T)) where Element == (repeat each T) {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil, coalesceUpdates: coalesceUpdates, debug: debug).stream
    }

    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter debug: Debug options controlling trigger and change output. Only active in `DEBUG` builds.
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, debug: DebugOptions = [], _ access: @Sendable @escaping () -> (repeat each T)?) where Element == (repeat each T)? {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil, coalesceUpdates: coalesceUpdates, debug: debug).stream
    }
}

public extension Model where Self: Sendable {
    /// Returns a stream that emits whenever any state in the model or any of its descendants changes.
    ///
    /// This is useful for cross-cutting concerns that need to react to *any* change in a subtree
    /// without caring about which specific property changed. Common use cases include:
    ///
    /// - **Dirty tracking**: detect unsaved changes to show a "modified" indicator
    /// - **Debounced autosave**: debounce rapid changes before persisting to disk
    /// - **Undo/redo stacks**: use ``ModelNode/onChange(capture:perform:)`` which skips
    ///   restore notifications automatically and provides lazy snapshot capture
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Show unsaved-changes indicator whenever anything in the form changes
    ///     node.forEach(observeAnyModification()) { _ in
    ///         hasUnsavedChanges = true
    ///     }
    ///
    ///     // Debounced autosave
    ///     node.task {
    ///         for await _ in observeAnyModification().debounce(for: .seconds(2)) {
    ///             await save()
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// The stream emits once per transaction (multiple mutations inside a `node.transaction { }`
    /// produce a single emission). It finishes when the model is deactivated.
    ///
    /// > Note: This method is on `Model` directly (not `node`), so you call it as
    /// > `observeAnyModification()` from within the model, or `model.observeAnyModification()`
    /// > from a parent.
    func observeAnyModification() -> AsyncStream<()> {
        guard let context = enforcedContext() else { return .finished }

        return AsyncStream { cont in
            let cancel = context.onAnyModification { didFinish in
                if didFinish {
                    cont.finish()
                } else {
                    cont.yield(())
                }
                return nil
            }

            cont.onTermination = { _ in
                cancel()
            }
        }
    }

}

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
    func memoize<T: Sendable>(for key: some Hashable&Sendable, debug: DebugOptions = [], produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: nil, debug: debug)
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
    func memoize<T: Sendable&Equatable>(for key: some Hashable&Sendable, debug: DebugOptions = [], produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: { $0 == $1 }, debug: debug)
    }

    /// Caches a tuple computation with automatic duplicate detection for each element.
    ///
    /// - Parameters:
    ///   - key: A unique key identifying this memoized computation.
    ///   - produce: A closure that computes the tuple value.
    ///
    /// - Returns: The cached tuple, or the result of `produce()` if not cached or dependencies changed.
    func memoize<each T: Sendable&Equatable>(for key: some Hashable&Sendable, debug: DebugOptions = [], produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
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
    func memoize<T: Sendable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, debug: DebugOptions = [], produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), debug: debug, produce: produce)
    }

    /// Caches an `Equatable` computation using source location as the cache key.
    ///
    /// Combines automatic key generation with duplicate value detection.
    ///
    /// - Parameter produce: A closure that computes the value.
    /// - Returns: The cached value, or the result of `produce()` if not cached or dependencies changed.
    func memoize<T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, debug: DebugOptions = [], produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), debug: debug, produce: produce)
    }

    /// Caches a tuple computation using source location as the cache key.
    ///
    /// - Parameter produce: A closure that computes the tuple value.
    /// - Returns: The cached tuple, or the result of `produce()` if not cached or dependencies changed.
    func memoize<each T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, debug: DebugOptions = [], produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
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

private extension Observed {
    init(access: @Sendable @escaping () -> Element, initial: Bool = true, isSame: (@Sendable (Element, Element) -> Bool)?, coalesceUpdates: Bool = false, debug: DebugOptions = []) {
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
            if !debug.options.isEmpty {
                let cancel = debugObserve(
                    options: debug,
                    label: "Observed",
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

    override func willAccess<M: Model, T>(_ model: M, at path: KeyPath<M, T> & Sendable) -> (() -> Void)? {
        if let context = model.context, !context.hasObservationRegistrar {
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
    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T, isSame: (@Sendable (T, T) -> Bool)?, debug: DebugOptions = []) -> T {
        guard let context = enforcedContext() else { return produce() }

        let key = AnyHashableSendable(key)
        let path: KeyPath<M, T>&Sendable = \M[memoizeKey: key]

#if DEBUG
        // Set up debug observation once (only on first access, when cache entry doesn't yet exist).
        // We do this before the external willAccess so that the debug collector can intercept
        // property reads inside produce() during the first update() call.
        // When debug == [] (the default), memoizeDebugSetup returns nils for zero overhead.
        let debugLabel = "\(String(describing: M.self))[memoize: \"\(key.base)\"]"
        let (debugPrint, debugPreviousValue, debugCollectorBox) = memoizeDebugSetup(
            options: debug,
            label: debugLabel
        ) as ((@Sendable (T, T?) -> Void)?, LockIsolated<T?>?, LockIsolated<DebugAccessCollector?>?)
#endif

        // External tracking: notify observers that this property is being accessed
        // This allows SwiftUI's ViewAccess to register callbacks for view invalidation
        _$modelContext.willAccess(context.model, at: path)?()

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

                    context.lock {
                        let entry = context._memoizeCache[key]
                        let prevValue = entry?.value as? T
                        let prevCancellable = entry?.cancellable

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
                                let currentEntry = context._memoizeCache[key]
                                let currentPrevValue = currentEntry?.value as? T
                                let currentCancellable = currentEntry?.cancellable
                                let currentOnUpdate = currentEntry?.onUpdate

                                if let isSame, let currentPrevValue, isSame(typedValue, currentPrevValue) {
                                    return
                                }

                                context._memoizeCache[key] = AnyContext.MemoizeCacheEntry(
                                    value: typedValue,
                                    cancellable: currentCancellable ?? {},
                                    isDirty: false,
                                    onUpdate: currentOnUpdate,  // Preserve the same callback
                                    usesAsyncTracking: usesAsyncTracking
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

                                        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *),
                                           let model = context.model as? any Model&Observable {
                                            callbacks.append {
                                                model.willSet(path: path, from: context)
                                                model.didSet(path: path, from: context)
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
                            isDirty: false,
                            onUpdate: wrappedOnUpdate,
                            usesAsyncTracking: usesAsyncTracking
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

                                if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), let model = context.model as? any Model&Observable {
                                    postCallbacks.append {
                                        model.willSet(path: path, from: context)
                                        model.didSet(path: path, from: context)
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
            context!.parents.map { $0.anyModel.modelID }
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

        // Tracks `onAnyModification` subscriptions for models returned directly from access().
        // These won't be picked up by withObservationTracking since no properties were read.
        let activeReturnedModels = LockIsolated<[ObjectIdentifier: @Sendable () -> Void]>([:])

        // Shared change handler used by both withObservationTracking.onChange and onAnyModification.
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
                    backgroundCall(performUpdate)
                }
            } else {
                backgroundCall(performUpdate)
            }
        }

        // Subscribe to any models found in `value` that are returned directly from access().
        @Sendable func subscribeReturnedModels(in value: T) {
            let contexts = reflectForModels(value)
            guard !contexts.isEmpty else { return }

            let newIDs = Set(contexts.map { ObjectIdentifier($0) })

            let toCancel = activeReturnedModels.withValue { models in
                let removed = models.filter { !newIDs.contains($0.key) }
                for id in removed.keys { models.removeValue(forKey: id) }
                return removed.values
            }
            for cancel in toCancel { cancel() }

            for context in contexts {
                let id = ObjectIdentifier(context)
                let isActive = activeReturnedModels.withValue { $0[id] != nil }
                guard !isActive else { continue }

                let cancellation = context.onAnyModification { [weak activeReturnedModels] finished in
                    if finished {
                        activeReturnedModels?.withValue { $0.removeValue(forKey: id) }
                        return nil
                    }
                    // Bypass isSame: onAnyModification confirms the model changed, but isSame
                    // reads via the live context and would compare current values against current
                    // values (since stored copies share the same live context reference),
                    // causing the update to be spuriously suppressed.
                    forceNext.setValue(true)
                    onObservedChange()
                    return nil
                }
                activeReturnedModels.withValue { $0[id] = cancellation }
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
            subscribeReturnedModels(in: value)
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
            backgroundCall(performUpdate)
        })
        usingActiveAccess(forceObserver) { _ = access() }

        return (
            cancel: {
                hasBeenCancelled.withValue { $0 = true }
                forceObserver.cancel()
                let cancels = activeReturnedModels.withValue { models in
                    defer { models.removeAll() }
                    return Array(models.values)
                }
                for cancel in cancels { cancel() }
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
            // `force` is true when the change was triggered by node.touch() or by
            // subscribeToReturnedModels' onAnyModification (model property changed).
            didModify?(force)
            // When force=true from subscribeToReturnedModels: bypass isSame so the update
            // always fires. Models stored in last.value share the live context reference,
            // so isSame would compare current values against current values — always equal.
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
                // backgroundCall schedules on next runloop iteration, allowing multiple
                // mutations to coalesce into a single update callback.
                return {
                    backgroundCall(performUpdate)
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

/// Walks `value` via `Mirror` with `collectingModelContexts` set, collecting all `AnyContext`
/// values reachable in the value. `ModelContext.mirror(of:children:)` self-registers and returns
/// empty children when `collectingModelContexts` is non-nil, acting as both the registration
/// hook and the recursion terminator (so we don't recurse into a model's own sub-models).
///
/// Works correctly for compound return values: tuples, arrays, optionals, and any other
/// non-model container — Mirror recurses explicitly, mirroring what `customDump`/`diff` do.
private func reflectForModels<T>(_ value: T) -> [AnyContext] {
    func walk(_ v: Any) {
        let m = Mirror(reflecting: v)
        for child in m.children {
            walk(child.value)
        }
    }

    return threadLocals.withValue([] as [AnyContext]?, at: \.collectingModelContexts) {
        walk(value)
        return threadLocals.collectingModelContexts ?? []
    }
}

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let onModify: @Sendable (AccessCollector, Bool) -> (@Sendable () -> Void)?
    let active = LockIsolated<(active: [Key: @Sendable () -> Void], added: Set<Key>)>(([:], []))
    /// Tracks `onAnyModification` subscriptions for models returned directly from the access
    /// closure (i.e. not accessed via property reads). Keyed by `ObjectIdentifier(context)`.
    let activeModels = LockIsolated<[ObjectIdentifier: @Sendable () -> Void]>([:])

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
        for cancel in activeModels.value.values {
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

        // Subscribe to any models returned directly from the access closure (not via property reads).
        // These models won't trigger `willAccess`, so we use `onAnyModification` as a fallback.
        subscribeToReturnedModels(in: value)

        return value
    }

    /// Walks `value` via `Mirror` with `collectingModelContexts` set. Any `@Model` struct
    /// encountered registers its context and returns empty children, so we only collect the
    /// top-level models in the value (their children are covered by `onAnyModification`).
    private func subscribeToReturnedModels<Value>(in value: Value) {
        let contexts = reflectForModels(value)
        guard !contexts.isEmpty else { return }

        let newIDs = Set(contexts.map { ObjectIdentifier($0) })

        // Cancel subscriptions for models no longer present in the return value.
        let toCancel = activeModels.withValue { activeModels in
            let removed = activeModels.filter { !newIDs.contains($0.key) }
            for id in removed.keys { activeModels.removeValue(forKey: id) }
            return removed.values
        }
        for cancel in toCancel { cancel() }

        // Subscribe to models not yet tracked.
        for context in contexts {
            let id = ObjectIdentifier(context)
            let isActive = activeModels.withValue { $0[id] != nil }
            guard !isActive else { continue }

            let cancellation = context.onAnyModification { [weak self] finished in
                guard let self else { return nil }
                if finished {
                    self.activeModels.withValue { $0.removeValue(forKey: id) }
                    return nil
                }
                // Always schedule asynchronously via backgroundCall rather than returning
                // the callback directly. Returning it inline causes the post-lock machinery
                // to execute it synchronously, which can trigger re-entrant property writes
                // (e.g. onUpdate appending the observed model to an array → updateContext →
                // addParent → onAnyModification fires again → infinite recursion).
                // Pass force=true so the outer onModify closure sets forceNext=true,
                // bypassing isSame when performUpdate runs. Models stored in last.value
                // share the live context reference, so isSame always sees the current
                // (already-updated) value and would spuriously suppress the update.
                if let callback = self.onModify(self, true) {
                    backgroundCall { callback() }
                }
                return nil
            }
            activeModels.withValue { $0[id] = cancellation }
        }
    }

    override var shouldPropagateToChildren: Bool { false }

    override func willAccess<M: Model, T>(_ model: M, at path: KeyPath<M, T>&Sendable) -> (() -> Void)? {
        if let context = model.context {
            let key = Key(id: model.modelID, path: path)

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

    override func willAccess<M: Model, T>(_ model: M, at path: KeyPath<M, T> & Sendable) -> (() -> Void)? {
        guard let context = model.context else { return nil }
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

