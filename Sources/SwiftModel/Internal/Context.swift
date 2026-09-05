import Foundation
import Dependencies
import OrderedCollections
import IssueReporting
import CustomDump
import Observation

@usableFromInline
final class Context<M: Model>: AnyContext, @unchecked Sendable {
    private let activations: [(M) -> Void]
    /// Backing store for `modifyCallbacks`. `nil` while no `onModify` callback is
    /// registered on this context — the common case for a property write — so the write
    /// path consults `hasModifyCallbacks` first and only hashes a key path against this
    /// dictionary when there is something to find. Only touched under `lock`;
    /// `@exclusivity(unchecked)` per the note at `AnyContext._modificationCount`.
    @exclusivity(unchecked) private var modifyCallbacksStore: [PartialKeyPath<M._ModelState>: [Int: (_ finished: Bool, _ force: Bool) -> (() -> Void)?]]?
    /// `modifyCallbacksStore != nil`, maintained by the `_modify` accessor below (the only
    /// mutation route). Read on every property write: a plain `Bool` load, so the check
    /// needs neither the dictionary's generic metadata nor a `PartialKeyPath` hash.
    @exclusivity(unchecked) private var hasModifyCallbacks = false
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
            // Only the two assignments above change the store's nil-ness, and both run after
            // the yield, so the flag can never disagree with the store — not even when the
            // caller's access is abandoned mid-yield (nothing after the yield runs then).
            hasModifyCallbacks = modifyCallbacksStore != nil
        }
    }
    @usableFromInline let reference: Reference
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
        let setupClosures = modelSetup?.setupClosures ?? []
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
        let capturedSetups = setupClosures
        let capturedActivations = activations
        let capturedReference = reference
        pendingActivation = { [localModel, capturedSetups, capturedActivations, capturedReference] in
            var m = localModel
            m.modelContext.setReference(capturedReference)
            m.modelContext.access = ModelAccess.active ?? ModelAccess.current
            for setup in capturedSetups {
                setup(m)
            }
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
                            setCachedDependencyValue(model, for: key)
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

        // `pendingActivation` must be consumed exactly once, by the single caller that won the
        // atomic anchored→active transition in `super.onActivate()` (which returns `true` only
        // for the first activation). Read-and-nil it under the hierarchy lock: concurrent
        // `onActivate()` calls on the same context — e.g. two concurrent collection writers each
        // running the `structuralChange` re-activation loop in `_performCollectionSet`, which
        // runs OUTSIDE `stateTransaction` — would otherwise race on this `var` (one writing `nil`
        // while another reads/calls it). Losers (`shouldActivate == false`) never touch it.
        if shouldActivate {
            let pending = lock { () -> (() -> Void)? in
                let p = pendingActivation
                pendingActivation = nil
                return p
            }
            pending?()
        }

        for child in lock(allChildren) {
            _ = child.onActivate()
        }

        return shouldActivate
    }

    override func onRemoval(callbacks: inout [() -> Void]) {
        super.onRemoval(callbacks: &callbacks)
        // Must acquire own lock explicitly. When a separately-anchored model is added as a
        // child of another hierarchy, teardown runs under the PARENT's lock, which differs
        // from self.lock. The memoize GCD callback acquires self.lock and reads modifyCallbacks
        // concurrently — without this, the two threads race on modifyCallbacksStore.
        // NSRecursiveLock makes this safe for the same-hierarchy case (re-entrant).
        let modifies = lock {
            let m = modifyCallbacks.values.flatMap({ $0.values })
            modifyCallbacks.removeAll()
            return m
        }

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
            // Hold AnyContext.lock during the state swap (lock order: AnyContext.lock → Reference.lock,
            // same order used by destruct() above) to prevent a concurrent Context.subscript._read
            // from racing on reference.state. Release old state after both locks drop so that
            // deinits triggered by state release can re-enter the lock without exclusivity violations.
            let ref = reference
            let contextLock = self.lock
            let generation = referenceGeneration
            callbacks.append {
                contextLock.lock()
                let stateToRelease = ref.clear(ifGeneration: generation)
                contextLock.unlock()
                _fixLifetime(stateToRelease)
            }
            return
        }

        let generation = referenceGeneration
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000*UInt64(lastSeenTimeToLive*1000))
            // Same fix as the non-TTL path: hold AnyContext.lock while swapping state so that
            // concurrent property reads (which also hold this lock) cannot race on reference.state.
            // Generation-guarded: a re-anchor within the TTL window must not have its live
            // state wiped by this stale task (see `clear(ifGeneration:)`).
            let stateToRelease = lock { reference.clear(ifGeneration: generation) }
            _fixLifetime(stateToRelease)
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
        // Shadow gap-race detector (withObservationTracking path) — `didModifyParents`
        // fires `modifyCallbacks` for this same path. See `willAccessGapShadow`.
        willAccessGapShadow(at: parentsObservationPath)
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

        // Shadow gap-race detector (withObservationTracking path): subscribe on the TYPED
        // `[_metadata:]` path — that is the key `didModifyStorage`'s post-lock callbacks
        // fire (`modifyCallbacks` for the untyped path never fire). See `willAccessGapShadow`.
        willAccessGapShadow(at: \M._ModelState[_metadata: storage] as WritableKeyPath<M._ModelState, V>&Sendable)

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
        // Pre-compute storage value so any code that needs to read it (TestAccess's
        // `didModify`, the debug initial-value capture in `ViewAccess.willAccess`) can
        // do so without invoking the `_ModelStateType[_metadata:]` `fatalError()`
        // stub getter. The same value is exposed both during the `willAccess` call
        // and around the returned closure — symmetric with `didModifyStorage`'s
        // behaviour, and the only way for `willAccess` to capture an `old` value for
        // `.withValue` / `.withDiff` debug emissions on these synthetic paths.
        let storageValue: V = lock { (contextStorage[storage.key]?.value as? V) ?? storage.defaultValue }
        let closureOpt = threadLocals.withValue(storageArea, at: \.modificationArea) {
            threadLocals.withValue(storage.name, at: \.storageName) {
                threadLocals.withValue(storageValue as Any, at: \.precomputedStorageValue) {
                    mc.activeAccess?.willAccess(from: self, at: typedPath)
                }
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
        // Defer `ObservationTracking.onObservedChange` performUpdate enqueues until every
        // listener for this write — Apple's one-shot onChange (fired inline by
        // `invokeDidModifySyntheticPath`) and the gap-shadow's post-lock callback — has made
        // its dedup decision against the same `hasPendingUpdate` snapshot. This is the same
        // tier-2 deferral `Context.transaction` provides for real `_State` writes; without
        // it, the shadow subscription registered by `willAccessGapShadow` could schedule a
        // duplicate performUpdate for a write Apple already handled. See
        // `ThreadLocals.lockHeldBackgroundCalls`.
        let lhbcOwned = beginLockHeldBackgroundCallsScope(threadLocals)
        defer { endLockHeldBackgroundCallsScope(threadLocals, lhbcOwned) }
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
            // The post-lock callbacks themselves need the same context-storage thread-locals
            // in scope: `ViewAccess.onModify`-registered closures (DEBUG) fire here and
            // dispatch `emitDebugTrigger`, whose `readValue()` reads
            // `precomputedStorageValue` and whose `debugPropertyName` reads
            // `storageName` / `modificationArea` — the `_metadata[…]` getter stub
            // `fatalError`s otherwise.
            let runArea: _ExhaustivityBits = storage.propagation == .environment ? .environment : .local
            threadLocals.withValue(runArea, at: \.modificationArea) {
                threadLocals.withValue(storage.name, at: \.storageName) {
                    threadLocals.withValue(newValue as Any, at: \.precomputedStorageValue) {
                        runPostLockCallbacks(postLockCallbacks)
                    }
                }
            }
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

        // Shadow gap-race detector (withObservationTracking path): subscribe on the TYPED
        // `[_preference:]` path — that is the key `didModifyPreference` /
        // `notifyPreferenceChange` fire post-lock callbacks for (`modifyCallbacks` for the
        // untyped path never fire). This runs per visited context during `preferenceValue`'s
        // subtree aggregation, so a contribution write on any visited descendant fires the
        // subscription registered on that same context. See `willAccessGapShadow`.
        willAccessGapShadow(at: \M._ModelState[_preference: storage] as WritableKeyPath<M._ModelState, V>&Sendable)

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
        // Set `precomputedPreferenceValue` both during the `willAccess` call and around
        // its returned closure — symmetric with the `precomputedStorageValue` pattern in
        // `willAccessStorage`. Required so any callee that needs the aggregated value
        // (the debug initial-value capture in `ViewAccess.willAccess` for the typed
        // `[_preference:]` path) can read it without invoking the `fatalError()` stub
        // getter.
        let closureOpt = threadLocals.withValue(.preference, at: \.modificationArea) {
            threadLocals.withValue(storage.name, at: \.storageName) {
                threadLocals.withValue(value as Any, at: \.precomputedPreferenceValue) {
                    mc.activeAccess?.willAccess(from: self, at: typedPath)
                }
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
        // Same tier-2 performUpdate-enqueue deferral as `didModifyStorage` (see the comment
        // there) — covers this context AND the entire `notifyPreferenceChange` parent-chain
        // walk (nested scopes share the outer array).
        let lhbcOwned = beginLockHeldBackgroundCallsScope(threadLocals)
        defer { endLockHeldBackgroundCallsScope(threadLocals, lhbcOwned) }
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
            // The post-lock callbacks themselves need the same preference thread-locals
            // in scope: `ViewAccess.onModify`-registered closures (DEBUG) fire here and
            // dispatch `emitDebugTrigger`, whose `readValue()` reads
            // `precomputedPreferenceValue` and whose `debugPropertyName` reads
            // `storageName` / `modificationArea` — the `_preference[…]` getter stub
            // `fatalError`s otherwise.
            threadLocals.withValue(.preference, at: \.modificationArea) {
                threadLocals.withValue(storage.name, at: \.storageName) {
                    threadLocals.withValue(newValue as Any, at: \.precomputedPreferenceValue) {
                        runPostLockCallbacks(postLockCallbacks)
                    }
                }
            }

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
        // Same tier-2 performUpdate-enqueue deferral as `didModifyPreference` (usually a
        // nested no-op — that caller already opened the scope — but upward propagation can
        // also be entered directly, e.g. from teardown paths).
        let lhbcOwned = beginLockHeldBackgroundCallsScope(threadLocals)
        defer { endLockHeldBackgroundCallsScope(threadLocals, lhbcOwned) }
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
        let key = generateKey()
        let registered = lock { () -> Bool in
            // Destructed check in the SAME lock scope as the insert: teardown
            // flips the lifetime and drains `modifyCallbacks` under this lock,
            // so an entry registered through a pre-lock check-then-act gap
            // would never be fired with `finished == true` and would pin its
            // captures until the context deallocates. (`unprotected` is fine —
            // we hold the lock.)
            guard !unprotectedIsDestructed else { return false }
            modifyCallbacks[path, default: [:]][key] = callback
            return true
        }
        guard registered else {
            return {}
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
        // Lock-order inversion guard — see the matching comment in
        // `beginDirectWrite` and
        // the `transaction(_:)` variant below (line ~1201) for the full
        // rationale. Acquire `TestAccess.lock` BEFORE `context.lock` to
        // match the reader's order (`TestAccess → context`); without this
        // a concurrent `subscript._modify` on another thread can deadlock
        // against an in-flight transaction that holds `context.lock` and
        // then tries to acquire `TestAccess.lock` for its nested writes.
        let writeLockHolder = modelContext.access ?? ModelAccess.current
        writeLockHolder?.acquireWriteLock()
        defer { writeLockHolder?.releaseWriteLock() }
        // Defer `ObservationTracking.onObservedChange` enqueues until this write's
        // lock-held + postLockCallbacks phases finish. See the helper definitions
        // (`beginLockHeldBackgroundCallsScope` / `endLockHeldBackgroundCallsScope`)
        // and `ThreadLocals.lockHeldBackgroundCalls` for rationale.
        let lhbcOwned = beginLockHeldBackgroundCallsScope(threadLocals)
        defer { endLockHeldBackgroundCallsScope(threadLocals, lhbcOwned) }
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
            let postLockCallbacks = buildPostLockCallbacksWithPropDesc(for: statePath, tl: threadLocals)
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
    @usableFromInline
    subscript<T>(statePath statePath: WritableKeyPath<M._ModelState, T>, observeCallback callback: (() -> Void)?) -> T {
        @inlinable
        _read {
            lock.lock()
            // Materialize the value into a local before yielding so that the dynamic
            // exclusivity borrow on `reference.state` ends here rather than persisting
            // through the yield suspension.  Without this, a subsequent _modify on any
            // other property of the same model (same reference.state address) would
            // trigger a simultaneous-access trap even in single-threaded code.
            let _value: T
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
                    _value = reference.state[keyPath: statePath]
                } else {
                    _value = reference.state[keyPath: statePath]
                }
            } else if threadLocals.transitionOverrideValue != nil, let override = threadLocals.transitionOverrideValue as? T {
                _value = override
            } else {
                _value = reference.state[keyPath: statePath]
            }
            yield _value
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
        // Skip everything while memoize's dirty-recompute is running `produce()` —
        // its reads must not leak to whatever outer observation is currently active
        // (SwiftUI body's `withObservationTracking`, a `ViewAccess` from
        // `$model.debug`, etc.). See `ThreadLocals.isInsideMemoizeProduce`.
        // Also skip inside a `withUntrackedModelReads` scope — synthetic-path reads
        // (memoize keys, environment, preference, parents) register no dependencies there.
        let tl = threadLocals
        if tl.isInsideMemoizeProduce || tl.untrackedReads { return }
        guard useObservationRegistrar,
              !(tl.isInsideAsyncPerformUpdate && ModelAccess.active != nil) else { return }
        let observer = _StateObserver<M._ModelState>()
        if useMainThreadObservation, isOnMainThread {
            mainObservationRegistrarMakingIfNeeded.access(observer, keyPath: kp)
        } else {
            backgroundObservationRegistrarMakingIfNeeded.access(observer, keyPath: kp)
        }
    }

    /// Dispatches the gap-race shadow collector (see the `let shadow = …` doc comment in
    /// `ObservationTracking.update`'s `withObservationTracking` branch) for a synthetic-path read.
    ///
    /// `willAccessSyntheticPath` registers synthetic dependencies (memoize sentinels,
    /// environment/local storage, preferences, the parents relationship) ONLY with Apple's
    /// one-shot `withObservationTracking`, and `ModelContext.willAccess` short-circuits for
    /// the whole `observe()` body (`isInsideMemoizeObserve`). Without this dispatch the
    /// shadow never sees synthetic reads, leaving the Gap A/B registration races open for
    /// them: a synthetic-path write landing between one-shot registration windows is
    /// dropped, `hasPendingUpdate` stays false, and the outer Observed/memoize holds a
    /// stale value until some other tracked dependency changes.
    ///
    /// `path` must be the key path whose `modifyCallbacks` the corresponding write-side
    /// actually fires: the TYPED `[_metadata:]` / `[_preference:]` paths for
    /// storage/preferences (`didModifyStorage` / `didModifyPreference` /
    /// `notifyPreferenceChange` build their post-lock callbacks for those; the untyped
    /// registrar-facing `[environmentKey:]` / `[preferenceKey:]` paths' `modifyCallbacks`
    /// never fire), and the untyped sentinel/parents paths for memoize/parents. Taken as an
    /// autoclosure so the key-path allocation is only paid when a shadow is installed.
    ///
    /// Gates mirror `willAccessDirect`'s shadow dispatch plus the registrar gate in
    /// `willAccessSyntheticPath`: skipped inside memoize's synchronous dirty-recompute
    /// (`isInsideMemoizeProduce`) and inside `withUntrackedModelReads` scopes
    /// (`untrackedReads`), so the shadow's persistent subscriptions never cover reads
    /// Apple's tracking is also blind to. Deliberately NOT gated on
    /// `isInsideMemoizeObserve` — the shadow exists precisely to see reads inside the
    /// observe() body.
    func willAccessGapShadow<T>(at path: @autoclosure () -> KeyPath<M._ModelState, T>&Sendable) {
        let tl = threadLocals
        guard let shadow = tl.gapShadowCollector, !tl.isInsideMemoizeProduce, !tl.untrackedReads else { return }
        _ = shadow.willAccess(from: self, at: path())
    }

    /// Fires ObservationRegistrar willSet/didSet for a synthetic `_StateObserver` keypath.
    /// Supports batching via `pendingObservationNotifications`. Does NOT handle activeAccess
    /// callbacks — callers handle those separately via `modelContext.invokeDidModify(at:)`.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func invokeDidModifySyntheticPath<T>(_ kp: KeyPath<_StateObserver<M._ModelState>, T> & Sendable) {
        guard useObservationRegistrar else { return }
        let observer = _StateObserver<M._ModelState>()
        let observerKP = kp
        let useMain = useMainThreadObservation

        // Fire background registrar synchronously on the mutating thread; optionally also
        // fire the main registrar via `mainCallQueue` (which runs the closure inline when
        // already on main, or enqueues onto `@MainActor` otherwise). Skipping the main work
        // entirely when `useMain` is false avoids the @MainActor hop — required on platforms
        // where @MainActor doesn't drain (Android), and a useful opt-out on Apple platforms
        // when there is no SwiftUI/UIKit/AppKit consumer.
        let notify: @Sendable () -> Void = { [self] in
            self.backgroundObservationRegistrar?.willSet(observer, keyPath: observerKP)
            self.backgroundObservationRegistrar?.didSet(observer, keyPath: observerKP)
            if useMain, let mainReg = self.mainObservationRegistrar {
                self.mainCallQueue {
                    mainReg.willSet(observer, keyPath: observerKP)
                    mainReg.didSet(observer, keyPath: observerKP)
                }
            }
        }

        if threadLocals.pendingObservationNotifications != nil {
            threadLocals.pendingObservationNotifications!.append(notify)
        } else {
            notify()
        }
    }

    // MARK: - Direct access helpers (for _ModelSourceBox subscripts)

    /// Computes the willAccess observation callback without constructing a ModelContext.
    /// Called from `_ModelSourceBox` read subscripts.
    ///
    /// Uses `_StateObserver` for registrar calls (no Model instance needed).
    /// Uses `_StateObserver` for registrar calls; delegates to `activeAccess.willAccess/didModify(from:at:)` for TestAccess.
    @usableFromInline
    func willAccessDirect<T>(statePath: WritableKeyPath<M._ModelState, T>, accessBox: _ModelAccessBox) -> (() -> Void)? {
        // Skip everything while memoize's dirty-recompute is running `produce()` —
        // its reads must not leak to whatever outer observation is currently active
        // (SwiftUI body's `withObservationTracking`, a `ViewAccess` from
        // `$model.debug`, a debug collector, a `TestAccess`). Memoize's own
        // dependency tracking is unaffected because the dirty branch doesn't
        // re-track here — the async `performUpdate` does, via `observe()`, which
        // is not flagged. See `ThreadLocals.isInsideMemoizeProduce`.
        if threadLocals.isInsideMemoizeProduce { return nil }

        let cachedActive = ModelAccess.active
        let access = accessBox._reference?.access ?? ModelAccess.current
        let activeAccess = cachedActive ?? access

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), useObservationRegistrar,
           !(threadLocals.isInsideAsyncPerformUpdate && cachedActive != nil) {
            let observer = _StateObserver<M._ModelState>()
            // Cached KP avoids a heap allocation on every read (`_swift_getKeyPath`
            // for a subscript KP allocates, ~1.7 μs). `_stateObserverKP` resolves via
            // an identity-keyed fast path (no structural KeyPath.hashValue on warm
            // reads) with a hashValue-keyed structural fallback for appended key
            // paths — see the doc comment at `_stateObserverKP`.
            let contextID = UInt(bitPattern: ObjectIdentifier(self))
            let observerKP: KeyPath<_StateObserver<M._ModelState>, AnyHashable> = _stateObserverKP(contextID: contextID, statePath: statePath)
            if useMainThreadObservation, isOnMainThread {
                mainObservationRegistrarMakingIfNeeded.access(observer, keyPath: observerKP)
            } else {
                backgroundObservationRegistrarMakingIfNeeded.access(observer, keyPath: observerKP)
            }
        }

        // Shadow gap-race detector. When non-nil (set by
        // `ObservationTracking.observe()`), dispatch willAccess here too so
        // it can register a synchronous per-(context, path) `context.onModify`
        // subscription for each read — closing Apple's `withObservationTracking`
        // registration-gap race. Runs BEFORE the
        // `isInsideMemoizeObserve` short-circuit because the shadow needs to
        // see reads even inside memoize observation (that's the whole point).
        // See `ThreadLocals.gapShadowCollector` for the rationale on why
        // this can't piggyback on `activeAccess`.
        if let shadow = threadLocals.gapShadowCollector {
            let sendableStatePath = unsafeBitCast(statePath, to: (WritableKeyPath<M._ModelState, T> & Sendable).self)
            _ = shadow.willAccess(from: self, at: sendableStatePath)
        }

        // Skip the swift-model side `activeAccess.willAccess` dispatch during a
        // memoize's async `observe()` body. The registrar.access above keeps
        // memoize's own `withObservationTracking` tracking intact; this check
        // prevents the read from accumulating as a dep on the calling view's
        // `ViewAccess` (the stamped-access fall-through that
        // `usingActiveAccess(nil)` cannot clear). See `ThreadLocals.isInsideMemoizeObserve`.
        if threadLocals.isInsideMemoizeObserve { return nil }

        guard let activeAccess else { return nil }
        let sendableStatePath = unsafeBitCast(statePath, to: (WritableKeyPath<M._ModelState, T> & Sendable).self)
        return activeAccess.willAccess(from: self, at: sendableStatePath)
    }

    /// Invokes post-modify observation notifications without constructing a ModelContext.
    /// Returns the active-access callback for the caller to execute after releasing the lock.
    ///
    /// Uses `_StateObserver` for registrar calls (no Model instance needed); delegates to
    /// `activeAccess.didModify(from:at:)` for TestAccess / AccessCollector.
    ///
    /// Must be called with `lock` held (both callers are inside `finishWrite`): the main
    /// registrar is read through `unprotectedMainObservationRegistrar` on that basis.
    ///
    /// - Parameter activeAccess: the caller's resolved `ModelAccess.active ??
    ///   accessBox._reference?.access ?? ModelAccess.current` — the same chain the write lock
    ///   was taken on, passed down rather than re-reading both task-locals here.
    /// - Parameter tl: the caller's `threadLocals` handle.
    @discardableResult
    func invokeDidModifyDirect<T>(statePath: WritableKeyPath<M._ModelState, T>, activeAccess: ModelAccess?, tl: ThreadLocals) -> (() -> Void)? {
        // The access callback is the only consumer of the `& Sendable` view of `statePath`.
        // Forming that view (`unsafeBitCast` to a protocol composition) costs an existential
        // metadata lookup, and holding it in an `Optional` a second lookup plus an opaque
        // copy — so it is built only when there is an access to hand it to.
        @inline(__always) func accessCallback() -> (() -> Void)? {
            guard let activeAccess else { return nil }
            return activeAccess.didModify(from: self, at: unsafeBitCast(statePath, to: (WritableKeyPath<M._ModelState, T> & Sendable).self))
        }

        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *), useObservationRegistrar {
            let observer = _StateObserver<M._ModelState>()
            // Use cached KP to avoid per-write _swift_getKeyPath allocation (same rationale as willAccessDirect).
            let contextID = UInt(bitPattern: ObjectIdentifier(self))
            nonisolated(unsafe) let observerKP: KeyPath<_StateObserver<M._ModelState>, AnyHashable> = _stateObserverKP(contextID: contextID, statePath: statePath)
            let useMain = useMainThreadObservation
            // Resolved once per write — the box → pair → background chain is immutable and
            // non-nil whenever `useObservationRegistrar` holds, so one borrowed read serves
            // willSet and didSet alike (no `Optional` of the resilient registrar to copy).
            let backgroundReg = backgroundObservationRegistrarMakingIfNeeded

            // Ordering rule for the main registrar:
            //   - When already on the main thread, the strict `willSet → mutation → didSet`
            //     order is preserved (matches the pre-dual-registrar behaviour and what
            //     `withObservationTracking`'s `onChange` semantically expects).
            //   - When off the main thread we have to bridge via `mainCallQueue`, which
            //     `@MainActor`-enqueues async. The main registrar's `willSet/didSet` therefore
            //     fire as a bundle *after* the mutation. Strict willSet-before-mutation isn't
            //     reachable here without blocking the mutating thread.
            // The background registrar always uses strict ordering (synchronous on the mutating
            // thread).
            let mainOnMain = useMain && isOnMainThread

            if tl.pendingObservationNotifications != nil {
                // Batched: the mutation has already happened by the time we drain the pending
                // list, so strict willSet-before-mutation is unreachable for either registrar.
                // Fire both as post-mutation bundles. Main goes through `mainCallQueue` which
                // runs inline if we drain on main, otherwise enqueues onto `@MainActor`.
                let callback = accessCallback()
                tl.pendingObservationNotifications!.append {
                    backgroundReg.willSet(observer, keyPath: observerKP)
                    backgroundReg.didSet(observer, keyPath: observerKP)
                    if useMain, let mainReg = self.mainObservationRegistrar {
                        self.mainCallQueue {
                            mainReg.willSet(observer, keyPath: observerKP)
                            mainReg.didSet(observer, keyPath: observerKP)
                        }
                    }
                }
                return callback
            } else {
                // Non-batched: emit willSet eagerly so background — and main when already on
                // main — see the strict pre-mutation notification. didSet fires after the
                // access callback has been captured and (on main) the queue drained — the
                // sequence a `defer` used to produce, written out inline so the
                // `_StateObserver<M._ModelState>: Observable` witness table and the registrar
                // metadata are resolved once per write rather than once here and again in
                // the defer's separate function.
                backgroundReg.willSet(observer, keyPath: observerKP)
                if mainOnMain {
                    unprotectedMainObservationRegistrar?.willSet(observer, keyPath: observerKP)
                }
                let callback = accessCallback()
                if mainOnMain {
                    // `drainIfOnMain` is a no-op off the main thread; skipping the call there
                    // saves its own `Thread.isMainThread` query.
                    mainCallQueue.drainIfOnMain()
                }
                backgroundReg.didSet(observer, keyPath: observerKP)
                if useMain, let mainReg = unprotectedMainObservationRegistrar {
                    if mainOnMain {
                        // Synchronous on the mutating (main) thread: matches strict ordering.
                        mainReg.didSet(observer, keyPath: observerKP)
                    } else {
                        // Off-main: bundle main `willSet/didSet` onto `@MainActor`.
                        mainCallQueue {
                            mainReg.willSet(observer, keyPath: observerKP)
                            mainReg.didSet(observer, keyPath: observerKP)
                        }
                    }
                }
                return callback
            }
        } else {
            let callback = accessCallback()
            if useMainThreadObservation, tl.pendingObservationNotifications == nil {
                mainCallQueue.drainIfOnMain()
            }
            return callback
        }
    }

    /// How a direct `_State` write completes. Decided under `lock` before the caller's
    /// mutation runs (`beginDirectWrite`) and acted on after it (`endDirectWrite`).
    enum DirectWriteMode {
        /// Live model: the value is written back and observers are notified.
        case live
        /// Destructed but not yet cleared: the value is written back, nobody is notified.
        case destructedSilent
        /// Destructed and cleared: the write is intentionally dropped.
        case dropped
    }

    /// What `beginDirectWrite` hands its caller for the duration of a direct write: the
    /// locks and scope it took, and how the write is to complete.
    ///
    /// The shape exists so that the write's yield happens in the *caller's* coroutine
    /// (`_ModelSourceBox`'s write `_modify`). The previous design had that `_modify` yield
    /// into a second `_modify` on `Context`, which cost every write:
    ///   • a second heap-allocated coroutine frame — a generic `_modify` cannot size its
    ///     frame statically, so each one is a `swift_coroFrameAlloc` (malloc + free; on the
    ///     current allocator the free alone includes a `mach_absolute_time` call);
    ///   • a heap-boxed closure for the sameness check — `isSame` had to cross a coroutine
    ///     boundary, and a closure argument to a coroutine is not stack-promoted even when
    ///     non-escaping, so the `Equatable` overload's `==` thunk (which captures `T`'s
    ///     witness table) was a `swift_allocObject` + `free` per write.
    /// With the caller yielding its own local there is one coroutine per write, and the
    /// `Equatable` overload compares with a direct `==`.
    ///
    /// Deliberately *not* generic over the property type: the value being written stays a
    /// plain local in the caller's frame. A first cut carried `value`/`oldValue` in a
    /// `Frame<T>`, and every unspecialised caller then instantiated that struct's metadata
    /// through the runtime's locked cache three times per write (its `init`, the `defer`
    /// borrowing it, the caller's copy) — a tenth of the write. Also why the `defer` that
    /// closes the write captures this `let` and nothing else: a `var` captured across a
    /// yield is boxed on the heap.
    struct DirectWriteScope {
        let writeLockHolder: ModelAccess?
        let tl: ThreadLocals
        let lhbcOwned: Bool
        let mode: DirectWriteMode
    }

    /// Opens a direct write: takes the access write lock, opens the `lockHeldBackgroundCalls`
    /// scope, takes `lock` and decides the `DirectWriteMode`. Returns with `lock` HELD. The
    /// caller then reads the current value out of `reference.state`, mutates a local copy
    /// (typically by yielding it) and calls `endDirectWrite` — and must
    /// `defer { closeDirectWrite(scope) }` right after this call so the outer lock and scope
    /// are released even if its access is abandoned mid-yield.
    ///
    /// The value round-trips through a local rather than being yielded straight out of
    /// `reference.state[keyPath: …]`: that would hold an *exclusive* dynamic borrow on
    /// `reference.state` for the whole of the user's mutation, and any access on
    /// `reference.state` from inside the expression — `m.x = m.y + 1`, or the
    /// optional-chained `m.x?.field = m.x.map { … }` pattern — would trip Swift's law of
    /// exclusivity with a fatal "Simultaneous accesses to 0x…, but modification requires
    /// exclusive access" trap. The copy ends the borrow before the yield; the write-back
    /// re-acquires it briefly for a single store.
    @inline(__always)
    func beginDirectWrite(accessBox: _ModelAccessBox) -> DirectWriteScope {
        // Lock-order inversion guard. The writer's `activeAccessCallback` (which
        // appends to `TestAccess.valueUpdates` and updates `lastState`) runs AFTER
        // `lock.unlock()` in `finishWrite`, and acquires `TestAccess.lock` at that time.
        // Readers (predicate evaluators) hold `TestAccess.lock` and then take
        // `context.lock` — opposite order. Without serialization the reader can
        // observe the new `reference.state` (after our `lock.unlock()`) before
        // `TestAccess.valueUpdates` has the corresponding entry, miss the entry in
        // its clearing pass, and leave it surviving to end-of-test exhaustion.
        // Taking the access's write lock BEFORE the context lock matches the
        // reader's order and closes the window. No-op when `activeAccess` is nil
        // (production) or a non-test `ModelAccess` (View/AccessCollector — they
        // don't queue state behind the reference write).
        //
        // The chain is resolved once here and carried in the scope: `finishWrite` reuses
        // it as the active access, so the two task-locals are read once per write.
        let writeLockHolder = ModelAccess.active ?? accessBox._reference?.access ?? ModelAccess.current
        writeLockHolder?.acquireWriteLock()
        // Defer `ObservationTracking.onObservedChange`'s `backgroundCallQueue(performUpdate)`
        // enqueue until AFTER this write's lock-held + postLockCallbacks phases finish.
        // See the helper definitions (`beginLockHeldBackgroundCallsScope` /
        // `endLockHeldBackgroundCallsScope`) and `ThreadLocals.lockHeldBackgroundCalls`
        // for the rationale on why an inline enqueue races against the writer's
        // own dedup decisions (shadow `onModify`'s `hasPendingUpdate` check vs
        // `performUpdate`'s clear).
        let tl = threadLocals
        let lhbcOwned = beginLockHeldBackgroundCallsScope(tl)
        lock.lock()
        let mode: DirectWriteMode
        if unprotectedIsDestructed {
            if reference._stateCleared {
                if !reference._hasGenesis {
                    reportIssue("Modifying a fully destructed model with no last-seen snapshot.")
                }
                mode = .dropped
            } else {
                mode = .destructedSilent
            }
        } else {
            mode = .live
        }
        return DirectWriteScope(writeLockHolder: writeLockHolder, tl: tl, lhbcOwned: lhbcOwned, mode: mode)
    }

    /// Completes a direct write opened by `beginDirectWrite`: writes `value` back (unless
    /// dropped), releases `lock`, and — for a live model whose value actually changed —
    /// notifies observers through `finishWrite`. `isSame` is the caller's verdict on `value`
    /// vs `oldValue` (`==` for `Equatable`, `false` when there is nothing to compare with);
    /// a same-value write releases the lock and notifies nobody, exactly as before.
    ///
    /// `oldValue` is pinned until this returns for the same reason the old `_modify` held it
    /// past the yield with `_fixLifetime`: its deinit must not run while `reference.state`
    /// is briefly held for the store.
    @inline(__always)
    func endDirectWrite<T>(_ scope: DirectWriteScope, statePath: WritableKeyPath<M._ModelState, T>, value: T, oldValue: T, isSame: Bool) {
        defer { _fixLifetime(oldValue) }
        switch scope.mode {
        case .dropped:
            // Already isolated from `reference.state`: nothing is written back.
            lock.unlock()
        case .destructedSilent:
            reference.state[keyPath: statePath] = value
            lock.unlock()
        case .live:
            reference.state[keyPath: statePath] = value
            if isSame {
                lock.unlock()
                return
            }
            finishWrite(statePath: statePath, activeAccess: scope.writeLockHolder, tl: scope.tl)
        }
    }

    /// Releases what `beginDirectWrite` took *outside* `lock`: the background-call scope
    /// (draining it) and the access write lock, in that order — the order the two `defer`s
    /// of the old `_modify` unwound in. Callers run this from a `defer` registered right
    /// after `beginDirectWrite`, so it also runs when the access is abandoned mid-yield;
    /// `lock` itself is released only by `endDirectWrite`, as before.
    @inline(__always)
    func closeDirectWrite(_ scope: DirectWriteScope) {
        endLockHeldBackgroundCallsScope(scope.tl, scope.lhbcOwned)
        scope.writeLockHolder?.releaseWriteLock()
    }

    /// Whole-value assignment of the property at `statePath` — the `set` accessor's
    /// counterpart to the caller-yielded `beginDirectWrite`/`endDirectWrite` pair. Plain
    /// assignment is the most common write in application code (`isLoading = true`) and
    /// never needs a yield, so it is a plain function: no coroutine, no frame allocation.
    /// `isSame` is non-escaping (a plain `(T, T) -> Bool`, never optional), so the
    /// `Equatable` overload's `==` costs no heap allocation here either.
    func setValue<T>(_ newValue: T, statePath: WritableKeyPath<M._ModelState, T>, isSame: (T, T) -> Bool, accessBox: _ModelAccessBox) {
        let scope = beginDirectWrite(accessBox: accessBox)
        defer { closeDirectWrite(scope) }
        let oldValue: T = reference.state[keyPath: statePath]
        endDirectWrite(scope, statePath: statePath, value: newValue, oldValue: oldValue, isSame: isSame(newValue, oldValue))
    }

    /// Coroutine form of the direct write, for a caller that cannot yield its own local.
    ///
    /// Used only by the parameter-pack (tuple property) overload of `_ModelSourceBox`'s
    /// write subscript: SILGen (Swift 6.3) crashes lowering the caller-owned form for a
    /// `(repeat each T)` value, so tuple properties keep yielding through here, where `T`
    /// is an ordinary generic parameter. This path still pays the second coroutine frame
    /// and the heap-boxed `isSame` closure that the scalar overloads no longer do; tuple
    /// properties are rare enough for that to be fine.
    subscript<T>(yieldingStatePath statePath: WritableKeyPath<M._ModelState, T>, isSame isSame: (T, T) -> Bool, accessBox accessBox: _ModelAccessBox) -> T {
        _read { fatalError() }
        _modify {
            let scope = beginDirectWrite(accessBox: accessBox)
            defer { closeDirectWrite(scope) }
            var value: T = reference.state[keyPath: statePath]
            let oldValue = value
            yield &value
            endDirectWrite(scope, statePath: statePath, value: value, oldValue: oldValue, isSame: isSame(value, oldValue))
        }
    }

    /// Shared tail of every direct `_State` write (`endDirectWrite` — behind both the
    /// caller-yielded `_modify` and `setValue` — and `stateTransaction`): bumps the
    /// modification count, fires the registrar and
    /// access notifications, builds the post-lock callbacks, releases `lock`, then runs
    /// the callbacks. Entered with `lock` held; returns with it released.
    ///
    /// `activeAccess` is the caller's resolved `ModelAccess.active ?? accessBox._reference?.access
    /// ?? ModelAccess.current` chain — the same value it took the write lock on — and `tl` its
    /// `threadLocals` handle, so the two task-locals and the TLS slot are each read once per write.
    private func finishWrite<T>(statePath: WritableKeyPath<M._ModelState, T>, activeAccess: ModelAccess?, tl: ThreadLocals) {
        didModify()
        let activeAccessCallback = invokeDidModifyDirect(statePath: statePath, activeAccess: activeAccess, tl: tl)
#if DEBUG
        let postLockCallbacks = buildPostLockCallbacksWithPropDesc(for: statePath, tl: tl)
#else
        let postLockCallbacks = buildPostLockCallbacks(for: statePath, tl: tl)
#endif
        lock.unlock()

        activeAccessCallback?()
        runPostLockCallbacks(postLockCallbacks)
    }

    /// Transaction-based modification using state paths and access box.
    func stateTransaction<Value, T>(at statePath: WritableKeyPath<M._ModelState, Value>, isSame: (Value, Value) -> Bool, accessBox: _ModelAccessBox, modify: (inout Value) throws -> T) rethrows -> T {
        // See the matching comment in `beginDirectWrite`.
        // Take the access's write lock BEFORE the context lock so we match the reader's
        // lock order (TestAccess.lock → context.lock) and writers don't race the
        // valueUpdates append against a concurrent predicate evaluation.
        let writeLockHolder = ModelAccess.active ?? accessBox._reference?.access ?? ModelAccess.current
        writeLockHolder?.acquireWriteLock()
        defer { writeLockHolder?.releaseWriteLock() }
        // Defer `ObservationTracking.onObservedChange` enqueues until this write's
        // lock-held + postLockCallbacks phases finish. See the helper definitions
        // (`beginLockHeldBackgroundCallsScope` / `endLockHeldBackgroundCallsScope`)
        // and `ThreadLocals.lockHeldBackgroundCalls` for rationale.
        let tl = threadLocals
        let lhbcOwned = beginLockHeldBackgroundCallsScope(tl)
        defer { endLockHeldBackgroundCallsScope(tl, lhbcOwned) }
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

            if isSame(value, oldValue) {
                lock.unlock()
                return result
            }

            finishWrite(statePath: statePath, activeAccess: writeLockHolder, tl: tl)
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
    private func buildPostLockCallbacksWithPropDesc<T>(for statePath: WritableKeyPath<M._ModelState, T>, tl: ThreadLocals) -> [() -> Void]? {
        let name: String? = usingActiveAccess(nil) {
            propertyName(from: _modelSeed, path: M._modelStateKeyPath.appending(path: statePath))
        }
        let desc: (@Sendable () -> String?)?
        if let name {
            desc = { name }
        } else {
            desc = nil
        }
        return buildPostLockCallbacks(for: statePath, propertyDescription: desc, tl: tl)
    }
#endif

    /// Builds the post-lock callbacks array for a property modification.
    /// Returns nil when there is nothing to do, avoiding the array allocation entirely.
    /// Must be called while the context lock is held.
    private func buildPostLockCallbacks(for path: PartialKeyPath<M._ModelState>, kind: ModificationKind = .properties, propertyDescription: (@Sendable () -> String?)? = nil, tl: ThreadLocals = threadLocals) -> [() -> Void]? {
        // Fast path: nothing to build when no observer of any kind is registered and we're
        // not inside a batched transaction. Checked in cost order — two plain loads first,
        // and the key-path hash (`modifyCallbacksStore[path]`) only once this context is
        // known to hold `onModify` callbacks. The previous `modifyCallbacks[path] != nil`
        // paid, on every observer-less write, for the `_read` accessor's `?? [:]` (a
        // `Dictionary.init(dictionaryLiteral:)` in unspecialised generic code, which
        // instantiates the `(key:value:)` tuple metadata through the runtime's locked
        // cache), a copy of the dictionary, the `Hashable` witness for
        // `PartialKeyPath<M._ModelState>`, and the structural hash of the key path itself.
        if anyModificationActiveCount == 0 && tl.postTransactions == nil {
            guard hasModifyCallbacks, modifyCallbacksStore?[path] != nil else {
                return nil
            }
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

    func transaction<T>(writeLockHolder: ModelAccess?, _ callback: () throws -> T) rethrows -> T {
        if reference.isDestructed {
            return try callback()
        }

        // Defer `ObservationTracking.onObservedChange` enqueues until the entire
        // transaction (lock-held callback + post-transaction defer drain + outer
        // postLockCallbacks) has completed. See `ThreadLocals.lockHeldBackgroundCalls`
        // for why this matters — without it, `performUpdate` (queued during the
        // transaction's defer drain) can start running on the cooperative pool
        // and clear `hasPendingUpdate` while the outer postLockCallbacks (which
        // include shadow `onObservedChange` invocations on the WOT path) are still
        // running, causing those shadow callbacks to schedule duplicate
        // performUpdates against the just-cleared flag.
        //
        // This defer is registered FIRST so it runs LAST (LIFO) — after
        // `runPostLockCallbacks` below, ensuring all observation dedup decisions
        // have completed before any `performUpdate` is enqueued.
        let tl = threadLocals
        let lhbcOwned = beginLockHeldBackgroundCallsScope(tl)
        defer { endLockHeldBackgroundCallsScope(tl, lhbcOwned) }

        var postLockCallbacks: [() -> Void] = []
        defer {
            runPostLockCallbacks(postLockCallbacks)
        }

        // Lock-order inversion guard — same shape as the one in
        // `beginDirectWrite` and
        // `stateTransaction` (line ~1058). Acquire `TestAccess.lock` BEFORE
        // `context.lock` to match the reader's order.
        //
        // Without this guard, a deadlock pattern exists:
        //   Thread A: enters this `transaction`, takes `lock` (context.lock),
        //     inside `callback` does a property write which goes through
        //     `stateTransaction` and tries to take `TestAccess.lock` while
        //     still holding `context.lock` — chain `context → TestAccess`.
        //   Thread B: enters `subscript._modify` (a regular property write),
        //     takes `TestAccess.lock` then tries `context.lock` — the
        //     documented `TestAccess → context` order.
        // Cross those threads and you have the classic inversion.
        //
        // CRITICAL: `writeLockHolder` MUST be computed by the caller using
        // the SAME chain that `stateTransaction` will use inside the
        // callback — `ModelAccess.active ?? accessBox._reference?.access ??
        // ModelAccess.current`. Otherwise this method holds one `TestAccess`
        // instance's lock while the nested `stateTransaction` picks a
        // different one (when stamped access differs from `ModelAccess.current`),
        // re-introducing the same inversion via two distinct `NSRecursiveLock`s
        // — `NSRecursiveLock` allows re-entry only on identity, not "any
        // TestAccess".
        //
        // The first fix attempt (commit fa4fdea) used
        // `ModelAccess.active ?? ModelAccess.current` here, which dropped
        // the `accessBox._reference?.access` middle term and re-introduced
        // the deadlock in `testChangeOfChildConcurrency` on the very next
        // x1000 stress run. Threading the chain through the caller (which
        // has the accessBox) closes that gap.
        writeLockHolder?.acquireWriteLock()
        defer { writeLockHolder?.releaseWriteLock() }

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
    // MutableCollection whose elements are Model & Identifiable. ModelRef uses the element's
    // Identifiable `id` as the registry key — the outer `containerPath` dict key already
    // distinguishes collections, so `id` alone disambiguates elements within a bucket.
    //
    // NOTE on `id`: this is the element's *Identifiable* `id`, NOT necessarily the per-instance
    // `modelID`. For a default-`id` @Model the two coincide; a @Model that declares an explicit
    // `id` shadows the default, so the key is that domain id. This is deliberate: `id` is the
    // stable-identity slot key (the ForEach / IdentifiedArray model), so replacing an element with
    // a NEW instance carrying an existing `id` CONTINUES the live child — its context, activation,
    // tasks and state are preserved and the new instance's birth state is intentionally ignored
    // (to change a child, mutate it; do not replace it). The required contract is the standard
    // Identifiable one: `id` must be UNIQUE WITHIN THIS COLLECTION at any instant — two distinct
    // instances sharing an `id` in one collection are conflated onto a single context. See
    // ExplicitIdReplacementTests for the full characterization.

    /// Creates or retrieves the child context for a `MutableCollection` element,
    /// using `ModelRef(id: childModel.id)` as the registry key.
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
                threadLocals.didReplaceModelWithDestructedOrFrozenCopy = true
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
    // The inner child Model's context is stored under `children[collectionPath]` using
    // `ModelRef(id: childModel.id)` (the inner Model's Identifiable id) as the registry key, with a
    // constant `elementPath`, so no per-element cursor key path is needed — eliminating the 3 heap
    // allocations that cursor construction would otherwise require before every registry lookup.
    // As with `childContextForCollection`, `id` is the Identifiable id (== modelID only for a
    // default-`id` @Model); see the stable-identity contract note there.

    /// Creates or retrieves the child context for a `Model` child inside a `ModelContainer`
    /// element of a `MutableCollection` that is not itself `ModelContainer`.
    ///
    /// Uses `ModelRef(id: childModel.id)` as the registry key with a constant `elementPath`, so no
    /// cursor key path is needed to disambiguate elements. This eliminates the 3 cursor allocations
    /// that would otherwise be required before every registry lookup. `id` is the element's
    /// Identifiable id — see the stable-identity contract note above `childContextForCollection`.
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
            let id = threadLocals.withForceDirectAccess { element.id }

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
    @usableFromInline
    final class Reference: @unchecked Sendable {
        let modelID: ModelID
        private let lock = NSRecursiveLock()
        private weak var _context: Context<M>?
        /// Strong reference to the live context's hierarchy lock, maintained in exact
        /// lockstep with `_context` (set in `setContext`, cleared in
        /// `clearStateForGeneration` — the only two sites that touch `_context`).
        ///
        /// `_context` has to stay `weak`: the Context holds this Reference strongly, so a
        /// strong back-reference would be a retain cycle and no Context would ever deinit.
        /// The hierarchy lock is a *leaf* object though — an `NSRecursiveLock` references
        /// nothing — so holding it strongly is cycle-free while giving
        /// `withHierarchyLockIfLive` the one thing it actually needs. That skips the weak
        /// load (side-table traffic, ~40 ns measured in Release) on every read that routes
        /// through the `dynamicMember` getter, which is the O(N) per-element cost during
        /// collection reconciliation.
        ///
        /// Non-nil exactly when `_context` is non-nil, so `withHierarchyLockIfLive` locks
        /// under precisely the same condition as before.
        private var _hierarchyLock: NSRecursiveLock?
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
        /// Backing storage for `state`. Allocated once per Reference and initialised either in
        /// `init` (an explicit state, or a construction frame that is already complete) or by
        /// `_materializeState()` once the last required property has been assigned.
        ///
        /// A raw pointer rather than an `Optional` so the `state` accessors can yield the value
        /// *in place* (`pointee` is an addressor): every keypath projection on the read path
        /// borrows the struct without copying it, exactly as the former stored property did.
        /// `Optional` storage would turn each `state[keyPath:]` into a whole-struct copy.
        private let _stateStorage: UnsafeMutablePointer<M._ModelState> = .allocate(capacity: 1)
        /// True once `_stateStorage` holds a fully built value. False only while a user-written
        /// `init` body is still assigning properties that have no default value (see `_pending`).
        ///
        /// Read without the lock on the hot path. That is sound because the flag flips exactly
        /// once, under the lock, and — in every well-formed flow — *inside* the constructing
        /// `init` body: the last required assignment materialises synchronously, before the
        /// model value can escape to another thread. A Reference that never materialises (an
        /// init that skipped a required property) traps on first whole-state use regardless
        /// of which thread gets there first.
        private(set) var _hasMaterializedState: Bool
        /// The construction frame, kept until every required property has been assigned.
        /// Properties are read and written through it in the meantime (`_readPending`,
        /// `_pendingBox`, `_writeDirect`). Nil once materialised.
        private var _pending: PendingStorage<M._ModelState>?
        /// The macro-generated `_makeState`: builds `_State` from `_pending`, or returns nil
        /// (recording the missing key path on the frame) while a required property is unassigned.
        private var _factory: ((PendingStorage<M._ModelState>) -> M._ModelState?)?

        /// Live/lastSeen/snapshot state. After `clear()`, replaced with genesis state to release
        /// live-model references.
        ///
        /// Whole-state access on an unmaterialised Reference materialises it first, trapping
        /// with the property name if a required property was never assigned — the model is
        /// being anchored, copied, or read as a whole before its `init` finished the job.
        @usableFromInline var state: M._ModelState {
            _read {
                if !_hasMaterializedState { _materializeState() }
                yield _stateStorage.pointee
            }
            set {
                if _hasMaterializedState {
                    _stateStorage.pointee = newValue
                } else {
                    _adoptState(newValue)
                }
            }
            _modify {
                if !_hasMaterializedState { _materializeState() }
                yield &_stateStorage.pointee
            }
        }
        /// True after `clear()`. Reads from a cleared reference will reportIssue and
        /// return a genesis fallback.
        @usableFromInline var _stateCleared: Bool = false
        /// Genesis state captured at the first `setContext` call (post-`withContextAdded`).
        /// All property values are correct at that point (no self-referencing closures yet).
        /// Used to restore `state` when re-anchoring a static dependency model, and as a
        /// safe fallback for reads on a cleared reference. Falls back to `state` until
        /// captured (never read before `_hasGenesis = true` in practice).
        private var _genesisStorage: M._ModelState?
        @usableFromInline var _genesisState: M._ModelState {
            get { _genesisStorage ?? state }
            set { _genesisStorage = newValue }
        }
        /// True once genesis has been captured (set in `setContext` on first anchor).
        @usableFromInline var _hasGenesis: Bool = false
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
            _stateStorage.initialize(to: state)
            _hasMaterializedState = true
            self._snapshotLifetime = nil
        }

        /// Creates a live Reference from a construction frame. Builds `state` immediately when
        /// the frame is complete (memberwise init, or a user-written init whose every tracked
        /// property has a default); otherwise keeps the frame and lets the init body's
        /// assignments complete it — see `_writeDirect`. No placeholder value is ever
        /// fabricated for an unassigned property: there is no bit pattern that is valid for
        /// every type (an all-zero existential, for one, crashes on its first copy).
        init(modelID: ModelID, pending: PendingStorage<M._ModelState>, factory: @escaping (PendingStorage<M._ModelState>) -> M._ModelState?) {
            self.modelID = modelID
            self._snapshotLifetime = nil
            if let built = factory(pending) {
                _stateStorage.initialize(to: built)
                _hasMaterializedState = true
            } else {
                _hasMaterializedState = false
                _pending = pending
                _factory = factory
            }
        }

        /// Creates a snapshot Reference (frozen or lastSeen) with independent state.
        init(modelID: ModelID, state: M._ModelState, lifetime: ModelLifetime) {
            self.modelID = modelID
            _stateStorage.initialize(to: state)
            _hasMaterializedState = true
            self._snapshotLifetime = lifetime
        }

        deinit {
            if _hasMaterializedState {
                _stateStorage.deinitialize(count: 1)
            }
            _stateStorage.deallocate()
        }

        // MARK: Construction frame (pre-materialisation)

        /// Installs a fully built state. Must be called with the lock held or from `init`.
        private func _installState(_ built: M._ModelState) {
            _stateStorage.initialize(to: built)
            _hasMaterializedState = true
            _pending = nil
            _factory = nil
        }

        /// Whole-state assignment on an unmaterialised Reference: the value *is* the state.
        private func _adoptState(_ built: M._ModelState) {
            lock.lock()
            defer { lock.unlock() }
            if _hasMaterializedState {
                _stateStorage.pointee = built
            } else {
                _installState(built)
            }
        }

        /// Builds `state` from the construction frame. Reached by any whole-state access
        /// (anchoring, `frozenCopy`, `_modelState`, a keypath projection through `state`)
        /// that arrives before the init body has assigned every required property — which
        /// means the model escaped its `init` incomplete, so this traps naming the property.
        private func _materializeState() {
            lock.lock()
            defer { lock.unlock() }
            guard !_hasMaterializedState else { return }
            guard let pending = _pending, let factory = _factory else {
                preconditionFailure("SwiftModel: Reference has neither state nor a construction frame — this is a bug in SwiftModel.")
            }
            guard let built = factory(pending) else {
                fatalError(pending.neverAssignedMessage(modelType: M.self))
            }
            _installState(built)
        }

        /// Reads `path` from the construction frame (or from `state` once materialised).
        /// Traps naming the property if it has not been assigned yet — reading a property
        /// in an init body before assigning it.
        func _readPending<T>(_ path: WritableKeyPath<M._ModelState, T>) -> T {
            lock.lock()
            defer { lock.unlock() }
            if _hasMaterializedState {
                return _stateStorage.pointee[keyPath: path]
            }
            guard let pending = _pending else {
                preconditionFailure("SwiftModel: Reference has neither state nor a construction frame — this is a bug in SwiftModel.")
            }
            return pending.value(for: path, modelType: M.self)
        }

        /// The frame's box for `path`, so an in-place mutation (`_modify`) in an init body can
        /// yield straight into the frame. Traps naming the property if it has not been assigned.
        func _pendingBox<T>(_ path: WritableKeyPath<M._ModelState, T>) -> TypedPendingValue<T> {
            lock.lock()
            defer { lock.unlock() }
            guard let pending = _pending, let box = pending.box(for: path) else {
                fatalError(PendingStorage<M._ModelState>.neverAssignedMessage(for: path, modelType: M.self))
            }
            return box
        }

        /// Pre-anchor write. Into `state` when materialised; otherwise into the construction
        /// frame — and, if that assignment completed the frame, materialises `state` right
        /// here, synchronously, inside the init body that made it.
        func _writeDirect<T>(_ path: WritableKeyPath<M._ModelState, T>, _ value: T) {
            lock.lock()
            defer { lock.unlock() }
            if _hasMaterializedState {
                _stateStorage.pointee[keyPath: path] = value
                return
            }
            guard let pending = _pending, let factory = _factory else {
                preconditionFailure("SwiftModel: Reference has neither state nor a construction frame — this is a bug in SwiftModel.")
            }
            pending.store(path, value)
            if let built = factory(pending) {
                _installState(built)
            }
        }

        var lifetime: ModelLifetime {
            if let _snapshotLifetime { return _snapshotLifetime }
            return context?.lifetime ?? lock {
                _isDestructed ? .destructed : .initial
            }
        }

        @usableFromInline
        var context: Context<M>? {
            // Explicit lock()/unlock() rather than `lock { _context }`: the latter routes
            // through `NSLocking.callAsFunction` → Foundation's non-inlinable generic
            // `withLock<R>`, adding a call plus a reabstraction thunk to what is the
            // single hottest resolution on every read path.
            lock.lock()
            defer { lock.unlock() }
            return _context
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
        /// cycles after the last-seen TTL expires. Genesis is the pre-anchor state (no live
        /// child contexts) and always a valid value — a zero-filled placeholder is not, for
        /// any type carrying a class reference (e.g. SwiftUI.ScrollPosition) or an existential.
        /// If no genesis was captured the model was never anchored, so there are no retain
        /// cycles to break.
        /// `_context` is intentionally NOT cleared here — that happens in `clearStateForGeneration`
        /// (called from Context.deinit). Clearing `_context` here would make `ModelNode.isDestructed`
        /// return `true` before `onCancel` callbacks fire, causing dependency lookups to fall
        /// through to the live default instead of the test override.
        ///
        /// Must be called while the caller holds the AnyContext lock (lock order:
        /// AnyContext.lock → Reference.lock). This prevents a concurrent `Context.subscript._read`
        /// (which holds AnyContext.lock) from racing on `reference.state` while we swap it.
        /// Returns the old state for deferred release after both locks are dropped — deinits
        /// triggered by the release may re-enter AnyContext.lock, so they must not run while
        /// either lock is held.
        ///
        /// Generation-guarded: `clear` fires long after removal (the last-seen TTL task
        /// sleeps ~2 s; the non-TTL path runs from the deferred teardown-callbacks array).
        /// If this Reference has been re-anchored in the meantime (`setContext` bumped
        /// `_generation` — an undo-driven re-anchor, or a static `testValue` dependency
        /// claimed by the next test), clearing now would wipe the NEW hierarchy's live
        /// state — and race its writers, which operate under a *different* hierarchy lock
        /// than the stale caller holds. Returns nil (no-op) when outdated; `Context.deinit`'s
        /// `clearStateForGeneration` applies the same discipline.
        func clear(ifGeneration generation: Int) -> M._ModelState? {
            lock {
                guard generation == _generation else { return nil }
                _stateCleared = true
                let old = state
                if _hasGenesis {
                    state = _genesisState
                }
                return old
            }
        }

        /// Runs `body` under the live hierarchy lock when one exists, so reads of
        /// `state` / `_stateCleared` synchronize with concurrent locked writers
        /// (property writes hold the hierarchy lock; `clear` holds it plus this
        /// Reference's lock). For read paths reached OUTSIDE any locked scope —
        /// deep-access visitors walking a value copy after `subscript.read`'s lock
        /// scope ended, frozen/lastSeen whole-state copies — the raw read can tear
        /// against a concurrent collection-write clearing a removed child
        /// (TSan-confirmed). With no live context there is no locked concurrent
        /// writer left to race: pre-anchor construction is thread-confined,
        /// snapshot state is immutable, and both deferred `clear(ifGeneration:)`
        /// paths run while the old context (and thus a discoverable lock) is
        /// still alive.
        ///
        /// Lock-order note: the `_hierarchyLock` read takes and releases `Reference.lock`
        /// BEFORE the hierarchy lock is acquired — no held-across violation of the
        /// AnyContext.lock → Reference.lock convention.
        ///
        /// PERF: this is the per-read cost of the locked `dynamicMember` projection, paid
        /// O(N) times during collection reconciliation, so it is written for cost rather
        /// than for brevity:
        /// - it reads `_hierarchyLock` (a strong `let`-shaped leaf object) instead of the
        ///   `context` weak var, skipping `swift_weakLoadStrong`'s side-table traffic;
        /// - it takes the locks with explicit `lock()` / `unlock()` rather than
        ///   `NSLocking.callAsFunction`, whose underlying `withLock<R>` is a
        ///   non-inlinable generic in Foundation — a real call plus a reabstraction
        ///   thunk on every read.
        ///
        /// Both are pure call-shape changes; the locking discipline is byte-for-byte the
        /// one PR #50 established.
        func withHierarchyLockIfLive<R>(_ body: () -> R) -> R {
            lock.lock()
            let hierarchyLock = _hierarchyLock
            lock.unlock()

            guard let hierarchyLock else { return body() }

            hierarchyLock.lock()
            defer { hierarchyLock.unlock() }
            return body()
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
                _hierarchyLock = context.lock
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
                    _hierarchyLock = nil // Kept in lockstep with `_context` — see its doc comment.
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

/// Begin a `lockHeldBackgroundCalls` scope on the current thread. Returns `true`
/// if the scope was newly opened (caller owns the drain); `false` if a scope was
/// already open (caller is nested — the outer caller will drain).
///
/// Paired with `endLockHeldBackgroundCallsScope`. See `ThreadLocals.lockHeldBackgroundCalls`
/// and `ThreadLocals.isLockHeldBackgroundCallsScopeOpen` for rationale. Takes the
/// caller's `threadLocals` handle so a write resolves the TLS slot once.
func beginLockHeldBackgroundCallsScope(_ tl: ThreadLocals) -> Bool {
    if tl.isLockHeldBackgroundCallsScopeOpen { return false }
    tl.isLockHeldBackgroundCallsScopeOpen = true
    return true
}

/// Close a `lockHeldBackgroundCalls` scope opened by `beginLockHeldBackgroundCallsScope`.
/// If `owned` is `true`, closes the scope and drains the accumulated calls (if any) on
/// the current thread. If `false`, this is a no-op (the nested caller's outer scope will
/// drain). The scope is closed *before* the drain, so a call that itself reaches
/// `onObservedChange` enqueues inline rather than into a scope that is being torn down.
func endLockHeldBackgroundCallsScope(_ tl: ThreadLocals, _ owned: Bool) {
    guard owned else { return }
    tl.isLockHeldBackgroundCallsScopeOpen = false
    guard let calls = tl.lockHeldBackgroundCalls else { return }
    tl.lockHeldBackgroundCalls = nil
    for f in calls { f() }
}

