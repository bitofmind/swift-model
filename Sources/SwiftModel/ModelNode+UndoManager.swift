#if canImport(ObjectiveC)
@preconcurrency import Foundation

// MARK: - UndoManagerBackend

/// An ``UndoBackend`` that bridges to a Foundation `UndoManager`.
///
/// Each ``ModelUndoEntry`` pushed via ``push(_:)`` is registered as an undo
/// action on the wrapped `UndoManager`. Undoing replays the entry and
/// automatically registers the reverse action for redo.
///
/// ```swift
/// let backend = UndoManagerBackend(undoManager)
/// let model = MyModel().withAnchor {
///     $0.undoSystem.backend = backend
/// }
/// ```
///
/// From a SwiftUI view, wire it when the `UndoManager` changes:
///
/// ```swift
/// .task(id: undoManager.map(ObjectIdentifier.init)) {
///     model.node.undoSystem.backend = undoManager.map(UndoManagerBackend.init)
/// }
/// ```
public final class UndoManagerBackend: UndoBackend, @unchecked Sendable {
    private let undoManager: UndoManager
    private let target = UndoManagerTarget()

    public init(_ undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    public var availability: AsyncStream<UndoAvailability> {
        let um = undoManager
        return AsyncStream<UndoAvailability> { cont in
            // NSUndoManagerCheckpoint fires after each run-loop pass (groupsByEvent=true)
            // and after each registerUndo/undo/redo call.
            let names: [Notification.Name] = [
                .NSUndoManagerCheckpoint,
                .NSUndoManagerDidUndoChange,
                .NSUndoManagerDidRedoChange,
            ]
            let observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: um, queue: .main
                ) { [weak um] _ in
                    MainActor.assumeIsolated {
                        guard let um else { return }
                        cont.yield(UndoAvailability(canUndo: um.canUndo, canRedo: um.canRedo))
                    }
                }
            }
            DispatchQueue.main.async {
                cont.yield(UndoAvailability(canUndo: um.canUndo, canRedo: um.canRedo))
            }
            cont.onTermination = { _ in
                observers.forEach { NotificationCenter.default.removeObserver($0) }
            }
        }.removeDuplicates().eraseToStream()
    }

    public func push(_ entry: ModelUndoEntry) {
        let um = undoManager
        let t = target
        DispatchQueue.main.async {
            t.register(entry, undoManager: um)
        }
    }

    public func undo() {
        let um = undoManager
        DispatchQueue.main.async { um.undo() }
    }

    public func redo() {
        let um = undoManager
        DispatchQueue.main.async { um.redo() }
    }
}

// MARK: - NSObject shim

/// NSObject shim required by `UndoManager.registerUndo(withTarget:handler:)`.
private final class UndoManagerTarget: NSObject, @unchecked Sendable {
    @MainActor
    func register(_ entry: ModelUndoEntry, undoManager: UndoManager) {
        let needsGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            guard let self else { return }
            // Capture the reverse entry before applying, so redo restores what was here.
            let reverse = entry.captureReverse()
            undoManager.disableUndoRegistration()
            entry.apply()
            undoManager.enableUndoRegistration()
            self.register(reverse, undoManager: undoManager)
        }
        if needsGroup { undoManager.endUndoGrouping() }
    }
}
#endif // canImport(ObjectiveC)
