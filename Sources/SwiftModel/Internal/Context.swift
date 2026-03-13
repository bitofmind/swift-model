import Foundation
import Dependencies
import OrderedCollections
import IssueReporting
import CustomDump

final class Context<M: Model>: AnyContext, @unchecked Sendable {
    private let activations: [(M) -> Void]
    private(set) var modifyCallbacks: [PartialKeyPath<M>: [Int: (_ finished: Bool, _ force: Bool) -> (() -> Void)?]] = [:]
    let reference: Reference
    var readModel: M
    var modifyModel: M
    private var isMutating = false

    @Dependency(\.uuid) private var dependencies

    init(model: M, lock: NSRecursiveLock, options: ModelOption, dependencies: (inout ModelDependencies) -> Void, parent: AnyContext?) {
        if model.lifetime != .initial {
            reportIssue("It is not allowed to add an already anchored or fozen model, instead create new instance.")
        }

        readModel = model.initialCopy
        modifyModel = readModel

        let modelSetup = model.modelSetup
        self.activations = modelSetup?.activations ?? []
        reference = readModel.reference ?? Reference(modelID: model.modelID)
        let isObservable: Bool
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            isObservable = M.self is any Observable.Type
        } else {
            isObservable = false
        }
        super.init(lock: lock, options: options, parent: parent, isObservable: isObservable)

        var dependencyModels: [AnyHashable: any Model] = [:]
        Dependencies.withDependencies(from: parent ?? self) {
            var contextDependencies = ModelDependencies(dependencies: $0)
            dependencies(&contextDependencies)
            for dependency in modelSetup?.dependencies ?? [] {
                dependency(&contextDependencies)
            }

            $0 = contextDependencies.dependencies
            dependencyModels = contextDependencies.models
        } operation: {
            _dependencies = Dependency(\.uuid)
        }

        readModel.withContextAdded(context: self)
        readModel.modelContext.access = nil
        modifyModel = readModel
        reference.setContext(self)

        withPostActions { postActions in
            for (key, model) in dependencyModels {
                var model = model
                setupModelDependency(&model, cacheKey: nil, postSetups: &postActions)
                dependencyCache[key] = model
            }
        }
    }

    deinit {
    }

    override func onActivate() -> Bool {
        let shouldActivate = super.onActivate()

        if shouldActivate {
            AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: ContextCancellationKey.onActivate)]) {
                model.onActivate()
            }

            for activation in activations {
                activation(model)
            }
        }

        for child in lock(allChildren) {
            _ = child.onActivate()
        }

        return shouldActivate
    }

    override func onRemoval(callbacks: inout [() -> Void]) {
        super.onRemoval(callbacks: &callbacks)
        let modifies = modifyCallbacks.values.flatMap({ $0.values })
        modifyCallbacks.removeAll()

        callbacks.append {
            for cont in modifies {
                cont(true, false)?()
            }
        }

        guard !_XCTIsTesting || AnyContext.keepLastSeenAround else {
            reference.destruct(nil)
            return
        }

        let lastSeenValue = readModel.lastSeen(at: Date(), dependencyCache: dependencyCache)
        reference.destruct(lastSeenValue)

        Task {
            try? await Task.sleep(nanoseconds: NSEC_PER_MSEC*UInt64(lastSeenTimeToLive*1000))
            reference.clear()
        }
    }

    func sendEvent(_ event: Any, to relation: ModelRelation, context: AnyContext) {
        let eventInfo = EventInfo(event: event, context: context)
        sendEvent(eventInfo, to: relation)
    }

    // MARK: - Parents observation

    // The key path used to represent the parents relationship in the observation system.
    // Using a subscript guarantees no collision with any user-defined property on M.
    private var parentsObservationPath: KeyPath<M, [ModelID]>&Sendable { \M[_parentsObservationKey: _ParentsObservationKey()] }

    // A ModelContext wrapping this context, used to delegate to the shared
    // willAccess/didModify helpers which handle all observation paths uniformly.
    private var modelContext: ModelContext<M> { ModelContext(context: self) }

    override func willAccessParents() {
        modelContext.willAccess(readModel, at: parentsObservationPath)?()
    }

    override func willModifyParents() {
        // willSet is called as part of the didModify closure returned by ModelContext.didModify.
        // Nothing needed here — the modify closure captures willSet/didSet together.
    }

    override func didModifyParents(callbacks: inout [() -> Void]) {
        let path = parentsObservationPath
        didModify()
        let mc = modelContext
        let snap = readModel
        let modifyCallbacksForPath = modifyCallbacks[path]?.values.compactMap { $0(false, false) } ?? []
        callbacks.append {
            mc.invokeDidModify(snap, at: path)
            for c in modifyCallbacksForPath { c() }
        }
        var didModifyCallbacks: [() -> Void] = []
        didModify(callbacks: &didModifyCallbacks)
        callbacks.append(contentsOf: didModifyCallbacks)
    }

    override func willAccessStorage<V>(_ storage: ContextStorage<V>) {
        // Skip all observation when applying Access closures to snapshot copies inside the
        // isEqualIncludingIds lock. Keypath creation via _swift_getKeyPath can deadlock
        // when the Swift runtime lock is held on another thread.
        guard !threadLocals.isApplyingSnapshot else { return }

        // Synthetic untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
        let untypedPath: KeyPath<M, AnyHashableSendable>&Sendable = \M[environmentKey: storage.key]
        modelContext.willAccess(readModel, at: untypedPath)?()

        // Typed writable path — drives TestAccess snapshot tracking so that
        // `model.node.context.myKey` inside tester.assert {} is fully assertable.
        // \M[_metadata: storage] is a WritableKeyPath<M, V> because ContextStorage<V>
        // is Hashable (via its key), giving Swift what it needs to form and distinguish paths.
        // Tag the access as `.metadata` so TestAccess records it under the correct exhaustivity area.
        //
        // Use a ModelContext with a known access rather than the computed `modelContext` property
        // (which creates a fresh ModelContext with _access = nil and never reaches TestAccess).
        // For dependency model contexts, readModel.modelContext.access is nil; fall back to the
        // access registered on the nearest ancestor (e.g. ConsumerModel's TestAccess).
        // Guard against re-entry: the TestAccess.willAccess closure reads
        // model.context![path] which invokes the context getter, which calls willAccessStorage
        // again → infinite recursion. The flag is set for the closure call only, not the
        // willAccess call itself, so legitimate outer calls (predicate evaluation) still work.
        guard !threadLocals.isAccessingMetadataStorage else { return }
        let typedPath: WritableKeyPath<M, V>&Sendable = \M[_metadata: storage]
        let mc = metadataModelContext()
        let closureOpt = threadLocals.withValue(.context, at: \.modificationArea) {
            threadLocals.withValue(storage.name, at: \.storageName) {
                mc.willAccess(readModel, at: typedPath)
            }
        }
        if let closure = closureOpt {
            threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                closure()
            }
        }
    }

    override func didModifyStorage<V>(_ storage: ContextStorage<V>) {
        // Synthetic untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
        let untypedPath: KeyPath<M, AnyHashableSendable>&Sendable = \M[environmentKey: storage.key]
        // Typed writable path — drives TestAccess didModify so writes are tracked for exhaustion.
        // Tag the modification as `.metadata` so TestAccess records it under the correct area.
        //
        // Use a ModelContext with a known access: own readModel's access if set, or the nearest
        // ancestor's access (handles dependency model contexts where own access is nil).
        // Guard against re-entry via the same isAccessingMetadataStorage flag used in willAccessStorage.
        let typedPath: WritableKeyPath<M, V>&Sendable = \M[_metadata: storage]
        let mc = metadataModelContext()

        lock { self.didModify() }
        modelContext.invokeDidModify(readModel, at: untypedPath)
        // Same re-entry guard as willAccessStorage: the TestAccess.didModify closure reads
        // model.context![path] which goes through the context getter → willAccessStorage → loop.
        if !threadLocals.isAccessingMetadataStorage {
            threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                threadLocals.withValue(.context, at: \.modificationArea) {
                    threadLocals.withValue(storage.name, at: \.storageName) {
                        mc.invokeDidModify(readModel, at: typedPath)
                    }
                }
            }
        }
        // Use the typed path for post-lock callbacks so modifyCallbacks keyed on it fire correctly.
        let postLockCallbacks = lock { buildPostLockCallbacks(for: typedPath) }
        runPostLockCallbacks(postLockCallbacks)
    }

    override func willAccessPreference<V>(_ storage: PreferenceStorage<V>) {
        // Skip all observation when applying Access closures to snapshot copies inside the
        // isEqualIncludingIds lock. Keypath creation via _swift_getKeyPath can deadlock
        // when the Swift runtime lock is held on another thread.
        guard !threadLocals.isApplyingSnapshot else { return }

        // Synthetic untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
        let untypedPath: KeyPath<M, AnyHashableSendable>&Sendable = \M[preferenceKey: storage.key]
        modelContext.willAccess(readModel, at: untypedPath)?()

        // The typed writable path for TestAccess is now handled by willAccessPreferenceValue,
        // called after preferenceValue finishes aggregating with the computed value in hand.
        // Registering it here (during reduceHierarchy traversal) would require reading back
        // the value via model.context![path], which re-enters preferenceValue under a lock
        // and can deadlock due to lock-ordering inversion with background tasks.
    }

    override func willAccessPreferenceValue<V>(_ storage: PreferenceStorage<V>, value: V) {
        // Skip all observation when applying Access closures to snapshot copies inside the
        // isEqualIncludingIds lock (same guard as willAccessPreference).
        guard !threadLocals.isApplyingSnapshot else { return }

        // Typed writable path — drives TestAccess snapshot tracking.
        // Called after preferenceValue has finished aggregating, with the computed value
        // already in hand. This avoids re-entering preferenceValue (which acquires child
        // locks) while the caller's context lock may still be held.
        guard !threadLocals.isAccessingMetadataStorage else { return }
        let typedPath: WritableKeyPath<M, V>&Sendable = \M[_preference: storage]
        let mc = metadataModelContext()
        let closureOpt = threadLocals.withValue(.preference, at: \.modificationArea) {
            threadLocals.withValue(storage.name, at: \.storageName) {
                mc.willAccess(readModel, at: typedPath)
            }
        }
        if let closure = closureOpt {
            // Store the pre-computed aggregated value so the TestAccess willAccess closure
            // can use it instead of re-reading via model.context![path] (which would
            // re-enter preferenceValue under a lock and deadlock).
            threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                threadLocals.withValue(value as Any, at: \.precomputedPreferenceValue) {
                    closure()
                }
            }
        }
    }

    override func didModifyPreference<V>(_ storage: PreferenceStorage<V>) {
        // Synthetic untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
        let untypedPath: KeyPath<M, AnyHashableSendable>&Sendable = \M[preferenceKey: storage.key]
        // Typed writable path — drives TestAccess didModify so writes are tracked for exhaustion.
        let typedPath: WritableKeyPath<M, V>&Sendable = \M[_preference: storage]
        let mc = metadataModelContext()

        lock { self.didModify() }
        modelContext.invokeDidModify(readModel, at: untypedPath)
        if !threadLocals.isAccessingMetadataStorage {
            threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                threadLocals.withValue(.preference, at: \.modificationArea) {
                    threadLocals.withValue(storage.name, at: \.storageName) {
                        mc.invokeDidModify(readModel, at: typedPath)
                    }
                }
            }
        }
        // Post-lock callbacks for this context.
        let postLockCallbacks = lock { buildPostLockCallbacks(for: typedPath) }
        runPostLockCallbacks(postLockCallbacks)

        // Preferences are bottom-up: a child contribution change must invalidate ancestor observers.
        // Use notifyPreferenceChange (not didModifyPreference) so that only the untyped observation
        // path fires on ancestors — this prevents TestAccess from recording spurious ValueUpdate
        // entries for ancestor nodes that never wrote their own preference contribution.
        let parents = lock(self.parents)
        for parent in parents {
            parent.notifyPreferenceChange(storage)
        }
    }

    /// Fires only the untyped observation path upward through the hierarchy.
    ///
    /// Used by upward preference propagation to invalidate ancestor observers (Observed {}, SwiftUI)
    /// without creating TestAccess ValueUpdate entries. The typed `_preference` path is intentionally
    /// omitted — ancestors that never wrote a contribution should not appear in exhaustion reports.
    override func notifyPreferenceChange<V>(_ storage: PreferenceStorage<V>) {
        let untypedPath: KeyPath<M, AnyHashableSendable>&Sendable = \M[preferenceKey: storage.key]
        lock { self.didModify() }
        modelContext.invokeDidModify(readModel, at: untypedPath)
        let typedPath: WritableKeyPath<M, V>&Sendable = \M[_preference: storage]
        let postLockCallbacks = lock { buildPostLockCallbacks(for: typedPath) }
        runPostLockCallbacks(postLockCallbacks)

        let parents = lock(self.parents)
        for parent in parents {
            parent.notifyPreferenceChange(storage)
        }
    }

    /// Returns a ModelContext for use in context storage willAccess/didModify notifications.
    ///
    /// Uses `readModel.modelContext` when it has a non-nil access (normal child models with
    /// TestAccess wired in). For dependency model contexts (where readModel.modelContext.access
    /// is nil), falls back to a copy with the nearest ancestor's access, so TestAccess on the
    /// root model correctly receives context read/write notifications from dependency models.
    private func metadataModelContext() -> ModelContext<M> {
        if readModel.modelContext.access != nil {
            return readModel.modelContext
        }
        // Dependency model context: readModel.modelContext.access is nil.
        // Walk parents to find a context that has a propagating access (e.g. TestAccess).
        let ancestorAccess = lock {
            parents.lazy.compactMap { $0.anyModelAccess }.first
        }
        guard let ancestorAccess, ancestorAccess.shouldPropagateToChildren else {
            return readModel.modelContext
        }
        var mc = readModel.modelContext
        mc.access = ancestorAccess
        return mc
    }

    func onModify<T>(for path: KeyPath<M, T>&Sendable, _ callback: @Sendable @escaping (_ finished: Bool, _ force: Bool) -> (() -> Void)?) -> @Sendable () -> Void {
        guard !isDestructed else {
            return {}
        }

        let key = generateKey()
        lock {
            modifyCallbacks[path, default: [:]][key] = callback
        }

        return { [weak self] in
            guard let self else { return }
            self.lock {
                _ = self.modifyCallbacks[path]?.removeValue(forKey: key)
            }
        }
    }

    override var typeDescription: String {
        String(describing: M.self)
    }

    override var selfPath: AnyKeyPath { \M.self }

    var model: M {
        lock(readModel)
    }

    override var anyModel: any Model {
        model
    }

    override var anyModelAccess: ModelAccess? {
        lock { readModel.modelContext.access }
    }

    func updateContext<T: Model>(for model: inout T, at path: WritableKeyPath<M, T>){
        guard !isDestructed else { return }
        
        model.withContextAdded(context: self, containerPath: \M.self, elementPath: path, includeSelf: true)
    }

    private var modelRefs: Set<ModelRef> = []

    func updateContext<C: ModelContainer>(for container: inout C, at path: WritableKeyPath<M, C>) -> [AnyContext] {
        guard !isDestructed else { return [] }

        return lock {
            let prevChildren = (children[path] ?? [:])
            let prevRefs = Set(prevChildren.keys)

            modelRefs.removeAll(keepingCapacity: true)
            container.withContextAdded(context: self, containerPath: path, elementPath: \.self, includeSelf: false)

            let oldRefs = prevRefs.subtracting(modelRefs)
            return oldRefs.map { prevChildren[$0]! }
        }
    }

    subscript<T>(path: KeyPath<M, T>, callback: (() -> Void)? = nil) -> T {
        _read {
            lock.lock()
            if unprotectedIsDestructed {
                if let last = reference.model {
                    yield last[keyPath: path]
                } else {
                    yield readModel[keyPath: path]
                }
            } else {
                if isMutating { // Handle will and did set recursion
                    yield modifyModel[keyPath: path]
                } else {
                    yield readModel[keyPath: path]
                }
                callback?()
            }
            lock.unlock()
        }
    }

    subscript<T>(path: WritableKeyPath<M, T>&Sendable, isSame: ((T, T) -> Bool)?, modelContext: ModelContext<M>) -> T {
        _read {
            fatalError()
        }
        _modify {
            lock.lock()
            if unprotectedIsDestructed {
                if var last = reference.model {
                    yield &last[keyPath: path]
                    reference.destruct(last)
                } else {
                    var value = readModel[keyPath: path]
                    yield &value
                }
                lock.unlock()
            } else {
                yield &modifyModel[keyPath: path]

                if let isSame, isSame(modifyModel[keyPath: path], readModel[keyPath: path]) {
                    return lock.unlock()
                }

                self.didModify()
                isMutating = true
                readModel[keyPath: path] = modifyModel[keyPath: path] // handle exclusivity access with recursive calls
                isMutating = false

                // Invoke observation notifications via shared helper — no closure allocation.
                modelContext.invokeDidModify(readModel, at: path)

                let postLockCallbacks = buildPostLockCallbacks(for: path)
                lock.unlock()

                runPostLockCallbacks(postLockCallbacks)
            }
        }
    }

    func transaction<Value, T>(at path: WritableKeyPath<M, Value>&Sendable, isSame: ((Value, Value) -> Bool)?, modelContext: ModelContext<M>, modify: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        let result: T
        if var last = reference.model {
            result = try modify(&last[keyPath: path])
            reference.destruct(last)
            lock.unlock()
        } else {
            result = try modify(&modifyModel[keyPath: path])

            if let isSame, isSame(modifyModel[keyPath: path], readModel[keyPath: path]) {
                lock.unlock()
                return result
            }

            didModify()
            isMutating = true
            readModel[keyPath: path] = modifyModel[keyPath: path] // handle exclusivity access with recursive calls
            isMutating = false

            // Invoke observation notifications via shared helper — no closure allocation.
            modelContext.invokeDidModify(readModel, at: path)

            let postLockCallbacks = buildPostLockCallbacks(for: path)
            lock.unlock()

            runPostLockCallbacks(postLockCallbacks)
        }
        return result
    }

    /// Builds the post-lock callbacks array for a property modification.
    /// Returns nil when there is nothing to do, avoiding the array allocation entirely.
    /// Must be called while the context lock is held.
    private func buildPostLockCallbacks(for path: PartialKeyPath<M>) -> [() -> Void]? {
        // Fast path: skip allocation when no observers exist and we're not in a batched transaction.
        guard modifyCallbacks[path] != nil || anyModificationActiveCount > 0 || threadLocals.postTransactions != nil else {
            return nil
        }
        var postLockCallbacks: [() -> Void] = []
        onPostTransaction(callbacks: &postLockCallbacks) { postCallbacks in
            if let callbacks = self.modifyCallbacks[path] {
                for callback in callbacks.values {
                    if let postCallback = callback(false, false) {
                        postCallbacks.append(postCallback)
                    }
                }
            }
            self.didModify(callbacks: &postCallbacks)
        }
        return postLockCallbacks
    }

    /// Forces observation notifications for `path` without changing the stored value.
    ///
    /// Normally, writing an `Equatable` property with the same value it already holds is a no-op —
    /// no observers are notified. `touch` bypasses that optimisation: it fires all registered
    /// callbacks for the backing storage of `path` as if the value had changed, even though the
    /// value itself is unchanged.
    ///
    /// This is useful when external state that a property depends on has changed in a way that is
    /// invisible to the equality check — for example, a reference-typed backing store that is
    /// mutated in-place, or a computed property whose result depends on external state.
    ///
    /// - Parameter path: The public key path of the property whose observers should be notified.
    ///   Typically the user-visible property path (e.g. `\.document`), not the backing storage path.
    /// - Parameter modelContext: The model context used to invoke `@Observable` / TestAccess notifications.
    func touch<V>(_ path: WritableKeyPath<M, V>&Sendable, modelContext: ModelContext<M>) {
        // Use a PathCollector as the active access so that reading via the normal _read accessor
        // triggers willAccess with the @_ModelTracked backing storage path(s).
        // This avoids any frozen-copy issues that arise when writing through a computed setter.
        let collector = PathCollector<M>()
        usingActiveAccess(collector) {
            _ = readModel[keyPath: path]
        }
        let backingPaths = collector.paths

        lock {
            guard !unprotectedIsDestructed else { return }
            self.didModify()
        }
        // Notify @Observable / TestAccess for each discovered backing path using the
        // type-erased invokers collected by PathCollector.
        let model = lock(readModel)
        for invoker in collector.invokers {
            invoker(modelContext, model)
        }
        // Fire AccessCollector onModify callbacks keyed on the backing paths.
        let postLockCallbacks: [() -> Void]? = lock {
            var callbacks: [() -> Void] = []
            for backingPath in backingPaths {
                onPostTransaction(callbacks: &callbacks) { postCallbacks in
                    if let cbs = self.modifyCallbacks[backingPath] {
                        for callback in cbs.values {
                            if let c = callback(false, true) { postCallbacks.append(c) }
                        }
                    }
                    self.didModify(callbacks: &postCallbacks)
                }
            }
            return callbacks.isEmpty ? nil : callbacks
        }
        // Set forceObservation so that Observed callbacks re-emit the current value
        // even when it hasn't changed (bypassing the isSame duplicate-suppression check).
        threadLocals.withValue(true, at: \.forceObservation) {
            runPostLockCallbacks(postLockCallbacks)
        }
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        if reference.model != nil {
            return try callback()
        }

        var postLockCallbacks: [() -> Void] = []
        defer {
            runPostLockCallbacks(postLockCallbacks)
        }

        return try lock {
            if threadLocals.postTransactions != nil {
                return try callback()
            }

            threadLocals.postTransactions = []
            defer {
                let posts = threadLocals.postTransactions!
                threadLocals.postTransactions = nil
                for postTransaction in posts {
                    postTransaction(&postLockCallbacks)
                }
            }

            return try callback()
        }
    }

    func childContext<C: ModelContainer, Child: Model>(containerPath: WritableKeyPath<M, C>, elementPath: WritableKeyPath<C, Child>, childModel: Child) -> Context<Child> {
        var postLockCallbacks: [() -> Void] = []
        defer {
            runPostLockCallbacks(postLockCallbacks)
        }
        return lock {
            let modelRef = ModelRef(elementPath: elementPath, id: childModel.id)
            modelRefs.insert(modelRef)

            if let child = children[containerPath]?[modelRef] as? Context<Child> {
                return child
            }

            assert(children[containerPath]?[modelRef] == nil)

            if let child = childModel.context {
                child.addParent(self, callbacks: &postLockCallbacks)
                children[containerPath, default: [:]][modelRef] = child
                return child
            } else {
                let child = Context<Child>(model: childModel, lock: lock, options: self.options, dependencies: { _ in }, parent: self)
                children[containerPath, default: [:]][modelRef] = child
                return child
            }
        }
    }
}

extension Context {
    final class Reference: @unchecked Sendable {
        let modelID: ModelID
        private let lock = NSRecursiveLock()
        private weak var _context: Context<M>?
        private(set) var _model: M?
        private var _isDestructed = false

        init(modelID: ModelID) {
            self.modelID = modelID
        }

        deinit {
        }

        var lifetime: ModelLifetime {
            context?.lifetime ?? lock {
                _isDestructed ? .destructed : .initial
            }
        }

        var context: Context<M>? {
            lock { _context }
        }

        var model: M? {
            lock { _model }
        }

        func updateAccess(_ access: ModelAccess?) {
            lock {
                if _model != nil {
                    _model!.modelContext._access = access?.reference
                }
            }
        }

        var isDestructed: Bool {
            lock { _isDestructed }
        }

        func destruct(_ model: M?) {
            lock {
                _isDestructed = true
                _model = model
            }
        }

        func clear() {
            lock {
                _context = nil
                _model = nil
            }
        }

        func setContext(_ context: Context) {
            lock {
                assert(!_isDestructed)
                _context = context
                _model = nil
            }
        }

        subscript (fallback fallback: M) -> M {
            _read {
                lock.lock()
                yield _model?.withAccess(fallback.access) ?? fallback
                lock.unlock()
            }
            _modify {
                lock.lock()
                var model = _model?.withAccess(fallback.access) ?? fallback
                yield &model
                _model = model
                lock.unlock()
            }
        }
    }
}

func _testing_keepLastSeenAround<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await AnyContext.$keepLastSeenAround.withValue(true) {
        try await operation()
    }
}

func _testing_keepLastSeenAround<T>(_ operation: () throws -> T) rethrows -> T {
    try AnyContext.$keepLastSeenAround.withValue(true) {
        try operation()
    }
}

let lastSeenTimeToLive: TimeInterval = 2

/// A lightweight `ModelAccess` subclass used by `Context.touch` to discover the backing storage
/// path(s) that correspond to a user-visible property path.
///
/// When `readModel[keyPath: publicPath]` is called inside `usingActiveAccess(collector)`, the
/// `@_ModelTracked`-generated `_read` accessor invokes `willAccess(model, at: backingPath)` with
/// the *backing* key path (e.g. `\._count`).  `PathCollector` records both the backing path and a
/// type-erased closure that can later call `ModelContext.invokeDidModify` with the correct generic
/// type, bypassing the need to open an existential.
private final class PathCollector<M: Model>: ModelAccess, @unchecked Sendable {
    /// Backing storage paths discovered via `willAccess`.
    var paths: [PartialKeyPath<M>] = []
    /// Type-erased closures; each calls `ModelContext.invokeDidModify(_:at:)` for one path.
    var invokers: [(ModelContext<M>, M) -> Void] = []

    init() { super.init(useWeakReference: false) }

    override func willAccess<N: Model, T>(_ model: N, at path: KeyPath<N, T> & Sendable) -> (() -> Void)? {
        // We only care about accesses on M itself.
        guard let typedPath = path as? KeyPath<M, T> else { return nil }
        paths.append(typedPath)
        // Capture a type-erased invoker. The cast to `& Sendable` is safe here: the call-site
        // guarantees `path` is Sendable (it arrives as `KeyPath<N, T> & Sendable`), and after
        // the `as? KeyPath<M, T>` downcast we still have the same Sendable key path object.
        // We use `unsafeBitCast` to reattach the Sendable marker without a dynamic check.
        let sendablePath = unsafeBitCast(typedPath, to: (KeyPath<M, T> & Sendable).self)
        invokers.append { mc, m in mc.invokeDidModify(m, at: sendablePath) }
        return nil
    }
}

/// Runs `callbacks` and then drains any `threadLocals.postLockFlushes` registered during the run.
///
/// Setting `postLockFlushes` to a non-nil array before execution allows callbacks (such as the
/// `UndoCoalescer`) to defer work until after ALL per-property `onModify` callbacks in the
/// current transaction batch have completed. This guarantees that multi-property transactions
/// are merged into a single undo entry rather than one entry per changed property.
///
/// Re-entrant: if `postLockFlushes` is already non-nil (we're nested inside another
/// `runPostLockCallbacks` call), we simply run `callbacks` without wrapping, allowing the outer
/// invocation to drain the accumulated flushes.
func runPostLockCallbacks(_ callbacks: [() -> Void]?) {
    guard let callbacks else { return }
    guard threadLocals.postLockFlushes == nil else {
        // Nested call — outer invocation will drain flushes after all callbacks complete.
        for plc in callbacks { plc() }
        return
    }
    threadLocals.postLockFlushes = []
    for plc in callbacks { plc() }
    let flushes = threadLocals.postLockFlushes!
    threadLocals.postLockFlushes = nil
    for f in flushes { f() }
}
