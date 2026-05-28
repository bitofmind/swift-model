@preconcurrency import Foundation
import Dependencies

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

// MARK: - _SyncAvailabilityObservable

/// Internal protocol adopted by ``ModelUndoStack`` to deliver availability updates
/// synchronously — without going through the Swift cooperative thread pool.
///
/// ``ModelUndoSystem/onActivate()`` checks for this conformance and, when present,
/// registers a sync observer instead of using `node.forEach(backend.availability)`.
/// This avoids async scheduling latency and ensures `canUndo`/`canRedo` are always
/// current immediately after `undo()`/`redo()` returns.
private protocol _SyncAvailabilityObservable: Sendable {
    /// Registers `callback` to be called synchronously (on the calling thread) whenever
    /// undo availability changes. `callback` is also called once immediately with the
    /// current state before `_addSyncObserver` returns.
    ///
    /// Returns a cancel closure. Call it to unregister the observer.
    func _addSyncObserver(_ callback: @escaping @Sendable (UndoAvailability) -> Void) -> @Sendable () -> Void
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
    private var syncObservers: [Int: @Sendable (UndoAvailability) -> Void] = [:]
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
        // Call sync observers first — they update canUndo/canRedo on the model immediately,
        // without any cooperative-pool scheduling. Copy the dict outside the lock so that
        // observers are free to call undo()/redo()/push() without deadlocking.
        let syncs = lock { syncObservers }
        for observer in syncs.values { observer(avail) }
        let conts = lock { continuations }
        for cont in conts.values { cont.yield(avail) }
    }
}

extension ModelUndoStack: _SyncAvailabilityObservable {
    fileprivate func _addSyncObserver(_ callback: @escaping @Sendable (UndoAvailability) -> Void) -> @Sendable () -> Void {
        // Register the observer and capture the current availability atomically under the lock,
        // then deliver the initial state synchronously outside the lock.
        let (key, initialAvail): (Int, UndoAvailability) = lock {
            let k = nextKey
            nextKey += 1
            syncObservers[k] = callback
            return (k, UndoAvailability(canUndo: !undoEntries.isEmpty, canRedo: !redoEntries.isEmpty))
        }
        callback(initialAvail)
        return { [weak self] in
            self?.lock { _ = self?.syncObservers.removeValue(forKey: key) }
        }
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
        if let syncBackend = backend as? any _SyncAvailabilityObservable {
            // Fast path: update canUndo/canRedo synchronously on the calling thread,
            // ensuring they are always current immediately after undo()/redo() returns.
            let cancel = syncBackend._addSyncObserver { [self] avail in
                canUndo = avail.canUndo
                canRedo = avail.canRedo
            }
            node.onCancel(perform: cancel)
        } else {
            // Fallback for custom UndoBackend implementations that don't conform to
            // _SyncAvailabilityObservable: use the async stream path.
            node.forEach(backend.availability) { [self] avail in
                canUndo = avail.canUndo
                canRedo = avail.canRedo
            }
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
