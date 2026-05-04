import Foundation
import Dependencies
import OrderedCollections
import IssueReporting
import CustomDump
import Observation

final class Context<M: Model>: AnyContext, @unchecked Sendable {
    private let activations: [(M) -> Void]
    private var modifyCallbacksStore: [PartialKeyPath<M._ModelState>: [Int: (_ finished: Bool, _ force: Bool) -> (() -> Void)?]]?
    var modifyCallbacks: [PartialKeyPath<M._ModelState>: [Int: (_ finished: Bool, _ force: Bool) -> (() -> Void)?]] {
        _read { yield modifyCallbacksStore ?? [:] }
        _modify {
            if modifyCallbacksStore != nil {
                yield &modifyCallbacksStore!
                if modifyCallbacksStore!.isEmpty { modifyCallbacksStore = nil }
            } else {
                var temp: [PartialKeyPath<M._ModelState>: [Int: (_ finished: Bool, _ force: Bool) -> (() -> Void)?]] = [:]
                yield &temp
                if !temp.isEmpty { modifyCallbacksStore = temp }
            }
        }
    }
    let reference: Reference
    /// The generation of `reference` at the time this context called `setContext`.
    /// Used by `deinit` to avoid niling `_stateHolder` when a newer context has
    /// re-anchored the same Reference (e.g. a `static let testValue` model reused
    /// across tests).
    private var referenceGeneration: Int = 0

    // Seed model with correct `let` property values (e.g. LockIsolated counters).
    // Set to localModel after withContextAdded so that var properties are backed by
    // _stateHolder (live source). context.model switches this to .reference source
    // so that reading tracked properties triggers willAccessDirect → observation.
    // Only written once during init; thereafter read-only (under lock for thread safety).
    var _modelSeed: M

    init(model: M, lock: NSRecursiveLock, dependencies: ((inout ModelDependencies) -> Void)?, parent: AnyContext?, isDepContext: Bool = false) {
        // Allow `.initial` (normal first-time anchoring) and `.destructed` (re-anchoring a static
        // dependency model across test runs, or re-anchoring via undo). Block `.active` (already has
        // a live context) and `.frozenCopy` snapshots which must not be anchored.
        if model.context != nil || model.lifetime == .frozenCopy {
            reportIssue("It is not allowed to add an already anchored or frozen model, instead create a new instance.")
        }
        // initialCopy transitions the source to .live without creating a new Reference.
        // All pre-anchor copies of this model share the same Reference (class). After
        // setContext is called below, those copies automatically route to this context
        // via ref._context — no _linkedReference forwarding needed.
        var localModel = model.initialCopy

        let modelSetup = model.modelSetup
        self.activations = modelSetup?.activations ?? []
        // The Reference is the one already in the model (shared by all pre-anchor copies).
        // `initialCopy` may transform `.reference` → `.pending` (for undo restore captures), so
        // use `_anyReference` to cover all source kinds rather than `_liveReference` alone.
        reference = localModel.modelContext._source._anyReference
        _modelSeed = localModel  // Phase-1 placeholder; updated in phase 2 after withContextAdded.
        super.init(lock: lock, parent: parent, isDepContext: isDepContext)

        var dependencyModels: [AnyHashableSendable: ModelDependencies.DepModelEntry] = [:]
        let modelSetupDeps = modelSetup?.dependencies ?? []
        let hasOverrides = dependencies != nil || !modelSetupDeps.isEmpty

        if hasOverrides || parent == nil {
            // Full ceremony: root context, or context with explicit dependency overrides.
            // For child contexts, install parent.capturedDependencies (which includes all parent
            // dep overrides) as _current before applying this context's own overrides. This ensures
            // child contexts inherit the parent's explicit dep overrides, not just the Phase-1
            // initial values that withDependencies(from: parent) would provide.
            // For root contexts (parent == nil), self.capturedDependencies == .init() here, so
            // withOwnDependencies is a no-op and withDependencies starts from the default values.
            (parent ?? self).withOwnDependencies {
                Dependencies.withDependencies {
                    var contextDependencies = ModelDependencies(dependencies: $0)
                    dependencies?(&contextDependencies)
                    for dependency in modelSetupDeps {
                        dependency(&contextDependencies)
                    }

                    $0 = contextDependencies.dependencies
                    dependencyModels = contextDependencies.models
                } operation: {
                    capturedDependencies = DependencyValues._current
                }
            }
        } else {
            // Fast-path: child inherits parent dependencies unchanged. DependencyValues uses
            // COW internally (shared storage + shared CachedValues class), so this is O(1).
            capturedDependencies = parent!.capturedDependencies
        }

        // If this Reference was previously destroyed (re-anchoring a static let testValue),
        // restore state from _genesisState so withContextAdded can traverse children.
        // The full re-anchoring reset (_isDestructed, generation) happens in setContext below.
        reference.prepareForReanchoring()

        // Create pre-`withContextAdded` snapshots for RMW pollution protection.
        // A stored child's dep closure may perform a read-modify-write on an inherited dep
        // (e.g. deps.envProp.state = "childDefault"). Because @_ModelTracked generates
        // nonmutating _modify, the RMW mutates the shared Reference's class state in place
        // without going through ModelDependencies.subscript — so dependencyModels[key].model
        // still points to the same Reference, but its state and _stateVersion have changed.
        // DepModelEntry.capturedVersion records _stateVersion at write time. After
        // withContextAdded, if _stateVersion changed the dep model in dependencyModels is
        // polluted; we use the pre-snapshot clone (correct state, fresh modelID, no cache
        // collision) instead. If version unchanged, we use entry.model directly — this is
        // critical for sharing: sibling children with the same dep model instance share one
        // dep context via _PendingDepKey (same modelID → cache hit).
        var depPreSnapshots: [AnyHashableSendable: any Model] = [:]
        if !dependencyModels.isEmpty {
            func makeClone<D: Model>(_ m: D) -> any Model { m.initialDependencyCopy }
            for (key, entry) in dependencyModels {
                depPreSnapshots[key] = makeClone(entry.model)
            }
        }

        localModel.withContextAdded(context: self)
        // Nil out access on localModel: the incoming model may carry ModelSetupAccess
        // (or another access) in _access. Storing it would create a retain cycle:
        //   Context → localModel → _access → ModelSetupAccess → anchor → Context
        localModel.modelContext.access = nil
        // Store the final seed: correct `let` values + live source (.live → .reference on read).
        _modelSeed = localModel
        assert(reference.hasState || M._ModelState.self == _EmptyModelState.self,
               "Context<\(M.self)>.init: Reference has no state after withContextAdded")
        referenceGeneration = reference.setContext(self)

        // Capture localModel (has correct `let` values) for use during onActivate().
        // Transition to .reference source so node._context is non-nil inside onActivate().
        // Access is set at call time (mirrors the original `model` computed property).
        // Cleared after first call so the model doesn't outlive activation.
        let capturedActivations = activations
        let capturedReference = reference
        pendingActivation = { [localModel, capturedActivations, capturedReference] in
            var m = localModel
            m.modelContext.setReference(capturedReference)
            m.modelContext.access = ModelAccess.active ?? ModelAccess.current
            AnyCancellable.$contexts.withValue(AnyCancellable.contexts + [CancellableKey(key: ContextCancellationKey.onActivate)]) {
                m.onActivate()
            }
            for activation in capturedActivations {
                activation(m)
            }
        }

        // Use withOwnDependencies so that setupModelDependency's Context<D>.init sees
        // self.capturedDependencies as _current, not the caller's task-local. Without this,
        // a background task from an ancestor context would contaminate the model-dep context
        // with the ancestor's DependencyValues via the withDependencies(from: parent) merge.
        if !dependencyModels.isEmpty {
            withOwnDependencies {
                withPostActions { postActions in
                    for (key, entry) in dependencyModels {
                        // If a stored child's RMW mutated this dep's Reference (bypassing
                        // ModelDependencies.subscript), _stateVersion will have changed. In
                        // that case use the pre-snapshot clone — correct state, fresh modelID,
                        // avoids _PendingDepKey cache collision with the child's dep context.
                        // If version unchanged, use entry.model directly so its modelID is
                        // preserved for sharing (sibling children with the same dep instance
                        // share one dep context via _PendingDepKey cache hit).
                        func currentVer<D: Model>(_ m: D) -> Int { m.modelContext._source.reference._stateVersion }
                        let versionChanged = currentVer(entry.model) != entry.capturedVersion
                        var model: any Model = versionChanged ? depPreSnapshots[key]! : entry.model
                        // For dep contexts: if an ancestor already has an explicit dep context for
                        // this type (set by the ancestor's dep loop which ran before ours), skip
                        // creating a competing local one. nearestDependencyContext will find it.
                        if isDepContext,
                           nearestDependencyContext(for: ObjectIdentifier(type(of: model))) != nil {
                            continue
                        }
                        setupModelDependency(&model, cacheKey: nil, postSetups: &postActions)
                        if versionChanged {
                            // capturedDependencies still has the RMW-polluted original Reference;
                            // update it to point to the clone's live Reference.
                            entry.restoreInto(&capturedDependencies, model)
                        }
                        if !isDepContext {
                            dependencyCache[key] = model
                        }
                    }
                }
            }
        }
    }

    deinit {
        // Nil _stateHolder to break potential retain cycles: closures in _State
        // can capture .reference models that hold this Reference, which holds
        // _stateHolder strongly. The generation guard prevents niling state that
        // a newer Context already claimed (re-anchored static dependency models).
        reference.clearStateForGeneration(referenceGeneration)
    }

    override func onActivate() -> Bool {
        let shouldActivate = super.onActivate()

        if shouldActivate {
            pendingActivation?()
        }
        pendingActivation = nil

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

        let keepLastSeen = !isTesting || AnyContext.keepLastSeenAround
        reference.destruct()

        guard keepLastSeen else {
            // No last-seen needed: zero state to break retain cycles, but defer until after the
            // callbacks array has run so that onCancel closures can still read model state.
            let ref = reference
            callbacks.append { ref.clear() }
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000*UInt64(lastSeenTimeToLive*1000))
            reference.clear()
        }
    }

    func sendEvent(_ event: Any, model: any Model, to relation: ModelRelation, context: AnyContext) {
        let eventInfo = EventInfo(event: event, model: model, context: context)
        sendEvent(eventInfo, to: relation)
    }

    // MARK: - Parents observation

    // The key path used to represent the parents relationship in the observation system.
    // Using a subscript on _ModelState guarantees no collision with user-defined properties on M.
    private var parentsObservationPath: KeyPath<M._ModelState, [ModelID]>&Sendable { \M._ModelState[_parentsObservationKey: _ParentsObservationKey()] }

    // A ModelContext wrapping this context, used to delegate to the shared
    // willAccess/didModify helpers which handle all observation paths uniformly.
    private var modelContext: ModelContext<M> { ModelContext(context: self) }

    override func willAccessParents() {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            willAccessSyntheticPath(\_StateObserver<M._ModelState>[_parentsObservationKey: _ParentsObservationKey(), modelID: reference.modelID])
        }
        modelContext.willAccess(at: parentsObservationPath)?()
    }

    override func willModifyParents() {
        // willSet is called as part of the didModify closure returned by ModelContext.didModify.
        // Nothing needed here — the modify closure captures willSet/didSet together.
    }

    override func didModifyParents(callbacks: inout [() -> Void]) {
        let path = parentsObservationPath
        didModify()
        let mc = modelContext
        let modifyCallbacksForPath = modifyCallbacks[path]?.values.compactMap { $0(false, false) } ?? []
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            invokeDidModifySyntheticPath(\_StateObserver<M._ModelState>[_parentsObservationKey: _ParentsObservationKey(), modelID: reference.modelID])
        }
        callbacks.append {
            mc.invokeDidModify(at: path)?()
            for c in modifyCallbacksForPath { c() }
        }
        var didModifyCallbacks: [() -> Void] = []
        didModify(callbacks: &didModifyCallbacks, kind: .parentRelationship, depth: 0, origin: self)
        callbacks.append(contentsOf: didModifyCallbacks)
    }

    override func willAccessStorage<V>(_ storage: ContextStorage<V>) {
        // Skip all observation when applying Access closures to snapshot copies inside the
        // isEqualIncludingIds lock. Keypath creation via _swift_getKeyPath can deadlock
        // when the Swift runtime lock is held on another thread.
        guard !threadLocals.isApplyingSnapshot else { return }

        // Untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
        // Registrar call uses _StateObserver (no Model Observable conformance needed).
        let untypedPath: KeyPath<M._ModelState, AnyHashableSendable>&Sendable = \M._ModelState[environmentKey: storage.key]
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            willAccessSyntheticPath(\_StateObserver<M._ModelState>[environmentKey: storage.key, modelID: reference.modelID])
        }
        modelContext.willAccess(at: untypedPath)?()

        // Typed writable path on M._ModelState — drives TestAccess snapshot tracking so that
        // `model.node.local.myKey`/`model.node.environment.myKey` inside expect {} is fully assertable.
        // \M._ModelState[_metadata: storage] is a WritableKeyPath because ContextStorage<V>
        // is Hashable (via its key), giving Swift what it needs to form and distinguish paths.
        // Tag the access as `.metadata` so TestAccess records it under the correct exhaustivity area.
        //
        // The getter on _ModelStateType._metadata stubs have fatalError — TestAccess reads the value
        // via the precomputedStorageValue thread-local instead of calling the getter.
        // The re-entry guard (isAccessingMetadataStorage) is no longer needed since calling the getter
        // is no longer possible from TestAccess, but we keep it for clarity of intent.
        guard !threadLocals.isAccessingMetadataStorage else { return }
        let typedPath: WritableKeyPath<M._ModelState, V>&Sendable = \M._ModelState[_metadata: storage]
        let mc = metadataModelContext()
        let storageArea: _ExhaustivityBits = storage.propagation == .environment ? .environment : .local
        // Pre-compute storage value for TestAccess (the _ModelState getter stubs have fatalError).
        let storageValue: V = lock { (contextStorage[storage.key]?.value as? V) ?? storage.defaultValue }
        let closureOpt = threadLocals.withValue(storageArea, at: \.modificationArea) {
            threadLocals.withValue(storage.name, at: \.storageName) {
                mc.activeAccess?.willAccess(from: self, at: typedPath)
            }
        }
        if let closure = closureOpt {
            threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                threadLocals.withValue(storageValue as Any, at: \.precomputedStorageValue) {
                    closure()
                }
            }
        }
    }

    override func didModifyStorage<V>(_ storage: ContextStorage<V>) {
        // Batch all ObservationRegistrar willSet/didSet notifications so that the two
        // invokeDidModify calls below (untyped + typed paths) fire only one drain at the end
        // instead of one per call.
        _withBatchedUpdates {
            // Untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
            // Registrar call uses _StateObserver (no Model Observable conformance needed).
            let untypedPath: KeyPath<M._ModelState, AnyHashableSendable>&Sendable = \M._ModelState[environmentKey: storage.key]
            // Typed writable path on M._ModelState — drives TestAccess didModify so writes are tracked.
            // Tag the modification as `.metadata` so TestAccess records it under the correct area.
            let typedPath: WritableKeyPath<M._ModelState, V>&Sendable = \M._ModelState[_metadata: storage]
            let mc = metadataModelContext()

            lock { self.didModify() }
            if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                invokeDidModifySyntheticPath(\_StateObserver<M._ModelState>[environmentKey: storage.key, modelID: reference.modelID])
            }
            modelContext.invokeDidModify(at: untypedPath)?()
            // Pre-compute new value for both TestAccess.didModify and DebugAccessCollector
            // post-lock callbacks (the _metadata stub getter calls fatalError()).
            let newValue: V = lock { (contextStorage[storage.key]?.value as? V) ?? storage.defaultValue }
            if !threadLocals.isAccessingMetadataStorage {
                let storageArea: _ExhaustivityBits = storage.propagation == .environment ? .environment : .local
                threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                    threadLocals.withValue(storageArea, at: \.modificationArea) {
                        threadLocals.withValue(storage.name, at: \.storageName) {
                            threadLocals.withValue(newValue as Any, at: \.precomputedStorageValue) {
                                mc.activeAccess?.didModify(from: self, at: typedPath)?()
                            }
                        }
                    }
                }
            }
            // Use the typed path for post-lock callbacks so modifyCallbacks keyed on it fire correctly.
            // Set precomputedStorageValue while building (not just running) post-lock callbacks:
            // DebugAccessCollector's onModify callback runs during buildPostLockCallbacks
            // (inside the context lock) and reads precomputedStorageValue to get the new value
            // without calling the fatalError() getter stub.
            #if DEBUG
            let storagePropArea = storage.propagation == .environment ? "environment" : "local"
            let storagePropName = storage.name
            let envPropDesc: (@Sendable () -> String?)? = { "\(storagePropArea).\(storagePropName)" }
            let postLockCallbacks = threadLocals.withValue(newValue as Any, at: \.precomputedStorageValue) {
                lock { buildPostLockCallbacks(for: typedPath, kind: .environment, propertyDescription: envPropDesc) }
            }
            #else
            let postLockCallbacks = threadLocals.withValue(newValue as Any, at: \.precomputedStorageValue) {
                lock { buildPostLockCallbacks(for: typedPath, kind: .environment) }
            }
            #endif
            runPostLockCallbacks(postLockCallbacks)
        }
    }

    override func willAccessPreference<V>(_ storage: PreferenceStorage<V>) {
        // Skip all observation when applying Access closures to snapshot copies inside the
        // isEqualIncludingIds lock. Keypath creation via _swift_getKeyPath can deadlock
        // when the Swift runtime lock is held on another thread.
        guard !threadLocals.isApplyingSnapshot else { return }

        // Untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
        // Registrar call uses _StateObserver (no Model Observable conformance needed).
        let untypedPath: KeyPath<M._ModelState, AnyHashableSendable>&Sendable = \M._ModelState[preferenceKey: storage.key]
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            willAccessSyntheticPath(\_StateObserver<M._ModelState>[preferenceKey: storage.key, modelID: reference.modelID])
        }
        modelContext.willAccess(at: untypedPath)?()

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

        // Typed writable path on M._ModelState — drives TestAccess snapshot tracking.
        // Called after preferenceValue has finished aggregating, with the computed value
        // already in hand. This avoids re-entering preferenceValue (which acquires child
        // locks) while the caller's context lock may still be held.
        guard !threadLocals.isAccessingMetadataStorage else { return }
        let typedPath: WritableKeyPath<M._ModelState, V>&Sendable = \M._ModelState[_preference: storage]
        let mc = metadataModelContext()
        let closureOpt = threadLocals.withValue(.preference, at: \.modificationArea) {
            threadLocals.withValue(storage.name, at: \.storageName) {
                mc.activeAccess?.willAccess(from: self, at: typedPath)
            }
        }
        if let closure = closureOpt {
            // Store the pre-computed aggregated value so the TestAccess willAccess closure
            // can use it instead of re-reading via context[path] (which would
            // re-enter preferenceValue under a lock and deadlock).
            threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                threadLocals.withValue(value as Any, at: \.precomputedPreferenceValue) {
                    closure()
                }
            }
        }
    }

    override func didModifyPreference<V>(_ storage: PreferenceStorage<V>) {
        // Batch all registrar notifications across this context's two invokeDidModify calls
        // AND the entire parent-chain walk (notifyPreferenceChange), so there is one drain
        // at the end rather than one per context level.
        _withBatchedUpdates {
            // Untyped path — drives Observed {} / SwiftUI / AccessCollector observation.
            // Registrar call uses _StateObserver (no Model Observable conformance needed).
            let untypedPath: KeyPath<M._ModelState, AnyHashableSendable>&Sendable = \M._ModelState[preferenceKey: storage.key]
            // Typed writable path on M._ModelState — drives TestAccess didModify so writes are tracked.
            let typedPath: WritableKeyPath<M._ModelState, V>&Sendable = \M._ModelState[_preference: storage]
            let mc = metadataModelContext()

            lock { self.didModify() }
            if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
                invokeDidModifySyntheticPath(\_StateObserver<M._ModelState>[preferenceKey: storage.key, modelID: reference.modelID])
            }
            modelContext.invokeDidModify(at: untypedPath)?()
            // Pre-compute new value for both TestAccess.didModify and DebugAccessCollector
            // post-lock callbacks (the _preference stub getter calls fatalError()).
            let newValue: V = lock { preferenceStorage[storage.key]?.value as? V ?? storage.defaultValue }
            if !threadLocals.isAccessingMetadataStorage {
                threadLocals.withValue(true, at: \.isAccessingMetadataStorage) {
                    threadLocals.withValue(.preference, at: \.modificationArea) {
                        threadLocals.withValue(storage.name, at: \.storageName) {
                            threadLocals.withValue(newValue as Any, at: \.precomputedPreferenceValue) {
                                mc.activeAccess?.didModify(from: self, at: typedPath)?()
                            }
                        }
                    }
                }
            }
            // Post-lock callbacks for this context.
            // Set precomputedPreferenceValue while building (not just running) post-lock callbacks:
            // DebugAccessCollector's onModify callback runs during buildPostLockCallbacks
            // (inside the context lock) and reads precomputedPreferenceValue to get the new value
            // without calling the fatalError() getter stub.
            #if DEBUG
            let prefName = storage.name
            let prefPropDesc: (@Sendable () -> String?)? = { "preference.\(prefName)" }
            let postLockCallbacks = threadLocals.withValue(newValue as Any, at: \.precomputedPreferenceValue) {
                lock { buildPostLockCallbacks(for: typedPath, kind: .preferences, propertyDescription: prefPropDesc) }
            }
            #else
            let postLockCallbacks = threadLocals.withValue(newValue as Any, at: \.precomputedPreferenceValue) {
                lock { buildPostLockCallbacks(for: typedPath, kind: .preferences) }
            }
            #endif
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
    }

    /// Fires only the untyped observation path upward through the hierarchy.
    ///
    /// Used by upward preference propagation to invalidate ancestor observers (Observed {}, SwiftUI)
    /// without creating TestAccess ValueUpdate entries. The typed `_preference` path is intentionally
    /// omitted — ancestors that never wrote a contribution should not appear in exhaustion reports.
    override func notifyPreferenceChange<V>(_ storage: PreferenceStorage<V>) {
        let untypedPath: KeyPath<M._ModelState, AnyHashableSendable>&Sendable = \M._ModelState[preferenceKey: storage.key]
        lock { self.didModify() }
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            invokeDidModifySyntheticPath(\_StateObserver<M._ModelState>[preferenceKey: storage.key, modelID: reference.modelID])
        }
        modelContext.invokeDidModify(at: untypedPath)?()
        let typedPath: WritableKeyPath<M._ModelState, V>&Sendable = \M._ModelState[_preference: storage]
        #if DEBUG
        let prefName = storage.name
        let prefPropDesc: (@Sendable () -> String?)? = { "preference.\(prefName)" }
        let postLockCallbacks = lock { buildPostLockCallbacks(for: typedPath, kind: .preferences, propertyDescription: prefPropDesc) }
        #else
        let postLockCallbacks = lock { buildPostLockCallbacks(for: typedPath, kind: .preferences) }
        #endif
        runPostLockCallbacks(postLockCallbacks)

        let parents = lock(self.parents)
        for parent in parents {
            parent.notifyPreferenceChange(storage)
        }
    }

    /// Returns a ModelContext for use in context storage willAccess/didModify notifications.
    ///
    /// Access is derived from task-locals (`ModelAccess.active` or `ModelAccess.current`),
    /// which are set by callers that need TestAccess tracking (predicate evaluation,
    /// task execution, and direct model method calls via LocalValues/EnvironmentContext/
    /// PreferenceValues wrapping their subscripts in `usingActiveAccess`).
    private func metadataModelContext() -> ModelContext<M> {
        var mc = ModelContext(context: self)
        mc.access = ModelAccess.active ?? ModelAccess.current
        return mc
    }

    func onModify<T>(for path: KeyPath<M._ModelState, T>&Sendable, _ callback: @Sendable @escaping (_ finished: Bool, _ force: Bool) -> (() -> Void)?) -> @Sendable () -> Void {
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

    override var typeDescription: String { String(describing: M.self) }

    override var selfPath: AnyKeyPath { \M.self }

    var model: M {
        // Start from _modelSeed (has correct `let` values, e.g. LockIsolated counters),
        // then switch to .reference source so that reading tracked properties triggers
        // willAccessDirect → observation registration (required for Observed/mapHierarchy).
        // No lock needed: _modelSeed is written once during init (before the object is
        // reachable from other threads) and never modified afterward.
        var m = _modelSeed
        m.modelContext.setReference(reference)
        m.modelContext.access = ModelAccess.active ?? ModelAccess.current
        return m
    }

    override var anyModelID: ModelID {
        reference.modelID
    }

    override var anyModel: any Model {
        model
    }

    override func mapModel<T>(access: ModelAccess?, _ body: (any Model) throws -> T?) rethrows -> T? {
        try body(model.withAccessIfPropagateToChildren(access))
    }

    func updateContext<T: Model>(for model: inout T, at path: WritableKeyPath<M, T>){
        guard !isDestructed else { return }
        
        model.withContextAdded(context: self, containerPath: \M.self, elementPath: path, includeSelf: true)
    }

    private var modelRefs: Set<ModelRef> = []

    /// Updates contexts for the elements of a `ModelContainer` property.
    ///
    /// **Must be called with the hierarchy lock held.** This method is always invoked from within
    /// `stateTransaction.modify`, which acquires the lock before calling the closure. The `lock { }`
    /// wrapper is intentionally absent to avoid a redundant re-entrant lock acquisition. Calling
    /// this method without holding the lock is a data race and must never happen.
    ///
    /// The `hierarchyLockHeld: true` flag passed to `withContextAdded` further eliminates O(N)
    /// per-element lock re-entries for the existing-elements fast path in `AnchorVisitor`.
    func updateContext<C: ModelContainer>(for container: inout C, at path: WritableKeyPath<M, C>) -> [AnyContext] {
        guard !isDestructed else { return [] }

        // Called from stateTransaction.modify — lock already held. No lock { } wrapper needed.
        let prevChildren = (children[path] ?? [:])
        let prevRefs = Set(prevChildren.keys)

        modelRefs.removeAll(keepingCapacity: true)
        // hierarchyLockHeld: true lets AnchorVisitor skip N redundant recursive lock re-entries
        // for existing elements, using the inlined findOrTrackChildLocked fast path instead.
        container.withContextAdded(context: self, containerPath: path, elementPath: \.self, includeSelf: false, hierarchyLockHeld: true)

        let oldRefs = prevRefs.subtracting(modelRefs)
        return oldRefs.map { prevChildren[$0]! }
    }

    /// Model-keypath transaction for undo restore of Model/ModelContainer-typed properties.
    /// The M-level `path` is used for value read/write (via `_modelSeed` live source, which
    /// routes Model/Container writes through `stateTransaction`). The `statePath` is used for
    /// explicit notifications for scalar writes that bypass `stateTransaction`.
    func transaction<Value, T>(at path: WritableKeyPath<M, Value>&Sendable, statePath: WritableKeyPath<M._ModelState, Value>&Sendable, isSame: ((Value, Value) -> Bool)?, modelContext: ModelContext<M>, modify: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        let result: T
        do {
            // Use _modelSeed directly (.live source) instead of model (.reference source).
            // .live source routes reads/writes directly to the state storage without going
            // through willAccessDirect/invokeDidModify — avoiding double-processing since
            // this function manually issues all post-write notifications below.
            var localModel = _modelSeed
            let oldValue = localModel[keyPath: path]
            result = try modify(&localModel[keyPath: path])

            if let isSame, isSame(localModel[keyPath: path], oldValue) {
                lock.unlock()
                return result
            }

            didModify()

            let activeAccessCallback = modelContext.invokeDidModify(at: statePath)

#if DEBUG
            let postLockCallbacks = buildPostLockCallbacksWithPropDesc(for: statePath)
#else
            let postLockCallbacks = buildPostLockCallbacks(for: statePath)
#endif
            lock.unlock()

            activeAccessCallback?()
            runPostLockCallbacks(postLockCallbacks)
        }
        return result
    }

    // MARK: - State-path subscripts (direct _State access)

    /// Reads a property directly from Reference._state, bypassing readModel indirection.
    /// The `observeCallback` is the result of `activeAccess.willAccess(from:at:)`.
    subscript<T>(statePath statePath: WritableKeyPath<M._ModelState, T>, observeCallback callback: (() -> Void)?) -> T {
        _read {
            lock.lock()
            if unprotectedIsDestructed {
                threadLocals.transitionOverrideValue = nil
                if reference._stateCleared {
                    // clear() now stores genesis into state (or leaves state valid when !_hasGenesis),
                    // so reference.state is always safe to read here. Report an issue only when
                    // there is no genesis — that means the model was destructed without ever being
                    // anchored, which is a bug in the caller (e.g. a background performUpdate).
                    if !reference._hasGenesis {
                        reportIssue("Reading from a fully destructed model with no last-seen snapshot.")
                    }
                    yield reference.state[keyPath: statePath]
                } else {
                    yield reference.state[keyPath: statePath]
                }
            } else if threadLocals.transitionOverrideValue != nil, let override = threadLocals.transitionOverrideValue as? T {
                yield override
            } else {
                yield reference.state[keyPath: statePath]
            }
            callback?()
            lock.unlock()
        }
    }

    // MARK: - Synthetic path observation helpers (for storage/preference/parents)

    /// Registers access with the ObservationRegistrar for a synthetic `_StateObserver` keypath.
    /// Used by `willAccessStorage`, `willAccessPreference`, and `willAccessParents` to drive
    /// SwiftUI / Observed {} observation without needing Model to conform to Observable.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func willAccessSyntheticPath<T>(_ kp: KeyPath<_StateObserver<M._ModelState>, T>) {
        guard useObservationRegistrar,
              !(threadLocals.isInsideAsyncPerformUpdate && ModelAccess.active != nil) else { return }
        let observer = _StateObserver<M._ModelState>()
        if isOnMainThread {
            mainObservationRegistrarMakingIfNeeded.access(observer, keyPath: kp)
        } else {
            backgroundObservationRegistrarMakingIfNeeded.access(observer, keyPath: kp)
        }
    }

    /// Fires ObservationRegistrar willSet/didSet for a synthetic `_StateObserver` keypath.
    /// Supports batching via `pendingObservationNotifications`. Does NOT handle activeAccess
    /// callbacks — callers handle those separately via `modelContext.invokeDidModify(at:)`.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func invokeDidModifySyntheticPath<T>(_ kp: KeyPath<_StateObserver<M._ModelState>, T> & Sendable) {
        guard useObservationRegistrar else { return }
        let observer = _StateObserver<M._ModelState>()
        let observerKP = kp
        if threadLocals.pendingObservationNotifications != nil {
            threadLocals.pendingObservationNotifications!.append {
                if isOnMainThread {
                    self.mainObservationRegistrar?.willSet(observer, keyPath: observerKP)
                    self.backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                    self.mainObservationRegistrar?.didSet(observer, keyPath: observerKP)
                    self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                } else {
                    self.backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                    self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                    if let mainReg = self.mainObservationRegistrar {
                        self.mainCallQueue {
                            mainReg.willSet(observer, keyPath: observerKP)
                            mainReg.didSet(observer, keyPath: observerKP)
                        }
                    }
                }
            }
        } else {
            if isOnMainThread {
                mainObservationRegistrar?.willSet(observer, keyPath: observerKP)
                backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                mainObservationRegistrar?.didSet(observer, keyPath: observerKP)
                backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
            } else {
                backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                if let mainReg = self.mainObservationRegistrar {
                    self.mainCallQueue {
                        mainReg.willSet(observer, keyPath: observerKP)
                        mainReg.didSet(observer, keyPath: observerKP)
                    }
                }
            }
        }
    }

    // MARK: - Direct access helpers (for _ModelSourceBox subscripts)

    /// Computes the willAccess observation callback without constructing a ModelContext.
    /// Called from `_ModelSourceBox` read subscripts.
    ///
    /// Uses `_StateObserver` for registrar calls (no Model instance needed).
    /// Uses `_StateObserver` for registrar calls; delegates to `activeAccess.willAccess/didModify(from:at:)` for TestAccess.
    func willAccessDirect<T>(statePath: WritableKeyPath<M._ModelState, T>, accessBox: _ModelAccessBox) -> (() -> Void)? {
        let cachedActive = ModelAccess.active
        let access = accessBox._reference?.access ?? ModelAccess.current
        let activeAccess = cachedActive ?? access

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), useObservationRegistrar,
           !(threadLocals.isInsideAsyncPerformUpdate && cachedActive != nil) {
            let observer = _StateObserver<M._ModelState>()
            // Cache the KP to avoid a heap allocation on every read.
            // `_swift_getKeyPath` for a subscript KP allocates (~1.7 μs);
            // caching by (contextID, propID) gives O(1) warm-path reads at ~15-20 ns.
            // Use hashValue (structural key path equality) instead of ObjectIdentifier
            // (pointer identity) so that dynamically-constructed key paths — which Swift
            // produces via appending and are never the same object across sites — still
            // yield the same propID and therefore the same cached observerKP.
            let contextID = UInt(bitPattern: ObjectIdentifier(self))
            let propID = UInt(bitPattern: (statePath as PartialKeyPath<M._ModelState>).hashValue)
            let observerKP: KeyPath<_StateObserver<M._ModelState>, AnyHashable> = _cachedStateObserverKP(contextID: contextID, propID: propID) {
                \_StateObserver<M._ModelState>[contextID: contextID, propID: propID]
            }
            if isOnMainThread {
                mainObservationRegistrarMakingIfNeeded.access(observer, keyPath: observerKP)
            } else {
                backgroundObservationRegistrarMakingIfNeeded.access(observer, keyPath: observerKP)
            }
        }

        guard let activeAccess else { return nil }
        let sendableStatePath = unsafeBitCast(statePath, to: (WritableKeyPath<M._ModelState, T> & Sendable).self)
        return activeAccess.willAccess(from: self, at: sendableStatePath)
    }

    /// Invokes post-modify observation notifications without constructing a ModelContext.
    /// Returns the active-access callback for the caller to execute after releasing the lock.
    ///
    /// Uses `_StateObserver` for registrar calls (no Model instance needed).
    /// Uses `_StateObserver` for registrar calls; delegates to `activeAccess.willAccess/didModify(from:at:)` for TestAccess.
    @discardableResult
    func invokeDidModifyDirect<T>(statePath: WritableKeyPath<M._ModelState, T>, accessBox: _ModelAccessBox) -> (() -> Void)? {
        let access = accessBox._reference?.access ?? ModelAccess.current
        let activeAccess = ModelAccess.active ?? access

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), useObservationRegistrar {
            let observer = _StateObserver<M._ModelState>()
            // Use cached KP to avoid per-write _swift_getKeyPath allocation (same rationale as willAccessDirect).
            let contextID = UInt(bitPattern: ObjectIdentifier(self))
            let propID = UInt(bitPattern: (statePath as PartialKeyPath<M._ModelState>).hashValue)
            nonisolated(unsafe) let observerKP: KeyPath<_StateObserver<M._ModelState>, AnyHashable> = _cachedStateObserverKP(contextID: contextID, propID: propID) {
                \_StateObserver<M._ModelState>[contextID: contextID, propID: propID]
            }
            let sendableStatePath: (WritableKeyPath<M._ModelState, T> & Sendable)? = activeAccess != nil ? unsafeBitCast(statePath, to: (WritableKeyPath<M._ModelState, T> & Sendable).self) : nil
            if threadLocals.pendingObservationNotifications != nil {
                // Batched: defer registrar notifications, collect activeAccess callback immediately.
                let callback = sendableStatePath.flatMap { [self] path in activeAccess?.didModify(from: self, at: path) }
                threadLocals.pendingObservationNotifications!.append {
                    // willSet
                    if isOnMainThread {
                        self.mainObservationRegistrar?.willSet(observer, keyPath: observerKP)
                        self.backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                    } else {
                        self.backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                    }
                    // didSet
                    if isOnMainThread {
                        self.mainObservationRegistrar?.didSet(observer, keyPath: observerKP)
                        self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                    } else {
                        self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                        if let mainReg = self.mainObservationRegistrar {
                            self.mainCallQueue {
                                mainReg.willSet(observer, keyPath: observerKP)
                                mainReg.didSet(observer, keyPath: observerKP)
                            }
                        }
                    }
                }
                return callback
            } else {
                // Not batched: willSet → activeAccess callback → didSet (via defer).
                // willSet
                if isOnMainThread {
                    mainObservationRegistrar?.willSet(observer, keyPath: observerKP)
                    backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                } else {
                    backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
                }
                defer {
                    // didSet
                    if isOnMainThread {
                        self.mainObservationRegistrar?.didSet(observer, keyPath: observerKP)
                        self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                    } else {
                        self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
                        if let mainReg = self.mainObservationRegistrar {
                            self.mainCallQueue {
                                mainReg.willSet(observer, keyPath: observerKP)
                                mainReg.didSet(observer, keyPath: observerKP)
                            }
                        }
                    }
                }
                let callback = sendableStatePath.flatMap { [self] path in activeAccess?.didModify(from: self, at: path) }
                mainCallQueue.drainIfOnMain()
                return callback
            }
        } else {
            let sendableStatePath2: (WritableKeyPath<M._ModelState, T> & Sendable)? = activeAccess != nil ? unsafeBitCast(statePath, to: (WritableKeyPath<M._ModelState, T> & Sendable).self) : nil
            let callback = sendableStatePath2.flatMap { [self] path in activeAccess?.didModify(from: self, at: path) }
            if threadLocals.pendingObservationNotifications == nil {
                mainCallQueue.drainIfOnMain()
            }
            return callback
        }
    }

    /// Modifies a property directly on Reference._state using access box for observation.
    subscript<T>(statePath statePath: WritableKeyPath<M._ModelState, T>, isSame isSame: ((T, T) -> Bool)?, accessBox accessBox: _ModelAccessBox) -> T {
        _read { fatalError() }
        _modify {
            lock.lock()
            if unprotectedIsDestructed {
                if reference._stateCleared {
                    if !reference._hasGenesis {
                        reportIssue("Modifying a fully destructed model with no last-seen snapshot.")
                    }
                    var value: T = reference.state[keyPath: statePath]
                    yield &value
                } else {
                    yield &reference.state[keyPath: statePath]
                }
                lock.unlock()
            } else {
                let oldValue = reference.state[keyPath: statePath]
                // Pin old value alive past the yield so its deinit cannot fire while
                // reference.state is exclusively held, preventing Swift exclusivity violations.
                defer { _fixLifetime(oldValue) }
                yield &reference.state[keyPath: statePath]

                if let isSame, isSame(reference.state[keyPath: statePath], oldValue) {
                    return lock.unlock()
                }

                self.didModify()
                let activeAccessCallback = invokeDidModifyDirect(statePath: statePath, accessBox: accessBox)
#if DEBUG
                let postLockCallbacks = buildPostLockCallbacksWithPropDesc(for: statePath)
#else
                let postLockCallbacks = buildPostLockCallbacks(for: statePath)
#endif
                lock.unlock()

                activeAccessCallback?()
                runPostLockCallbacks(postLockCallbacks)
            }
        }
    }

    /// Transaction-based modification using state paths and access box.
    func stateTransaction<Value, T>(at statePath: WritableKeyPath<M._ModelState, Value>, isSame: ((Value, Value) -> Bool)?, accessBox: _ModelAccessBox, modify: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        let result: T
        if unprotectedIsDestructed {
            var value: Value
            if reference._stateCleared {
                if !reference._hasGenesis {
                    reportIssue("Modifying a fully destructed model with no last-seen snapshot.")
                }
                value = reference.state[keyPath: statePath]
            } else {
                value = reference.state[keyPath: statePath]
            }
            result = try modify(&value)
            lock.unlock()
        } else {
            let oldValue = reference.state[keyPath: statePath]
            var value = oldValue
            result = try modify(&value)
            reference.state[keyPath: statePath] = value

            if let isSame, isSame(value, oldValue) {
                lock.unlock()
                return result
            }

            didModify()
            let activeAccessCallback = invokeDidModifyDirect(statePath: statePath, accessBox: accessBox)
#if DEBUG
            let postLockCallbacks = buildPostLockCallbacksWithPropDesc(for: statePath)
#else
            let postLockCallbacks = buildPostLockCallbacks(for: statePath)
#endif
            lock.unlock()
            activeAccessCallback?()
            runPostLockCallbacks(postLockCallbacks)
        }
        return result
    }

#if DEBUG
    /// Builds post-lock callbacks for a regular property write, including a property-name
    /// description for `observeModifications(debug:)` trigger output.
    ///
    /// Resolves the property name eagerly inside the lock via Mirror + property name cache.
    /// Safe: _modelSeed uses .live source (no observation side-effects during Mirror traversal),
    /// and the propertyName cache lock ordering (context lock → cache lock) is consistent here.
    private func buildPostLockCallbacksWithPropDesc<T>(for statePath: WritableKeyPath<M._ModelState, T>) -> [() -> Void]? {
        let name: String? = usingActiveAccess(nil) {
            propertyName(from: _modelSeed, path: M._modelStateKeyPath.appending(path: statePath))
        }
        let desc: (@Sendable () -> String?)?
        if let name {
            desc = { name }
        } else {
            desc = nil
        }
        return buildPostLockCallbacks(for: statePath, propertyDescription: desc)
    }
#endif

    /// Builds the post-lock callbacks array for a property modification.
    /// Returns nil when there is nothing to do, avoiding the array allocation entirely.
    /// Must be called while the context lock is held.
    private func buildPostLockCallbacks(for path: PartialKeyPath<M._ModelState>, kind: ModificationKind = .properties, propertyDescription: (@Sendable () -> String?)? = nil) -> [() -> Void]? {
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
            // For .properties changes, respect per-property exclusions registered via
            // excludeFromModifications(). Other kinds (environment, preferences, etc.) are
            // always forwarded — they use synthetic paths not registered as exclusions.
            if kind != .properties || self.modificationExcludedPaths?.contains(path) != true {
                self.didModify(callbacks: &postCallbacks, kind: kind, depth: 0, origin: self, propertyDescription: propertyDescription)
            }
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
        // model has .reference source, so reading via keyPath triggers willAccessDirect → PathCollector.willAccess.
        let touchTarget = model
        usingActiveAccess(collector) {
            _ = touchTarget[keyPath: path]
        }
        let backingPaths = collector.paths

        lock {
            guard !unprotectedIsDestructed else { return }
            self.didModify()
        }
        // Notify @Observable / TestAccess for each discovered backing path using the
        // type-erased invokers collected by PathCollector.
        for invoker in collector.invokers {
            invoker(modelContext)
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
                    if self.modificationExcludedPaths?.contains(backingPath) != true {
                        self.didModify(callbacks: &postCallbacks, kind: .properties, depth: 0, origin: self)
                    }
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
        if reference.isDestructed {
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

            // Assign a new unique ID to this transaction so TestAccess can coalesce
            // multiple writes to the same path into a single valueUpdates entry.
            threadLocals.currentTransactionID &+= 1
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

    /// Defers context creation for a child: stores a factory on its Reference and skips
    /// the `Context.init` + lock work until the child is first accessed.
    ///
    /// NOTE: We intentionally do NOT insert into `modelRefs` here. `modelRefs` is cleared
    /// and re-populated on every `updateContext` call, so an upfront insert would be
    /// discarded immediately. Removal detection only concerns children that have a live
    /// context (tracked in `children` dict); lazy children with no context have nothing
    /// to tear down and are simply not re-registered if they disappear from the array.
    func registerLazyChild<C: ModelContainer, Child: Model>(containerPath: WritableKeyPath<M, C>, elementPath: WritableKeyPath<C, Child>, childModel: Child) {
        // Weak self to avoid a retain cycle: the factory closure is stored on the child's
        // Reference which may outlive this parent context.
        childModel.modelContext._source.reference.setLazyContextCreator { [weak self] in
            // Re-entrance guard: context may have been created by a concurrent materialize call.
            if let existing = childModel.modelContext._source.reference.context { return existing }
            // Parent context is gone; cannot create child context.
            guard let self else { return nil }
            return self.childContext(containerPath: containerPath, elementPath: elementPath, childModel: childModel)
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

            if let child = childModel.modelContext.context {
                child.addParent(self, callbacks: &postLockCallbacks)
                children[containerPath, default: [:]][modelRef] = child
                // Only update myModelRef for same-hierarchy children (child.lock === self.lock).
                // Cross-hierarchy children (e.g. re-anchoring into a different test's hierarchy)
                // must not have their myModelRef overwritten under a foreign lock, as that would
                // race with findOrTrackChild reading myModelRef under the child's own lock.
                if child.lock === self.lock {
                    child.myModelRef = modelRef
                }
                return child
            } else {
                // Ensure that DependencyValues._current reflects this context's own captured
                // DependencyValues before creating the child context. Context.init calls
                // Use withOwnDependencies (not withDependencies(from: self)) to ensure the
                // child context captures this context's exact DependencyValues without merging
                // with the caller's task-local. withDependencies(from:) does:
                //   self.deps.merging(DependencyValues._current)  ← _current wins
                // so if a background task launched from an *ancestor* context is executing here,
                // its task-local would overwrite this context's dep overrides. By unconditionally
                // replacing _current with self's deps, the child correctly inherits this context.
                let child = withOwnDependencies {
                    Context<Child>(model: childModel, lock: lock, dependencies: nil, parent: self)
                }
                children[containerPath, default: [:]][modelRef] = child
                child.myModelRef = modelRef
                return child
            }
        }
    }

    /// Fast-path check used by `AnchorVisitor` during container traversal.
    ///
    /// If the child model already has a live context that is registered under `containerPath`
    /// in this parent, inserts the child's `ModelRef` into `modelRefs` (required for the
    /// set-subtraction diff in `updateContext`) and returns the registered context.
    ///
    /// Returning non-nil with `existing === childModel.context` means the element is fully
    /// up-to-date — the caller can skip all remaining work, including key-path construction.
    /// Returning nil (or non-nil but context mismatch) falls through to the full `childContext`
    /// slow path, which constructs the element key path and registers a new context.
    ///
    /// - Complexity: O(1) — uses the child context's stored `myModelRef` key, avoiding any
    ///   key-path composition (`elementPath.appending(path:)`) for already-registered elements.
    func findOrTrackChild<C: ModelContainer, Child: Model>(
        containerPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child>? {
        lock {
            // Look up the child's live context. If it has a stored modelRef, check whether
            // it's actually registered under this parent at the given containerPath.
            guard let existing = childModel.modelContext.context,
                  // Only use the fast path when the child shares our lock (same hierarchy).
                  // If locks differ (e.g. re-anchoring, cross-test shared dependency),
                  // reading `existing.myModelRef` without `existing`'s lock is a data race.
                  existing.lock === self.lock,
                  let modelRef = existing.myModelRef,
                  children[containerPath]?[modelRef] === existing
            else { return nil }
            // Found: track in modelRefs so this element is not mistakenly treated as removed.
            modelRefs.insert(modelRef)
            return existing
        }
    }

    /// Like `findOrTrackChild` but assumes the hierarchy lock is already held by the caller.
    ///
    /// Use this instead of `findOrTrackChild` when the hierarchy lock is known to be held
    /// (e.g., from within `stateTransaction`). This eliminates the redundant re-entrant
    /// `lock { }` acquisition, saving ~N × 2 × NSRecursiveLock.lock/unlock calls during
    /// container traversal in `updateContext`.
    ///
    /// **Thread safety**: all accessed state (`myModelRef`, `children`, `modelRefs`) is
    /// protected by the hierarchy lock. This method assumes the caller holds the lock; calling
    /// it without the lock held is a data race.
    func findOrTrackChildLocked<C: ModelContainer, Child: Model>(
        containerPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child>? {
        // No lock { } — hierarchy lock already held by caller.
        guard let existing = childModel.modelContext.context,
              existing.lock === self.lock,
              let modelRef = existing.myModelRef,
              children[containerPath]?[modelRef] === existing
        else { return nil }
        modelRefs.insert(modelRef)
        return existing
    }

    // MARK: - MutableCollection variants (no ModelContainer constraint)
    //
    // These mirror the existing ModelContainer-constrained overloads but work with any
    // MutableCollection whose elements are Model & Identifiable. The `elementPath` in
    // ModelRef uses \C.self (identity key path on the collection type) as a sentinel —
    // the outer `containerPath` dict key already distinguishes collections, so only `id`
    // needs to disambiguate elements within a collection.

    /// Creates or retrieves the child context for a `MutableCollection` element,
    /// using `ModelRef(elementPath: \C.self, id: childModel.id)` as the registry key.
    func childContextForCollection<C: MutableCollection, Child: Model>(
        containerPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child> where C.Element == Child {
        let elementPath = \C.self
        var postLockCallbacks: [() -> Void] = []
        defer { runPostLockCallbacks(postLockCallbacks) }
        return lock {
            let modelRef = ModelRef(elementPath: elementPath, id: childModel.id)
            modelRefs.insert(modelRef)

            if let child = children[containerPath]?[modelRef] as? Context<Child> {
                return child
            }

            assert(children[containerPath]?[modelRef] == nil)

            if let child = childModel.modelContext.context {
                child.addParent(self, callbacks: &postLockCallbacks)
                children[containerPath, default: [:]][modelRef] = child
                if child.lock === self.lock {
                    child.myModelRef = modelRef
                }
                return child
            } else {
                let child = withOwnDependencies {
                    Context<Child>(model: childModel, lock: lock, dependencies: nil, parent: self)
                }
                children[containerPath, default: [:]][modelRef] = child
                child.myModelRef = modelRef
                return child
            }
        }
    }

    /// Fast-path check for `MutableCollection` elements. Mirrors `findOrTrackChild` but
    /// without the `C: ModelContainer` constraint.
    func findOrTrackChildForCollection<C: MutableCollection, Child: Model>(
        containerPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child>? where C.Element == Child {
        lock {
            guard let existing = childModel.modelContext.context,
                  existing.lock === self.lock,
                  let modelRef = existing.myModelRef,
                  children[containerPath]?[modelRef] === existing
            else { return nil }
            modelRefs.insert(modelRef)
            return existing
        }
    }

    /// Like `findOrTrackChildForCollection` but assumes the hierarchy lock is already held.
    func findOrTrackChildLockedForCollection<C: MutableCollection, Child: Model>(
        containerPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child>? where C.Element == Child {
        guard let existing = childModel.modelContext.context,
              existing.lock === self.lock,
              let modelRef = existing.myModelRef,
              children[containerPath]?[modelRef] === existing
        else { return nil }
        modelRefs.insert(modelRef)
        return existing
    }

    /// Defers context creation for a `MutableCollection` child element.
    func registerLazyChildForCollection<C: MutableCollection, Child: Model>(
        containerPath: WritableKeyPath<M, C>,
        childModel: Child
    ) where C.Element == Child {
        childModel.modelContext._source.reference.setLazyContextCreator { [weak self] in
            if let existing = childModel.modelContext._source.reference.context { return existing }
            guard let self else { return nil }
            return self.childContextForCollection(containerPath: containerPath, childModel: childModel)
        }
    }

    /// Updates contexts for elements of a `MutableCollection` property that does not
    /// conform to `ModelContainer`. Mirrors `updateContext(for:at:)` using cursor-free
    /// index-based traversal.
    ///
    /// **Must be called with the hierarchy lock held** — same contract as `updateContext`.
    func updateContextForCollection<C: MutableCollection>(
        for collection: inout C,
        at path: WritableKeyPath<M, C>
    ) -> [AnyContext] where C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        guard !isDestructed else { return [] }

        let prevChildren = (children[path] ?? [:])
        let prevRefs = Set(prevChildren.keys)

        modelRefs.removeAll(keepingCapacity: true)

        for index in collection.indices {
            let element = collection[index]

            guard !element.lifetime.isDestructedOrFrozenCopy else {
                threadLocals.didReplaceModelWithDestructedOrFrozenCopy()
                continue
            }
            if let childRef = element.modelContext.reference, childRef.hasLazyContextCreator { continue }

            // O(1) fast path: element already registered and context is current.
            let existing = findOrTrackChildLockedForCollection(containerPath: path, childModel: element)
            if let existing, existing === element.modelContext.context { continue }

            // Slow path: create or update child context.
            let childCtx = childContextForCollection(containerPath: path, childModel: element)
            if childCtx !== element.modelContext.context {
                var elem = collection[index]
                elem.withContextAdded(context: childCtx, containerPath: \.self, elementPath: \.self, includeSelf: false, hierarchyLockHeld: true)
                elem.modelContext = ModelContext(context: childCtx)
                collection[index] = elem
            }
        }

        let oldRefs = prevRefs.subtracting(modelRefs)
        return oldRefs.map { prevChildren[$0]! }
    }

    // MARK: - ContainerCollection variants (MutableCollection<ModelContainer & Identifiable>)
    //
    // These handle MutableCollection properties whose element type is `ModelContainer & Identifiable`
    // but the collection itself is NOT ModelContainer (e.g. IdentifiedArray<@ModelContainer enum>).
    // Child model contexts are stored under `children[collectionPath]` using
    // `ModelRef(elementPath: \C.self, id: childModel.id)` as the registry key — the same
    // sentinel strategy used by `childContextForCollection`. Model IDs (UUIDs) are globally unique,
    // so no cursor key path is needed, eliminating the 3 heap allocations that cursor construction
    // would otherwise require before every registry lookup.

    /// Creates or retrieves the child context for a `Model` child inside a `ModelContainer`
    /// element of a `MutableCollection` that is not itself `ModelContainer`.
    ///
    /// Uses `ModelRef(elementPath: \C.self, id: childModel.id)` as the registry key — the same
    /// sentinel strategy as `childContextForCollection`. Model IDs (UUIDs) are globally unique,
    /// so no cursor key path is needed to disambiguate elements. This eliminates the 3 cursor
    /// allocations that would otherwise be required before every registry lookup.
    func childContextForContainerCollectionModel<C: MutableCollection, Child: Model>(
        collectionPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child> where C.Element: ModelContainer & Identifiable & Sendable {
        var postLockCallbacks: [() -> Void] = []
        defer { runPostLockCallbacks(postLockCallbacks) }
        return lock {
            let modelRef = ModelRef(elementPath: \C.self, id: childModel.id)
            modelRefs.insert(modelRef)

            if let child = children[collectionPath]?[modelRef] as? Context<Child> {
                return child
            }

            assert(children[collectionPath]?[modelRef] == nil)

            if let child = childModel.modelContext.context {
                child.addParent(self, callbacks: &postLockCallbacks)
                children[collectionPath, default: [:]][modelRef] = child
                if child.lock === self.lock {
                    child.myModelRef = modelRef
                }
                return child
            } else {
                let child = withOwnDependencies {
                    Context<Child>(model: childModel, lock: lock, dependencies: nil, parent: self)
                }
                children[collectionPath, default: [:]][modelRef] = child
                child.myModelRef = modelRef
                return child
            }
        }
    }

    /// Fast-path check for `Model` children inside a `ModelContainer` element of a
    /// `MutableCollection`. Mirrors `findOrTrackChildForCollection` but uses the stored
    /// `myModelRef` (composedPath-based key) to look up under `children[collectionPath]`.
    func findOrTrackChildForContainerCollectionModel<C: MutableCollection, Child: Model>(
        collectionPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child>? where C.Element: ModelContainer & Identifiable & Sendable {
        lock {
            guard let existing = childModel.modelContext.context,
                  existing.lock === self.lock,
                  let modelRef = existing.myModelRef,
                  children[collectionPath]?[modelRef] === existing
            else { return nil }
            modelRefs.insert(modelRef)
            return existing
        }
    }

    /// Like `findOrTrackChildForContainerCollectionModel` but assumes the hierarchy lock is held.
    func findOrTrackChildLockedForContainerCollectionModel<C: MutableCollection, Child: Model>(
        collectionPath: WritableKeyPath<M, C>,
        childModel: Child
    ) -> Context<Child>? where C.Element: ModelContainer & Identifiable & Sendable {
        guard let existing = childModel.modelContext.context,
              existing.lock === self.lock,
              let modelRef = existing.myModelRef,
              children[collectionPath]?[modelRef] === existing
        else { return nil }
        modelRefs.insert(modelRef)
        return existing
    }

    /// Updates contexts for `ModelContainer` elements of a `MutableCollection` property that
    /// does not conform to `ModelContainer`. Mirrors `updateContextForCollection` but uses
    /// `AnchorVisitorForContainerElement` to traverse each element's model children.
    ///
    /// **Must be called with the hierarchy lock held** — same contract as `updateContext`.
    func updateContextForContainerCollection<C: MutableCollection>(
        for collection: inout C,
        at path: WritableKeyPath<M, C>
    ) -> [AnyContext]
        where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        guard !isDestructed else { return [] }

        let prevChildren = (children[path] ?? [:])
        let prevRefs = Set(prevChildren.keys)

        modelRefs.removeAll(keepingCapacity: true)

        for index in collection.indices {
            let element = collection[index]
            let id = threadLocals.withValue(true, at: \.forceDirectAccess) { element.id }

            var elementVisitor = AnchorVisitorForContainerElement(
                value: element,
                context: self,
                collectionPath: path,
                elementID: id,
                capturedElement: element,
                hierarchyLockHeld: true
            )
            element.visit(with: &elementVisitor, includeSelf: false)
            collection[index] = elementVisitor.value
        }

        let oldRefs = prevRefs.subtracting(modelRefs)
        return oldRefs.map { prevChildren[$0]! }
    }
}

extension Context {
    /// Backing storage for one live model or one snapshot copy.
    ///
    /// ## Lifecycle (live reference)
    /// 1. **Pre-anchor**: created by `@_ModelTracked` init accessor. `state` is set; `_context`
    ///    is nil; `_isDestructed` is false.
    /// 2. **Anchored**: `_context` is set by `Context.init`. All pre-anchor copies holding this
    ///    Reference automatically see the context. `state` is the live mutable state, mutated
    ///    under the context lock.
    /// 3. **Destructed**: `destruct()` sets `_isDestructed = true`. `state` is NOT cleared —
    ///    it retains the last-seen values so SwiftUI can still read them during the TTL window.
    ///    `clearStateForGeneration` (from Context.deinit) nils `_context` once the last context
    ///    deinits, but does NOT clear `state`.
    /// 4. **Cleared**: `clear()` zeroes `state` after the last-seen TTL expires to break any
    ///    retain cycles (closures in `_State` may capture models holding this Reference).
    ///    Sets `_stateCleared = true`.
    ///
    /// ## Snapshot reference (`_snapshotLifetime != nil`)
    /// Created independently via `init(modelID:state:lifetime:)`. `_context` is always nil;
    /// `state` is immutable (writes are guarded at the source level); `_isDestructed` is false.
    ///
    /// ## Single Reference per model lifetime
    /// All copies of a model (pending and live) share the same Reference from creation.
    /// When `Context.init` calls `setContext`, all those copies immediately see the context
    /// via `ref._context` — no forwarding indirection needed.
    final class Reference: @unchecked Sendable {
        let modelID: ModelID
        private let lock = NSRecursiveLock()
        private weak var _context: Context<M>?
        private var _isDestructed = false
        /// Monotonically-increasing generation counter. Incremented each time `setContext` runs
        /// (including re-anchoring). `Context` stores its own generation so `deinit` can call
        /// `clearStateForGeneration` without affecting state claimed by a newer Context.
        private var _generation: Int = 0
        /// Number of live Context instances that have claimed this Reference (called `setContext`
        /// but not yet called `clearStateForGeneration`). `_context` is only nilled when this
        /// count drops to zero — prevents concurrent tests sharing a static `let testValue`
        /// Reference from clearing each other's live state.
        private var _liveContextCount: Int = 0
        /// Set by `reserveOrFork()` before Context.init to pre-increment `_liveContextCount`.
        /// Consumed (cleared) by the next `setContext(_:)` call.
        private var _isReserved: Bool = false
        /// Lazy context factory, set by `registerLazyChild` for collection elements.
        /// Cleared (set to nil) after first use in `materializeLazyContext()`.
        /// Returns nil if the parent context was deallocated before the child was materialized.
        private var _lazyContextCreator: (() -> Context<M>?)?
        /// Live/lastSeen/snapshot state. Non-optional — always holds a valid value.
        /// After `clear()`, replaced with genesis state to release live-model references.
        var state: M._ModelState
        /// True after `clear()`. Reads from a cleared reference will reportIssue and
        /// return a genesis fallback.
        var _stateCleared: Bool = false
        /// Genesis state captured at the first `setContext` call (post-`withContextAdded`).
        /// All property values are correct at that point (no self-referencing closures yet).
        /// Used to restore `state` when re-anchoring a static dependency model, and as a
        /// safe fallback for reads on a cleared reference. Stored inline — always needed for
        /// every anchored model, so boxing would only add malloc overhead with no saving.
        /// Initialized to `state` in Reference.init as a safe placeholder (never read until
        /// _hasGenesis = true, at which point setContext overwrites it with the correct value).
        var _genesisState: M._ModelState
        /// True once genesis has been captured (set in `setContext` on first anchor).
        var _hasGenesis: Bool = false
        /// Incremented by `_ModelSourceBox.subscript[write:access:]._modify` whenever a tracked
        /// property is mutated on a pre-anchor Reference. Used by `Context.init` to detect whether
        /// a stored child's dep closure performed a read-modify-write on a dep model inherited from
        /// the parent's `capturedDependencies` — even when Swift's compound-access optimization
        /// bypasses the outer `ModelDependencies.subscript` write-back.
        var _stateVersion: Int = 0
        /// Non-nil only for snapshot references (frozen/lastSeen). Immutable after init.
        private let _snapshotLifetime: ModelLifetime?
        /// True when this Reference backs a snapshot (frozen copy or lastSeen) rather than a live model.
        var isSnapshot: Bool { _snapshotLifetime != nil }

        /// True when a lazy context factory is pending (not yet materialized).
        var hasLazyContextCreator: Bool {
            lock { _lazyContextCreator != nil }
        }

        /// Registers a factory that creates this Reference's context on demand.
        /// Called by `Context.registerLazyChild` for collection element children.
        func setLazyContextCreator(_ creator: @escaping () -> Context<M>?) {
            lock { _lazyContextCreator = creator }
        }

        /// Creates the context on demand if a lazy factory was registered.
        ///
        /// Lock ordering: grab+clear factory under Reference lock, release, then call factory
        /// (which acquires tree lock → setContext re-acquires Reference lock re-entrantly).
        /// This avoids holding both locks simultaneously.
        func materializeLazyContext() -> Context<M>? {
            // Fast path: context already exists.
            if let ctx = lock({ _context }) { return ctx }

            // Grab and clear the factory under the Reference lock, then release before calling it.
            let factory: (() -> Context<M>?)? = lock {
                let f = _lazyContextCreator
                _lazyContextCreator = nil
                return f
            }

            guard let factory, let ctx = factory() else { return nil }

            _ = ctx.onActivate()
            return ctx
        }

        /// Creates a live Reference with initial state.
        init(modelID: ModelID, state: M._ModelState) {
            self.modelID = modelID
            self.state = state
            self._genesisState = state
            self._snapshotLifetime = nil
        }

        /// Creates a snapshot Reference (frozen or lastSeen) with independent state.
        init(modelID: ModelID, state: M._ModelState, lifetime: ModelLifetime) {
            self.modelID = modelID
            self.state = state
            self._genesisState = state
            self._snapshotLifetime = lifetime
        }

        deinit {
        }

        var lifetime: ModelLifetime {
            if let _snapshotLifetime { return _snapshotLifetime }
            return context?.lifetime ?? lock {
                _isDestructed ? .destructed : .initial
            }
        }

        var context: Context<M>? {
            lock { _context }
        }

        var isDestructed: Bool {
            lock { _isDestructed }
        }

        /// True when state is available for reads. Used to verify anchoring preconditions.
        var hasState: Bool {
            lock { !_stateCleared || _hasGenesis }
        }

        /// Restores `state` from `_genesisState` if the Reference was previously destroyed.
        /// Must be called before `withContextAdded` so child-model traversal can read state.
        /// The full re-anchoring reset (`_isDestructed`, generation) happens in `setContext`.
        ///
        /// Always restores genesis (not just when `_stateCleared`) so that re-anchored
        /// `static let testValue` models start from a clean initial state even while the
        /// TTL window is open from a prior test run. Without this, a test that mutated the
        /// model's state would leave those mutations visible to the next test.
        func prepareForReanchoring() {
            lock {
                guard _isDestructed, _hasGenesis else { return }
                state = _genesisState
                _stateCleared = false
            }
        }

        /// Marks the model as destructed. `state` retains its last-seen values for the TTL window.
        func destruct() {
            lock {
                _isDestructed = true
            }
        }

        /// Replaces `state` with genesis to release live-model references and break retain
        /// cycles after the last-seen TTL expires. Using genesis (pre-anchor state, no live
        /// child contexts) avoids _zeroInit(), which crashes for property types with class
        /// references (e.g. SwiftUI.ScrollPosition). If no genesis was captured the model
        /// was never anchored, so there are no retain cycles to break.
        /// `_context` is intentionally NOT cleared here — that happens in `clearStateForGeneration`
        /// (called from Context.deinit). Clearing `_context` here would make `ModelNode.isDestructed`
        /// return `true` before `onCancel` callbacks fire, causing dependency lookups to fall
        /// through to the live default instead of the test override.
        func clear() {
            // Return old state from the lock so its contents are destroyed AFTER the lock
            // releases. Deinits triggered by state destruction (e.g. onDeinit callbacks
            // reading model properties via Context.subscript.read) would cause Swift
            // exclusivity violations if reference.state were still exclusively held.
            let stateToRelease: M._ModelState = lock {
                _stateCleared = true
                let old = state
                if _hasGenesis {
                    state = _genesisState
                }
                return old
            }
            _fixLifetime(stateToRelease)
        }

        /// Atomically claims this Reference for a new Context, or creates a fresh
        /// independent Reference from genesis state if this Reference is already in use
        /// by another Context (e.g. a concurrent test sharing a static `let testValue`).
        ///
        /// Returns `self` if unclaimed (`_liveContextCount == 0`), or a new forked Reference
        /// if already claimed. Either way, the returned Reference has `_liveContextCount`
        /// pre-incremented and `_isReserved` set, so the subsequent `setContext(_:)` call
        /// skips its own increment to avoid double-counting.
        func reserveOrFork() -> Context<M>.Reference {
            lock {
                if _liveContextCount == 0 {
                    _liveContextCount = 1
                    _isReserved = true
                    return self
                }
                let initialState = _hasGenesis ? _genesisState : state
                let newRef = Context<M>.Reference(modelID: .generate(), state: initialState)
                if _hasGenesis {
                    newRef._genesisState = _genesisState
                    newRef._hasGenesis = true
                }
                newRef._liveContextCount = 1
                newRef._isReserved = true
                return newRef
            }
        }

        /// Sets the context, returns the new generation. The caller (Context.init) stores the
        /// generation so Context.deinit can call `clearStateForGeneration` correctly.
        @discardableResult
        func setContext(_ context: Context) -> Int {
            lock {
                if _isDestructed {
                    // Re-anchoring a static dependency model: restore initial state from genesis.
                    // `_genesisState` holds the state at first-anchor time (correct values,
                    // no self-referencing closures). `prepareForReanchoring()` may have already
                    // restored `state`, but ensure it is set here too in case the old
                    // Context.deinit ran between prepareForReanchoring and setContext.
                    //
                    // Always restore genesis regardless of `_stateCleared` — even when the
                    // TTL window is still open (state not yet zeroed), the previous test's
                    // mutations must not bleed into the next test's anchor.
                    if _hasGenesis {
                        state = _genesisState
                        _stateCleared = false
                    }
                    _isDestructed = false
                } else if !_hasGenesis {
                    // First anchor: capture genesis state. At this point `withContextAdded` has
                    // run so all property values (including MIDDLE properties from user-written
                    // inits) are correct. No self-referencing closures exist yet (those are set
                    // up in onActivate, which runs after setContext returns).
                    _genesisState = state
                    _hasGenesis = true
                }
                _generation += 1
                if _isReserved {
                    // Count was pre-incremented by reserveOrFork(); just consume the reservation.
                    _isReserved = false
                } else {
                    _liveContextCount += 1
                }
                _context = context
                return _generation
            }
        }

        /// Decrements `_liveContextCount` and nils `_context` when the last Context deinits.
        /// Does NOT clear `state` — it retains last-seen values for the TTL window.
        /// `clear()` is called after TTL to zero `state` and break retain cycles.
        func clearStateForGeneration(_ gen: Int) {
            lock {
                _liveContextCount -= 1
                if _liveContextCount <= 0 {
                    _liveContextCount = 0
                    _context = nil  // Eliminate race: _context must be nil whenever _liveContextCount == 0
                }
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
/// `@_ModelTracked`-generated `_read` accessor invokes `willAccess(from:at:)` with
/// the *backing* key path (e.g. `\._count`).  `PathCollector` records both the backing path and a
/// type-erased closure that can later call `ModelContext.invokeDidModify` with the correct generic
/// type, bypassing the need to open an existential.
private final class PathCollector<M: Model>: ModelAccess, @unchecked Sendable {
    /// Backing storage paths (M._ModelState-level) discovered via `willAccess`.
    var paths: [PartialKeyPath<M._ModelState>] = []
    /// Type-erased closures; each calls `ModelContext.invokeDidModify(at:)` for one path.
    var invokers: [(ModelContext<M>) -> Void] = []

    init() { super.init(useWeakReference: false) }

    override func willAccess<N: Model, T>(from context: Context<N>, at path: KeyPath<N._ModelState, T> & Sendable) -> (() -> Void)? {
        // We only care about accesses on M._ModelState itself.
        guard let typedPath = path as? KeyPath<M._ModelState, T> else { return nil }
        paths.append(typedPath)
        // Capture a type-erased invoker. The cast to `& Sendable` is safe here: the call-site
        // guarantees `path` is Sendable (it arrives as `KeyPath<N._ModelState, T> & Sendable`), and after
        // the `as? KeyPath<M._ModelState, T>` downcast we still have the same Sendable key path object.
        // We use `unsafeBitCast` to reattach the Sendable marker without a dynamic check.
        let sendablePath = unsafeBitCast(typedPath, to: (KeyPath<M._ModelState, T> & Sendable).self)
        invokers.append { mc in mc.invokeDidModify(at: sendablePath)?() }
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
/// Returns a zero-initialized value of type T. Defensive fallback for destructed contexts
/// and as a placeholder for unassigned properties during `_makeState` construction.
///
/// String is special-cased because its zero bit pattern is indistinguishable from
/// `Optional<T>.none` when T contains a String at the offset used for Optional's
/// spare-bit discriminator. This causes `Optional<_State>` to read as nil even
/// though a value was stored. Using `String()` produces a valid empty string with
/// proper internal representation that doesn't collide with Optional's nil pattern.
public func _zeroInit<T>() -> T {
    if T.self == String.self {
        return unsafeBitCast(String(), to: T.self)
    }
    return withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buf in
        _ = memset(buf.baseAddress!, 0, MemoryLayout<T>.size)
        return buf[0]
    }
}

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
