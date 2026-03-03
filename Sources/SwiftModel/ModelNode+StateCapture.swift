import Foundation

/// An opaque snapshot of a model tree's value state at a point in time.
///
/// Obtain a snapshot via ``ModelNode/captureState()`` and restore it via
/// ``ModelNode/restoreState(_:)``. Snapshots are value types and safe to
/// store in arrays (undo/redo stacks) or pass across concurrency boundaries.
///
/// > Note: A snapshot captures *data values* only. Running tasks, event
/// > streams, and dependency references are **not** part of the snapshot.
/// > Restoring a snapshot does not rewind ongoing async work.
public struct ModelStateSnapshot<M: Model>: Sendable {
    let frozenValue: M
}

/// Controls when a frozen copy of the model is taken in an ``ModelNode/onChange(capture:perform:)`` callback.
public enum ModelCaptureMode: Sendable {
    /// The frozen copy is taken on demand when ``ModelChangeProxy/snapshot`` is first accessed.
    ///
    /// This is the default. It is zero-cost if you never access `proxy.snapshot` (e.g. for
    /// dirty tracking). A small race window exists: another thread could mutate the model
    /// between the callback firing and `snapshot` being accessed.
    case lazy

    /// A frozen copy is taken synchronously before the callback is invoked.
    ///
    /// The copy is taken in the same post-transaction step as the callback dispatch,
    /// so it reflects exactly the state that triggered the callback. Slightly more
    /// expensive per modification because the copy is always taken, even if `snapshot`
    /// is never accessed.
    case eager
}

/// Passed to the callback registered with ``ModelNode/onChange(capture:perform:)``.
///
/// Call ``snapshot`` to obtain the captured model state. With `.lazy` capture (the default)
/// the frozen copy is taken on first access. With `.eager` capture it was taken atomically
/// inside the transaction.
public struct ModelChangeProxy<M: Model>: Sendable {
    private enum Storage: Sendable {
        case lazy(ModelContext<M>)
        case eager(M)
    }

    private let storage: Storage

    init(lazyContext: ModelContext<M>) {
        storage = .lazy(lazyContext)
    }

    init(eagerFrozen: M) {
        storage = .eager(eagerFrozen)
    }

    /// The model state at the moment the modification was committed.
    ///
    /// With `.lazy` capture, this performs a `frozenCopy` on first access.
    /// With `.eager` capture, the frozen copy was already taken inside the transaction.
    public var snapshot: ModelStateSnapshot<M> {
        switch storage {
        case .lazy(let modelContext):
            guard let context = modelContext.reference?.context else {
                // Model was deactivated between the callback and snapshot access.
                // Return the last known value from the reference if available.
                guard let lastKnown = modelContext.reference?.model else {
                    preconditionFailure("ModelChangeProxy.snapshot accessed after model was deactivated")
                }
                return ModelStateSnapshot(frozenValue: lastKnown)
            }
            return ModelStateSnapshot(frozenValue: context.model.frozenCopy)
        case .eager(let frozen):
            return ModelStateSnapshot(frozenValue: frozen)
        }
    }
}

public extension ModelNode {
    /// Captures the current state of the entire model tree rooted at this node.
    ///
    /// The snapshot is an immutable value copy of all tracked properties in this
    /// model and all of its descendants. Use it to implement undo/redo by storing
    /// snapshots in a stack and calling ``restoreState(_:)`` to revert.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.onChange { proxy in
    ///         undoStack.append(proxy.snapshot)
    ///         redoStack.removeAll()
    ///     }
    /// }
    ///
    /// func undo() {
    ///     guard let snapshot = undoStack.popLast() else { return }
    ///     redoStack.append(node.captureState())
    ///     node.restoreState(snapshot)
    /// }
    /// ```
    ///
    /// > Note: `@ModelIgnored` properties and dependencies are excluded from the snapshot.
    func captureState() -> ModelStateSnapshot<M> {
        guard let context = enforcedContext() else {
            return ModelStateSnapshot(frozenValue: _$modelContext.reference!.model!)
        }
        return ModelStateSnapshot(frozenValue: context.model.frozenCopy)
    }

    /// Restores the model tree to the state captured in `snapshot`.
    ///
    /// The restore is applied as a single transaction, so all observers
    /// (SwiftUI views, `Observed` streams, `observeAnyModification()`) fire
    /// exactly once after the restore completes.
    ///
    /// ``onChange(capture:perform:)`` callbacks are **not** called during a restore,
    /// preventing restore operations from polluting the undo stack.
    ///
    /// **Effect on child models:**
    /// - Children whose IDs exist in both the live tree and the snapshot have
    ///   their property values updated; their running tasks are **not** affected.
    /// - Children present in the live tree but absent from the snapshot are
    ///   **removed**: their tasks are cancelled and `onActivate` resources
    ///   are released (same as any normal removal).
    /// - Children present in the snapshot but absent from the live tree are
    ///   **added** fresh: `onActivate()` is called and new tasks are started.
    ///
    /// **What is not restored:**
    /// - Running tasks and ongoing async work
    /// - `@ModelIgnored` properties
    /// - Dependencies
    ///
    /// - Parameter snapshot: A snapshot previously obtained from ``captureState()``.
    func restoreState(_ snapshot: ModelStateSnapshot<M>) {
        guard let context = enforcedContext() else { return }

        threadLocals.withValue(true, at: \.isRestoringState) {
            context.transaction {
                restoreModel(snapshot.frozenValue, into: context, using: _$modelContext)
            }
        }
    }

    /// Registers a callback that fires after each modification to the model tree,
    /// excluding modifications caused by ``restoreState(_:)``.
    ///
    /// This is the recommended API for implementing undo/redo stacks. The callback receives a
    /// ``ModelChangeProxy`` from which you can obtain a ``ModelStateSnapshot`` on demand.
    ///
    /// ```swift
    /// func onActivate() {
    ///     // Undo/redo — capture a snapshot after each change, skip restores automatically
    ///     node.onChange { [weak self] proxy in
    ///         guard let self else { return }
    ///         undoStack.append(proxy.snapshot)
    ///         redoStack.removeAll()
    ///     }
    ///
    ///     // Dirty tracking — no snapshot needed, zero extra cost
    ///     node.onChange { [weak self] _ in
    ///         self?.isDirty = true
    ///     }
    /// }
    /// ```
    ///
    /// - Parameter capture: Controls when the frozen copy is taken. Defaults to `.lazy`,
    ///   where the copy is taken only if `proxy.snapshot` is accessed. Use `.eager` for
    ///   strict atomicity (the copy is taken inside the transaction before the lock releases).
    /// - Parameter perform: Called after each non-restore modification. Runs synchronously
    ///   on the same thread as the modification, after the transaction lock is released.
    ///   Avoid acquiring the model's own lock inside this callback to prevent deadlocks.
    /// - Returns: A ``Cancellable`` that unregisters the callback when cancelled. The callback
    ///   is also automatically cancelled when the model is deactivated.
    @discardableResult
    func onChange(capture: ModelCaptureMode = .lazy, perform: @escaping @Sendable (ModelChangeProxy<M>) -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        let modelContext = _$modelContext
        let cancel = context.onAnyModification { hasEnded in
            guard !hasEnded else { return nil }
            // Skip callbacks triggered by restoreState — prevents undo stack pollution.
            guard !threadLocals.isRestoringState else { return nil }

            // For .eager capture, take the frozen copy synchronously in the post-transaction
            // closure so it reflects the state that triggered this callback.
            // For .lazy, defer to proxy.snapshot which calls frozenCopy on demand.
            let frozen: M? = capture == .eager ? context.model.frozenCopy : nil

            return {
                let proxy: ModelChangeProxy<M>
                if let frozen {
                    proxy = ModelChangeProxy(eagerFrozen: frozen)
                } else {
                    proxy = ModelChangeProxy(lazyContext: modelContext)
                }
                perform(proxy)
            }
        }

        return AnyCancellable(cancellations: context.cancellations, onCancel: cancel)
    }
}

// MARK: - Internal restore machinery

/// Walks the fields of `snapshot` (a frozenCopy) and writes each field's value
/// into the live `context`, using the appropriate write path for each field type.
private func restoreModel<M: Model>(_ snapshot: M, into context: Context<M>, using modelContext: ModelContext<M>) {
    var visitor = RestoreVisitor(snapshot: snapshot, context: context, modelContext: modelContext)
    context.model.visit(with: &visitor, includeSelf: false)
}

private struct RestoreVisitor<M: Model>: ModelVisitor {
    typealias State = M

    let snapshot: M
    let context: Context<M>
    let modelContext: ModelContext<M>

    mutating func visit<T>(path: WritableKeyPath<M, T>) {
        let newValue = snapshot[keyPath: path]
        // Skip the write if the type is Equatable and the value hasn't changed,
        // to avoid spurious change notifications during restore.
        if areEqual(newValue, context.model[keyPath: path]) { return }
        let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)
        modelContext[model: context.model, path: sendablePath] = newValue
    }

    mutating func visit<T: Model>(path: WritableKeyPath<M, T>) {
        let snapshotChild = snapshot[keyPath: path]
        let liveChild = context.model[keyPath: path]

        if snapshotChild.id == liveChild.id {
            if let childContext = liveChild.context {
                restoreModel(snapshotChild, into: childContext, using: ModelContext(context: childContext))
            }
        } else {
            let restoredChild = snapshotChild.initialCopy
            let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)
            modelContext[model: context.model, path: sendablePath] = restoredChild
        }
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<M, T>) {
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
        let sendablePath = unsafeBitCast(path, to: (WritableKeyPath<M, T> & Sendable).self)
        modelContext[model: context.model, path: sendablePath] = restoredContainer
        for (id, snapshotModel) in snapshotModels {
            guard let liveContext = liveContextsByID[id] else { continue }
            restoreMatchedContext(snapshot: snapshotModel, liveContext: liveContext)
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
        restoreModel(snapshot, into: typedContext, using: ModelContext(context: typedContext))
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

// MARK: - Equality helpers

/// Returns `true` when both values are `Equatable` and compare equal, or when they are the same
/// reference. Returns `false` for non-Equatable types so the caller always writes in that case.
private func areEqual<T>(_ lhs: T, _ rhs: T) -> Bool {
    func openEquatable<E: Equatable>(_ l: E, _ r: Any) -> Bool {
        (r as? E).map { l == $0 } ?? false
    }
    if let l = lhs as? any Equatable {
        return openEquatable(l, rhs)
    }
    return false
}
