import Foundation

extension ModelContainer {
    func visit<V: ModelVisitor>(with visitor: inout V, includeSelf: Bool) where V.State == Self {
        var containerVisitor = ContainerVisitor<V>(modelVisitor: visitor)
        if includeSelf {
            containerVisitor.visitDynamically(with: self, at: \.self)
        } else {
            visit(with: &containerVisitor)
        }
        visitor = containerVisitor.modelVisitor
    }

    var frozenCopy: Self {
        transformModel(with: FrozenCopyTransformer())
    }

    var initialCopy: Self {
        transformModel(with: MakeInitialTransformer())
    }

    var initialDependencyCopy: Self {
        transformModel(with: MakeInitialDependencyCopyTransformer())
    }

    func lastSeen(at timestamp: Date, dependencyCache: [AnyHashable: Any]) -> Self {
        transformModel(with: LastSeenTransformer(lastSeenAccess: LastSeenAccess(timestamp: timestamp, dependencyCache: dependencyCache)))
    }

    func reduceValue<Reducer: ValueReducer>(with reducer: Reducer.Type, initialValue: Reducer.Value) -> Reducer.Value {
        var visitor = ReduceValueVisitor(root: self, path: \.self, reducer: reducer, value: initialValue)
        visit(with: &visitor, includeSelf: true)
        return visitor.value
    }

    func transformModel<Transformer: ModelTransformer>(with transformer: Transformer) -> Self {
        var visitor = ModelTransformerVisitor(root: self, path: \.self, transformer: transformer)
        visit(with: &visitor, includeSelf: true)
        return visitor.root
    }

    var isAllInitial: Bool {
        reduceValue(with: InitialReducer.self, initialValue: true)
    }

    func withDeepAccess(_ access: ModelAccess?) -> Self {
        transformModel(with: WithAccessTransformer(access: access))
    }
}

private struct MakeInitialTransformer: ModelTransformer {
    func transform<M: Model>(_ model: inout M) -> Void {
        let src = model.modelContext._source
        if src._isLive {
            // Already a live/internal direct-access copy — no change needed.
            return
        }
        let ref = src.reference
        if ref.isSnapshot || ref.context != nil {
            // Snapshot or anchored model: copy state into a fresh Reference so the copy is
            // independent of the original — the original's state is zeroed after TTL,
            // which would otherwise corrupt any undo baseline that shares the same Reference.
            guard !ref._stateCleared else { return }
            let newRef = Context<M>.Reference(modelID: ref.modelID, state: ref.state)
            var mc = model.modelContext
            mc._source = _ModelSourceBox(reference: newRef)
            model.modelContext = mc
        } else {
            // Pre-anchor model: transition to live so internal reads bypass context routing.
            // All pre-anchor copies share the same Reference. After Context.init calls setContext,
            // those copies automatically route to the context via ref._context.
            var mc = model.modelContext
            mc._source._transitionToLive()
            model.modelContext = mc
        }
    }
}

private struct MakeInitialDependencyCopyTransformer: ModelTransformer {
    func transform<M: Model>(_ model: inout M) -> Void {
        // Capture the original reference BEFORE shallowCopy may convert an anchored model
        // to a frozen snapshot. shallowCopy creates a brand-new Reference with no genesis,
        // losing the original's _genesisState. We need the original to recover genesis.
        // For pre-anchor models, shallowCopy returns self unchanged, so originalRef === srcRef.
        let originalRef = model.modelContext._source.reference
        model = model.shallowCopy
        // Create a fresh Reference with a new identity and copy state from the frozen copy.
        // Without state, Context.init's `hasState` assertion would fire when anchoring this copy.
        let srcRef = model.modelContext._source.reference
        // Prefer genesis state when available — matching reserveOrFork() — so that a fresh
        // dependency copy always starts from the clean initial state, not from mutations
        // made by a concurrently-running test that has the same static `testValue` anchored.
        // Use originalRef for genesis since shallowCopy may have replaced srcRef with a
        // frozen snapshot reference that has no _hasGenesis/_genesisState of its own.
        // If state has been cleared post-TTL but genesis was captured, genesis is also used.
        // If neither live state nor genesis is available, bail out and leave model.context
        // intact; setupModelDependency guards against this residual non-nil context.
        let genesisRef = originalRef._hasGenesis ? originalRef : srcRef
        guard !srcRef._stateCleared || genesisRef._hasGenesis else { return }
        let sourceState = genesisRef._hasGenesis ? genesisRef._genesisState : srcRef.state
        let newRef = Context<M>.Reference(modelID: .generate(), state: sourceState)
        if genesisRef._hasGenesis {
            newRef._genesisState = genesisRef._genesisState
            newRef._hasGenesis = true
        }
        model.modelContext.setReference(newRef)
    }
}

private struct FrozenCopyTransformer: ModelTransformer {
    func transform<M: Model>(_ model: inout M) -> Void {
        model = model.shallowCopy.noAccess
        model.modelContext.makeFrozen(id: model.modelID)
    }
}

private struct LastSeenTransformer: ModelTransformer {
    let lastSeenAccess: LastSeenAccess

    func transform<M: Model>(_ model: inout M) -> Void {
        model = model.shallowCopy.withAccess(lastSeenAccess)
        model.modelContext.makeLastSeen(id: model.modelID)
    }
}

final class LastSeenAccess: ModelAccess, @unchecked Sendable {
    let timestamp: Date
    let dependencyCache: [AnyHashable: Any]

    init(timestamp: Date, dependencyCache: [AnyHashable: Any]) {
        self.timestamp = timestamp
        self.dependencyCache = dependencyCache
        super.init(useWeakReference: false)
    }
}

private struct WithAccessTransformer: ModelTransformer {
    let access: ModelAccess?
    func transform<M: Model>(_ model: inout M) -> Void {
        model.modelContext.access = access
    }
}

private struct InitialReducer: ValueReducer {
    static func reduce<M: Model>(value: inout Bool, model: M) -> Void {
        value = value && model.isInitial
    }
}

func copy<T>(_ value: T, shouldFreeze: Bool) -> T {
    if shouldFreeze, let models = value as? any ModelContainer {
        return models.frozenCopy as! T
    } else {
        return value
    }
}

func frozenCopy<T>(_ value: T) -> T {
    copy(value, shouldFreeze: true)
}

struct ContainerCursor<ID: Hashable, Root, Value>: Hashable, @unchecked Sendable {
    let id: ID
    let get: @Sendable (Root) -> Value
    let set: @Sendable (inout Root, Value) -> Void

    init(id: ID, get: @escaping @Sendable (Root) -> Value, set: @escaping @Sendable (inout Root, Value) -> Void) {
        self.id = id
        self.get = get
        self.set = set
    }

    static func == (lhs: ContainerCursor, rhs: ContainerCursor) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ModelContainer {
    subscript<ID: Hashable, Value>(cursor cursor: ContainerCursor<ID, Self, Value>) -> Value {
        get {
            threadLocals.withValue(true, at: \.forceDirectAccess) {
                cursor.get(self)
            }
        }
        set {
            threadLocals.withValue(true, at: \.forceDirectAccess) {
                cursor.set(&self, newValue)
            }
        }
    }
}

/// Cursor subscript for `MutableCollection` types that do not conform to `ModelContainer`.
///
/// Enables cursor-keyed `WritableKeyPath` construction (`\C.[cursor: cursor]`) for
/// non-`ModelContainer` MutableCollections — e.g. `IdentifiedArray<Path>` where `Path` is
/// a `@ModelContainer` enum. Used internally by `visitContainerCollection` and
/// `updateContextForContainerCollection` to build per-element paths without requiring the
/// collection itself to be a `ModelContainer`.
///
/// `@_disfavoredOverload` ensures that for types satisfying both this extension and
/// `ModelContainer` (e.g. `Array<Path>`), the `ModelContainer.subscript(cursor:)` wins.
extension MutableCollection where Self: Sendable, Element: Identifiable & Sendable, Index: Sendable, Element.ID: Sendable {
    @_disfavoredOverload
    subscript<ID: Hashable, Value>(cursor cursor: ContainerCursor<ID, Self, Value>) -> Value {
        get {
            threadLocals.withValue(true, at: \.forceDirectAccess) {
                cursor.get(self)
            }
        }
        set {
            threadLocals.withValue(true, at: \.forceDirectAccess) {
                cursor.set(&self, newValue)
            }
        }
    }
}

struct CaseAndID<ID: Hashable>: Hashable {
    var caseName: String
    var id: ID
}

func anyHashable(from value: Any) -> AnyHashable {
    (value as? any Identifiable)?.anyHashable ?? AnyHashable(ObjectIdentifier(Any.self))
}

extension Identifiable {
    var anyHashable: AnyHashable { AnyHashable(id) }
}

protocol OptionalModel { }

extension Optional: OptionalModel where Wrapped: Model {}

