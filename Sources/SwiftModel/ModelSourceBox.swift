import Foundation
import Dependencies
import IssueReporting

// MARK: - _ModelAccessBox

/// Public opaque wrapper for the model's observation/visitor access reference.
///
/// 8 bytes (Optional class reference). Holds a `ModelAccessReference` after anchoring,
/// `nil` before. No pending storage — init-accessor values are stored in a thread-local
/// `PendingStorage` that is popped by `_$modelSource`'s default value.
public struct _ModelAccessBox: @unchecked Sendable {
    var _reference: ModelAccessReference?

    public init() { _reference = nil }
    init(_reference: ModelAccessReference?) { self._reference = _reference }
}

// MARK: - Storage classes

/// Transient storage for accumulating property values during `@Model` struct init.
///
/// Keyed by `AnyKeyPath` (concrete type is `WritableKeyPath<State, V>`). Values are
/// boxed in `TypedPendingValue<V>` to safely handle nil Optionals and function types.
///
/// Public because macro-generated `_makeState` factories reference `PendingStorage`
/// in their parameter type.
public final class PendingStorage<State>: @unchecked Sendable {
    var storage: [AnyKeyPath: PendingValue] = [:]
    let pendingID: ModelID = .generate()

    public func value<V>(for path: WritableKeyPath<State, V>) -> V {
        guard let entry = storage[path] as? TypedPendingValue<V> else {
            fatalError(
                "@Model: property '\(path)' was never assigned during init. " +
                "Assign a value before anchoring the model."
            )
        }
        return entry.value
    }

    public func value<V>(for path: WritableKeyPath<State, V>, default defaultValue: @autoclosure () -> V) -> V {
        guard let entry = storage[path] as? TypedPendingValue<V> else {
            return defaultValue()
        }
        return entry.value
    }

    func store<V>(_ path: WritableKeyPath<State, V>, _ value: V) {
        storage[path] = TypedPendingValue(value)
    }
}

// MARK: - Internal pending-value box

/// Type-erased base for a single pending property value.
class PendingValue: @unchecked Sendable {
    fileprivate init() {}
}

/// Typed subclass that preserves the concrete type `V`.
final class TypedPendingValue<V>: PendingValue, @unchecked Sendable {
    let value: V
    init(_ v: V) { value = v; super.init() }
}

// (SourceKind enum removed in Phase 3 — replaced by _ModelSourceBox.reference + _isLive)
// (_StateHolder removed in Phase 4 — replaced by non-optional Reference.state + _stateCleared)

// MARK: - _ModelSourceBox

// MARK: - _StateObserver

/// Zero-size Observable wrapper for `_State` keypaths.
///
/// `ObservationRegistrar.access/willSet/didSet` require `Subject: Observable`.
/// `_State` itself can't conform to `Observable` (iOS 17+ availability vs iOS 14+ struct).
/// This wrapper provides an Observable subject type with `@dynamicMemberLookup` so that
/// `\_StateObserver<_State>.count` is a valid keypath for registrar calls.
///
/// The subscripts are never called — only used for keypath construction. With the shared
/// tree registrar (one `ObservationRegistrar` pair for the whole model hierarchy), per-instance
/// and per-property identity is encoded in the keypath subscript arguments so that each
/// `(registrar, keyPath)` pair is unique, preserving fine-grained observation semantics.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
struct _StateObserver<State>: Observable, Sendable {
    /// Per-instance + per-property subscript for direct state paths.
    /// Arguments are raw pointer values (`ObjectIdentifier.rawValue`) so that UInt arguments
    /// hash as trivial single integers — much cheaper than a compound `(ModelID, WritableKeyPath)`
    /// key where the WritableKeyPath itself is a nested subscript argument.
    /// Never called — used only for keypath construction.
    subscript(contextID _: UInt, propID _: UInt) -> AnyHashable { fatalError() }

    /// Synthetic subscripts for non-`_State` observation paths.
    /// `modelID` is included so that a single shared registrar can distinguish
    /// observations from different context instances of the same type.
    /// Never called — used only for keypath construction.
    subscript(environmentKey _: AnyHashableSendable, modelID _: ModelID) -> AnyHashableSendable { fatalError() }
    subscript(preferenceKey _: AnyHashableSendable, modelID _: ModelID) -> AnyHashableSendable { fatalError() }
    subscript(_parentsObservationKey _: _ParentsObservationKey, modelID _: ModelID) -> [ModelID] { fatalError() }
    subscript(memoizeKey _: AnyHashableSendable, modelID _: ModelID) -> AnyHashableSendable { fatalError() }
}

// MARK: - _stateObserverKPCache

/// Process-wide cache: `(contextID, propID)` → `_StateObserver`-subscript KP for registrar calls.
///
/// `\_StateObserver<M._ModelState>[contextID: contextID, propID: propID]` allocates a new heap
/// `KeyPath` object on every call via `_swift_getKeyPath` (~1.7 μs). Since both IDs are stable
/// for the lifetime of the context, caching by the compound `(contextID, propID)` pair eliminates
/// the per-call allocation. One write per (property, model-instance) pair per process lifetime;
/// all subsequent accesses are cache hits.
///
/// Cache size: O(instances × properties). For typical apps (dozens to hundreds of live instances,
/// a handful of properties each) this is bounded and small. Entries are never evicted — the per-
/// entry overhead is negligible.
///
/// `LockIsolated` cannot be used here because its `withValue` closure is `@Sendable`, which
/// requires the return type to be provably `Sendable`. `KeyPath<_StateObserver<State>, AnyHashable>`
/// cannot be proven `Sendable` under Swift 6 strict concurrency.
/// `@unchecked Sendable` is safe: the lock ensures mutual exclusion for all cache mutations.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
private struct _StateObserverKPKey: Hashable, Sendable {
    let contextID: UInt  // UInt(bitPattern: ObjectIdentifier(context))
    let propID: UInt     // UInt(bitPattern: ObjectIdentifier(statePath as AnyKeyPath))
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
private final class _StateObserverKPCacheStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var cache = [_StateObserverKPKey: AnyObject]()

    func getOrInsert<State>(
        _ key: _StateObserverKPKey,
        make: () -> KeyPath<_StateObserver<State>, AnyHashable>
    ) -> KeyPath<_StateObserver<State>, AnyHashable> {
        lock {
            if let cached = cache[key] as? KeyPath<_StateObserver<State>, AnyHashable> { return cached }
            let kp = make()
            cache[key] = kp
            return kp
        }
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
private let _stateObserverKPCacheStorage = _StateObserverKPCacheStorage()

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
func _cachedStateObserverKP<State>(
    contextID: UInt,
    propID: UInt,
    make: () -> KeyPath<_StateObserver<State>, AnyHashable>
) -> KeyPath<_StateObserver<State>, AnyHashable> {
    _stateObserverKPCacheStorage.getOrInsert(_StateObserverKPKey(contextID: contextID, propID: propID), make: make)
}

// MARK: - _ModelStateType

/// Default `_ModelState` for `Model` types without any tracked `var` properties (non-macro types
/// or macro types with only `let` fields). Conforms to `_ModelStateType` so generic code can
/// always constrain `M._ModelState: _ModelStateType` without a special-case for `Void`.
public struct _EmptyModelState: _ModelStateType, Sendable {}

/// Marker protocol conformed to by the `_State` struct of every `@Model` type.
///
/// Provides stub subscripts for synthetic observation paths that live on the state struct
/// rather than on the model itself. These subscripts are **keypath-only** — they are never
/// called for their value. They exist so that `\M._ModelState[environmentKey: key]` etc.
/// form valid `KeyPath<M._ModelState, T>` expressions for use in `modifyCallbacksStore` and
/// `ModelAccess.willAccess/didModify`.
///
/// The `_metadata` and `_preference` subscripts expose writable `WritableKeyPath` forms so
/// that `TestAccess`'s `apply` closure can write through them. The setter is intentionally
/// a no-op — context storage lives in `AnyContext.contextStorage`, not in the `_State` struct.
public protocol _ModelStateType {}

public extension _ModelStateType {
    // Synthetic read-only paths — keypath construction only, never called.
    subscript(environmentKey _: AnyHashableSendable) -> AnyHashableSendable { fatalError() }
    subscript(preferenceKey _: AnyHashableSendable) -> AnyHashableSendable { fatalError() }
    subscript(memoizeKey _: AnyHashableSendable) -> AnyHashableSendable { fatalError() }

    // Writable stub paths for typed TestAccess snapshot tracking.
    // The getter is never called (precomputedStorageValue thread-local provides the value).
    // The setter is a no-op (context storage lives outside _State).
    subscript<V>(_metadata _: ContextStorage<V>) -> V {
        get { fatalError() }
        set {}
    }
    subscript<V>(_preference _: PreferenceStorage<V>) -> V {
        get { fatalError() }
        set {}
    }
}

extension _ModelStateType {
    // Internal-only: `_ParentsObservationKey` is an internal type so this subscript
    // cannot be public. Only accessed via `\M._ModelState[_parentsObservationKey: ...]`
    // inside the framework.
    subscript(_parentsObservationKey _: _ParentsObservationKey) -> [ModelID] { fatalError() }
}

// MARK: - _ModelSourceBox

/// Public opaque wrapper for the model's backing Reference and access mode.
///
/// 8 bytes: a 2-case enum whose cases both carry a class reference. Swift encodes the
/// discriminant in the spare low bits of the pointer (heap objects are ≥8-byte aligned,
/// so bits 0–2 are always 0), so the whole enum fits in one word.
///
/// **Routing**:
/// - `.live`: always reads/writes directly from `reference.state`, bypassing context routing.
///   Used for `_modelSeed` and other internal direct-access copies that must not trigger
///   observation or go through the context lock. (Formerly `_isLive == true`.)
/// - `.regular` with `reference.context != nil`: anchored — reads/writes route through
///   Context for observation tracking and lock-protected state updates.
/// - `.regular` with `reference.context == nil && !reference.isSnapshot`: pre-anchor
///   or re-anchorable destructed model — direct reads/writes, no lock needed.
/// - `.regular` with `reference.isSnapshot`: frozen/lastSeen snapshot — reads are direct;
///   writes are no-ops (with `reportIssue`) unless `isApplyingSnapshot` is set.
///
/// **Pending storage design**:
/// Init accessors store values to a thread-local `PendingStorage` via `_threadLocalStore`.
/// At pop time (`_threadLocalStoreAndPop` or `_popFromThreadLocal`), a macro-generated
/// factory builds `_State` from the accumulated values, creates a Reference with `state`
/// populated, and returns a `.regular` source box. All pre-anchor copies share the same
/// Reference. `_transitionToLive()` switches the case to `.live` for internal copies.
@dynamicMemberLookup
public struct _ModelSourceBox<M: Model>: @unchecked Sendable {
    /// Two-case enum that packs into 8 bytes via spare pointer bits.
    private enum _Mode {
        case live(Context<M>.Reference)    // bypass context routing (internal direct-access)
        case regular(Context<M>.Reference) // normal routing
    }
    private var _mode: _Mode

    var reference: Context<M>.Reference {
        switch _mode { case .live(let r), .regular(let r): return r }
    }
    var _isLive: Bool {
        if case .live = _mode { return true }
        return false
    }

    // MARK: dynamicMemberLookup

    public subscript<T>(dynamicMember path: WritableKeyPath<M._ModelState, T>) -> T {
        get {
            if reference._stateCleared {
                if !reference._hasGenesis {
                    reportIssue("Reading from a fully destructed model with no last-seen snapshot.")
                }
                return reference._hasGenesis ? reference._genesisState[keyPath: path] : _zeroInit()
            }
            return reference.state[keyPath: path]
        }
        set {
            if _isLive || (reference.context == nil && !reference.isSnapshot && !reference.hasLazyContextCreator) {
                // Pre-anchor or internal direct-access: write directly to reference.state.
                reference.state[keyPath: path] = newValue
            } else if reference.lifetime == .frozenCopy, threadLocals.isApplyingSnapshot {
                // Allow writes when isApplyingSnapshot is set (TestAccess lastState updates).
                reference.state[keyPath: path] = newValue
            }
            // Anchored writes go through ModelContext subscript; lastSeen snapshots are immutable.
        }
    }

    /// Exposes the full `_State` value for direct read/write.
    /// Read works for all sources. Write only takes effect for pre-anchor, live, and
    /// frozen-copy sources when `isApplyingSnapshot` is set (TestAccess snapshot writes).
    public var _modelState: M._ModelState {
        get {
            if reference._stateCleared {
                if !reference._hasGenesis {
                    reportIssue("Reading _modelState from a cleared model — this is a bug in SwiftModel.")
                }
                return reference._hasGenesis ? reference._genesisState : _zeroInit()
            }
            return reference.state
        }
        nonmutating set {
            if _isLive || (reference.context == nil && !reference.isSnapshot && !reference.hasLazyContextCreator) {
                reference.state = newValue
            } else if reference.lifetime == .frozenCopy, threadLocals.isApplyingSnapshot {
                reference.state = newValue
            }
        }
    }

    /// Stores a value into the Reference's `state` directly (if pre-anchor and unlinked).
    /// Used by willSet/didSet `nonmutating set` to short-circuit writes before anchoring.
    @discardableResult
    public func _storePendingIfNeeded<T>(_ path: WritableKeyPath<M._ModelState, T>, _ value: T) -> Bool {
        guard !_isLive, reference.context == nil, !reference.isSnapshot, !reference.hasLazyContextCreator else { return false }
        reference.state[keyPath: path] = value
        return true
    }

    // MARK: Thread-local pending storage

    /// **First/Only property**: clears stale `latest` from a previous construction,
    /// then stores the value on the thread-local stack. Prevents cross-construction bleed.
    public static func _threadLocalStoreFirst<V>(_ path: WritableKeyPath<M._ModelState, V>, _ value: V) {
        threadLocals.pendingStack.latest = nil
        _PendingStack.store(path, value)
    }

    /// **Middle property**: if `latest` is set (user-written init, phase-2 setter path),
    /// writes directly to the already-created Reference.state. Otherwise stores on the
    /// thread-local stack (phase-1 init accessor path).
    public static func _threadLocalStoreOrLatest<V>(_ path: WritableKeyPath<M._ModelState, V>, _ value: V) {
        if let ref = threadLocals.pendingStack.latest as? Context<M>.Reference {
            // Keep old value alive past the write so its deinit cannot fire while
            // ref.state is exclusively held, preventing Swift exclusivity violations.
            withExtendedLifetime(ref.state[keyPath: path]) {
                ref.state[keyPath: path] = value
            }
        } else {
            _PendingStack.store(path, value)
        }
    }

    /// **Last/Only property**: stores the value, pops the `PendingStorage` from the
    /// thread-local stack, builds `_State` via factory, creates a pre-anchor Reference,
    /// and sets `latest` (so subsequent phase-2 setter calls route to the same Reference).
    public static func _threadLocalStoreAndPop<V>(_ path: WritableKeyPath<M._ModelState, V>, _ value: V, _ factory: (PendingStorage<M._ModelState>) -> M._ModelState) -> _ModelSourceBox {
        _PendingStack.store(path, value)
        let pending = _PendingStack.popOrCreate(M._ModelState.self)
        let state = factory(pending)
        let ref = Context<M>.Reference(modelID: pending.pendingID, state: state)
        threadLocals.pendingStack.latest = ref
        return _ModelSourceBox(reference: ref)
    }

    /// Pops the thread-local pending storage, builds `_State` via factory, and creates
    /// a pre-anchor source box with a Reference.
    /// Used as the default value for `_$modelSource` — fires after all init accessors.
    public static func _popFromThreadLocal(_ factory: (PendingStorage<M._ModelState>) -> M._ModelState) -> _ModelSourceBox {
        let pending = _PendingStack.popOrCreate(M._ModelState.self)
        let state = factory(pending)
        let ref = Context<M>.Reference(modelID: pending.pendingID, state: state)
        return _ModelSourceBox(reference: ref)
    }

    // MARK: Initialisers

    /// Creates a source box from a Reference. `isLive` defaults to `false` (pre-anchor or user-facing).
    init(reference: Context<M>.Reference, isLive: Bool = false) {
        _mode = isLive ? .live(reference) : .regular(reference)
    }

    /// Used by `shallowCopy` / `frozenCopy`.
    init(frozen state: M._ModelState, id: ModelID) {
        _mode = .regular(Context<M>.Reference(modelID: id, state: state, lifetime: .frozenCopy))
    }

    /// Used by `lastSeen` (post-destruction snapshot).
    init(lastSeen state: M._ModelState, id: ModelID) {
        _mode = .regular(Context<M>.Reference(modelID: id, state: state, lifetime: .destructed))
    }

    // MARK: Live transition

    /// Switches this source box to a live/internal direct-access copy (formerly `.live` SourceKind).
    /// Reads/writes bypass context routing — used for `_modelSeed` and internal copies.
    public mutating func _transitionToLive() {
        _mode = .live(reference)
    }

    /// Returns the Reference when anchored (context non-nil) or live. Returns nil for
    /// pre-anchor unlinked copies. Used to check if the source can be used for context routing.
    var _liveReference: Context<M>.Reference? {
        (_isLive || reference.context != nil) ? reference : nil
    }

    /// Returns the backing Reference for any source state.
    var _anyReference: Context<M>.Reference { reference }

    // MARK: Model identity

    var modelID: ModelID { reference.modelID }

}

// MARK: - Direct property access subscripts

extension _ModelSourceBox {

    /// Resolves the modify context for writes.
    /// Returns the Context when this is a live anchored model.
    /// Returns nil (with `reportIssue` for snapshots) when writes should be direct or no-ops.
    func _modifyContext(accessBox: _ModelAccessBox) -> Context<M>? {
        if _isLive {
            return nil  // internal direct-access copy — bypass context
        }
        if let context = reference.context { return context }
        // Try lazy materialization before falling through to pre-anchor/snapshot path.
        if let context = reference.materializeLazyContext() { return context }
        // No live context — check for snapshot (warn) vs pre-anchor (silent).
        if reference.isSnapshot {
            switch reference.lifetime {
            case .frozenCopy:
                if !threadLocals.isApplyingSnapshot {
                    reportIssue("Modifying a frozen copy of a model is not allowed and has no effect")
                }
            case .destructed:
                let access = accessBox._reference?.access ?? ModelAccess.current
                if let access = access as? LastSeenAccess, -access.timestamp.timeIntervalSinceNow < lastSeenTimeToLive {
                    break
                }
                reportIssue("Modifying a destructed model is not allowed and has no effect")
            default:
                break
            }
        }
        return nil
    }

    // MARK: Read subscripts

    @_disfavoredOverload
    public subscript<T>(read statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        _read {
            if threadLocals.forceDirectAccess || _isLive {
                yield self[dynamicMember: statePath]
            } else if let context = reference.context {
                let callback = context.willAccessDirect(statePath: statePath, accessBox: accessBox)
                yield context[statePath: statePath, observeCallback: callback]
            } else {
                yield self[dynamicMember: statePath]
            }
        }
    }

    public subscript<T: Model>(read statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        get {
            let access = accessBox._reference?.access ?? ModelAccess.current
            if threadLocals.forceDirectAccess || _isLive {
                return self[dynamicMember: statePath]
            } else if let context = reference.context {
                let callback = context.willAccessDirect(statePath: statePath, accessBox: accessBox)
                let value: T = context[statePath: statePath, observeCallback: callback]
                return value.withAccessIfPropagateToChildren(access)
            } else {
                return self[dynamicMember: statePath]
            }
        }
    }

    public subscript<T: ModelContainer>(read statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        _read {
            let access = accessBox._reference?.access ?? ModelAccess.current
            let deepAccess = access.flatMap { $0.shouldPropagateToChildren ? $0 : nil }
            if threadLocals.forceDirectAccess || _isLive {
                yield self[dynamicMember: statePath]
            } else if let context = reference.context {
                let callback = context.willAccessDirect(statePath: statePath, accessBox: accessBox)
                let value: T = context[statePath: statePath, observeCallback: callback]
                if let deepAccess {
                    yield value.withDeepAccess(deepAccess)
                } else {
                    yield value
                }
            } else {
                yield self[dynamicMember: statePath]
            }
        }
    }

    /// Handles `MutableCollection` properties whose element type is `Model & Identifiable & Sendable`
    /// but that do NOT conform to `ModelContainer` (e.g. `IdentifiedArray<Model>`).
    /// Disfavored so that when the collection also conforms to `ModelContainer`, the
    /// `subscript<T: ModelContainer>(read:)` overload wins and applies full recursive `withDeepAccess`.
    @_disfavoredOverload
    public subscript<C: MutableCollection>(read statePath: WritableKeyPath<M._ModelState, C>, access accessBox: _ModelAccessBox) -> C
        where C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        get {
            let access = accessBox._reference?.access ?? ModelAccess.current
            if threadLocals.forceDirectAccess || _isLive {
                return self[dynamicMember: statePath]
            } else if let context = reference.context {
                let callback = context.willAccessDirect(statePath: statePath, accessBox: accessBox)
                let value: C = context[statePath: statePath, observeCallback: callback]
                guard let access, access.shouldPropagateToChildren else { return value }
                var result = value
                for index in result.indices {
                    result[index] = result[index].withAccessIfPropagateToChildren(access)
                }
                return result
            } else {
                return self[dynamicMember: statePath]
            }
        }
    }

    // MARK: Modify subscripts

    @_disfavoredOverload
    public subscript<T>(write statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        _read { fatalError("Use read subscript for reads") }
        nonmutating _modify {
            guard let context = _modifyContext(accessBox: accessBox) else {
                if _isLive || (reference.context == nil && !reference.isSnapshot) {
                    yield &reference.state[keyPath: statePath]
                    // Track pre-anchor state mutations so Context.init can detect dep model
                    // pollution: a child's RMW on an inherited dep increments _stateVersion,
                    // letting the dep loop substitute the pre-mutation snapshot for root.
                    reference._stateVersion &+= 1
                } else {
                    var value = self[dynamicMember: statePath]
                    yield &value
                }
                return
            }
            yield &context[statePath: statePath, isSame: nil, accessBox: accessBox]
        }
    }

    @_disfavoredOverload
    public subscript<T: Equatable>(write statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        _read { fatalError("Use read subscript for reads") }
        nonmutating _modify {
            guard let context = _modifyContext(accessBox: accessBox) else {
                if _isLive || (reference.context == nil && !reference.isSnapshot) {
                    yield &reference.state[keyPath: statePath]
                    reference._stateVersion &+= 1
                } else {
                    var value = self[dynamicMember: statePath]
                    yield &value
                }
                return
            }
            yield &context[statePath: statePath, isSame: ==, accessBox: accessBox]
        }
    }

    @_disfavoredOverload
    public subscript<each T: Equatable>(write statePath: WritableKeyPath<M._ModelState, (repeat each T)>, access accessBox: _ModelAccessBox) -> (repeat each T) {
        get { fatalError("Use read subscript for reads") }
        nonmutating _modify {
            guard let context = _modifyContext(accessBox: accessBox) else {
                if _isLive || (reference.context == nil && !reference.isSnapshot) {
                    yield &reference.state[keyPath: statePath]
                    reference._stateVersion &+= 1
                } else {
                    var value = self[dynamicMember: statePath]
                    yield &value
                }
                return
            }
            yield &context[statePath: statePath, isSame: isSame, accessBox: accessBox]
        }
    }

    public subscript<T: Model>(write statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        get { self[read: statePath, access: accessBox] }
        nonmutating set {
            // Pre-anchor or live: store directly without anchoring semantics.
            // _modifyContext returns nil for this case and would silently drop the write.
            if _isLive || (reference.context == nil && !reference.isSnapshot && !reference.hasLazyContextCreator) {
                reference.state[keyPath: statePath] = newValue
                return
            }
            guard let context = _modifyContext(accessBox: accessBox) else { return }

            guard context.reference.state[keyPath: statePath].context !== newValue.context else {
                return
            }

            guard newValue.isInitial || newValue.context != nil else {
                reportIssue("It is not allowed to add a frozen model, instead create a new instance or add an already anchored model.")
                return
            }

            let modelPath = M._modelStateKeyPath.appending(path: statePath)
            var callbacks: [() -> Void] = []
            context.stateTransaction(at: statePath, isSame: {
                $0.modelID == $1.modelID
            }, accessBox: accessBox, modify: { child in
                var newChild = newValue
                if let childContext = child.context {
                    context.removeChild(childContext, at: \M.self, callbacks: &callbacks)
                }
                context.updateContext(for: &newChild, at: modelPath)
                child = newChild
            })

            for callback in callbacks {
                callback()
            }

            let access = accessBox._reference?.access ?? ModelAccess.current
            if let access, access.shouldPropagateToChildren {
                usingAccess(access) {
                    _ = context.reference.state[keyPath: statePath].context?.onActivate()
                }
            } else {
                _ = context.reference.state[keyPath: statePath].context?.onActivate()
            }
        }
    }

    /// Handles `MutableCollection & ModelContainer` properties (e.g. `[Model]`, `Array<Model>`).
    /// More constrained than `subscript<T: ModelContainer>` alone, so this overload wins when
    /// both `MutableCollection` (with `Model` elements) and `ModelContainer` apply — ensuring the
    /// write path uses `updateContextForCollection` (consistent with the `visitCollection` read path
    /// that uses `\C.self`-keyed child registration).
    public subscript<C: MutableCollection & ModelContainer>(write statePath: WritableKeyPath<M._ModelState, C>, access accessBox: _ModelAccessBox) -> C
        where C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        get { self[read: statePath, access: accessBox] }
        nonmutating set { _performCollectionSet(statePath: statePath, accessBox: accessBox, newValue: newValue) }
    }

    /// Handles `MutableCollection` properties whose element type is `Model & Identifiable`
    /// but that do NOT conform to `ModelContainer` themselves (e.g. `IdentifiedArray`, custom
    /// sorted-array types). Not disfavored, so it beats the disfavored `ModelContainer &
    /// Identifiable` overload below when both match (e.g. `IdentifiedArray<@Model>`).
    /// When the collection is also `ModelContainer`, the more-constrained
    /// `MutableCollection & ModelContainer` overload above wins via specificity.
    public subscript<C: MutableCollection>(write statePath: WritableKeyPath<M._ModelState, C>, access accessBox: _ModelAccessBox) -> C
        where C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        get { self[read: statePath, access: accessBox] }
        nonmutating set { _performCollectionSet(statePath: statePath, accessBox: accessBox, newValue: newValue) }
    }

    /// Shared implementation for both `MutableCollection` write subscripts.
    private func _performCollectionSet<C: MutableCollection>(
        statePath: WritableKeyPath<M._ModelState, C>,
        accessBox: _ModelAccessBox,
        newValue: C
    ) where C.Element: Model & Identifiable & Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        if !_isLive && reference.context == nil && !reference.isSnapshot && !reference.hasLazyContextCreator {
            reference.state[keyPath: statePath] = newValue
            return
        }
        guard let context = _modifyContext(accessBox: accessBox) else { return }

        let modelPath = M._modelStateKeyPath.appending(path: statePath)
        var postLockCallbacks: [() -> Void] = []
        var structuralChange = false
        context.stateTransaction(at: statePath, isSame: {
            collectionIsSame($0, $1)
        }, accessBox: accessBox, modify: { collection in
            var newCollection = newValue
            var didReplaceModelWithDestructedOrFrozenCopy = false
            let oldContexts = threadLocals.withValue({
                didReplaceModelWithDestructedOrFrozenCopy = true
            }, at: \.didReplaceModelWithDestructedOrFrozenCopy) {
                context.updateContextForCollection(for: &newCollection, at: modelPath)
            }

            if didReplaceModelWithDestructedOrFrozenCopy {
                reportIssue("It is not allowed to add a destructed nor frozen model.")
                return
            }

            if !collectionIsSame(newCollection, collection) {
                structuralChange = true
            }
            collection = newCollection

            for oldContext in oldContexts {
                context.removeChild(oldContext, at: modelPath, callbacks: &postLockCallbacks)
            }
        })

        for callback in postLockCallbacks {
            callback()
        }

        if structuralChange {
            let access = accessBox._reference?.access ?? ModelAccess.current
            if let access, access.shouldPropagateToChildren {
                usingAccess(access) {
                    for element in context.reference.state[keyPath: statePath] {
                        element.activate()
                    }
                }
            } else {
                for element in context.reference.state[keyPath: statePath] {
                    element.activate()
                }
            }
        }
    }

    /// Fallback for `MutableCollection` properties whose element type is `ModelContainer & Identifiable`
    /// but that do NOT conform to `ModelContainer` themselves (e.g. `IdentifiedArray` of a
    /// `@ModelContainer` enum). Disfavored so that when a type is also `ModelContainer` the
    /// more-constrained overload wins.
    @_disfavoredOverload
    public subscript<C: MutableCollection>(write statePath: WritableKeyPath<M._ModelState, C>, access accessBox: _ModelAccessBox) -> C
        where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        get { self[read: statePath, access: accessBox] }
        nonmutating set { _performContainerCollectionSet(statePath: statePath, accessBox: accessBox, newValue: newValue) }
    }

    private func _performContainerCollectionSet<C: MutableCollection>(
        statePath: WritableKeyPath<M._ModelState, C>,
        accessBox: _ModelAccessBox,
        newValue: C
    ) where C.Element: ModelContainer & Identifiable & Sendable, C: Sendable, C.Index: Sendable, C.Element.ID: Sendable {
        if !_isLive && reference.context == nil && !reference.isSnapshot && !reference.hasLazyContextCreator {
            reference.state[keyPath: statePath] = newValue
            return
        }
        let context: Context<M>
        if _isLive {
            guard let ctx = reference.context else {
                // Live source but no context yet — occurs during withContextAdded in Context.init
                // before setContext is called (e.g. pre-populated collection elements whose
                // modelContext is updated by visitContainerCollection). Write directly, mirroring
                // the Equatable subscript behaviour for this initialisation case.
                reference.state[keyPath: statePath] = newValue
                return
            }
            context = ctx
        } else {
            guard let ctx = _modifyContext(accessBox: accessBox) else { return }
            context = ctx
        }

        let modelPath = M._modelStateKeyPath.appending(path: statePath)
        var postLockCallbacks: [() -> Void] = []
        var structuralChange = false
        context.stateTransaction(at: statePath, isSame: { lhs, rhs in
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy { $0.id == $1.id }
        }, accessBox: accessBox, modify: { collection in
            var newCollection = newValue
            var didReplaceModelWithDestructedOrFrozenCopy = false
            let oldContexts = threadLocals.withValue({
                didReplaceModelWithDestructedOrFrozenCopy = true
            }, at: \.didReplaceModelWithDestructedOrFrozenCopy) {
                context.updateContextForContainerCollection(for: &newCollection, at: modelPath)
            }

            if didReplaceModelWithDestructedOrFrozenCopy {
                reportIssue("It is not allowed to add a destructed nor frozen model.")
                return
            }

            let sameStructure: Bool = {
                guard newCollection.count == collection.count else { return false }
                return zip(newCollection, collection).allSatisfy { $0.id == $1.id }
            }()
            if !sameStructure {
                structuralChange = true
            }
            collection = newCollection

            for oldContext in oldContexts {
                context.removeChild(oldContext, at: modelPath, callbacks: &postLockCallbacks)
            }
        })

        for callback in postLockCallbacks {
            callback()
        }

        if structuralChange {
            let access = accessBox._reference?.access ?? ModelAccess.current
            if let access, access.shouldPropagateToChildren {
                usingAccess(access) {
                    for element in context.reference.state[keyPath: statePath] {
                        element.activate()
                    }
                }
            } else {
                for element in context.reference.state[keyPath: statePath] {
                    element.activate()
                }
            }
        }
    }

    public subscript<T: ModelContainer>(write statePath: WritableKeyPath<M._ModelState, T>, access accessBox: _ModelAccessBox) -> T {
        get { self[read: statePath, access: accessBox] }
        nonmutating set {
            // Pre-anchor: store directly without anchoring semantics.
            // _modifyContext returns nil for this case and would silently drop the write.
            if !_isLive && reference.context == nil && !reference.isSnapshot && !reference.hasLazyContextCreator {
                reference.state[keyPath: statePath] = newValue
                return
            }
            // For live (_isLive == true, e.g. _modelSeed in context.transaction(at:)), route
            // through the reference's context. NSRecursiveLock makes re-entrant locking safe here.
            let context: Context<M>
            if _isLive {
                guard let ctx = reference.context else { return }
                context = ctx
            } else {
                guard let ctx = _modifyContext(accessBox: accessBox) else { return }
                context = ctx
            }

            let modelPath = M._modelStateKeyPath.appending(path: statePath)
            var postLockCallbacks: [() -> Void] = []
            var structuralChange = false
            context.stateTransaction(at: statePath, isSame: {
                containerIsSame($0, $1)
            }, accessBox: accessBox, modify: { container in
                // Fast path: if element structure is unchanged (same IDs in same order),
                // skip the O(N) updateContext traversal — no child contexts need to change.
                if containerIsSame(newValue, container) {
                    container = newValue
                    return
                }

                var newContainer = newValue
                var didReplaceModelWithDestructedOrFrozenCopy = false
                let oldContexts = threadLocals.withValue({
                    didReplaceModelWithDestructedOrFrozenCopy = true
                }, at: \.didReplaceModelWithDestructedOrFrozenCopy) {
                    context.updateContext(for: &newContainer, at: modelPath)
                }

                if didReplaceModelWithDestructedOrFrozenCopy {
                    reportIssue("It is not allowed to add a destructed nor frozen model.")
                    return
                }

                structuralChange = true
                container = newContainer

                for oldContext in oldContexts {
                    context.removeChild(oldContext, at: modelPath, callbacks: &postLockCallbacks)
                }
            })

            for callback in postLockCallbacks {
                callback()
            }

            if structuralChange {
                let access = accessBox._reference?.access ?? ModelAccess.current
                if let access, access.shouldPropagateToChildren {
                    usingAccess(access) {
                        context.reference.state[keyPath: statePath].activate()
                    }
                } else {
                    context.reference.state[keyPath: statePath].activate()
                }
            }
        }
    }
}

// MARK: - _PendingStack (thread-local, type-erased)

/// Thread-local stack of `PendingStorage` instances used during `@Model` struct init.
///
/// Each init accessor calls `store` which auto-creates a `PendingStorage` on the stack.
/// After all init accessors fire, `_$modelSource`'s default calls `popOrCreate` to collect
/// the accumulated values. Nested model inits (child default values) stack correctly.
enum _PendingStack {
    /// Stores a value in the top-of-stack pending storage for this `State` type.
    /// Auto-creates if no matching storage exists yet.
    static func store<State, V>(_ path: WritableKeyPath<State, V>, _ value: V) {
        let box = threadLocals.pendingStack
        if let top = box.last as? PendingStorage<State> {
            top.store(path, value)
        } else {
            let pending = PendingStorage<State>()
            pending.store(path, value)
            box.append(pending)
        }
    }

    /// Pops the top pending storage for this `State` type, or creates an empty one
    /// if the stack is empty (all properties used their defaults).
    static func popOrCreate<State>(_: State.Type) -> PendingStorage<State> {
        let box = threadLocals.pendingStack
        if box.isEmpty {
            return PendingStorage<State>()
        }
        let top = box.removeLast()
        guard let pending = top as? PendingStorage<State> else {
            // Stack has entries but top is a different type — this happens when
            // _$modelSource's default ._popFromThreadLocal() fires in a user-written
            // init while a parent model's pending storage is on the stack.
            // Push the parent's entry back and return an empty PendingStorage.
            box.append(top)
            return PendingStorage<State>()
        }
        return pending
    }
}

final class _PendingStackBox: @unchecked Sendable {
    var stack: [AnyObject] = []
    /// Set by `_threadLocalStoreAndPop` after the last init accessor pops the pending storage.
    /// Allows phase-2 setter calls (user-written inits) to route to the same Reference.
    /// Cleared by `_threadLocalStoreFirst` at the start of each new model construction.
    var latest: AnyObject?

    var last: AnyObject? { stack.last }
    var isEmpty: Bool { stack.isEmpty }
    func append(_ obj: AnyObject) { stack.append(obj) }
    @discardableResult func removeLast() -> AnyObject { stack.removeLast() }
}
