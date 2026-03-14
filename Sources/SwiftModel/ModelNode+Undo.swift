@preconcurrency import Foundation
import AsyncAlgorithms
import ConcurrencyExtras
import Dependencies

// MARK: - Context storage keys for undo state

extension ContextKeys {
    /// Guards against calling `trackUndo` more than once per context.
    var isTrackingUndo: ContextStorage<Bool> { .init(defaultValue: false, isSystemStorage: true) }

    /// The shared `UndoCoalescer` for a context. Stored directly on the context to avoid
    /// the ObjectIdentifier address-reuse bug that occurs with global static dictionaries.
    fileprivate var undoCoalescer: ContextStorage<UndoCoalescer?> { .init(defaultValue: nil, isSystemStorage: true) }
}

// MARK: - UndoAvailability

/// The combined undo/redo availability state emitted by an ``UndoBackend``.
public struct UndoAvailability: Sendable, Equatable {
    public var canUndo: Bool
    public var canRedo: Bool

    public init(canUndo: Bool = false, canRedo: Bool = false) {
        self.canUndo = canUndo
        self.canRedo = canRedo
    }
}

// MARK: - ModelUndoEntry

/// A single undoable action produced by ``ModelNode/trackUndo(_:)``/``ModelNode/trackUndo()``.
///
/// An entry encapsulates both how to *apply* a state restoration and how to
/// *capture* the reverse action (for redo when undoing, or undo when redoing).
/// ``UndoBackend`` implementations store and replay entries without needing
/// any knowledge of SwiftModel internals.
public struct ModelUndoEntry: Sendable {
    /// Restores the model to the state this entry represents.
    public let apply: @Sendable () -> Void

    /// Returns an entry representing the *current* live model state.
    ///
    /// Call this **before** ``apply`` to capture a reverse action. The returned
    /// entry's ``apply`` will restore the state that existed before this entry
    /// was applied.
    public let captureReverse: @Sendable () -> ModelUndoEntry
}

// MARK: - UndoBackend protocol

/// A backend that stores and replays ``ModelUndoEntry`` values for undo/redo.
///
/// Implement this protocol to provide a custom undo system. Two implementations
/// are included:
/// - ``ModelUndoStack``: An in-memory stack you drive directly.
/// - ``UndoManagerBackend``: Bridges to a Foundation `UndoManager`.
///
/// Set the backend on the ``ModelUndoSystem`` dependency before anchoring:
///
/// ```swift
/// let stack = ModelUndoStack()
/// let model = MyModel().withAnchor {
///     $0.undoSystem.backend = stack
/// }
/// ```
public protocol UndoBackend: Sendable {
    /// A stream that yields the current availability immediately and on every change.
    var availability: AsyncStream<UndoAvailability> { get }

    /// Called when a tracked property changes. Store the entry for later replay.
    func push(_ entry: ModelUndoEntry)

    /// Pop the most recent undo entry and apply it, pushing its reverse onto the redo stack.
    func undo()

    /// Pop the most recent redo entry and apply it, pushing its reverse onto the undo stack.
    func redo()
}

// MARK: - ModelUndoStack

/// An in-memory ``UndoBackend`` with a simple push/undo/redo stack.
///
/// ```swift
/// let stack = ModelUndoStack()
/// let model = MyModel().withAnchor {
///     $0.undoSystem.backend = stack
/// }
///
/// stack.undo()
/// stack.redo()
/// print(stack.canUndo, stack.canRedo)
/// ```
public final class ModelUndoStack: UndoBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var undoEntries: [ModelUndoEntry] = []
    private var redoEntries: [ModelUndoEntry] = []
    private var continuations: [Int: AsyncStream<UndoAvailability>.Continuation] = [:]
    private var nextKey = 0

    public init() {}

    /// The current undo availability (synchronous read for tests and direct use).
    public var canUndo: Bool { lock { !undoEntries.isEmpty } }
    /// The current redo availability (synchronous read for tests and direct use).
    public var canRedo: Bool { lock { !redoEntries.isEmpty } }

    public var availability: AsyncStream<UndoAvailability> {
        let key = lock { defer { nextKey += 1 }; return nextKey }
        return AsyncStream { [weak self] cont in
            guard let self else { cont.finish(); return }
            self.lock { self.continuations[key] = cont }
            cont.yield(UndoAvailability(canUndo: self.canUndo, canRedo: self.canRedo))
            cont.onTermination = { [weak self] _ in
                self?.lock { _ = self?.continuations.removeValue(forKey: key) }
            }
        }.removeDuplicates().eraseToStream()
    }

    public func push(_ entry: ModelUndoEntry) {
        let (wasEmpty, hadRedo) = lock {
            let was = undoEntries.isEmpty
            let had = !redoEntries.isEmpty
            undoEntries.append(entry)
            redoEntries.removeAll()
            return (was, had)
        }
        if wasEmpty || hadRedo { notifyAll() }
    }

    public func undo() {
        guard let entry = lock({ undoEntries.popLast() }) else { return }
        let reverse = entry.captureReverse()
        entry.apply()
        lock { redoEntries.append(reverse) }
        notifyAll()
    }

    public func redo() {
        guard let entry = lock({ redoEntries.popLast() }) else { return }
        let reverse = entry.captureReverse()
        entry.apply()
        lock { undoEntries.append(reverse) }
        notifyAll()
    }

    private func notifyAll() {
        let avail = UndoAvailability(canUndo: canUndo, canRedo: canRedo)
        let conts = lock { continuations }
        for cont in conts.values { cont.yield(avail) }
    }
}

// MARK: - ModelUndoSystem (@Model dependency)

/// The undo/redo dependency injected into the model hierarchy.
///
/// Set a ``backend`` before anchoring the model to enable undo/redo.
/// ``canUndo`` and ``canRedo`` are observable model properties that update
/// reactively as the backend's stack changes.
///
/// ```swift
/// let stack = ModelUndoStack()
/// let model = MyModel().withAnchor {
///     $0.undoSystem.backend = stack
/// }
/// ```
///
/// In your model, call ``ModelNode/trackUndo(_:)`` from `onActivate` to
/// register which properties participate in undo:
///
/// ```swift
/// func onActivate() {
///     node.trackUndo(\.title, \.items)
/// }
/// ```
///
/// Access from views via `model.node.undoSystem`:
///
/// ```swift
/// Button("Undo") { model.node.undoSystem.undo() }
///     .disabled(!model.node.undoSystem.canUndo)
/// ```
@Model public struct ModelUndoSystem {
    /// The backend that stores undo/redo entries.
    ///
    /// Set this before anchoring. Changes after activation are not observed;
    /// use ``UndoManagerBackend`` for system UndoManager integration.
    @_ModelIgnored public var backend: (any UndoBackend)? = nil

    /// Whether there is at least one undoable action available.
    public var canUndo = false
    /// Whether there is at least one redoable action available.
    public var canRedo = false

    public init() {}

    /// Undo the most recent tracked change.
    public func undo() { backend?.undo() }
    /// Redo the most recently undone change.
    public func redo() { backend?.redo() }

    public func onActivate() {
        guard let backend else { return }
        node.forEach(backend.availability) { [self] avail in
            canUndo = avail.canUndo
            canRedo = avail.canRedo
        }
    }
}

extension ModelUndoSystem: DependencyKey {
    public static var liveValue: ModelUndoSystem { ModelUndoSystem() }
    public static var testValue: ModelUndoSystem { ModelUndoSystem() }
}

extension DependencyValues {
    /// The undo system used by ``ModelNode/trackUndo(_:)`` to record undoable changes.
    public var undoSystem: ModelUndoSystem {
        get { self[ModelUndoSystem.self] }
        set { self[ModelUndoSystem.self] = newValue }
    }
}

// MARK: - ModelNode.trackUndo

public extension ModelNode {
    /// Registers all tracked properties of this model for undo/redo tracking.
    ///
    /// Each property is tracked independently. When a property changes, a
    /// ``ModelUndoEntry`` is pushed onto the ``ModelUndoSystem`` dependency's
    /// backend. Multiple property changes within a single `node.transaction {}`
    /// are coalesced into one entry. Changes caused by a restore are not
    /// re-recorded, preventing infinite loops.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.trackUndo()  // tracks all model properties
    /// }
    /// ```
    ///
    /// Each model is responsible for its own properties. Child models that
    /// should participate in undo must call `trackUndo` in their own `onActivate`.
    func trackUndo() {
        guard let context = enforcedContext() else { return }
        guard !context.context.isTrackingUndo else {
            reportIssue("trackUndo() has already been called for this model. Call it only once in onActivate().")
            return
        }
        let undoSystem: ModelUndoSystem = self[dynamicMember: \.undoSystem]
        guard let backend = undoSystem.backend else { return }

        context.context.isTrackingUndo = true
        var visitor = InstallUndoVisitor(context: context, backend: backend, modelContext: _$modelContext, only: nil)
        context.model.visit(with: &visitor, includeSelf: false)
    }

    /// Registers one or more writable key paths for undo/redo tracking.
    ///
    /// When any of the listed properties changes, a ``ModelUndoEntry`` is pushed
    /// onto the ``ModelUndoSystem`` dependency's backend. Multiple property
    /// changes within a single `node.transaction {}` are coalesced into one entry.
    /// Changes caused by a restore are not re-recorded, preventing infinite loops.
    ///
    /// Each model is responsible for its own properties — child models that
    /// should participate in undo must call `trackUndo` in their own `onActivate`.
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Only \.items participates in undo; \.newItemTitle is excluded.
    ///     node.trackUndo(\.items)
    /// }
    /// ```
    func trackUndo<each PathValue: Sendable>(
        _ paths: repeat WritableKeyPath<M, each PathValue> & Sendable
    ) {
        guard let context = enforcedContext() else { return }
        guard !context.context.isTrackingUndo else {
            reportIssue("trackUndo() has already been called for this model. Call it only once in onActivate().")
            return
        }
        let undoSystem: ModelUndoSystem = self[dynamicMember: \.undoSystem]
        guard let backend = undoSystem.backend else { return }

        // The user-provided paths are computed properties (e.g. \.items), but the @Model
        // macro generates accessors that read/write private backing storage (e.g. \._items).
        // We need the backing paths to register onModify callbacks correctly.
        //
        // Strategy: read each path on the LIVE model while a BackingPathCollector is installed
        // as the active ModelAccess. The live model routes reads through Context.subscript._read,
        // which calls willAccess(model, at: backingPath) before yielding. Frozen copies bypass
        // the Context machinery entirely and never fire willAccess.
        let collector = BackingPathCollector<M>()
        usingActiveAccess(collector) {
            func collect<PV>(_ path: WritableKeyPath<M, PV> & Sendable) {
                _ = context.model[keyPath: path]
            }
            repeat collect(each paths)
        }
        let trackedBackingPaths = collector.paths

        context.context.isTrackingUndo = true
        var visitor = InstallUndoVisitor(context: context, backend: backend, modelContext: _$modelContext, only: trackedBackingPaths)
        context.model.visit(with: &visitor, includeSelf: false)
    }

    /// Registers all tracked properties **except** the listed ones for undo/redo tracking.
    ///
    /// Equivalent to `trackUndo()` but excludes specific key paths from the undo stack.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.trackUndo(excluding: \.draftText)
    /// }
    /// ```
    func trackUndo<each PathValue: Sendable>(
        excluding paths: repeat WritableKeyPath<M, each PathValue> & Sendable
    ) {
        guard let context = enforcedContext() else { return }
        guard !context.context.isTrackingUndo else {
            reportIssue("trackUndo() has already been called for this model. Call it only once in onActivate().")
            return
        }
        let undoSystem: ModelUndoSystem = self[dynamicMember: \.undoSystem]
        guard let backend = undoSystem.backend else { return }

        let collector = BackingPathCollector<M>()
        usingActiveAccess(collector) {
            func collect<PV>(_ path: WritableKeyPath<M, PV> & Sendable) {
                _ = context.model[keyPath: path]
            }
            repeat collect(each paths)
        }
        let excludedBackingPaths = collector.paths

        context.context.isTrackingUndo = true
        var visitor = InstallUndoVisitor(context: context, backend: backend, modelContext: _$modelContext, excluding: excludedBackingPaths)
        context.model.visit(with: &visitor, includeSelf: false)
    }
}

// MARK: - InstallUndoVisitor

/// Visits each field of a model and installs a per-property `onModify` undo callback.
///
/// The visitor is used by all `trackUndo` variants:
/// - `only == nil, excluding == nil`:  install for all fields (zero-arg `trackUndo()`)
/// - `only != nil`:                    install only for fields whose backing path is in `only`
/// - `excluding != nil`:               install for all fields except those in `excluding`
private struct InstallUndoVisitor<M: Model>: ModelVisitor {
    typealias State = M

    let context: Context<M>
    let backend: any UndoBackend
    let modelContext: ModelContext<M>
    // When non-nil, only these backing paths are installed.
    nonisolated(unsafe) let only: Set<PartialKeyPath<M>>?
    // When non-nil, skip these backing paths (all-except variant).
    nonisolated(unsafe) let excluding: Set<PartialKeyPath<M>>?

    init(context: Context<M>, backend: any UndoBackend, modelContext: ModelContext<M>,
         only: Set<PartialKeyPath<M>>?) {
        self.context = context
        self.backend = backend
        self.modelContext = modelContext
        self.only = only
        self.excluding = nil
    }

    init(context: Context<M>, backend: any UndoBackend, modelContext: ModelContext<M>,
         excluding: Set<PartialKeyPath<M>>) {
        self.context = context
        self.backend = backend
        self.modelContext = modelContext
        self.only = nil
        self.excluding = excluding
    }

    private func shouldInstall(path: PartialKeyPath<M>) -> Bool {
        if let only { return only.contains(path) }
        if let excluding { return !excluding.contains(path) }
        return true
    }

    mutating func visit<T>(path: WritableKeyPath<M, T>) {
        guard shouldInstall(path: path) else { return }
        // T is not constrained to Sendable by the ModelVisitor protocol, but @Model properties
        // are always Sendable in practice. We use unsafeBitCast (same pattern as RestoreVisitor)
        // to satisfy the Swift concurrency checker.
        installPropertyUndoUnchecked(for: path, context: context, backend: backend, modelContext: modelContext)
    }

    // Model and ModelContainer fields are stored as a whole value (snapshot of the full
    // field). Writing them back goes through the normal context assignment path which
    // handles child-context re-creation automatically. We use initialCopy (not frozenCopy)
    // so that restored values can be re-anchored by the context assignment path.
    mutating func visit<T: Model & Sendable>(path: WritableKeyPath<M, T>) {
        guard shouldInstall(path: path) else { return }
        installPropertyUndoUnchecked(for: path, context: context, backend: backend, modelContext: modelContext, useInitialCopy: true)
    }

    mutating func visit<T: ModelContainer & Sendable>(path: WritableKeyPath<M, T>) {
        guard shouldInstall(path: path) else { return }
        installPropertyUndoUnchecked(for: path, context: context, backend: backend, modelContext: modelContext, useInitialCopy: true)
    }
}

// MARK: - Per-property undo installation

/// Installs a single `onModify` undo callback for a typed backing path.
///
/// `T` is treated as Sendable via `nonisolated(unsafe)` — valid because all `@Model`
/// stored properties must be Sendable in practice (the macro enforces this).
///
/// When the property at `path` changes:
/// 1. The old value (captured in `baseline`) and a restore closure are handed to the
///    shared ``UndoCoalescer`` for this context.
/// 2. The coalescer merges all property changes that occur within one transaction
///    into a single ``ModelUndoEntry`` pushed to the backend.
private func installPropertyUndoUnchecked<M: Model, T>(
    for path: WritableKeyPath<M, T>,
    context: Context<M>,
    backend: any UndoBackend,
    modelContext: ModelContext<M>,
    useInitialCopy: Bool = false
) {
    // All @Model stored properties are Sendable in practice (the macro enforces this).
    // We use nonisolated(unsafe) / unsafeBitCast to satisfy the Swift concurrency checker
    // without adding a T: Sendable constraint that the ModelVisitor protocol cannot provide.
    let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)

    // One coalescer is shared across all properties registered for the same context/backend.
    let coalescer = UndoCoalescer.forContext(context, backend: backend)

    // Per-property baseline: last committed value, used to build undo entries.
    // Wrapped in a class box so @Sendable closures can capture it without a T: Sendable constraint.
    // For Model/ModelContainer typed properties we use initialCopy (not frozenCopy) so that
    // restored values can be re-anchored by the context assignment path. Frozen copies are
    // rejected by the setter ("It is not allowed to add a destructed nor frozen model.").
    let baseline = UnsafeSendableBox(snapshotValue(context.model[keyPath: path], useInitialCopy: useInitialCopy))

    let cancel = context.onModify(for: sendablePath) { hasEnded, _ in
        guard !hasEnded else { return nil }
        guard !threadLocals.isRestoringState else { return nil }

        let oldValue = baseline.value
        let newValue = snapshotValue(context.model[keyPath: sendablePath], useInitialCopy: useInitialCopy)

        guard !areEqual(oldValue, newValue) else { return nil }

        // Builds a closure that writes `value` back into the live model.
        // Uses modelContext.transaction(with:at:) which ends the inout access before
        // postLockCallbacks run — safe to call from within another callback chain.
        //
        // We run the transaction under `usingAccess(rootAccess)` where `rootAccess` is the
        // ModelAccess registered on the root model (e.g. TestAccess in tests). Without this,
        // `ModelAccess.current` and `ModelAccess.active` are both nil during undo, so
        // TestAccess.lastState is never updated and the tester's exhaustion check fails.
        @Sendable func makeRestore(value: T) -> @Sendable () -> Void {
            nonisolated(unsafe) let v = value
            return {
                // Skip if the model has been destructed (e.g. item removed from parent array).
                guard context.lifetime == .active else { return }
                // Propagate the root access (e.g. TestAccess) so that didModify notifications
                // fire correctly during restore. The root context's readModel._$modelContext
                // holds the registered ModelAccess; child contexts have _access = nil.
                let rootAccess = context.rootParent.anyModelAccess
                usingAccess(rootAccess) {
                    threadLocals.withValue(true, at: \.isRestoringState) {
                        if let ctx = ModelNode(_$modelContext: modelContext)._context {
                            modelContext.transaction(with: ctx.model, at: sendablePath, modify: { $0 = v }, isSame: nil)
                        }
                    }
                }
                baseline.value = v
            }
        }

        // captureReverse: reads the current live value and returns a restore closure for it.
        // Guards against the context having been destructed (e.g. the item was removed from
        // its parent array and then re-added via undo — the old context is gone).
        let captureCurrentReverse: @Sendable () -> @Sendable () -> Void = {
            guard context.lifetime == .active else {
                // Context is gone — return a no-op restore.
                return {}
            }
            let currentValue = snapshotValue(context.model[keyPath: sendablePath], useInitialCopy: useInitialCopy)
            return makeRestore(value: currentValue)
        }

        let restore = makeRestore(value: oldValue)

        return {
            baseline.value = newValue
            coalescer.add(restore: restore, captureReverse: captureCurrentReverse)
        }
    }
    _ = AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
}

/// Returns a snapshot of `value` suitable for undo baseline/restore storage.
///
/// - `useInitialCopy == true` (Model/ModelContainer properties): returns `initialCopy`, which
///   creates a fresh `Reference` that can be re-anchored by the context assignment path during
///   restore. `frozenCopy` would produce values rejected by the setter.
/// - `useInitialCopy == false` (plain value types): returns `frozenCopy`, which freezes any
///   nested `ModelContainer` trees so they are safe to capture in closures.
private func snapshotValue<T>(_ value: T, useInitialCopy: Bool) -> T {
    if useInitialCopy, let container = value as? any ModelContainer {
        return container.initialCopy as! T
    }
    return frozenCopy(value)
}

/// A class box that allows capturing non-Sendable values in @Sendable closures via
/// nonisolated(unsafe). Used in installPropertyUndoUnchecked where T may not be Sendable
/// at the type-system level but is always Sendable in practice for @Model properties.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - UndoCoalescer

/// Collects all property-change restore closures that arrive during a single transaction
/// (one `postLockCallbacks` flush) and merges them into a single ``ModelUndoEntry``.
///
/// One coalescer is shared per `(context, backend)` pair. When the first property change
/// arrives in a batch, the coalescer registers a flush callback via `context.onPostTransaction`;
/// subsequent changes in the same batch append to the accumulator. The flush runs after all
/// per-property callbacks have fired, building and pushing one merged entry.
private final class UndoCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let backend: any UndoBackend
    // Accumulated restore/captureReverse pairs for the current transaction batch.
    private var pending: [PendingChange] = []
    private var isFlushScheduled = false

    struct PendingChange {
        let restore: @Sendable () -> Void
        let captureReverse: @Sendable () -> @Sendable () -> Void
    }

    init(backend: any UndoBackend) {
        self.backend = backend
    }

    // MARK: - Shared instance lookup

    // The coalescer is stored directly on the context to avoid the ObjectIdentifier
    // address-reuse bug: two concurrent tests can allocate Context<M> at the same memory
    // address, causing a global-dict lookup keyed by ObjectIdentifier to return the wrong
    // (still-live) coalescer from the other test and push undo entries to the wrong backend.
    static func forContext<M: Model>(_ context: Context<M>, backend: any UndoBackend) -> UndoCoalescer {
        return context.lock {
            if let existing = context.context.undoCoalescer {
                return existing
            }
            let new = UndoCoalescer(backend: backend)
            context.context.undoCoalescer = new
            return new
        }
    }

    // MARK: - Accumulation

    /// Called from each per-property `onModify` postLockCallback.
    func add(restore: @escaping @Sendable () -> Void, captureReverse: @escaping @Sendable () -> @Sendable () -> Void) {
        lock {
            pending.append(PendingChange(restore: restore, captureReverse: captureReverse))
        }
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        // Register the flush to run at the end of the current postLockCallbacks pass.
        // onPostTransaction is called from within postLockCallbacks, so if postTransactions
        // is already being drained, this append runs after all current callbacks.
        //
        // We use a simple flag to avoid registering the flush closure more than once per batch.
        let shouldSchedule = lock {
            guard !isFlushScheduled else { return false }
            isFlushScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        // If we're inside a postLockCallbacks pass (signalled by postLockFlushes being non-nil),
        // append the flush to run AFTER all per-property onModify callbacks for the transaction
        // have completed. This ensures that multi-property transactions produce one merged entry.
        // Outside postLockCallbacks (e.g. from a background thread or directly from user code),
        // flush synchronously.
        if threadLocals.postLockFlushes != nil {
            threadLocals.postLockFlushes!.append { [weak self] in self?.flush() }
        } else {
            flush()
        }
    }

    private func flush() {
        let changes = lock {
            defer {
                pending.removeAll()
                isFlushScheduled = false
            }
            return pending
        }
        guard !changes.isEmpty else { return }

        let entry = makeEntry(for: changes)
        backend.push(entry)
    }

    private func makeEntry(for changes: [PendingChange]) -> ModelUndoEntry {
        makeEntryFromRestores(
            applyRestores: changes.map { $0.restore },
            captureReverses: changes.map { $0.captureReverse }
        )
    }

    private func makeEntryFromRestores(
        applyRestores: [@Sendable () -> Void],
        captureReverses: [@Sendable () -> @Sendable () -> Void]
    ) -> ModelUndoEntry {
        ModelUndoEntry(
            apply: {
                for restore in applyRestores { restore() }
            },
            captureReverse: { [self] in
                // Capture current live values for all changed properties to build the reverse entry.
                let reverseRestores = captureReverses.map { $0() }
                // The reverse entry's captureReverse re-captures at that future point in time.
                return self.makeEntryFromRestores(applyRestores: reverseRestores, captureReverses: captureReverses)
            }
        )
    }
}

// MARK: - Equality helper

/// Returns `true` when both values are `Equatable` and compare equal.
/// Returns `false` for non-Equatable types so the caller always treats them as changed.
private func areEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    func openEquatable<E: Equatable>(_ l: E, _ r: Any) -> Bool {
        (r as? E).map { l == $0 } ?? false
    }
    if let l = lhs as? any Equatable {
        return openEquatable(l, rhs)
    }
    return false
}

// MARK: - Backing path collector

/// A `ModelAccess` subclass that intercepts `willAccess` callbacks to collect the
/// backing key paths accessed when reading a model's properties.
///
/// Used by `trackUndo(_ paths:)` and `trackUndo(excluding:)` to map user-provided
/// computed key paths (e.g. `\.items`) to the private backing storage paths (e.g. `\._items`)
/// generated by the `@Model` macro. Must be installed via `usingActiveAccess` while
/// reading from the LIVE model — frozen copies bypass `Context` and never fire `willAccess`.
private final class BackingPathCollector<M: Model>: ModelAccess, @unchecked Sendable {
    private(set) var paths: Set<PartialKeyPath<M>> = []

    init() {
        super.init(useWeakReference: false)
    }

    override func willAccess<N: Model, T>(_ model: N, at path: KeyPath<N, T> & Sendable) -> (() -> Void)? {
        if let typedPath = path as? PartialKeyPath<M> {
            paths.insert(typedPath)
        }
        return nil
    }
}
