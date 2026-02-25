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
    /// - Parameter access: closure providing the value to be observed
    @_disfavoredOverload
    public init(initial: Bool = true, coalesceUpdates: Bool = true, _ access: @Sendable @escaping () -> Element) {
        self.init(access: access, initial: initial, isSame: nil, coalesceUpdates: coalesceUpdates)
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
    /// - Parameter access: closure providing the value to be observed
    init(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, _ access: @Sendable @escaping () -> Element) {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? (==) : nil, coalesceUpdates: coalesceUpdates).stream
    }
}

public extension Observed {
    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, _ access: @Sendable @escaping () -> (repeat each T)) where Element == (repeat each T) {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil, coalesceUpdates: coalesceUpdates).stream
    }

    /// Create as Observed stream observing changes of the value provided by  `access`
    ///
    /// - Parameter initial: Start by sending current initial value (defaults to true).
    /// - Parameter removeDuplicates: Whether to filter out duplicate values (defaults to true).
    /// - Parameter coalesceUpdates: Whether to batch rapid dependency changes into single updates (defaults to true).
    /// - Parameter access: closure providing the value to be observed
    init<each T: Equatable>(initial: Bool = true, removeDuplicates: Bool = true, coalesceUpdates: Bool = true, _ access: @Sendable @escaping () -> (repeat each T)?) where Element == (repeat each T)? {
        stream = Observed(access: access, initial: initial, isSame: removeDuplicates ? isSame : nil, coalesceUpdates: coalesceUpdates).stream
    }
}

public extension Model where Self: Sendable {
    /// Returns a stream observing any updates on self or any descendants
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

    /// Will start to print state changes until cancelled, but only in `DEBUG` configurations.
    @discardableResult
    func _printChanges(name: String? = nil, to printer: some TextOutputStream&Sendable = PrintTextOutputStream()) -> Cancellable {
#if DEBUG
        guard let context = enforcedContext() else { return EmptyCancellable() }
        let previous = LockIsolated(context.model.frozenCopy)

        let cancel = context.onAnyModification { hasEnded in
            guard !hasEnded else { return nil }

            let current = context.model
            defer { previous.setValue(current.frozenCopy) }

            var difference: String? = diff(previous.value, current)

            if difference == nil {
                difference = threadLocals.withValue(true, at: \.includeInMirror) {
                    diff(previous.value, current)
                }
            }

            guard let difference else { return nil }

            return {
                var printer = printer
                printer.write("State did update for \(name ?? typeDescription):\n" + difference)
            }
        }
        
        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
#else
       return EmptyCancellable()
#endif
    }
}

public struct PrintTextOutputStream: TextOutputStream, Sendable {
    public init() {}
    public func write(_ string: String) {
        print(string)
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
    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: nil)
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
    func memoize<T: Sendable&Equatable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: key, produce: produce, isSame: { $0 == $1 })
    }

    /// Caches a tuple computation with automatic duplicate detection for each element.
    ///
    /// - Parameters:
    ///   - key: A unique key identifying this memoized computation.
    ///   - produce: A closure that computes the tuple value.
    ///
    /// - Returns: The cached tuple, or the result of `produce()` if not cached or dependencies changed.
    func memoize<each T: Sendable&Equatable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
        memoize(for: key, produce: produce, isSame: isSame)
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
    func memoize<T: Sendable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), produce: produce)
    }

    /// Caches an `Equatable` computation using source location as the cache key.
    ///
    /// Combines automatic key generation with duplicate value detection.
    ///
    /// - Parameter produce: A closure that computes the value.
    /// - Returns: The cached value, or the result of `produce()` if not cached or dependencies changed.
    func memoize<T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> T) -> T {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), produce: produce)
    }

    /// Caches a tuple computation using source location as the cache key.
    ///
    /// - Parameter produce: A closure that computes the tuple value.
    /// - Returns: The cached tuple, or the result of `produce()` if not cached or dependencies changed.
    func memoize<each T: Sendable&Equatable>(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, produce: @Sendable @escaping () -> (repeat each T)) -> (repeat each T) {
        memoize(for: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), produce: produce)
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
    init(access: @Sendable @escaping () -> Element, initial: Bool = true, isSame: (@Sendable (Element, Element) -> Bool)?, coalesceUpdates: Bool = false) {
        stream = AsyncStream { cont in
            // Observed must use AccessCollector since it can't access model options
            // to check for .disableObservationRegistrar. withObservationTracking
            // would silently fail on models without an ObservationRegistrar.
            // Note: memoize() respects model options and will use the appropriate path
            let cancellable = update(initial: initial, isSame: isSame, useWithObservationTracking: false, useCoalescing: coalesceUpdates) {
                access()
            } onUpdate: { value in
                cont.yield(value)
            }

            cont.onTermination = { _ in
                cancellable()
            }
        }
    }
}

private extension ModelNode {
    func memoize<T: Sendable>(for key: some Hashable&Sendable, produce: @Sendable @escaping () -> T, isSame: (@Sendable (T, T) -> Bool)?) -> T {
        guard let context = enforcedContext() else { return produce() }

        let key = AnyHashableSendable(key)
        let path: KeyPath<M, T>&Sendable = \M[memoizeKey: key]
        _$modelContext.willAccess(context.model, at: path)?()

        // Check if dirty tracking is enabled
        let useDirtyTracking = !context.options.contains(.disableMemoizeDirtyTracking)

        // Create didModify callback that marks cache as dirty (outside the main lock to avoid type inference issues)
        let didModifyCallback: (@Sendable () -> Void)? = useDirtyTracking ? { @Sendable in
            context.lock {
                if var entry = context._memoizeCache[key] {
                    entry.isDirty = true
                    context._memoizeCache[key] = entry
                }
            }
        } : nil

        // Check for cached value with dirty flag
        let cachedEntry = context.lock { context._memoizeCache[key] }
        
        if let entry = cachedEntry {
            // If dirty tracking enabled and cache is dirty
            if useDirtyTracking && entry.isDirty {
                // Compute fresh WITHOUT tracking (tracking will be set up by coalesced update)
                let fresh: T = produce()
                
                // Update cache with fresh value and clear dirty flag
                context.lock {
                    var updatedEntry = entry
                    updatedEntry.value = fresh
                    updatedEntry.isDirty = false
                    context._memoizeCache[key] = updatedEntry
                }
                
                return fresh
            }
            
            // Not dirty, use cached value
            return entry.value as! T
        }

        // First access: set up tracking
        return context.lock {

            // First access: set up tracking with didModify callback
            let cancellable = context.transaction {
                // Enable coalescing by default to batch multiple dependency changes during transactions
                // Can be disabled via ModelOption.disableMemoizeCoalescing for testing
                let useCoalescing = !context.options.contains(.disableMemoizeCoalescing)
                
                // Determine which observation path to use based on context options
                // Can't use withObservationTracking if ObservationRegistrar is disabled or if explicitly disabled
                let useWithObservationTracking = !(context.options.contains(.disableObservationTracking)) && 
                                                  !(context.options.contains(.disableObservationRegistrar))
                
                return update(
                    initial: true, 
                    isSame: nil, 
                    useWithObservationTracking: useWithObservationTracking, 
                    useCoalescing: useCoalescing,
                    didModify: didModifyCallback
                ) {
                    produce()
                } onUpdate: { value in
                    DebugHook.record("[memoize] onUpdate fired for key=\(key), value=\(value), thread=\(Thread.isMainThread ? "main" : "background")")
                    var postLockCallbacks: [() -> Void] = []

                    context.lock {
                        let entry = context._memoizeCache[key]
                        let prevValue = entry?.value as? T
                        let prevCancellable = entry?.cancellable
                        
                        DebugHook.record("[memoize] prevValue=\(String(describing: prevValue)), updating cache")
                        if let isSame, let prevValue, isSame(value, prevValue) {
                            return
                        }

                        context._memoizeCache[key] = AnyContext.MemoizeCacheEntry(
                            value: value,
                            cancellable: prevCancellable ?? {},
                            isDirty: false  // Fresh value from coalesced update
                        )

                        if prevValue != nil {
                            context.onPostTransaction(callbacks: &postLockCallbacks) { postCallbacks in
                                for callback in (context.modifyCallbacks[path] ?? [:]).values {
                                    if let postCallback = callback(false) {
                                        postCallbacks.append(postCallback)
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
                }
            }

            let value = context._memoizeCache[key]!.value as! T
            var entry = context._memoizeCache[key]!
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
/// ### AccessCollector (fallback and opt-in via `.disableObservationTracking`)
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
///   - didModify: Optional callback fired immediately when ANY dependency changes (before coalescing). Used by memoize for dirty tracking.
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
internal func update<T: Sendable>(
    initial: Bool,
    isSame: (@Sendable (T, T) -> Bool)?,
    useWithObservationTracking: Bool,
    useCoalescing: Bool = false,
    didModify: (@Sendable () -> Void)? = nil,
    access: @Sendable @escaping () -> T,
    onUpdate: @Sendable @escaping (T) -> Void
) -> @Sendable () -> Void {
    // Versioning for stale update detection
    // `index` is incremented before each recomputation to invalidate in-flight updates
    let last = LockIsolated((value: T?.none, index: 0))
    
    // updateLock ensures only one update processes at a time, preventing race conditions
    // when multiple threads trigger updates simultaneously
    let updateLock = NSRecursiveLock()
    
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
            let shouldUpdate: Bool = last.withValue { last in
                // Stale update check: if index doesn't match, this update is outdated
                // A newer recomputation has started, so skip this one
                guard index == last.index else {
                    return false
                }

                // isSame check: skip if value hasn't actually changed
                if let isSame {
                    if let last = last.value, isSame(last, value) {
                        return false  // Value unchanged, skip onUpdate
                    } else {
                        last.value = value  // Value changed, update cache
                    }
                }

                return true
            }

            if shouldUpdate {
                onUpdate(value)
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

        @Sendable func observe() -> T {
            withObservationTracking {
                access()
            } onChange: {
                if hasBeenCancelled.value { return }

                // Call didModify immediately when dependency changes (for dirty tracking)
                didModify?()

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
                    
                    guard shouldSchedule else { return }
                }

                let performUpdate: @Sendable () -> Void = {
                    let (value, index) = last.withValue { last in
                        last.index = last.index &+ 1
                        return (observe(), last.index)
                    }
                    
                    if useCoalescing {
                        hasPendingUpdate.setValue(false)
                    }
                    
                    update(with: value, index: index)
                }
                
                // Check if we're inside a transaction
                if threadLocals.postTransactions != nil {
                    // Inside transaction: defer callback until transaction completes
                    // This matches AccessCollector behavior and prevents 100x callback spam
                    threadLocals.postTransactions!.append { callbacks in
                        if useCoalescing {
                            // With coalescing: use backgroundCall to batch
                            backgroundCall(performUpdate)
                        } else {
                            // Without coalescing: append to post-transaction callbacks
                            callbacks.append(performUpdate)
                        }
                    }
                } else {
                    // Outside transaction: execute as before
                    if useCoalescing {
                        // Use background coalescing to batch rapid updates
                        // With didModify callback and dirty tracking, this is safe even inside
                        // transactions because:
                        // 1. didModify marks cache dirty immediately
                        // 2. Cache access checks dirty flag and recomputes on-demand
                        // 3. backgroundCall batches the onUpdate notifications
                        // This prevents redundant recomputations during bulk mutations.
                        backgroundCall(performUpdate)
                    } else {
                        // Coalescing disabled: execute immediately
                        // Without coalescing, every dependency change triggers an immediate update
                        performUpdate()
                    }
                }
            }
        }

        updateInitial(with: observe())

        return {
            hasBeenCancelled.withValue {
                $0 = true
            }
        }
    } else {
        // AccessCollector path (default, works on all OS versions and threads)
        let hasPendingUpdate = LockIsolated(false)
        
        let collector = AccessCollector { collector in
            // Call didModify immediately when dependency changes (for dirty tracking)
            didModify?()
            
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

                    let value = collector.reset {
                        usingActiveAccess(collector) {
                            access()
                        }
                    }

                    return (value, last.index)
                }
                
                if useCoalescing {
                    hasPendingUpdate.setValue(false)
                }
                
                update(with: value, index: index)
            }
            
            if useCoalescing {
                // Use background coalescing to batch rapid updates
                // With didModify callback and dirty tracking, this is safe even inside
                // transactions because:
                // 1. didModify marks cache dirty immediately
                // 2. Cache access checks dirty flag and recomputes on-demand
                // 3. backgroundCall batches the onUpdate notifications
                // This prevents redundant recomputations during bulk mutations.
                return {
                    backgroundCall(performUpdate)
                }
            } else {
                // Coalescing disabled: execute immediately
                // Without coalescing, every dependency change triggers an immediate update
                return performUpdate
            }
        }

        let value = collector.reset {
            usingActiveAccess(collector) {
                access()
            }
        }

        updateInitial(with: value)

        return {
            collector.reset { }
        }
    }
}

private final class AccessCollector: ModelAccess, @unchecked Sendable {
    let onModify: @Sendable (AccessCollector) -> (() -> Void)?
    let active = LockIsolated<(active: [Key: @Sendable () -> Void], added: Set<Key>)>(([:], []))

    struct Key: Hashable, @unchecked Sendable {
        var id: ModelID
        var path: AnyKeyPath
    }

    init(onModify: @Sendable @escaping (AccessCollector) -> (() -> Void)?) {
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

    override func willAccess<M: Model, T>(_ model: M, at path: KeyPath<M, T>&Sendable) -> (() -> Void)? {
        if let context = model.context {
            let key = Key(id: model.modelID, path: path)

            let isActive = active.withValue {
                $0.added.insert(key)
                return $0.active[key] != nil
            }

            if !isActive {
                // Make sure to call this outside active lock to avoid dead-locks with context lock.
                let cancellation = context.onModify(for: path) { finished in
                    if finished { return {} }
                    return self.onModify(self)
                }

                active.withValue {
                    $0.active[key] = cancellation
                }
            }
        }

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

