import Foundation
import Dependencies
import OrderedCollections
import Observation

/// Internal carrier passed through the `anyModificationCallbacks` notification chain.
/// Carries what kind of change occurred, how deep in the hierarchy it was relative to the
/// registered observer, and which context originated the change.
struct _ModificationCallbackSource: @unchecked Sendable {
    /// `true` when the model is deactivating — the stream should finish.
    var isFinished: Bool
    /// The kind of state that changed.
    var kind: ModificationKind
    /// Distance from the registered observer context to the origin context.
    /// 0 = the context that registered the callback, 1 = a direct child, 2+ = deeper descendants.
    var depth: Int
    /// The context where the change originated. `nil` only when `isFinished == true`.
    var origin: AnyContext?
    /// Lazily-produced human-readable name of what changed (e.g. `"duration"`,
    /// `"environment.theme"`, `"preference.score"`). Evaluated post-lock. Nil when
    /// unavailable (parentRelationship, touch, or finish signals).
    var propertyDescription: (@Sendable () -> String?)?
}

@usableFromInline
class AnyContext: @unchecked Sendable {
    @usableFromInline let lock: NSRecursiveLock
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

    // Protects `_dependencyContexts` and `_dependencyCache` independently of the hierarchy
    // lock — the same leaf-lock pattern as `parentsLock` above. The hierarchy lock alone
    // cannot protect these dictionaries: `setupModelDependency` writes to
    // `rootParent`'s stores while holding only *self*'s hierarchy lock, and for a grafted
    // (separately-anchored) child `self.lock !== rootParent.lock` — so a grafted child's
    // dep setup raced the root hierarchy's own locked mutations. Likewise
    // `nearestDependencyContext` reads each *ancestor*'s store while holding only self's
    // hierarchy lock; taking the ancestor's hierarchy lock there would be the reverse of
    // teardown's parent → child lock order (`removeParent` → `onRemoval`) — an AB-BA
    // deadlock. The leaf lock resolves both: every store access (read or write, own or
    // cross-hierarchy) goes through the accessors below, which take ONLY this lock.
    //
    // Leaf-lock discipline: the closures passed to `dependenciesLock` touch nothing but
    // the two dictionaries — never call anything that can acquire another lock (context
    // locks, `parentsLock`, Reference locks, key-path construction) and never nest two
    // contexts' `dependenciesLock`s. Same-context check-then-act sequences (e.g.
    // check-nil-then-insert in `setupModelDependency`) remain atomic for same-hierarchy
    // callers via the hierarchy lock they already hold; the insert-if-absent accessor
    // additionally re-checks under the leaf lock so concurrent grafted writers can't
    // corrupt the dictionaries (first insert wins).
    private let dependenciesLock = NSLock()
    private var _dependencyContexts: [ObjectIdentifier: AnyContext] = [:]
    private var _dependencyCache: [AnyHashable: Any] = [:]

    /// Leaf-locked read of the dependency context registered for `typeID`, if any.
    func dependencyContext(for typeID: ObjectIdentifier) -> AnyContext? {
        dependenciesLock { _dependencyContexts[typeID] }
    }

    /// Atomically inserts `context` for `typeID` if no entry exists.
    /// Returns `true` if the insert happened, `false` if an entry was already present
    /// (including `context` itself) — callers use this to decide whether to link
    /// parents, so a lost cross-hierarchy race must not double-link.
    func addDependencyContextIfAbsent(_ context: AnyContext, for typeID: ObjectIdentifier) -> Bool {
        dependenciesLock {
            guard _dependencyContexts[typeID] == nil else { return false }
            _dependencyContexts[typeID] = context
            return true
        }
    }

    /// Unconditionally (re)places the entry for `typeID` — used when re-anchoring a
    /// destructed dependency context. Any replaced context is released outside the leaf lock.
    func setDependencyContext(_ context: AnyContext, for typeID: ObjectIdentifier) {
        let replaced = dependenciesLock { _dependencyContexts.updateValue(context, forKey: typeID) }
        _ = replaced  // released here, outside the leaf lock
    }

    /// Leaf-locked snapshot of all registered dependency contexts.
    var dependencyContextValues: [AnyContext] {
        dependenciesLock { _dependencyContexts.isEmpty ? [] : Array(_dependencyContexts.values) }
    }

    /// Leaf-locked read of the dependency cache.
    func cachedDependencyValue(for key: AnyHashable) -> Any? {
        dependenciesLock { _dependencyCache[key] }
    }

    /// Leaf-locked write to the dependency cache. Any replaced value is released
    /// outside the leaf lock (releasing a model copy can run arbitrary deinit chains).
    func setCachedDependencyValue(_ value: Any, for key: AnyHashable) {
        let replaced = dependenciesLock { _dependencyCache.updateValue(value, forKey: key) }
        _ = replaced  // released here, outside the leaf lock
    }

    /// Drains both dependency stores, returning the contents so the caller controls
    /// where the (potentially deinit-heavy) releases happen — never inside the leaf lock.
    func drainDependencyStores() -> (contexts: [ObjectIdentifier: AnyContext], cache: [AnyHashable: Any]) {
        dependenciesLock {
            let drained = (_dependencyContexts, _dependencyCache)
            _dependencyContexts.removeAll()
            _dependencyCache.removeAll()
            return drained
        }
    }

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
    /// observation). Never accessed in production. Protected by THIS context's hierarchy
    /// lock — writers (`registerCollectionElementPathMaker`) hold it, and `rootPathTree()`
    /// snapshots a parent's store under the parent's own lock (not the querying child's,
    /// which for grafted children is a different lock). `nonisolated(unsafe)` since
    /// locking discipline is enforced at call sites.
    ///
    /// The maker signature is `(elementID, fallbackElement) -> elementPath`. The
    /// `fallbackElement` is the child context's current live model value, captured
    /// at the time the path is requested. The `ContainerCursor.get` produced by
    /// the maker uses this fallback when the requested element has been removed
    /// from the parent collection between path construction and read — a race
    /// that can happen when a child task writes to a property of an element that
    /// is concurrently being removed from the parent collection. Without the
    /// fallback, `cursor.get` would crash with a force-unwrap. Type-erased to
    /// `Any` because the generic element type isn't visible at this layer.
    nonisolated(unsafe) var collectionElementPathMakersStore: [AnyKeyPath: @Sendable (AnyHashable, Any) -> AnyKeyPath]?

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

    /// Whether to bridge observation notifications through the main thread for SwiftUI/UIKit/AppKit.
    /// See `ModelOption.disableMainThreadObservation` for the full rationale.
    ///
    /// - Apple platforms (`canImport(Darwin)`): enabled unless the user opts out via the option.
    /// - Non-Apple (Linux/Android/WASM): always disabled. There is no `Observable`-consuming UI
    ///   framework outside Apple, and on Android `@MainActor` work never executes (Android's
    ///   `Looper` doesn't drain libdispatch's main queue), so any `mainObservationRegistrar`
    ///   notification queued by `invokeDidModifyDirect`'s background path would be silently
    ///   dropped — breaking `Observed { ... }` and similar consumers.
    let useMainThreadObservation: Bool

    /// Pairs both observation registrars in one heap allocation.
    /// Created eagerly with the `RegistrarBox` at the root context and shared by all children
    /// in the tree, so that the whole hierarchy uses O(2) registrar instances instead of O(2N).
    ///
    /// The `background` registrar is a `let` — the immutable chain box → pair → background
    /// is safely readable lock-free from any thread.
    /// The `main` registrar is allocated lazily on first main-channel use — contexts with
    /// `useMainThreadObservation == false` (non-Apple, or opt-out on Apple) never touch it,
    /// saving one `ObservationRegistrar` allocation (which itself heap-allocates an internal
    /// `Extent`) per model tree on those platforms. ALL `_main` reads and writes go through
    /// the hierarchy lock: the nil → non-nil publication read without it is a data race
    /// (double-checked locking without atomics) — do not add an unlocked fast path.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    final class RegistrarPair: @unchecked Sendable {
        let background: ObservationRegistrar
        /// Lazily-allocated main-channel registrar. Read and written only under the
        /// hierarchy lock. `nonisolated(unsafe)`: locking discipline enforced at call sites.
        nonisolated(unsafe) var _main: ObservationRegistrar?
        init() {
            background = ObservationRegistrar()
        }
    }

    /// Container for the tree's `RegistrarPair`, created at the root context when
    /// observation is enabled. The pair is created eagerly with the box (3 allocations
    /// per anchored tree: box + pair + the background registrar's storage): a `let`
    /// makes the background-registrar chain immutable and race-free with zero locks.
    /// The previous lazily-published `var _pair` was double-checked locking without
    /// atomics — a formal data race on every unlocked fast-path read (TSan-confirmed).
    /// All child contexts inherit the same box reference — thread-safe as `let` constants.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    final class RegistrarBox: @unchecked Sendable {
        let pair = RegistrarPair()
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
            // `_main` is lock-published; read it under the same lock.
            return lock { (_registrarBox as? RegistrarBox)?.pair._main }
        }
        return nil
    }
    var backgroundObservationRegistrarStore: Any? {
        if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
            return (_registrarBox as? RegistrarBox)?.pair.background
        }
        return nil
    }
    /// Lazily-allocated task registry. Written once (nil → non-nil) under `lock`.
    /// `nonisolated(unsafe)`: manual locking discipline (same as other lazy stores).
    nonisolated(unsafe) var cancellationsStore: Cancellations?
    /// Returns the Cancellations registry, creating it lazily on first use.
    /// All task-registration paths go through this; read-only paths snapshot
    /// `cancellationsStore` under `lock`. Always locks — an unlocked fast-path
    /// read of the `nonisolated(unsafe)` store races the locked nil → non-nil
    /// publication (double-checked locking without atomics), and registration
    /// paths are not hot enough to justify that.
    var cancellations: Cancellations {
        lock {
            if cancellationsStore == nil { cancellationsStore = Cancellations() }
            return cancellationsStore!
        }
    }

    let mainCallQueue: MainCallQueue

    /// Set by `TestAccess` on the root context. Used by `ModelNode+Undo` to find the
    /// root `TestAccess` (via `as? TestAccess<…>`) so undo restores propagate
    /// `didModify` notifications. Always `nil` in production.
    weak var modelAccess: ModelAccess?

    /// Captured during `Context<M>.init` to call `model.onActivate()` with correct `let` values.
    /// Called once by `Context<M>.onActivate()` and then cleared.
    var pendingActivation: (() -> Void)?

    private(set) var anyModificationActiveCount = 0
    private var anyModificationCallbacksStore: [Int: (_ModificationCallbackSource) -> (() -> Void)?]?
    private var anyModificationCallbacks: [Int: (_ModificationCallbackSource) -> (() -> Void)?] {
        _read { yield anyModificationCallbacksStore ?? [:] }
        _modify {
            if anyModificationCallbacksStore != nil {
                yield &anyModificationCallbacksStore!
                if anyModificationCallbacksStore!.isEmpty { anyModificationCallbacksStore = nil }
            } else {
                var temp: [Int: (_ModificationCallbackSource) -> (() -> Void)?] = [:]
                yield &temp
                if !temp.isEmpty { anyModificationCallbacksStore = temp }
            }
        }
    }
    private var _modificationCount = 0

    /// Paths excluded from `observeModifications()` notifications. Nil means no exclusions.
    /// Set by `ModelNode.excludeFromModifications`. Only checked for `.properties` kind changes.
    var modificationExcludedPaths: Set<AnyKeyPath>?

    struct MemoizeCacheEntry: @unchecked Sendable {
        var value: Any & Sendable
        var cancellable: (@Sendable () -> Void)?
        /// Monotonic count of dependency-change signals (`didModify`) received for
        /// this entry. Bumped under the context lock on every dependency change.
        var dirtyVersion: UInt64
        /// The `dirtyVersion` the cached `value` is known to incorporate. A recompute
        /// captures `dirtyVersion` under the lock *before* running `produce()` and
        /// advances `cleanVersion` to that captured value when it stores its result —
        /// so a dependency change that arrives *during* `produce()` keeps the entry
        /// dirty, while the change(s) the recompute already incorporated are cleared.
        ///
        /// A plain bool can't make that distinction: preserving it across a recompute
        /// left the entry permanently dirty after any value-changing dependency write
        /// (produce-per-access thrash); clearing it swallowed concurrent changes
        /// (stale cache). See `MemoizeThrashTests`.
        var cleanVersion: UInt64
        /// Whether the cached `value` is stale relative to the latest dependency change.
        var isDirty: Bool { dirtyVersion > cleanVersion }
        /// The last value external observers were notified about. A dirty *read* on the
        /// async tracking path writes its fresh value back into `value` silently (reads
        /// must never fire observer notifications — they can re-enter whatever machinery
        /// initiated the read, e.g. a SwiftUI body evaluation or a `ModelTester` predicate
        /// evaluation under its own lock). The performUpdate that notifies dedups against
        /// THIS value rather than `value`, so a silent write-back can't swallow the
        /// notification.
        var notifiedValue: Any & Sendable
        /// Callback to store a freshly produced value and trigger observation updates.
        /// The second parameter is the `dirtyVersion` captured before that value's
        /// `produce()` ran (see `cleanVersion`).
        var onUpdate: (@Sendable (Any, UInt64) -> Void)?
        var usesAsyncTracking: Bool  // True if using withObservationTracking (async), false if using AccessCollector (sync)
        /// Type-erased identity comparison built once on first access via buildObservationIsSame.
        var isSame: (@Sendable (Any, Any) -> Bool)?
        /// ObjectIdentifier of T — asserts same key is never reused with a different type.
        var typeID: ObjectIdentifier

        init(value: Any & Sendable, cancellable: (@Sendable () -> Void)? = nil, dirtyVersion: UInt64 = 0, cleanVersion: UInt64 = 0, notifiedValue: (Any & Sendable)? = nil, onUpdate: (@Sendable (Any, UInt64) -> Void)? = nil, usesAsyncTracking: Bool = false, isSame: (@Sendable (Any, Any) -> Bool)? = nil, typeID: ObjectIdentifier = ObjectIdentifier(Never.self)) {
            self.value = value
            self.cancellable = cancellable
            self.dirtyVersion = dirtyVersion
            self.cleanVersion = cleanVersion
            self.notifiedValue = notifiedValue ?? value
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
        /// The element's path within its parent container.
        ///
        /// Also used for equality and hash — but via `elementPath.hashValue`, NOT `AnyKeyPath.==`.
        /// Calling `AnyKeyPath.==` on cursor-backed paths crashes (`swift_retain` SIGSEGV) when
        /// generic type metadata is not fully initialized (observed on Linux CI). Key path hashes
        /// are computed without retaining, so they are safe. The theoretical hash-collision risk is
        /// negligible: cursor IDs are strings or typed IDs, making cross-position collisions
        /// virtually impossible in practice.
        var elementPath: AnyKeyPath
        var id: AnyHashable

        static func == (lhs: ModelRef, rhs: ModelRef) -> Bool {
            lhs.id == rhs.id && lhs.elementPath.hashValue == rhs.elementPath.hashValue
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(elementPath.hashValue)
        }
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
        // Take `self.lock` for the whole body.
        //
        // The caller is the *parent* context, which is holding *its own* lock
        // (`parent.lock`). For same-hierarchy children, `child.lock === parent.lock`
        // and the recursive NSRecursiveLock makes this a near-free re-entry. For
        // *separately-anchored* children grafted into another hierarchy
        // (`child.lock !== parent.lock`), we'd otherwise mutate `self`'s state
        // (`willModifyParents`, `didModifyParents` reading `modifyCallbacks`, …)
        // under the wrong lock — racing against any other thread that touches
        // `self` under `self.lock`.
        //
        // Lock ordering: callers always hold `parent.lock` first, then take
        // `self.lock` (the child's). This matches the existing ordering at
        // `Context.swift:childContext` call sites.
        lock {
            willModifyParents()
            parentsLock { weakParents.append(WeakParent(parent: parent)) }
            anyModificationActiveCount += parent.anyModificationActiveCount
            didModifyParents(callbacks: &callbacks)
        }
    }

    func removeParent(_ parent: AnyContext, callbacks: inout [() -> Void]) {
        // Take `self.lock` for the whole body — same reasoning as `addParent`.
        //
        // Lock-order note (cross-hierarchy): teardown chains locks parent → child
        // (`onRemoval` holds self.lock and recurses into `child.removeParent`, taking
        // child.lock). Two hierarchies grafted into each other in ONE direction never
        // produce the reverse pair. MUTUAL grafting (A's root a parent inside B while
        // B's root is a parent inside A) would allow an AB-BA between two concurrent
        // teardowns — but a mutual graft is a cycle in the parent graph, which is
        // already structurally unsupported (`rootParent` and every ancestor walk would
        // recurse forever), so teardown deliberately does not defend against it.
        //
        // This also covers the `onRemoval(callbacks:)` recursion at the tail:
        // when the child's last parent is being removed, `onRemoval(callbacks:)`
        // tears down `self`'s dictionaries (`_memoizeCache`, `eventContinuations`,
        // `modifyCallbacks`, …). Without this lock acquisition, a sibling-hierarchy
        // parent tearing down concurrently would race on the same dictionaries —
        // the documented heap-use-after-free in the `__NSTaggedDate
        // doesNotRecognizeSelector countByEnumeratingWithState:` crash signature.
        lock {
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
    }

    var rootParent: AnyContext {
        // Each hop snapshots that ancestor's parents under its own `parentsLock`
        // (released before the next hop) — never more than one lock at a time.
        parents.first?.rootParent ?? self
    }

    /// The current live parents. Calling this from observation-tracked code will register
    /// a dependency on the parents relationship via `willAccessParents()`.
    /// Snapshots `weakParents` under `parentsLock`: writers (`addParent`/`removeParent`)
    /// mutate the array under their hierarchy lock + `parentsLock`, but a cross-hierarchy
    /// reader (grafted trees don't share the hierarchy lock) can otherwise catch a COW
    /// reallocation mid-read. `parentsLock` is a leaf lock — the closure only does weak
    /// loads, so no ordering hazard.
    var parents: [AnyContext] {
        parentsLock { weakParents.compactMap(\.parent) }
    }

    /// Observed access to parents — registers observation tracking before reading.
    var observedParents: [AnyContext] {
        willAccessParents()
        return parents
    }

    var selfPath: AnyKeyPath { fatalError() }

    var anyModelID: ModelID { fatalError() }

    var anyModel: any Model { fatalError() }

    /// Calls `body` with the model this context backs, with `access` applied if it propagates to children.
    /// Used by `reduceHierarchy` to hand a correctly-configured model value to the user's transform closure.
    func mapModel<T>(access: ModelAccess?, _ body: (any Model) throws -> T?) rethrows -> T? { fatalError() }

    var rootPaths: [AnyKeyPath] {
        // Collect raw path segments one lock at a time (see `rootPathTree()`), then
        // compose OUTSIDE all locks. appending(path:) calls _swift_getKeyPath which
        // acquires the Swift runtime lock. Holding a context lock while needing the
        // runtime lock deadlocks when a GCD thread holds the runtime lock (key path
        // creation during observation/memoize) and needs the context lock (model write).
        //
        // Callers must NOT hold any context lock (TestAccess call sites are engineered
        // to compute rootPaths post-lock — see the deadlock comments there): the walk
        // takes each parent's lock in child → parent direction, which is the reverse of
        // teardown's parent → child order — safe only because at most one lock is held
        // at a time.
        composeRootPaths(from: rootPathTree())
    }

    /// Intermediate representation of the path hierarchy — raw segments with no
    /// key path composition. Built entirely under the shared context lock.
    private enum RootPathTree {
        case leaf(AnyKeyPath)
        case node([(childPath: AnyKeyPath, elementPath: AnyKeyPath, parentTree: RootPathTree)])
    }

    /// Registers a lazy element-path maker for `collectionPath`. No-op if already registered.
    /// Must be called under the hierarchy lock.
    ///
    /// `maker` receives the element's ID and a fallback element value (the child
    /// context's current live model). See `collectionElementPathMakersStore` for
    /// the rationale.
    func registerCollectionElementPathMaker(
        for collectionPath: AnyKeyPath,
        maker: @Sendable @escaping (AnyHashable, Any) -> AnyKeyPath
    ) {
        if collectionElementPathMakersStore == nil {
            collectionElementPathMakersStore = [collectionPath: maker]
        } else if collectionElementPathMakersStore![collectionPath] == nil {
            collectionElementPathMakersStore![collectionPath] = maker
        }
    }

    /// Collects the raw path segments for this context, walking upward one lock at a time.
    /// Must be called with NO context lock held (see `rootPaths`).
    ///
    /// Each parent's `children` / `collectionElementPathMakersStore` is snapshotted under
    /// THAT parent's own hierarchy lock. The pre-fix code held self's lock for the whole
    /// walk — correct for same-hierarchy parents (`parent.lock === self.lock`), but for a
    /// grafted (separately-anchored) child the parent lives under a different lock, so the
    /// reads raced the parent hierarchy's own locked mutations. Taking the parent's lock
    /// while still holding self's would reverse teardown's parent → child order (AB-BA),
    /// so — like `didModify`'s iterative ancestor walk — the lock is released before each
    /// upward hop. Element-path makers run OUTSIDE the lock: they construct key paths
    /// (Swift runtime lock — see `rootPaths`).
    private func rootPathTree() -> RootPathTree {
        let parents = self.parents
        if parents.isEmpty {
            return .leaf(selfPath)
        }

        return .node(parents.flatMap { parent -> [(childPath: AnyKeyPath, elementPath: AnyKeyPath, parentTree: RootPathTree)] in
            // Snapshot self's registrations in this parent under the parent's lock.
            let segments = parent.lock {
                parent.children.flatMap { childPath, modelRefs in
                    modelRefs.compactMap { modelRef, context -> (childPath: AnyKeyPath, modelRef: ModelRef, maker: (@Sendable (AnyHashable, Any) -> AnyKeyPath)?)? in
                        guard context === self else { return nil }
                        return (childPath, modelRef, parent.collectionElementPathMakersStore?[childPath])
                    }
                }
            }
            guard !segments.isEmpty else { return [] }
            // Recurse outside parent.lock — never more than one lock at a time.
            let parentTree = parent.rootPathTree()
            return segments.map { segment in
                // If a lazy element-path maker was registered for this collection
                // property (by visitCollection), use it to build the element-level
                // key path on demand. Without a maker, fall back to the stored
                // elementPath (cursor-based or sentinel \C.self for non-collection
                // children). Pass the child's current live model as the fallback for
                // the cursor's `get` closure — see `collectionElementPathMakersStore` doc.
                let elementPath = segment.maker.map { $0(segment.modelRef.id, anyModel) } ?? segment.modelRef.elementPath
                return (childPath: segment.childPath, elementPath: elementPath, parentTree: parentTree)
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
        self.useMainThreadObservation = Self.shouldEnableMainThreadObservation(options: self.options)

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
        // Snapshot self's tasks + children under self.lock. `allChildren` walks
        // `children.values` (protected by self.lock) and the dependency contexts
        // (snapshotted under `dependenciesLock` inside `forEachChild`). Reading
        // `children` lockless here races concurrent `childContext` inserts.
        let (selfTasks, snapshot) = lock { (cancellationsStore?.activeTasks ?? [], allChildren) }
        return snapshot.reduce(into: selfTasks) { $0.append(contentsOf: $1.activeTasks) }
    }

    /// True if any context in this subtree has a `TaskCancellable` whose body
    /// has not yet started running. Used by `TestAccess.settle()` to keep its
    /// quiet window open until every freshly-registered task has had a chance
    /// to execute at least once — see `Cancellations.hasPendingStartTask`.
    var hasPendingStartTask: Bool {
        // Same lock-protected snapshot pattern as `activeTasks`.
        let (selfPending, snapshot) = lock { (cancellationsStore?.hasPendingStartTask ?? false, allChildren) }
        if selfPending { return true }
        return snapshot.contains { $0.hasPendingStartTask }
    }

    /// Returns the main registrar if the main channel has been created (lazy), or nil
    /// otherwise. `_main` is lock-published, so the read takes the hierarchy lock too.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var mainObservationRegistrar: ObservationRegistrar? {
        lock { (_registrarBox as? RegistrarBox)?.pair._main }
    }

    /// Returns the background registrar if observation is enabled, or nil otherwise.
    /// Lock-free: the box → pair → background chain is immutable.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var backgroundObservationRegistrar: ObservationRegistrar? {
        (_registrarBox as? RegistrarBox)?.pair.background
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

    /// Computes whether main-thread observation bridging should be active for this context,
    /// based on platform and the `ModelOption.disableMainThreadObservation` flag.
    ///
    /// Non-Apple platforms always disable it: there is no consumer of main-thread observation
    /// (SwiftUI/UIKit/AppKit are Apple-only) and Android's `@MainActor` work never executes
    /// because Android's UI thread is owned by Android's `Looper`, not libdispatch.
    private static func shouldEnableMainThreadObservation(options: ModelOption) -> Bool {
        #if canImport(Darwin)
        return !options.contains(.disableMainThreadObservation)
        #else
        return false
        #endif
    }

    /// Returns the main registrar, allocating the `_main` channel lazily on first call.
    /// Only called when `useObservationRegistrar` is true, so `_registrarBox` is non-nil.
    ///
    /// Only invoked when `useMainThreadObservation == true` — contexts with the option
    /// disabled (every context on non-Apple) never reach here, so the main-channel allocation
    /// is paid only by trees that actually have a SwiftUI/UIKit/AppKit consumer.
    /// The whole body runs under the hierarchy lock: an unlocked `_main` fast path would be
    /// double-checked locking without atomics (a data race with the locked publication).
    /// Main-channel callers are on write/registration paths that typically already hold the
    /// (recursive) lock, so the re-acquisition is cheap.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var mainObservationRegistrarMakingIfNeeded: ObservationRegistrar {
        let pair = (_registrarBox as! RegistrarBox).pair
        return lock {
            if pair._main == nil { pair._main = ObservationRegistrar() }
            return pair._main!
        }
    }

    /// Returns the background registrar. Only called when `useObservationRegistrar` is true.
    /// Lock-free and race-free: the box → pair → background chain is immutable.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    var backgroundObservationRegistrarMakingIfNeeded: ObservationRegistrar {
        (_registrarBox as! RegistrarBox).pair.background
    }

    var lifetime: ModelLifetime {
        lock(modeLifeTime)
    }

    var isDestructed: Bool {
        lifetime == .destructed
    }

    @usableFromInline
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

    /// Calls `body` for each direct child context without allocating an intermediate array
    /// for `children`. Use this in hot paths instead of `allChildren` to avoid the 3-array
    /// allocation overhead. Dependency contexts are snapshotted under `dependenciesLock`
    /// (empty → no allocation) and iterated outside it so `body` can take other locks.
    func forEachChild(_ body: (AnyContext) -> Void) {
        for modelRefs in children.values {
            for child in modelRefs.values where child !== self {
                body(child)
            }
        }
        for child in dependencyContextValues where child !== self {
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
            switch modeLifeTime {
            case .anchored:
                modeLifeTime = .active
                return true
            case .initial, .active, .destructed, .frozenCopy:
                // No transition. In particular never resurrect `.destructed`:
                // `_performCollectionSet`'s re-activation loop runs OUTSIDE the
                // hierarchy lock over a possibly-stale element list, so it can
                // reach a context that a concurrent writer just destructed —
                // flipping it back to `.active` would create a zombie
                // (`isDestructed == false` forever) that no teardown path ever
                // visits again.
                return false
            }
        }
    }

    func onRemoval(callbacks: inout [() -> Void]) {
        let events = eventContinuations.values
        let anyModifies = anyModificationCallbacks.values
        let children = allChildren

        eventContinuations.removeAll()
        anyModificationCallbacks.removeAll()
        modeLifeTime = .destructed
        // Seal the task registry in the same locked scope that flips the
        // lifetime: a registration racing teardown (its context check passed
        // just before destruct) would otherwise land in the store AFTER the
        // `cancelAll()` in the deferred callback below has drained it — leaving
        // its cancellation to `Cancellations.deinit`, which the last-seen TTL
        // task can delay by seconds. A sealed store cancels post-seal
        // registrations immediately (the test teardown path already seals via
        // `sealRecursively()`). Create-if-nil first: a later lazy creation
        // would otherwise produce an UNSEALED store, reopening the hole.
        if cancellationsStore == nil { cancellationsStore = Cancellations() }
        cancellationsStore!.seal()
        self.children.removeAll()
        // Drain the leaf-locked dependency stores. The contents are released right here —
        // under the hierarchy lock (matching the old `removeAll()` timing) but outside the
        // leaf lock, since releasing contexts/model copies can run deinit chains that take
        // other locks. The dep contexts themselves stay alive via the `children` snapshot
        // above until their `removeParent` teardown below.
        _ = drainDependencyStores()

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
                cont(_ModificationCallbackSource(isFinished: true, kind: .all, depth: 0, origin: nil))?()
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
                // Register the parents-relationship observation dependency BEFORE taking
                // the context lock. `willAccessParents()` routes through
                // `TestAccess.willAccess` → `registerReadOnlyPathWake`, which acquires the
                // `TestAccess` lock. Doing that while holding `self.lock` (the shared
                // hierarchy/context lock) here inverts the established
                // `TestAccess.lock → context.lock` order that `Context._modify` /
                // `Context.transaction` enforce (they `acquireWriteLock()` BEFORE
                // `lock.lock()`). That inversion is a real AB-BA deadlock: a concurrent
                // writer holds `TestAccess.lock` and waits for `context.lock`, while this
                // traversal holds `context.lock` and waits for `TestAccess.lock` — observed
                // as a hang under the concurrent test-drain (e.g. one model activating and
                // reading an environment value via `reduceHierarchy` while another writes a
                // property). Hoisting the registration out of the lock keeps this path on
                // the same `TestAccess.lock → context.lock` order; the parents list itself
                // is still read under the lock just below.
                willAccessParents()
                parents = lock { weakParents.compactMap(\.parent) }
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
                self.children.values.flatMap { $0.values } + (relation.contains(.dependencies) ? dependencyContextValues : [])
            }
            for child in children {
                try child.reduce(for: dependencies.union([.self, .descendants]), observeParents: observeParents, transform: transform, into: &result, updateAccumulatingResult: updateAccumulatingResult, uniques: &uniques)
            }
        } else if relation.contains(.children) {
            let children = lock {
                self.children.values.flatMap { $0.values } + (relation.contains(.dependencies) ? dependencyContextValues : [])
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
            // Snapshot `eventContinuations.values` under `context.lock`.
            //
            // `reduceHierarchy(observeParents: false, …)` deliberately avoids each
            // context's hierarchy lock for property-read isolation (see the class-doc
            // at the top of this file). But `eventContinuationsStore` itself is mutated
            // under `context.lock` — `events()` inserts new continuations there, and
            // `onRemoval` clears the dict. Iterating `.values` lockless against those
            // writers is the same `Dictionary`-mid-mutation pattern that produced the
            // `__NSTaggedDate doesNotRecognizeSelector` heap-UAF in `onRemoval` before
            // the `addParent`/`removeParent` lock fix landed.
            //
            // Yielding into the continuations happens outside the lock to avoid
            // holding it across `AsyncStream.Continuation.yield`'s buffer push.
            let continuations = context.lock { Array(context.eventContinuations.values) }
            for continuation in continuations {
                continuation.yield(eventInfo)
            }
        }
    }

    func cancelAllRecursively(for id: some Hashable&Sendable) {
        // Snapshot children under self.lock to avoid racing against concurrent
        // `childContext` writes to `children` (dependency contexts are snapshotted
        // under `dependenciesLock` inside `forEachChild`).
        //
        // CRITICAL: do NOT call `cancellationsStore?.cancelAll(for: id)` while
        // holding self.lock. `cancelAll(for:)` invokes `onCancel()` on each
        // registered cancellable, which for `TaskCancellable` calls
        // `Task.cancel()` → `swift_task_cancelImpl` → `withStatusRecordLock`.
        // Inside that status-record lock the runtime propagates cancellation
        // to child tasks/groups; those child cancellations fire user cancel
        // callbacks (e.g. `ForceObserver.cancel` → `Context.onModify`'s
        // unsubscribe closure) that re-enter context locks. If self.lock is
        // held and a sibling task is already inside `withStatusRecordLock`
        // waiting for the same self.lock (via its own onModify unsubscribe),
        // we deadlock: lock-then-status-record on this side vs.
        // status-record-then-lock on the other side. `Cancellations` has its
        // own internal NSLock for `registered`/`keyed`, so calling cancelAll
        // outside self.lock is fully synchronized.
        //
        // Recursion runs on the snapshot OUTSIDE the lock as well — each
        // child takes its own lock when `cancelAllRecursively` enters it, so
        // we never hold more than one context's lock at a time, matching the
        // parent→child convention `addParent` / `removeParent` use.
        // Snapshot the store in the same locked scope as the children: the raw
        // `cancellationsStore` read otherwise races a concurrent locked lazy
        // creation of the registry.
        let (children, store) = lock { (allChildren, cancellationsStore) }
        store?.cancelAll(for: id)
        for child in children {
            child.cancelAllRecursively(for: id)
        }
    }

    func sealRecursively() {
        // Force-create the store if nil, then seal it atomically.
        // If we only do `cancellationsStore?.seal()`, a nil store is a no-op and any
        // subsequent lazy creation produces an unsealed store — allowing tasks to register
        // after cancelAllRecursively() has already run.
        //
        // Snapshot children under the same lock so the recursive walk doesn't race
        // against concurrent inserts (same reasoning as `cancelAllRecursively`).
        let children = lock {
            if cancellationsStore == nil { cancellationsStore = Cancellations() }
            cancellationsStore!.seal()
            return allChildren
        }
        for child in children {
            child.sealRecursively()
        }
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

    func onAnyModification(callback: @Sendable @escaping (_ModificationCallbackSource) -> (() -> Void)?) -> @Sendable () -> Void {
        let key = generateKey()
        let registered = lock { () -> Bool in
            // Destructed check in the SAME lock scope as the insert (mirrors
            // `events()`): teardown drains `anyModificationCallbacks` under
            // this lock, so an entry registered after the drain would never
            // receive its `isFinished` call and would pin its captures for the
            // context's remaining lifetime.
            guard modeLifeTime != .destructed else { return false }
            anyModificationCallbacks[key] = callback
            withModificationActiveCount {
                $0 += 1
            }
            return true
        }
        guard registered else {
            // Deliver the terminal signal the teardown drain would have sent.
            callback(_ModificationCallbackSource(isFinished: true, kind: .all, depth: 0, origin: nil))?()
            return {}
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

    func didModify(callbacks: inout [() -> Void], kind: ModificationKind, depth: Int, origin: AnyContext, propertyDescription: (@Sendable () -> String?)? = nil) {
        // Process self under self.lock — the caller is responsible for holding it
        // when entering didModify. All entry call sites in Context.swift acquire
        // self.lock around the call (`buildPostLockCallbacks` and friends).
        _modificationCounts = nil
        guard anyModificationActiveCount > 0 else { return }

        let source = _ModificationCallbackSource(isFinished: false, kind: kind, depth: depth, origin: origin, propertyDescription: propertyDescription)
        for callback in anyModificationCallbacks.values {
            if let c = callback(source) {
                callbacks.append(c)
            }
        }

        // Walk ancestors iteratively, holding at most one ancestor's lock at a time.
        //
        // The pre-fix code recursed via `parent.didModify(callbacks:&callbacks, …)`
        // without acquiring `parent.lock`. For same-hierarchy ancestors
        // (`parent.lock === self.lock`) NSRecursiveLock re-entry made the
        // unlocked read safe. For cross-hierarchy ancestors (a separately-
        // anchored model grafted via `addParent`) `parent.lock !== self.lock`
        // and the read of `parent.anyModificationCallbacks.values` raced
        // against concurrent writes to `anyModificationCallbacksStore` —
        // same `Dictionary` mid-mutation pattern fixed in
        // `addParent`/`removeParent` (commit 1955172).
        //
        // The naive fix — wrap the recursive call in `parent.lock { … }` —
        // would chain locks `leaf.lock → parent.lock → grandparent.lock → …`,
        // which is the REVERSE of the `parent.lock → child.lock` order used by
        // `addParent`/`removeParent` (caller holds parent's lock, callee
        // acquires child's lock). Cross-hierarchy concurrent invocations would
        // deadlock: a setter walking didModify upward + a teardown walking
        // removeParent downward on overlapping context pairs each wait for the
        // other's lock.
        //
        // Iterative walk via an explicit DFS stack resolves this by never
        // holding more than one ancestor's lock simultaneously. Each
        // ancestor's contribution (callback dispatch +
        // `_modificationCounts = nil` reset + parents read) is atomic under
        // that ancestor's own lock; the lock is released before descending
        // further. Stack push uses `.reversed()` so the pop order matches the
        // original recursive DFS (each parent's full ancestor subtree drains
        // before the next parent's subtree begins). `_ModificationCallbackSource`
        // is reconstructed per level with the correct `depth`, matching the
        // recursive form.
        var stack: [(AnyContext, Int)] = parents.reversed().map { ($0, depth + 1) }
        while let (current, d) = stack.popLast() {
            let nextParents = current.lock { () -> [AnyContext] in
                current._modificationCounts = nil
                guard current.anyModificationActiveCount > 0 else { return [] }
                let s = _ModificationCallbackSource(isFinished: false, kind: kind, depth: d, origin: origin, propertyDescription: propertyDescription)
                for callback in current.anyModificationCallbacks.values {
                    if let c = callback(s) {
                        callbacks.append(c)
                    }
                }
                return current.parents
            }
            for parent in nextParents.reversed() {
                stack.append((parent, d + 1))
            }
        }
    }

    @TaskLocal static var keepLastSeenAround = false

    /// Walks up the context hierarchy from self to rootParent, returning the first
    /// dependency context found for the given type ID. This ensures child-level
    /// withDependencies overrides take precedence over root-level ones.
    ///
    /// Each ancestor's store is read via `dependencyContext(for:)` — the `dependenciesLock`
    /// leaf lock — never the ancestor's hierarchy lock: the caller may hold self's hierarchy
    /// lock (`dependency(for:)`), and for grafted ancestors `ctx.lock !== self.lock`, so
    /// taking the ancestor's hierarchy lock here would reverse teardown's parent → child
    /// lock order (AB-BA deadlock). Like the parent hops, each read is an independent
    /// snapshot — never more than one lock at a time.
    func nearestDependencyContext(for typeID: ObjectIdentifier) -> AnyContext? {
        // Dep contexts search parents first so the root's explicit override wins over the dep
        // model's own testValue dep defaults (e.g. BackendModel.testValue overrides EnvDep to
        // "backendEnv", but root sets EnvDep to "editor" — root must win). If no parent has
        // an override, fall back to self's own dep contexts (set up by the dep loop in init).
        var current: AnyContext? = isDepContext
            ? parentsLock { weakParents.first?.parent }
            : self
        while let ctx = current {
            if let dep = ctx.dependencyContext(for: typeID) {
                return dep
            }
            if ctx === rootParent { break }
            current = ctx.parentsLock { ctx.weakParents.first?.parent }
        }
        // For dep contexts with no parent override, use own dep-loop context as fallback.
        return isDepContext ? dependencyContext(for: typeID) : nil
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
                if addDependencyContextIfAbsent(child, for: ObjectIdentifier(D.self)) {
                    child.addParent(self, callbacks: &postSetups)
                }
                return
            } else if dependencyContext(for: ObjectIdentifier(D.self)) == nil || reference.lifetime == .destructed {
                if let cacheKey {
                    if let context = rootParent.dependencyContext(for: ObjectIdentifier(D.self)) as? Context<D> {
                        model.withContextAdded(context: context)
                        model.modelContext = ModelContext(context: context)
                    } else {
                        model = model.initialDependencyCopy // make sure to do unique copy of default value (liveValue etc).
                        rootParent.setupModelDependency(&model, cacheKey: nil, postSetups: &postSetups)
                        rootParent.setCachedDependencyValue(model, for: cacheKey)
                    }
                    // Register the shared dependency context on self directly rather than
                    // recursing into setupModelDependency again. At this point the model's
                    // context exists in rootParent.dependencyContexts, but its parent link
                    // to rootParent hasn't been established yet (that happens in postSetups),
                    // so the child.rootParent === rootParent check in the recursive call would
                    // fail, producing an infinite recursion / stack overflow.
                    if let child = model.modelContext.reference?.context {
                        if addDependencyContextIfAbsent(child, for: ObjectIdentifier(D.self)) {
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
                    // Unconditional set: this branch is entered when the entry is nil OR the
                    // previous dep context was destructed — the destructed entry must be replaced.
                    setDependencyContext(child, for: ObjectIdentifier(D.self))
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
                    // For a grafted (separately-anchored) self, `rootParent.lock !== self.lock`
                    // — these writes are synchronized by rootParent's `dependenciesLock`, not
                    // by the hierarchy lock we hold.
                    rootParent.setDependencyContext(child, for: depTypeID)
                    model.withContextAdded(context: child)
                    model.modelContext = ModelContext(context: child)
                    rootParent.setCachedDependencyValue(model, for: cacheKey)
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
                if let child = model.modelContext.reference?.context {
                    if addDependencyContextIfAbsent(child, for: depTypeID) {
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
                if let existing = rootParent.cachedDependencyValue(for: pendingKey) as? Context<D> {
                    model.withContextAdded(context: existing)
                    model.modelContext = ModelContext(context: existing)
                    if addDependencyContextIfAbsent(existing, for: depTypeID) {
                        existing.addParent(self, callbacks: &postSetups)
                    }
                } else {
                    assert(model.context == nil)
                    let child = Context<D>(model: model, lock: lock, dependencies: nil, parent: self, isDepContext: true)
                    child.withModificationActiveCount { $0 = anyModificationActiveCount }
                    setDependencyContext(child, for: depTypeID)
                    model.withContextAdded(context: child)
                    model.modelContext = ModelContext(context: child)
                    // No _linkedReference needed: all pre-anchor copies already hold child.reference
                    // (the single shared Reference). After setContext, ref._context = child.
                    rootParent.setCachedDependencyValue(child, for: pendingKey)
                    postSetups.append {
                        _ = child.onActivate()
                    }
                }
            }
        }
    }

    func dependency<Value>(for keyPath: KeyPath<DependencyValues, Value>&Sendable) -> Value {
        lock {
            if let value = cachedDependencyValue(for: keyPath) as? Value {
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
                        setCachedDependencyValue(model, for: keyPath)
                    }
                    return model as! Value
                } else {
                    if !unprotectedIsDestructed {
                        setCachedDependencyValue(value, for: keyPath)
                    }
                    return value
                }
            }
        }
    }

    func dependency<Value: DependencyKey>(for type: Value.Type) -> Value where Value.Value == Value {
        lock {
            let key = ObjectIdentifier(type)
            if let value = cachedDependencyValue(for: key) as? Value {
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
                        setCachedDependencyValue(model, for: key)
                    }
                    return model as! Value
                } else {
                    if !unprotectedIsDestructed {
                        setCachedDependencyValue(value, for: key)
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
