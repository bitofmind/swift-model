@preconcurrency import Foundation
import ConcurrencyExtras
import Dependencies

// MARK: - Snapshot types

struct ModelStateSnapshot<M: Model>: Sendable {
    let frozenValue: M
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

/// A single undoable action produced by ``ModelNode/trackUndo(_:)``.
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
    @ModelIgnored public var backend: (any UndoBackend)? = nil

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
    /// Registers all `@ModelTracked` properties for undo/redo tracking.
    ///
    /// When any tracked property in this model changes, a ``ModelUndoEntry`` is pushed
    /// onto the ``ModelUndoSystem`` dependency's backend. Changes caused by a
    /// restore are not re-recorded, preventing infinite loops.
    ///
    /// This is the simplest way to enable full undo/redo. Use ``trackUndo(_:)`` with
    /// explicit key paths if you need to track only a subset of properties.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.trackUndo()  // tracks all @ModelTracked properties
    /// }
    /// ```
    ///
    /// Inject a backend at anchor time:
    ///
    /// ```swift
    /// let stack = ModelUndoStack()
    /// let model = MyModel().withAnchor { $0.undoSystem.backend = stack }
    /// ```
    func trackUndo() {
        _setupUndoTracking { previous, current in
            var visitor = DiffVisitor(lhs: previous, rhs: current)
            previous.visit(with: &visitor, includeSelf: false)
            return visitor.anyChanged
        }
    }

    /// Registers one or more writable key paths for undo/redo tracking.
    ///
    /// When any of the listed properties changes, a ``ModelUndoEntry`` is pushed
    /// onto the ``ModelUndoSystem`` dependency's backend. Changes caused by a
    /// restore are not re-recorded, preventing infinite loops.
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Only \.items participates in undo; \.newItemTitle is excluded.
    ///     node.trackUndo(\.items)
    /// }
    /// ```
    ///
    /// Inject a backend at anchor time:
    ///
    /// ```swift
    /// let stack = ModelUndoStack()
    /// let model = MyModel().withAnchor { $0.undoSystem.backend = stack }
    /// ```
    func trackUndo<each V: Equatable & Sendable>(
        _ paths: repeat WritableKeyPath<M, each V> & Sendable
    ) {
        // The user-provided paths are computed properties (e.g. \.items), but the @Model macro
        // generates accessors that read/write the private backing storage (e.g. \._items).
        // We need the backing paths because:
        //
        // 1. Restore safety: writing via a computed WritableKeyPath goes through the property
        //    setter → Context.subscript._modify → `yield &modifyModel[keyPath: path]`. That
        //    `yield` holds an inout exclusive access on the storage while postLockCallbacks run.
        //    If a restore callback fires from postLockCallbacks and tries to write the same
        //    path again, Swift sees two simultaneous inout accesses → process terminates.
        //    RestoreVisitor avoids this by writing via Context.transaction(at: backingPath),
        //    where the inout ends before postLockCallbacks.
        //
        // 2. Path collection: we intercept willAccess on the LIVE model (not a frozen copy).
        //    Frozen copies bypass the Context machinery and don't fire willAccess.
        //    The live model goes through Context.subscript._read, which calls
        //    willAccess(model, at: backingPath) before yielding the value. Setting
        //    ModelAccess.active = collector before the reads lets us capture those paths.
        guard let context = enforcedContext() else { return }

        // Map user-provided computed paths (e.g. \.tracked) to backing storage paths
        // (e.g. \._tracked) by intercepting willAccess on the LIVE model.
        //
        // Frozen copies do NOT fire willAccess — they bypass the Context machinery and
        // yield model[keyPath: path] directly. The live model goes through
        // Context.subscript._read which calls willAccess(model, at: backingPath).
        // We set ModelAccess.active to our collector so that the willAccess calls land on it.
        let collector = BackingPathCollector<M>()
        usingActiveAccess(collector) {
            func collectPath<PathValue: Equatable & Sendable>(_ path: WritableKeyPath<M, PathValue> & Sendable) {
                _ = context.model[keyPath: path]
            }
            repeat collectPath(each paths)
        }
        let trackedBackingPaths = collector.paths

        _setupUndoTracking(trackedBackingPaths: trackedBackingPaths) { previousFrozen, currentFrozen in
            var anyChanged = false
            func checkChanged<PathValue: Equatable & Sendable>(_ path: WritableKeyPath<M, PathValue> & Sendable) {
                guard !anyChanged else { return }
                let keyPath = path as KeyPath<M, PathValue>
                if previousFrozen[keyPath: keyPath] != currentFrozen[keyPath: keyPath] {
                    anyChanged = true
                }
            }
            repeat checkChanged(each paths)
            return anyChanged
        }
    }
}

private extension ModelNode {
    /// Shared scaffolding for all `trackUndo` variants.
    ///
    /// Sets up the ``SnapshotBaseline``, restore closure, ``UndoEntryFactory``, and
    /// ``onAnyModification`` callback. The `hasChanged` closure is the only thing
    /// that differs between variants — it receives the previous and current frozen
    /// copies and returns whether the change is relevant.
    ///
    /// - Parameter trackedBackingPaths: When non-nil, `RestoreVisitor` restores only these
    ///   backing paths. Used by `trackUndo(\.field)` for selective restoration.
    ///   When nil, all fields are restored via `RestoreVisitor`.
    func _setupUndoTracking(
        trackedBackingPaths: Set<PartialKeyPath<M>>? = nil,
        hasChanged: @escaping @Sendable (_ previous: M, _ current: M) -> Bool
    ) {
        guard let context = enforcedContext() else { return }
        let undoSystem: ModelUndoSystem = self[dynamicMember: \.undoSystem]
        guard let backend = undoSystem.backend else { return }
        let modelContext = _$modelContext

        // `baseline` tracks the last committed snapshot so we can always hand the backend
        // the "before this change" state. Updated atomically inside the post-transaction
        // callback, so it is always consistent with the live model.
        let baseline = SnapshotBaseline(snapshot: context.model.frozenCopy)

        // Closure that restores a typed snapshot into the live model.
        // RestoreVisitor writes directly via backing paths using Context.transaction(at:),
        // which is safe to call from within ctx.transaction {} (postLockCallbacks) because
        // the inout access ends before postLockCallbacks run. If trackedBackingPaths is
        // provided, only those paths are restored; otherwise all fields are restored.
        //
        // PartialKeyPath does not conform to Sendable in all Swift compiler versions, so we
        // use nonisolated(unsafe) to suppress the concurrency warning. The paths are
        // immutable after construction and safe to share across threads.
        nonisolated(unsafe) let sendableTrackedPaths = trackedBackingPaths
        let restore: @Sendable (ModelStateSnapshot<M>) -> Void = { snapshot in
            let node = ModelNode(_$modelContext: modelContext)
            var postRestoreSnapshot: M? = nil
            threadLocals.withValue(true, at: \.isRestoringState) {
                if let ctx = node.context {
                    ctx.transaction {
                        restoreModel(snapshot.frozenValue, into: ctx, using: modelContext, only: sendableTrackedPaths)
                        postRestoreSnapshot = ctx.model.frozenCopy
                    }
                }
            }
            // Sync the baseline with the actual restored state so that subsequent
            // onAnyModification callbacks do not see a stale baseline.
            _ = baseline.swap(to: postRestoreSnapshot ?? snapshot.frozenValue)
        }

        // UndoEntryFactory (file-scoped below) builds ModelUndoEntry values. Using a
        // class allows its `make` method to be captured by @Sendable closures, enabling
        // the recursive captureReverse chain without @Sendable local-function restrictions.
        let factory = UndoEntryFactory(
            restore: restore,
            captureNow: { ModelStateSnapshot(frozenValue: context.model.frozenCopy) }
        )

        let cancel = context.onAnyModification { hasEnded in
            guard !hasEnded else { return nil }
            guard !threadLocals.isRestoringState else { return nil }

            let currentFrozen = context.model.frozenCopy
            let previousFrozen = baseline.value

            guard hasChanged(previousFrozen, currentFrozen) else { return nil }

            return {
                let before = baseline.swap(to: currentFrozen)
                let entry = factory.make(for: ModelStateSnapshot(frozenValue: before))
                backend.push(entry)
            }
        }
        _ = AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
    }
}

// MARK: - Internal restore machinery

/// Walks the fields of `snapshot` (a frozenCopy) and writes each field's value
/// into the live `context`. If `only` is non-nil, only those backing paths are restored.
private func restoreModel<M: Model>(_ snapshot: M, into context: Context<M>, using modelContext: ModelContext<M>, only trackedPaths: Set<PartialKeyPath<M>>? = nil) {
    var visitor = RestoreVisitor(snapshot: snapshot, context: context, modelContext: modelContext, trackedPaths: trackedPaths)
    context.model.visit(with: &visitor, includeSelf: false)
}

private struct RestoreVisitor<M: Model>: ModelVisitor {
    typealias State = M

    let snapshot: M
    let context: Context<M>
    let modelContext: ModelContext<M>
    /// When non-nil, only these backing paths are restored; others are skipped.
    let trackedPaths: Set<PartialKeyPath<M>>?

    mutating func visit<T>(path: WritableKeyPath<M, T>) {
        if let trackedPaths, !trackedPaths.contains(path) { return }
        let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)
        let newValue = snapshot[keyPath: path]
        if areEqual(newValue, context.model[keyPath: path]) { return }
        modelContext[model: context.model, path: sendablePath] = newValue
    }

    mutating func visit<T: Model>(path: WritableKeyPath<M, T>) {
        if let trackedPaths, !trackedPaths.contains(path) { return }
        let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)
        let snapshotChild = snapshot[keyPath: path]
        let liveChild = context.model[keyPath: path]

        if snapshotChild.id == liveChild.id {
            if let childContext = liveChild.context {
                // Use usingActiveAccess (not usingAccess) so that didModify notifications
                // from child context property writes reach ModelAccess.active (e.g. TestAccess),
                // which reads ModelAccess.active rather than ModelAccess.current.
                usingActiveAccess(modelContext.access) {
                    restoreModel(snapshotChild, into: childContext, using: ModelContext(context: childContext))
                }
            }
        } else {
            let restoredChild = snapshotChild.initialCopy
            modelContext[model: context.model, path: sendablePath] = restoredChild
        }
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<M, T>) {
        if let trackedPaths, !trackedPaths.contains(path) { return }
        let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)
        let snapshotContainer = snapshot[keyPath: path]
        let snapshotModels: [AnyHashable: any Model] = snapshotContainer.reduceValue(
            with: CollectModelsReducer.self,
            initialValue: [:]
        )
        var liveContextsByID: [AnyHashable: AnyContext] = [:]
        context.model[keyPath: path].forEachContext {
            liveContextsByID[$0.anyModel.anyModelID] = $0
        }
        let restoredContainer = snapshotContainer.initialCopy
        modelContext[model: context.model, path: sendablePath] = restoredContainer
        // Use usingActiveAccess (not usingAccess) so that didModify notifications from
        // child context writes reach ModelAccess.active (e.g. TestAccess).
        usingActiveAccess(modelContext.access) {
            for (id, snapshotModel) in snapshotModels {
                guard let liveContext = liveContextsByID[id] else { continue }
                restoreMatchedContext(snapshot: snapshotModel, liveContext: liveContext)
            }
        }
    }
}

private enum CollectModelsReducer: ValueReducer {
    typealias Value = [AnyHashable: any Model]
    static func reduce(value: inout Value, model: some Model) {
        value[model.anyModelID] = model
    }
}

private func restoreMatchedContext(snapshot: any Model, liveContext: AnyContext) {
    func open<S: Model>(_ snapshot: S) {
        guard let typedContext = liveContext as? Context<S> else { return }
        // Child contexts are always fully restored (no path filtering).
        restoreModel(snapshot, into: typedContext, using: ModelContext(context: typedContext), only: nil)
    }
    open(snapshot)
}

// MARK: - ID helpers

private extension AnyContext {
    var anyModelID: AnyHashable { anyModel.anyModelID }
}

private extension Model {
    var anyModelID: AnyHashable { AnyHashable(id) }
}

// MARK: - Diff visitor

/// Compares two frozen copies of a model field-by-field using the `ModelVisitor` pattern.
/// Sets `anyChanged` to `true` as soon as any tracked field differs between `lhs` and `rhs`.
/// Used by the zero-argument ``ModelNode/trackUndo()`` to detect whether any field changed.
private struct DiffVisitor<M: Model>: ModelVisitor {
    typealias State = M
    let lhs: M
    let rhs: M
    var anyChanged = false

    mutating func visit<T>(path: WritableKeyPath<M, T>) {
        guard !anyChanged else { return }
        if !areEqual(lhs[keyPath: path], rhs[keyPath: path]) {
            anyChanged = true
        }
    }

    mutating func visit<T: Model>(path: WritableKeyPath<M, T>) {
        guard !anyChanged else { return }
        let l = lhs[keyPath: path]
        let r = rhs[keyPath: path]
        // Different identities mean the field was replaced entirely.
        if l.id != r.id { anyChanged = true; return }
        // Same identity — recurse into the child to check its fields.
        var child = DiffVisitor<T>(lhs: l, rhs: r)
        l.visit(with: &child, includeSelf: false)
        if child.anyChanged { anyChanged = true }
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<M, T>) {
        guard !anyChanged else { return }
        if !areEqual(lhs[keyPath: path], rhs[keyPath: path]) {
            anyChanged = true
        }
    }
}

// MARK: - UndoEntry factory helper

/// Builds ``ModelUndoEntry`` values for `trackUndo`. Implemented as a class so its
/// `make` method can be captured by `@Sendable` closures — Swift does not allow
/// recursive local functions to be marked `@Sendable`, and generic functions
/// prohibit nested class declarations.
private final class UndoEntryFactory<M: Model>: @unchecked Sendable {
    let restore: @Sendable (ModelStateSnapshot<M>) -> Void
    let captureNow: @Sendable () -> ModelStateSnapshot<M>

    init(
        restore: @escaping @Sendable (ModelStateSnapshot<M>) -> Void,
        captureNow: @escaping @Sendable () -> ModelStateSnapshot<M>
    ) {
        self.restore = restore
        self.captureNow = captureNow
    }

    func make(for snapshot: ModelStateSnapshot<M>) -> ModelUndoEntry {
        ModelUndoEntry(
            apply: { self.restore(snapshot) },
            captureReverse: { self.make(for: self.captureNow()) }
        )
    }
}

// MARK: - Snapshot baseline helper

/// A `LockIsolated`-backed mutable snapshot used inside `trackUndo` to track the last
/// committed model state. Updated atomically so it is always consistent with the live model.
private final class SnapshotBaseline<M: Model>: @unchecked Sendable {
    private let storage: LockIsolated<M>

    init(snapshot: M) {
        storage = LockIsolated(snapshot)
    }

    /// The current stored snapshot (read-only).
    var value: M { storage.value }

    /// Atomically replaces the stored snapshot with `new` and returns the old value.
    @discardableResult
    func swap(to new: M) -> M {
        storage.withValue { old in
            defer { old = new }
            return old
        }
    }
}

// MARK: - Equality helpers

/// Returns `true` when both values are `Equatable` and compare equal.
/// Returns `false` for non-Equatable types so the caller always writes in that case.
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
/// backing key paths that are accessed when reading a model's properties.
///
/// Used by `trackUndo(_ paths:)` to map user-provided computed key paths (e.g. `\.items`)
/// to the private backing storage paths (e.g. `\._items`) generated by the `@Model` macro.
/// Must be installed via `usingActiveAccess` while reading from the LIVE model — frozen copies
/// bypass `Context` and never fire `willAccess`.
/// The collected backing paths are passed to `RestoreVisitor` for safe selective restoration.
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


