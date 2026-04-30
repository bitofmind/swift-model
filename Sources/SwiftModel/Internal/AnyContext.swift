import Foundation
import Dependencies
import OrderedCollections
import Observation

class AnyContext: @unchecked Sendable {
    let lock: NSRecursiveLock
    internal let options: ModelOption
    private var nextKey = 0

    final class WeakParent {
        weak var parent: AnyContext?

        init(parent: AnyContext? = nil) {
            self.parent = parent
        }
    }

    // Protects `weakParents` independently of the hierarchy lock.
    // Writers (addParent / removeParent) hold BOTH locks (hierarchy lock already held by caller,
    // then parentsLock). Event-routing reads (sendEvent / nearestDependencyContext) hold ONLY
    // parentsLock, so they never contend with concurrent property reads/writes (hierarchy lock).
    // Observation-path reads (observedParents) use the hierarchy lock, which is sufficient
    // because writers always hold the hierarchy lock when parentsLock is taken — no concurrent
    // write can be racing an observation read.
    private let parentsLock = NSLock()
    private(set) var weakParents: [WeakParent] = []
    var children: OrderedDictionary<AnyKeyPath, OrderedDictionary<ModelRef, AnyContext>> = [:]
    var dependencyContexts: [ObjectIdentifier: AnyContext] = [:]
    var dependencyCache: [AnyHashable: Any] = [:]
    /// True for contexts created by `setupModelDependency` (dep model contexts).
    /// When true, `nearestDependencyContext` skips this context's own `dependencyContexts`
    /// and starts the search from the parent — preventing dep models from shadowing
    /// the root's explicit overrides with their own `testValue` dep defaults.
    var isDepContext: Bool = false
    /// The `ModelRef` key under which this context is registered in its parent's `children` dict.
    /// Set by `childContext` when the context is first inserted. Used by `findOrTrackChild` as an
    /// O(1) fast path: instead of constructing the element key path to do a dict lookup, we look
    /// up the child's already-stored ModelRef directly via the child's live context pointer.
    ///
    /// **Thread safety**: both the write (in `childContext`) and the read (in `findOrTrackChild`)
    /// are guarded by the hierarchy lock AND require that the accessing context shares the same
    /// lock as this context (`child.lock === self.lock`). Cross-hierarchy accesses are rejected by
    /// the `existing.lock === self.lock` guard in `findOrTrackChild` and by the matching guard in
    /// `childContext`, so no concurrent cross-lock read/write of this field can occur.
    /// `nonisolated(unsafe)`: locking discipline is enforced at the call sites.
    nonisolated(unsafe) var myModelRef: ModelRef?

    /// Lazy map from a collection property's key path to an element-path maker closure.
    /// Registered once per collection property on first `visitCollection` call.
    /// Only consulted by `rootPathTree()` when `rootPaths` is queried (TestAccess / undo
    /// observation). Never accessed in production. Protected by the hierarchy lock;
    /// `nonisolated(unsafe)` since locking discipline is enforced at call sites.
    nonisolated(unsafe) var collectionElementPathMakersStore: [AnyKeyPath: @Sendable (AnyHashable) -> AnyKeyPath]?

    private var modeLifeTime: ModelLifetime = .anchored

    private var eventContinuationsStore: [Int: AsyncStream<EventInfo>.Continuation]?
    private var eventContinuations: [Int: AsyncStream<EventInfo>.Continuation] {
        _read { yield eventContinuationsStore ?? [:] }
        _modify {
            if eventContinuationsStore != nil {
                yield &eventContinuationsStore!
                if eventContinuationsStore!.isEmpty { eventContinuationsStore = nil }
            } else {
                var temp: [Int: AsyncStream<EventInfo>.Continuation] = [:]
                yield &temp
                if !temp.isEmpty { eventContinuationsStore = temp }
            }
        }
    }
    let useObservationRegistrar: Bool

    /// Pairs both observation registrars in one heap allocation.
    /// Created lazily (via `RegistrarBox`) at the root context and shared by all children
    /// in the tree, so that the whole hierarchy uses O(2) registrar instances instead of O(2N).
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    final class RegistrarPair: @unchecked Sendable {
        let main: ObservationRegistrar
        let background: ObservationRegistrar
        init() {
            main = ObservationRegistrar()
            background = ObservationRegistrar()
        }
    }

    /// Lightweight container for the lazily-allocated `RegistrarPair`.
    /// Created cheaply at the root context (1 allocation); the `RegistrarPair` inside
    /// (3 allocations: class + 2 `ObservationRegistrar._Storage`) is only created on first
    /// observation access, keeping activation cost low for unobserved models.
    /// All child contexts inherit the same box reference — thread-safe as a `let` constant.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    final class RegistrarBox: @unchecked Sendable {
        /// Lazily-populated pair. Written once (nil → non-nil) under the hierarchy lock.
        /// `nonisolated(unsafe)`: locking discipline enforced at all call sites.
        nonisolated(unsafe) var _pair: AnyObject?  // RegistrarPair?
    }

    /// Shared lazy box for the `ObservationRegistrar` pair for the entire model tree.
    /// Created at the root context when `useObservationRegistrar` is true; all child
    /// contexts inherit this same reference — thread-safe as a `let` constant.
    /// Stored as `AnyObject?` to avoid an `@available` annotation on the stored property.
    let _registrarBox: AnyObject?  // RegistrarBox?

    /// Computed accessors exposing the individual registrars for callers that use
    /// type-checked access (test assertions, willSet/didSet fast paths).
    /// Returns nil when observation is disabled or before the first observation access.
    var mainObservationRegistrarStore: Any? {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            return (_registrarBox as? RegistrarBox).flatMap { $0._pair as? RegistrarPair }?.main
        }
        return nil
    }
    var backgroundObservationRegistrarStore: Any? {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            return (_registrarBox as? RegistrarBox).flatMap { $0._pair as? RegistrarPair }?.background
        }
        return nil
    }
    /// Lazily-allocated task registry. Written once (nil → non-nil) under `lock`.
    /// `nonisolated(unsafe)`: manual locking discipline (same as other lazy stores).
    nonisolated(unsafe) var cancellationsStore: Cancellations?
    /// Returns the Cancellations registry, creating it lazily on first use.
    /// All task-registration paths go through this; read-only paths use `cancellationsStore`.
    var cancellations: Cancellations {
        if let c = cancellationsStore { return c }
        return lock {
            if cancellationsStore == nil { cancellationsStore = Cancellations() }
            return cancellationsStore!
        }
    }

    let mainCallQueue: MainCallQueue

    /// Set by `TestAccess` on the root context to receive task lifecycle events.
    /// Always `nil` in production — the delegate check is a single `Optional` load.
    weak var taskLifecycleDelegate: (any TaskLifecycleDelegate)?

    /// Captured during `Context<M>.init` to call `model.onActivate()` with correct `let` values.
    /// Called once by `Context<M>.onActivate()` and then cleared.
    var pendingActivation: (() -> Void)?

    private(set) var anyModificationActiveCount = 0
    private var anyModificationCallbacksStore: [Int: (Bool) -> (() -> Void)?]?
    private var anyModificationCallbacks: [Int: (Bool) -> (() -> Void)?] {
        _read { yield anyModificationCallbacksStore ?? [:] }
        _modify {
            if anyModificationCallbacksStore != nil {
                yield &anyModificationCallbacksStore!
                if anyModificationCallbacksStore!.isEmpty { anyModificationCallbacksStore = nil }
            } else {
                var temp: [Int: (Bool) -> (() -> Void)?] = [:]
                yield &temp
                if !temp.isEmpty { anyModificationCallbacksStore = temp }
            }
        }
    }
    private var _modificationCount = 0

    struct MemoizeCacheEntry: @unchecked Sendable {
        var value: Any & Sendable
        var cancellable: (@Sendable () -> Void)?
        var isDirty: Bool
        var onUpdate: (@Sendable (Any) -> Void)?  // Callback to trigger observation updates
        var usesAsyncTracking: Bool  // True if using withObservationTracking (async), false if using AccessCollector (sync)
        /// Type-erased identity comparison built once on first access via buildObservationIsSame.
        var isSame: (@Sendable (Any, Any) -> Bool)?
        /// ObjectIdentifier of T — asserts same key is never reused with a different type.
        var typeID: ObjectIdentifier

        init(value: Any & Sendable, cancellable: (@Sendable () -> Void)? = nil, isDirty: Bool = false, onUpdate: (@Sendable (Any) -> Void)? = nil, usesAsyncTracking: Bool = false, isSame: (@Sendable (Any, Any) -> Bool)? = nil, typeID: ObjectIdentifier = ObjectIdentifier(Never.self)) {
            self.value = value
            self.cancellable = cancellable
            self.isDirty = isDirty
            self.onUpdate = onUpdate
            self.usesAsyncTracking = usesAsyncTracking
            self.isSame = isSame
            self.typeID = typeID
        }
    }
    
    var memoizeCacheStore: [AnyHashableSendable: MemoizeCacheEntry]?
    var _memoizeCache: [AnyHashableSendable: MemoizeCacheEntry] {
        _read { yield memoizeCacheStore ?? [:] }
        _modify {
            if memoizeCacheStore != nil {
                yield &memoizeCacheStore!
                if memoizeCacheStore!.isEmpty { memoizeCacheStore = nil }
            } else {
                var temp: [AnyHashableSendable: MemoizeCacheEntry] = [:]
                yield &temp
                if !temp.isEmpty { memoizeCacheStore = temp }
            }
        }
    }

    // Typed per-context storage for internal features (undo, environment, etc.).
    // Keyed by AnyHashableSendable (source location or explicit key from ContextStorage).
    // Access via the typed subscript defined in ModelContextStorage.swift (ContextStorage subscript).
    struct ContextStorageEntry: @unchecked Sendable {
        var value: any Sendable
        // Type-erased onRemoval hook, set when the storage declares one.
        var cleanup: (() -> Void)?
    }
    var contextStorageStore: [AnyHashableSendable: ContextStorageEntry]?
    var contextStorage: [AnyHashableSendable: ContextStorageEntry] {
        _read { yield contextStorageStore ?? [:] }
        _modify {
            if contextStorageStore != nil {
                yield &contextStorageStore!
                if contextStorageStore!.isEmpty { contextStorageStore = nil }
            } else {
                var temp: [AnyHashableSendable: ContextStorageEntry] = [:]
                yield &temp
                if !temp.isEmpty { contextStorageStore = temp }
            }
        }
    }

    /// The DependencyValues captured at this context's initialization time, after all dependency
    /// overrides from withDependencies closures have been applied.
    ///
    /// Used by dependency(for:) to ensure dep resolution uses this context's own deps, not
    /// whatever happens to be in DependencyValues._current (which may belong to an ancestor
    /// context when this context is accessed from a background task).
    var capturedDependencies: DependencyValues = .init()

    /// Installs this context's captured DependencyValues as the current task-local,
    /// unconditionally replacing whatever the caller's task-local currently holds.
    ///
    /// Use this instead of `withDependencies(from: self)` when you need the child to inherit
    /// exactly this context's deps (with all overrides applied) rather than the merge that
    /// `withDependencies(from:)` performs against `DependencyValues._current`.
    func withOwnDependencies<R>(_ operation: () throws -> R) rethrows -> R {
        try DependencyValues.$_current.withValue(capturedDependencies) {
            try operation()
        }
    }

    // Bottom-up preference storage. Each context holds its own contribution; the aggregate
    // is computed by walking descendants. Keyed by AnyHashableSendable (source location or
    // explicit key from PreferenceStorage).
    // Access via the typed subscript defined in ModelPreferenceStorage.swift.
    struct PreferenceStorageEntry: @unchecked Sendable {
        var value: any Sendable
        var cleanup: (() -> Void)?
    }
    var preferenceStorageStore: [AnyHashableSendable: PreferenceStorageEntry]?
    var preferenceStorage: [AnyHashableSendable: PreferenceStorageEntry] {
        _read { yield preferenceStorageStore ?? [:] }
        _modify {
            if preferenceStorageStore != nil {
                yield &preferenceStorageStore!
                if preferenceStorageStore!.isEmpty { preferenceStorageStore = nil }
            } else {
                var temp: [AnyHashableSendable: PreferenceStorageEntry] = [:]
                yield &temp
                if !temp.isEmpty { preferenceStorageStore = temp }
            }
        }
    }

    func didModify() {
        _modificationCount &+= 1
    }

    typealias ModificationCounts = [ObjectIdentifier: Int]
    private var _modificationCounts: ModificationCounts?

    var modificationCount: Int { lock { _modificationCount } }

    var modificationCounts: ModificationCounts {
        lock {
            if let counts = _modificationCounts {
                return counts
            }

            var counts = ModificationCounts()
            collectModificationCounts(&counts)
            _modificationCounts = counts

            return counts
        }
    }

    private func collectModificationCounts(_ counts: inout ModificationCounts) {
        counts[ObjectIdentifier(self)] = _modificationCount  // already under lock, avoid re-entrant lock acquisition
        forEachChild { $0.collectModificationCounts(&counts) }
    }

    struct EventInfo: @unchecked Sendable {
        var event: Any
        var model: any Model
        var context: AnyContext
    }

    struct ModelRef: Hashable {
        var elementPath: AnyKeyPath
        var id: AnyHashable
    }

    // MARK: - Parents observation hooks
    //
    // `weakParents` is an internal relationship that is now treated as an observable
    // "property" of the context, using the same willAccess/willSet/didSet discipline
    // as any @Model property. This makes the parent relationship observable for free
    // across all observation paths (AccessCollector, withObservationTracking, ViewAccess)
    // for any code that walks parents (e.g. reduceHierarchy).
    //
    // The concrete implementations live in Context<M>, which has access to the typed
    // model and modifyCallbacks infrastructure needed to fire observation notifications.

    /// Called when the parents array is about to be read for observation purposes.
    /// Implementations should register the read with any active observation tracking.
    func willAccessParents() {}

    // MARK: - Storage observation hooks
    //
    // A context storage read (local or environment) calls `willAccessStorage` on each visited context
    // so that any active observation tracking (AccessCollector, ObservationRegistrar, ViewAccess,
    // TestAccess) registers a dependency. The typed `ContextStorage<V>` is passed so that
    // `Context<M>` can form both the synthetic untyped keypath (for Observed/SwiftUI) and a
    // typed `WritableKeyPath<M, V>` (for TestAccess snapshot tracking).
    // When a value is set or removed, `didModifyStorage` fires the corresponding notifications.

    /// Called when a storage key is read on this context during an environment walk.
    /// Implementations (Context<M>) call `willAccess` for both observation paths.
    func willAccessStorage<V>(_ storage: ContextStorage<V>) {}

    /// Called after a storage value is written or removed from this context.
    /// Implementations (Context<M>) call `invokeDidModify` and fire post-lock callbacks.
    func didModifyStorage<V>(_ storage: ContextStorage<V>) {}

    // MARK: - Preference observation hooks
    //
    // Analogous to storage observation hooks but for bottom-up preference aggregation.
    // A preference read calls `willAccessPreference` on each visited descendant context so that
    // observation tracking registers a dependency. A preference write or removal calls
    // `didModifyPreference` on the writing context, which then propagates upward through parents.

    /// Called when a preference key is read on this context during aggregation.
    /// Implementations (Context<M>) call `willAccess` for both observation paths.
    func willAccessPreference<V>(_ storage: PreferenceStorage<V>) {}

    /// Called on the root context after `preferenceValue` finishes aggregating, with the
    /// final computed value. Implementations (Context<M>) register the typed preference
    /// keypath with TestAccess using the already-computed value, avoiding re-entry into
    /// `preferenceValue` and the associated lock-ordering hazards.
    func willAccessPreferenceValue<V>(_ storage: PreferenceStorage<V>, value: V) {}

    /// Called after a preference contribution is written or removed from this context.
    /// Implementations (Context<M>) fire notifications and propagate upward through parents.
    func didModifyPreference<V>(_ storage: PreferenceStorage<V>) {}

    /// Called during upward preference propagation to invalidate ancestor observers.
    /// Unlike `didModifyPreference`, this fires only the untyped observation path — it
    /// does NOT fire the typed `_preference` path so TestAccess never records a
    /// ValueUpdate for ancestor contexts that did not write their own contribution.
    func notifyPreferenceChange<V>(_ storage: PreferenceStorage<V>) {}

    /// Called inside the lock just before weakParents is mutated.
    /// Implementations should call willSet on the ObservationRegistrar.
    func willModifyParents() {}

    /// Called after weakParents has been mutated (post-lock via callbacks).
    /// Implementations should fire modifyCallbacks and didSet on the ObservationRegistrar.
    func didModifyParents(callbacks: inout [() -> Void]) {}

    func addParent(_ parent: AnyContext, callbacks: inout [() -> Void]) {
        willModifyParents()
        parentsLock { weakParents.append(WeakParent(parent: parent)) }
        anyModificationActiveCount += parent.anyModificationActiveCount
        didModifyParents(callbacks: &callbacks)
    }

    func removeParent(_ parent: AnyContext, callbacks: inout [() -> Void]) {
        willModifyParents()
        var found = false
        parentsLock {
            for i in weakParents.indices {
                if weakParents[i].parent === parent {
                    weakParents.remove(at: i)
                    found = true
                    break
                }
            }
        }
        if found {
            anyModificationActiveCount -= parent.anyModificationActiveCount
        }

        didModifyParents(callbacks: &callbacks)

        if parents.isEmpty {
            onRemoval(callbacks: &callbacks)
        }
    }

    var rootParent: AnyContext {
        parents.first?.rootParent ?? self
    }

    /// The current live parents. Calling this from observation-tracked code will register
    /// a dependency on the parents relationship via `willAccessParents()`.
    var parents: [AnyContext] {
        weakParents.compactMap(\.parent)
    }

    /// Observed access to parents — registers observation tracking before reading.
    var observedParents: [AnyContext] {
        willAccessParents()
        return weakParents.compactMap(\.parent)
    }

    var selfPath: AnyKeyPath { fatalError() }

    var anyModelID: ModelID { fatalError() }

    /// Calls `body` with the model this context backs, with `access` applied if it propagates to children.
    /// Used by `reduceHierarchy` to hand a correctly-configured model value to the user's transform closure.
    func mapModel<T>(access: ModelAccess?, _ body: (any Model) throws -> T?) rethrows -> T? { fatalError() }

    var rootPaths: [AnyKeyPath] {
        // Collect raw path segments under the lock, then compose OUTSIDE the lock.
        // appending(path:) calls _swift_getKeyPath which acquires the Swift runtime
        // lock. Holding the context lock while needing the runtime lock deadlocks
        // when a GCD thread holds the runtime lock (key path creation during
        // observation/memoize) and needs the context lock (model write).
        let tree = lock { rootPathTree() }
        return composeRootPaths(from: tree)
    }

    /// Intermediate representation of the path hierarchy — raw segments with no
    /// key path composition. Built entirely under the shared context lock.
    private enum RootPathTree {
        case leaf(AnyKeyPath)
        case node([(childPath: AnyKeyPath, elementPath: AnyKeyPath, parentTree: RootPathTree)])
    }

    /// Registers a lazy element-path maker for `collectionPath`. No-op if already registered.
    /// Must be called under the hierarchy lock.
    func registerCollectionElementPathMaker(
        for collectionPath: AnyKeyPath,
        maker: @Sendable @escaping (AnyHashable) -> AnyKeyPath
    ) {
        if collectionElementPathMakersStore == nil {
            collectionElementPathMakersStore = [collectionPath: maker]
        } else if collectionElementPathMakersStore![collectionPath] == nil {
            collectionElementPathMakersStore![collectionPath] = maker
        }
    }

    /// Collects the raw path segments for this context. Must be called under the lock.
    private func rootPathTree() -> RootPathTree {
        if parents.isEmpty {
            return .leaf(selfPath)
        }

        return .node(parents.flatMap { parent in
            parent.children.flatMap { childPath, modelRefs in
                modelRefs.compactMap { modalRef, context -> (childPath: AnyKeyPath, elementPath: AnyKeyPath, parentTree: RootPathTree)? in
                    guard context === self else { return nil }
                    // If a lazy element-path maker was registered for this collection
                    // property (by visitCollection), use it to build the element-level
                    // key path on demand. Without a maker, fall back to the stored
                    // elementPath (cursor-based or sentinel \C.self for non-collection children).
                    let elementPath: AnyKeyPath
                    if let maker = parent.collectionElementPathMakersStore?[childPath] {
                        elementPath = maker(modalRef.id)
                    } else {
                        elementPath = modalRef.elementPath
                    }
                    return (childPath: childPath, elementPath: elementPath, parentTree: parent.rootPathTree())
                }
            }
        })
    }

    /// Composes the collected path segments into full root-relative key paths.
    /// Called outside the lock so _swift_getKeyPath doesn't contend with it.
    private func composeRootPaths(from tree: RootPathTree) -> [AnyKeyPath] {
        switch tree {
        case .leaf(let path):
            return [path]
        case .node(let entries):
            return entries.flatMap { entry -> [AnyKeyPath] in
                guard let childPath = entry.childPath.appending(path: entry.elementPath) else { return [] }
                return composeRootPaths(from: entry.parentTree).compactMap { $0.appending(path: childPath) }
            }
        }
    }

    func onPostTransaction(callbacks: inout [() -> Void], callback: @escaping (inout [() -> Void]) -> Void) {
        if threadLocals.postTransactions != nil {
            threadLocals.postTransactions!.append(callback)
        } else {
            callback(&callbacks)
        }
    }

    init(lock: NSRecursiveLock, parent: AnyContext?, isDepContext: Bool = false) {
        self.lock = lock
        self.isDepContext = isDepContext
        self.options = parent?.options ?? ModelOption.current
        self.mainCallQueue = parent?.mainCallQueue ?? MainCallQueue()
        self.useObservationRegistrar = !self.options.contains(.disableObservationRegistrar)

        // Share a single RegistrarBox across the whole tree. The box is cheap to create (1 alloc);
        // the RegistrarPair inside is allocated lazily on first observation access.
        // Children inherit the parent's reference; root creates a new box when obs is enabled.
        if let parent {
            self._registrarBox = parent._registrarBox
        } else if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), self.useObservationRegistrar {
            self._registrarBox = RegistrarBox()
        } else {
            self._registrarBox = nil
        }

        if let parent {
            // During init, no observers exist yet, so callbacks can be discarded.
            var callbacks: [() -> Void] = []
            addParent(parent, callbacks: &callbacks)
        }
    }

    deinit {
    }

    var activeTasks: [(modelName: String, tasks: [(name: String, fileAndLine: FileAndLine)])] {
        allChildren.reduce(into: cancellationsStore?.activeTasks ?? []) {
            $0.append(contentsOf: $1.activeTasks)
        }
    }

    /// Returns the main registrar if the pair has already been allocated, or nil otherwise.
    /// `_registrarBox` is a `let` constant — safe to read from any thread.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var mainObservationRegistrar: ObservationRegistrar? {
        (_registrarBox as? RegistrarBox).flatMap { $0._pair as? RegistrarPair }?.main
    }

    /// Returns the background registrar if the pair has already been allocated, or nil otherwise.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var backgroundObservationRegistrar: ObservationRegistrar? {
        (_registrarBox as? RegistrarBox).flatMap { $0._pair as? RegistrarPair }?.background
    }

    // Backward compatibility alias.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var observationRegistrar: ObservationRegistrar? {
        mainObservationRegistrar
    }

    /// True when observation registrars are enabled for this context.
    var hasObservationRegistrar: Bool {
        useObservationRegistrar
    }

    /// Returns the main registrar, allocating the `RegistrarPair` lazily on first call.
    /// Only called when `useObservationRegistrar` is true, so `_registrarBox` is non-nil.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var mainObservationRegistrarMakingIfNeeded: ObservationRegistrar {
        let box = _registrarBox as! RegistrarBox
        if let pair = box._pair as? RegistrarPair { return pair.main }
        return lock {
            if box._pair == nil { box._pair = RegistrarPair() }
            return (box._pair as! RegistrarPair).main
        }
    }

    /// Returns the background registrar. Only called when `useObservationRegistrar` is true.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var backgroundObservationRegistrarMakingIfNeeded: ObservationRegistrar {
        let box = _registrarBox as! RegistrarBox
        if let pair = box._pair as? RegistrarPair { return pair.background }
        return lock {
            if box._pair == nil { box._pair = RegistrarPair() }
            return (box._pair as! RegistrarPair).background
        }
    }

    var lifetime: ModelLifetime {
        lock(modeLifeTime)
    }

    var isDestructed: Bool {
        lifetime == .destructed
    }

    var unprotectedIsDestructed: Bool {
        modeLifeTime == .destructed
    }

    func removeChild(_ context: AnyContext, at path: AnyKeyPath, callbacks: inout [() -> Void]) {
        guard let contexts = children[path], let (modelRef, _) = contexts.first(where: { $0.value === context }) else {
            return assertionFailure()
        }

        children[path]?[modelRef] = nil
        if children[path]?.isEmpty == true {
            children[path] = nil
        }

        context.removeParent(self, callbacks: &callbacks)
    }

    /// Calls `body` for each direct child context without allocating an intermediate array.
    /// Use this in hot paths instead of `allChildren` to avoid the 3-array allocation overhead.
    func forEachChild(_ body: (AnyContext) -> Void) {
        for modelRefs in children.values {
            for child in modelRefs.values where child !== self {
                body(child)
            }
        }
        for child in dependencyContexts.values where child !== self {
            body(child)
        }
    }

    var allChildren: [AnyContext] {
        var result: [AnyContext] = []
        forEachChild { result.append($0) }
        return result
    }

    func onActivate() -> Bool {
        return lock {
            defer {
                modeLifeTime = .active
            }
            return modeLifeTime == .anchored
        }
    }

    func onRemoval(callbacks: inout [() -> Void]) {
        let events = eventContinuations.values
        let anyModifies = anyModificationCallbacks.values
        let children = allChildren

        eventContinuations.removeAll()
        anyModificationCallbacks.removeAll()
        modeLifeTime = .destructed
        self.children.removeAll()
        dependencyContexts.removeAll()
        dependencyCache.removeAll()

        for entry in _memoizeCache.values {
            entry.cancellable?()
        }

        // Move cache entries out of the dictionary before clearing. The entries'
        // closures (onUpdate, cancellable) capture shared objects (LockIsolated
        // boxes, context references) that may also be held by in-flight
        // performUpdate closures on the GCD backgroundCallQueue. Releasing the
        // entries here (inside the lock, on the teardown thread) would race with
        // the GCD thread releasing the same objects when it finishes executing or
        // dropping the performUpdate closure — a classic ARC race that causes
        // swift_deallocClassInstance crashes on Linux.
        //
        // By deferring the release to the callbacks array (which runs outside the
        // lock, after child teardown), we give the cancellation flag
        // (hasBeenCancelled) time to propagate and ensure the entries' closures
        // are released on a single thread.
        let memoizeEntries = Array(_memoizeCache.values)
        _memoizeCache.removeAll()

        for entry in contextStorage.values {
            entry.cleanup?()
        }

        contextStorage.removeAll()

        for entry in preferenceStorage.values {
            entry.cleanup?()
        }

        preferenceStorage.removeAll()

        callbacks.append {
            self.cancellationsStore?.cancelAll()

            for cont in events {
                cont.finish()
            }

            for cont in anyModifies {
                cont(true)?()
            }

            // Release memoize cache entries outside the lock. The entries'
            // closures share reference-counted objects with GCD-dispatched
            // performUpdate closures; releasing them here (single-threaded,
            // after cancellation) avoids the ARC race.
            withExtendedLifetime(memoizeEntries) {}
        }

        for child in children {
            child.removeParent(self, callbacks: &callbacks)
        }

        anyModificationActiveCount = 0
    }

    func onRemoval() {
        var callbacks: [() -> Void] = []
        
        lock {
            onRemoval(callbacks: &callbacks)
        }

        for callback in callbacks {
            callback()
        }
    }

    // Entry point for hierarchy traversal. Sets up deduplication state and delegates to
    // the recursive `reduce` helper. Deduplication prevents processing a context twice
    // in cases where a model is reachable via multiple paths (e.g. shared models, or a
    // model that is both a dependency and a child).
    func reduceHierarchy<Result, Element>(for relation: ModelRelation, observeParents: Bool = true, transform: (AnyContext) throws -> Element?, into initialResult: Result, _ updateAccumulatingResult: (inout Result, Element) throws -> ()) rethrows -> Result {
        var result = initialResult
        var uniques = Set<ObjectIdentifier>()
        try reduce(for: relation, observeParents: observeParents, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
        return result
    }

    // Recursive core of the hierarchy traversal.
    //
    // Design notes:
    // - `relation` is narrowed at each level of recursion. When moving upward to ancestors,
    //   the relation passed down keeps `.ancestors` so the walk continues to the root.
    //   Similarly, `.descendants` keeps propagating downward. By contrast, `.parent` and
    //   `.children` are one-hop relations: after processing the direct parent/child, only
    //   `.self` (and optionally `.dependencies`) is passed so the walk stops.
    // - `.dependencies` is preserved at every level so that dependency models attached to
    //   each visited context are also included.
    // - `uniques` prevents visiting the same context more than once across the entire
    //   traversal (important for shared models and multi-parent scenarios).
    // - When a relation includes `.parent` or `.ancestors` AND `observeParents` is true,
    //   `observedParents` is used instead of `parents` so that any active observation tracking
    //   (AccessCollector, ObservationRegistrar, ViewAccess) registers a dependency on the
    //   parents relationship. This means adding or removing a parent triggers re-evaluation in
    //   observers. Pass `observeParents: false` for traversals that don't need observation
    //   (e.g. event routing via `sendEvent`).
    private func reduce<Result, Element>(for relation: ModelRelation, observeParents: Bool = true, transform: (AnyContext) throws -> Element?, into result: inout Result, updateAccumulatingResult: (inout Result, Element) throws -> (), uniques: inout Set<ObjectIdentifier>) rethrows {
        // Read parents under the appropriate lock for the traversal kind.
        // - Observation traversals use the hierarchy lock via `lock(observedParents)` so that
        //   adding/removing a parent triggers re-evaluation in observers.
        // - Event-routing traversals (observeParents: false) use only `parentsLock` — a
        //   dedicated lightweight lock that is independent of the hierarchy lock used for
        //   property reads/writes. This eliminates lock contention between sendEvent and
        //   concurrent property mutations (e.g. a forEach Task updating state while events fly).
        // - When no parent traversal is needed, skip both lock acquisitions entirely.
        let needsParents = relation.contains(.parent) || relation.contains(.ancestors)
        let parents: [AnyContext]
        if needsParents {
            if observeParents {
                parents = lock(observedParents)
            } else {
                parents = parentsLock { weakParents.compactMap(\.parent) }
            }
        } else {
            parents = []
        }

        // Preserve the dependencies flag so it propagates to all levels of the traversal.
        let dependencies: ModelRelation = relation.contains(.dependencies) ? .dependencies : []

        // Process the current context if .self is requested and we haven't visited it yet.
        if relation.contains(.self), !uniques.contains(ObjectIdentifier(self)), let element = try transform(self) {
            try updateAccumulatingResult(&result, element)
            // Mark visited after transform succeeds to prevent double-processing in cycles.
            uniques.insert(ObjectIdentifier(self))
        }

        // Walk upward: ancestors (all levels) or parent (one hop).
        for parent in parents {
            if relation.contains(.ancestors) {
                // Continue upward traversal: pass [.self, .ancestors] so each ancestor is
                // processed and the walk keeps going towards the root.
                try parent.reduce(for: dependencies.union([.self, .ancestors]), observeParents: observeParents, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            } else if relation.contains(.parent) {
                // One-hop upward: pass .self only so the parent is processed but no further.
                try parent.reduce(for: dependencies.union(.self), observeParents: observeParents, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        }

        // Walk downward: descendants (all levels) or children (one hop).
        // Collect children under lock only when a downward traversal is actually needed —
        // ancestor-only relations (e.g. sendEvent routing upward) skip this entirely,
        // making them completely free of the hierarchy lock.
        if relation.contains(.descendants) {
            let children = lock {
                self.children.values.flatMap { $0.values } + (relation.contains(.dependencies) ? Array(dependencyContexts.values) : [])
            }
            for child in children {
                try child.reduce(for: dependencies.union([.self, .descendants]), observeParents: observeParents, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        } else if relation.contains(.children) {
            let children = lock {
                self.children.values.flatMap { $0.values } + (relation.contains(.dependencies) ? Array(dependencyContexts.values) : [])
            }
            for child in children {
                try child.reduce(for: dependencies.union(.self), observeParents: observeParents, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        }
    }

    func sendEvent(_ eventInfo: EventInfo, to relation: ModelRelation) {
        // observeParents: false — event routing never needs to register observation dependencies
        // on the parent relationship. Using plain `parents` (not `observedParents`) avoids the
        // `willAccessParents()` call at every level, reducing lock hold time and observation overhead.
        reduceHierarchy(for: relation, observeParents: false, transform: \.self, into: ()) { _, context in
            for continuation in context.eventContinuations.values {
                continuation.yield(eventInfo)
            }
        }
    }

    func cancelAllRecursively(for id: some Hashable&Sendable) {
        cancellationsStore?.cancelAll(for: id)
        forEachChild { $0.cancelAllRecursively(for: id) }
    }

    func sealRecursively() {
        // Force-create the store if nil, then seal it atomically.
        // If we only do `cancellationsStore?.seal()`, a nil store is a no-op and any
        // subsequent lazy creation produces an unsealed store — allowing tasks to register
        // after cancelAllRecursively() has already run.
        lock {
            if cancellationsStore == nil { cancellationsStore = Cancellations() }
            cancellationsStore!.seal()
        }
        forEachChild { $0.sealRecursively() }
    }

    var typeDescription: String { fatalError() }

    func generateKey() -> Int {
        lock {
            defer { nextKey += 1 }
            return nextKey
        }
    }

    func events() -> AsyncStream<EventInfo> {
        lock {
            guard !isDestructed else {
                return .finished
            }
            let (stream, cont) = AsyncStream<EventInfo>.makeStream()
            let key = generateKey()

            cont.onTermination = { [weak self] _ in
                self?.lock {
                    _ = self?.eventContinuations.removeValue(forKey: key)
                }
            }

            eventContinuations[key] = cont
            return stream
        }
    }

    func withModificationActiveCount(_ callback: (inout Int) -> Void) {
        lock {
            callback(&anyModificationActiveCount)
            forEachChild { $0.withModificationActiveCount(callback) }
        }
    }

    func onAnyModification(callback: @Sendable @escaping (Bool) -> (() -> Void)?) -> @Sendable () -> Void {
        let key = generateKey()
        lock {
            anyModificationCallbacks[key] = callback
            withModificationActiveCount {
                $0 += 1
            }
        }

        return { [weak self] in
            _ = self?.lock {
                self?.withModificationActiveCount {
                    $0 -= 1
                }
                self?.anyModificationCallbacks.removeValue(forKey: key)
            }
        }
    }

    func didModify(callbacks: inout [() -> Void]) {
        _modificationCounts = nil
        guard anyModificationActiveCount > 0 else { return }

        for callback in anyModificationCallbacks.values {
            if let c = callback(false) {
                callbacks.append(c)
            }
        }

        for parent in parents {
            parent.didModify(callbacks: &callbacks)
        }
    }

    @TaskLocal static var keepLastSeenAround = false

    /// Walks up the context hierarchy from self to rootParent, returning the first
    /// dependency context found for the given type ID. This ensures child-level
    /// withDependencies overrides take precedence over root-level ones.
    func nearestDependencyContext(for typeID: ObjectIdentifier) -> AnyContext? {
        // Dep contexts search parents first so the root's explicit override wins over the dep
        // model's own testValue dep defaults (e.g. BackendModel.testValue overrides EnvDep to
        // "backendEnv", but root sets EnvDep to "editor" — root must win). If no parent has
        // an override, fall back to self's own dep contexts (set up by the dep loop in init).
        var current: AnyContext? = isDepContext
            ? parentsLock { weakParents.first?.parent }
            : self
        while let ctx = current {
            if let dep = ctx.dependencyContexts[typeID] {
                return dep
            }
            if ctx === rootParent { break }
            current = ctx.parentsLock { ctx.weakParents.first?.parent }
        }
        // For dep contexts with no parent override, use own dep-loop context as fallback.
        return isDepContext ? dependencyContexts[typeID] : nil
    }

    func setupModelDependency<D: Model>(_ model: inout D, cacheKey: AnyHashable?, postSetups: inout [() -> Void]) {
        let modelSrc = model.modelContext._source
        let modelRef = modelSrc.reference

        guard !modelRef.isSnapshot else {
            // Snapshot reference (frozen/lastSeen) — no dependency setup needed.
            return
        }

        if !modelSrc._isLive && modelRef.context != nil {
            // Model has a live context (was `.reference` SourceKind with context).
            let reference = modelRef
            if let child = reference.context, child.rootParent === rootParent {
                if dependencyContexts[ObjectIdentifier(D.self)] == nil {
                    dependencyContexts[ObjectIdentifier(D.self)] = child
                    child.addParent(self, callbacks: &postSetups)
                }
                return
            } else if dependencyContexts[ObjectIdentifier(D.self)] == nil || reference.lifetime == .destructed {
                if let cacheKey {
                    if let context = rootParent.dependencyContexts[ObjectIdentifier(D.self)] as? Context<D> {
                        model.withContextAdded(context: context)
                        model.modelContext = ModelContext(context: context)
                    } else {
                        model = model.initialDependencyCopy // make sure to do unique copy of default value (liveValue etc).
                        rootParent.setupModelDependency(&model, cacheKey: nil, postSetups: &postSetups)
                        rootParent.dependencyCache[cacheKey] = model
                    }
                    // Register the shared dependency context on self directly rather than
                    // recursing into setupModelDependency again. At this point the model's
                    // context exists in rootParent.dependencyContexts, but its parent link
                    // to rootParent hasn't been established yet (that happens in postSetups),
                    // so the child.rootParent === rootParent check in the recursive call would
                    // fail, producing an infinite recursion / stack overflow.
                    if let child = model.modelContext.reference?.context {
                        if dependencyContexts[ObjectIdentifier(D.self)] == nil {
                            dependencyContexts[ObjectIdentifier(D.self)] = child
                            child.addParent(self, callbacks: &postSetups)
                        }
                    }
                } else {
                    // If the model already has a live context (e.g. a @Model dependency whose
                    // testValue/liveValue was previously anchored), make a fresh copy preserving
                    // its identity so it can be re-anchored cleanly.
                    // If it has no context, initialCopy suffices and preserves the model's identity.
                    if model.context != nil {
                        model = model.initialDependencyCopy
                    } else {
                        model = model.initialCopy
                    }
                    // After the copy transforms above, context must be nil. It can still be non-nil
                    // in the extreme edge case where _stateCleared AND _hasGenesis == false (e.g.
                    // a reference that was cleared before its first anchoring). Guard defensively
                    // rather than crashing — the dependency simply won't be registered this call.
                    guard model.context == nil else { return }
                    let child = Context<D>(model: model, lock: lock, dependencies: nil, parent: self, isDepContext: true)
                    child.withModificationActiveCount { $0 = anyModificationActiveCount }
                    dependencyContexts[ObjectIdentifier(D.self)] = child
                    model.withContextAdded(context: child)
                    model.modelContext = ModelContext(context: child)
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
            }
        } else {
            // Fresh pre-anchor model from DependencyValues (was `.pending`/`.live` SourceKind).
            // All pre-anchor copies of the model share the same Reference (class). After
            // Context.init calls setContext, those copies (e.g. test code's `sharedDep`)
            // automatically route writes to the context via ref._context.

            if let cacheKey {
                // Look for an existing dependency context: walk from self up through
                // parents to find the nearest ancestor that has one. This ensures that
                // a child-level withDependencies override takes precedence over the
                // root-level override (e.g. grandchild sees childDep, not rootDep).
                let depTypeID = ObjectIdentifier(D.self)
                if let context = nearestDependencyContext(for: depTypeID) as? Context<D> {
                    model.withContextAdded(context: context)
                    model.modelContext = ModelContext(context: context)
                } else {
                    // Atomically claim this Reference or fork a genesis-state copy if another
                    // Context is already using it (concurrent test sharing a static `let testValue`).
                    // `reserveOrFork` pre-increments _liveContextCount under the Reference lock,
                    // eliminating the TOCTOU race between checking model.context and setContext.
                    let ref = model.modelContext._source.reference
                    let reservedRef = ref.reserveOrFork()
                    if reservedRef !== ref {
                        var mc = model.modelContext
                        mc._source = _ModelSourceBox(reference: reservedRef)
                        model.modelContext = mc
                    }
                    // If this is a live/internal copy (unlikely but defensive), fall back
                    if model.context != nil {
                        model = model.initialDependencyCopy
                    }
                    // Guard defensively — see equivalent comment at the other call site above.
                    guard model.context == nil else { return }
                    let child = Context<D>(model: model, lock: lock, dependencies: nil, parent: self, isDepContext: true)
                    child.withModificationActiveCount { $0 = anyModificationActiveCount }
                    rootParent.dependencyContexts[depTypeID] = child
                    model.withContextAdded(context: child)
                    model.modelContext = ModelContext(context: child)
                    rootParent.dependencyCache[cacheKey] = model
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
                if let child = model.modelContext.reference?.context {
                    if dependencyContexts[depTypeID] == nil {
                        dependencyContexts[depTypeID] = child
                        // Only add self as parent if this is a reused context (found via
                        // nearestDependencyContext). When we just created the context above
                        // with `parent: self`, self is already a parent — don't duplicate.
                        if child.parents.allSatisfy({ $0 !== self }) {
                            child.addParent(self, callbacks: &postSetups)
                        }
                    }
                    // Ensure the root parent is also a parent of the dependency context so
                    // that metadataModelContext() can walk up to the root's TestAccess.
                    if self !== rootParent, child.parents.allSatisfy({ $0 !== rootParent }) {
                        child.addParent(rootParent, callbacks: &postSetups)
                    }
                }
            } else {
                // Check if a dependency context for the same original model already exists
                // (e.g. shared dependency anchored by a sibling child via withDependencies).
                // All copies share the same Reference, so modelID is the same across copies.
                let pendingKey = _PendingDepKey(typeID: ObjectIdentifier(D.self), modelID: model.modelID)
                let depTypeID = ObjectIdentifier(D.self)
                if let existing = rootParent.dependencyCache[pendingKey] as? Context<D> {
                    model.withContextAdded(context: existing)
                    model.modelContext = ModelContext(context: existing)
                    if dependencyContexts[depTypeID] == nil {
                        dependencyContexts[depTypeID] = existing
                        existing.addParent(self, callbacks: &postSetups)
                    }
                } else {
                    assert(model.context == nil)
                    let child = Context<D>(model: model, lock: lock, dependencies: nil, parent: self, isDepContext: true)
                    child.withModificationActiveCount { $0 = anyModificationActiveCount }
                    dependencyContexts[depTypeID] = child
                    model.withContextAdded(context: child)
                    model.modelContext = ModelContext(context: child)
                    // No _linkedReference needed: all pre-anchor copies already hold child.reference
                    // (the single shared Reference). After setContext, ref._context = child.
                    rootParent.dependencyCache[pendingKey] = child
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
            }
        }
    }

    func dependency<Value>(for keyPath: KeyPath<DependencyValues, Value>&Sendable) -> Value {
        lock {
            if let value = dependencyCache[keyPath] as? Value {
                return value
            }

            // Use capturedDependencies (not withDependencies(from: self)) to avoid the merge
            // where DependencyValues._current wins. When accessed from a background task
            // originating from an ancestor context, _current carries the ancestor's deps —
            // overwriting any overrides set on this context. By installing this context's own
            // captured deps, the lookup always uses the correct, override-respecting values.
            return DependencyValues.$_current.withValue(capturedDependencies) {
                let value = Dependency(keyPath).wrappedValue
                // Skip Model dependency setup when the context is destructed (e.g. onCancel
                // callbacks): the context's children/parents are already torn down, so calling
                // setupModelDependency would operate on an invalid context graph and crash.
                // Non-model dependencies are returned directly from capturedDependencies.
                if !unprotectedIsDestructed, var model = value as? any Model {
                    if model.anyContext === self {
                        reportIssue("Recursive dependency detected")
                    }

                    withPostActions { postActions in
                        setupModelDependency(&model, cacheKey: keyPath, postSetups: &postActions)
                        dependencyCache[keyPath] = model
                    }
                    return model as! Value
                } else {
                    if !unprotectedIsDestructed {
                        dependencyCache[keyPath] = value
                    }
                    return value
                }
            }
        }
    }

    func dependency<Value: DependencyKey>(for type: Value.Type) -> Value where Value.Value == Value {
        lock {
            let key = ObjectIdentifier(type)
            if let value = dependencyCache[key] as? Value {
                return value
            }

            // Same rationale as the keyPath overload above: use capturedDependencies directly
            // so that ancestor task-locals don't overwrite this context's dep overrides.
            return DependencyValues.$_current.withValue(capturedDependencies) {
                let value = Dependency(type).wrappedValue
                if !unprotectedIsDestructed, var model = value as? any Model {
                    if model.anyContext === self {
                        reportIssue("Recursive dependency detected")
                    }

                    withPostActions { postActions in
                        setupModelDependency(&model, cacheKey: key, postSetups: &postActions)
                        dependencyCache[key] = model
                    }
                    return model as! Value
                } else {
                    if !unprotectedIsDestructed {
                        dependencyCache[key] = value
                    }
                    return value
                }
            }
        }
    }
}

/// Composite key for looking up dependency contexts created from `.pending` models.
/// Two struct copies of the same `@Model` share Reference (class) and thus the same
/// modelID, enabling sibling contexts to find and share the dependency context.
private struct _PendingDepKey: Hashable {
    let typeID: ObjectIdentifier
    let modelID: ModelID
}

func withPostActions<T>(perform: (inout [() -> Void]) throws -> T) rethrows -> T {
    var postActions: [() -> Void] = []
    defer {
        for action in postActions {
            action()
        }
    }
    return try perform(&postActions)
}
