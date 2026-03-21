import Foundation
import Dependencies
import OrderedCollections

enum ModelLifetime: Comparable {
    case initial
    case anchored
    case active
    case destructed
    case frozenCopy
}

extension ModelLifetime {
    var isDestructedOrFrozenCopy: Bool {
        self == .destructed || self == .frozenCopy
    }
}

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

    private(set) var weakParents: [WeakParent] = []
    var children: OrderedDictionary<AnyKeyPath, OrderedDictionary<ModelRef, AnyContext>> = [:]
    var dependencyContexts: [ObjectIdentifier: AnyContext] = [:]
    var dependencyCache: [AnyHashable: Any] = [:]

    private var modeLifeTime: ModelLifetime = .anchored

    private var eventContinuations: [Int: AsyncStream<EventInfo>.Continuation] = [:]
    private let _mainObservationRegistrar: Any?
    private let _backgroundObservationRegistrar: Any?
    let cancellations = Cancellations()

    private(set) var anyModificationActiveCount = 0
    private var anyModificationCallbacks: [Int: (Bool) -> (() -> Void)?] = [:]
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
    
    var _memoizeCache: [AnyHashableSendable: MemoizeCacheEntry] = [:]

    // Typed per-context storage for internal features (undo, environment, etc.).
    // Keyed by AnyHashableSendable (source location or explicit key from ContextStorage).
    // Access via the typed subscript defined in ModelContextStorage.swift (ContextStorage subscript).
    struct ContextStorageEntry: @unchecked Sendable {
        var value: any Sendable
        // Type-erased onRemoval hook, set when the storage declares one.
        var cleanup: (() -> Void)?
    }
    var contextStorage: [AnyHashableSendable: ContextStorageEntry] = [:]

    /// The DependencyValues captured at this context's initialization time, after all dependency
    /// overrides from withDependencies closures have been applied.
    ///
    /// Used by dependency(for:) to ensure dep resolution uses this context's own deps, not
    /// whatever happens to be in DependencyValues._current (which may belong to an ancestor
    /// context when this context is accessed from a background task).
    var capturedDependencies: DependencyValues = .init()

    // Bottom-up preference storage. Each context holds its own contribution; the aggregate
    // is computed by walking descendants. Keyed by AnyHashableSendable (source location or
    // explicit key from PreferenceStorage).
    // Access via the typed subscript defined in ModelPreferenceStorage.swift.
    struct PreferenceStorageEntry: @unchecked Sendable {
        var value: any Sendable
        var cleanup: (() -> Void)?
    }
    var preferenceStorage: [AnyHashableSendable: PreferenceStorageEntry] = [:]

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
        weakParents.append(WeakParent(parent: parent))
        anyModificationActiveCount += parent.anyModificationActiveCount
        didModifyParents(callbacks: &callbacks)
    }

    func removeParent(_ parent: AnyContext, callbacks: inout [() -> Void]) {
        willModifyParents()
        for i in weakParents.indices {
            if weakParents[i].parent === parent {
                weakParents.remove(at: i)
                anyModificationActiveCount -= parent.anyModificationActiveCount

                break
            }
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

    func parents<Value>(ofType type: Value.Type = Value.self) -> [Value] {
        parents.compactMap { $0.anyModel as? Value }
    }

    func ancestors<Value>(ofType type: Value.Type = Value.self) -> [Value] {
        parents() + parents.flatMap { $0.ancestors() }
    }

    var selfPath: AnyKeyPath { fatalError() }

    var anyModel: any Model { fatalError() }

    /// The ModelAccess registered on this context's live model, if any.
    /// Overridden by Context<M> to return readModel.modelContext.access.
    var anyModelAccess: ModelAccess? { nil }

    var rootPaths: [AnyKeyPath] {
        lock {
            if parents.isEmpty {
                return [selfPath]
            }

            return parents.flatMap { parent in
                let childPaths = parent.children.flatMap { childPath, modelRefs in
                    modelRefs.compactMap { modalRef, context in
                        if context === self {
                            return childPath.appending(path: modalRef.elementPath)
                        } else {
                            return nil
                        }
                    }
                }

                return parent.rootPaths.flatMap { rootPath in
                    childPaths.compactMap { rootPath.appending(path: $0) }
                }
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

    let isObservable: Bool

    init(lock: NSRecursiveLock, options: ModelOption, parent: AnyContext?, isObservable: Bool) {
        self.lock = lock
        self.options = parent?.options ?? options
        self.isObservable = isObservable
        
        // Use ObservationRegistrar unless disabled
        let useObservationRegistrar = !self.options.contains(.disableObservationRegistrar)
        
        if useObservationRegistrar, #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            _mainObservationRegistrar = ObservationRegistrar()
            _backgroundObservationRegistrar = ObservationRegistrar()
        } else {
            _mainObservationRegistrar = nil
            _backgroundObservationRegistrar = nil
        }

        if let parent {
            // During init, no observers exist yet, so callbacks can be discarded.
            var callbacks: [() -> Void] = []
            addParent(parent, callbacks: &callbacks)
        }
    }

    deinit {
    }

    var activeTasks: [(modelName: String, fileAndLines: [FileAndLine])] {
        allChildren.reduce(into: cancellations.activeTasks) {
            $0.append(contentsOf: $1.activeTasks)
        }
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var mainObservationRegistrar: ObservationRegistrar? {
        _mainObservationRegistrar as? ObservationRegistrar
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var backgroundObservationRegistrar: ObservationRegistrar? {
        _backgroundObservationRegistrar as? ObservationRegistrar
    }

    // Backward compatibility: return main registrar
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var observationRegistrar: ObservationRegistrar? {
        mainObservationRegistrar
    }

    var hasObservationRegistrar: Bool {
        _mainObservationRegistrar != nil
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

        for entry in _memoizeCache.values {
            entry.cancellable?()
        }

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
            self.cancellations.cancelAll()

            for cont in events {
                cont.finish()
            }

            for cont in anyModifies {
                cont(true)?()
            }
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
    func reduceHierarchy<Result, Element>(for relation: ModelRelation, transform: (AnyContext) throws -> Element?, into initialResult: Result, _ updateAccumulatingResult: (inout Result, Element) throws -> ()) rethrows -> Result {
        var result = initialResult
        var uniques = Set<ObjectIdentifier>()
        try reduce(for: relation, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
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
    // - When a relation includes `.parent` or `.ancestors`, `observedParents` is used instead
    //   of `parents` so that any active observation tracking (AccessCollector, ObservationRegistrar,
    //   ViewAccess) registers a dependency on the parents relationship itself. This means that
    //   adding or removing a parent will trigger re-evaluation in observers.
    private func reduce<Result, Element>(for relation: ModelRelation, transform: (AnyContext) throws -> Element?, into result: inout Result, updateAccumulatingResult: (inout Result, Element) throws -> (), uniques: inout Set<ObjectIdentifier>) rethrows {
        // Read parents under lock to avoid data races on the weakParents array.
        // Use observedParents (instead of plain `parents`) when the traversal needs to walk
        // upward — this registers the read with any active observation tracking so that
        // adding/removing a parent triggers re-evaluation.
        let parents = lock(relation.contains(.parent) || relation.contains(.ancestors) ? observedParents : parents)

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
                try parent.reduce(for: dependencies.union([.self, .ancestors]), transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            } else if relation.contains(.parent) {
                // One-hop upward: pass .self only so the parent is processed but no further.
                try parent.reduce(for: dependencies.union(.self), transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        }

        // Collect children (and dependency contexts if requested) under lock.
        let children = lock {
            self.children.values.flatMap { $0.values } + (relation.contains(.dependencies) ? Array(dependencyContexts.values) : [])
        }

        // Walk downward: descendants (all levels) or children (one hop).
        if relation.contains(.descendants) {
            for child in children {
                try child.reduce(for: dependencies.union([.self, .descendants]), transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        } else if relation.contains(.children) {
            for child in children {
                try child.reduce(for: dependencies.union(.self), transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        }
    }

    func sendEvent(_ eventInfo: EventInfo, to relation: ModelRelation) {
        reduceHierarchy(for: relation, transform: \.self, into: ()) { _, context in
            for continuation in context.eventContinuations.values {
                continuation.yield(eventInfo)
            }
        }
    }

    func cancelAllRecursively(for id: some Hashable&Sendable) {
        cancellations.cancelAll(for: id)
        forEachChild { $0.cancelAllRecursively(for: id) }
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

    func setupModelDependency<D: Model>(_ model: inout D, cacheKey: AnyHashable?, postSetups: inout [() -> Void]) {
        switch model.modelContext.source {
        case let .reference(reference):
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
                    assert(model.context == nil)
                    let child = Context<D>(model: model, lock: lock, options: self.options, dependencies: { _ in }, parent: self)
                    child.withModificationActiveCount { $0 = anyModificationActiveCount }
                    dependencyContexts[ObjectIdentifier(D.self)] = child
                    model.withContextAdded(context: child)
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
            }
        case .frozenCopy, .lastSeen:
            return // warn?
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
                if var model = value as? any Model {
                    if model.anyContext === self {
                        reportIssue("Recursive dependency detected")
                    }

                    withPostActions { postActions in
                        setupModelDependency(&model, cacheKey: keyPath, postSetups: &postActions)
                        dependencyCache[keyPath] = model
                    }
                    return model as! Value
                } else {
                    dependencyCache[keyPath] = value
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
                if var model = value as? any Model {
                    if model.anyContext === self {
                        reportIssue("Recursive dependency detected")
                    }

                    withPostActions { postActions in
                        setupModelDependency(&model, cacheKey: key, postSetups: &postActions)
                        dependencyCache[key] = model
                    }
                    return model as! Value
                } else {
                    dependencyCache[key] = value
                    return value
                }
            }
        }
    }
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
