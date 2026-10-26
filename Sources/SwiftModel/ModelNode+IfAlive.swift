import Foundation

public extension ModelNode {
    /// Runs `body` unless the model was already removed from its tree, and tells whether it
    /// ran to the end with the model still alive.
    ///
    /// Use it for work the model does not own that may arrive after the model went away:
    /// a view's `onDisappear`, a KVO or delegate callback, an SDK completion handler. A
    /// write to a removed model has no effect and is otherwise reported as a likely bug
    /// ("Modifying a removed model"); here it is expected, so it is dropped silently.
    ///
    /// ```swift
    /// .onDisappear {
    ///     model.node.ifAlive { model.clearReadyForDisplay(view: viewID) }
    /// }
    /// ```
    ///
    /// Checking liveness first (`if alive { write }`) would race a removal on another
    /// thread. `ifAlive` instead decides for each write as it happens: the model can be
    /// removed while `body` runs, and the writes that then land on the removed model are
    /// dropped without a report. It is not a transaction, so earlier writes may have
    /// applied when later ones are dropped.
    ///
    /// The result tells the caller whether the model took part. Use it to clean up what the
    /// model never received:
    ///
    /// ```swift
    /// if model.node.ifAlive({ model.adopt(playerLayer) }) == nil {
    ///     playerLayer.invalidate()
    /// }
    /// ```
    ///
    /// Only writes are silenced. Starting work on a removed model (`node.task`,
    /// `node.send`, …) still reports. Writes from a `Task` that `body` starts and that
    /// outlives it are reported as usual too. Calls compose: an `ifAlive` inside another one
    /// is a checkpoint of its own.
    ///
    /// - Returns: The result of `body`, or `nil` if the model was removed before `body` ran
    ///   or before it returned.
    @discardableResult
    func ifAlive<R>(_ body: () throws -> R) rethrows -> R? {
        guard let context = aliveContext() else { return nil }

        let scope = AliveScope(owner: TaskOwner(context), parent: AliveScope.current)
        defer { scope.close() }
        let result = try AliveScope.$current.withValue(scope) { try body() }
        // Removal is permanent: alive now means every write in `body` landed.
        return context.isDestructed ? nil : result
    }

    /// Runs async `body` unless the model was already removed from its tree, and cancels it
    /// if the model is removed while it runs.
    ///
    /// For awaited work the model does not own, such as a view's `.refreshable` or `.task`:
    ///
    /// ```swift
    /// .refreshable {
    ///     await model.node.ifAlive { await model.reload() }
    /// }
    /// ```
    ///
    /// Removing the model cancels `body`, so it stops at its next cancellation point
    /// (`Task.isCancelled` is true inside it), and writes that still land on the removed
    /// model are dropped without a report, as in the synchronous `ifAlive(_:)`.
    /// Cancelling the calling task cancels `body` too.
    ///
    /// - Returns: The result of `body`, or `nil` if the model was removed before `body` ran
    ///   or before it returned.
    @discardableResult
    func ifAlive<R: Sendable>(_ body: sending @escaping () async -> R) async -> R? {
        guard let context = aliveContext() else { return nil }
        switch await runAlive(context, { .success(await body()) }) {
        case .success(let value): return value
        case .failure: return nil   // unreachable: `body` cannot throw
        case nil: return nil
        }
    }

    /// Runs async throwing `body` unless the model was already removed from its tree, and
    /// cancels it if the model is removed while it runs.
    ///
    /// Works like the non-throwing version. An error `body` throws is rethrown, except a
    /// `CancellationError` once the model was removed: that is the removal cancelling
    /// `body`, and it returns `nil`. A `CancellationError` while the model is alive comes
    /// from the calling task being cancelled and is rethrown.
    ///
    /// - Returns: The result of `body`, or `nil` if the model was removed before `body` ran
    ///   or before it returned.
    @discardableResult
    func ifAlive<R: Sendable>(_ body: sending @escaping () async throws -> R) async throws -> R? {
        guard let context = aliveContext() else { return nil }
        let result = await runAlive(context) {
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        switch result {
        case .success(let value): return value
        case .failure(let error) where error is CancellationError && context.isDestructed: return nil
        case .failure(let error): throw error
        case nil: return nil
        }
    }
}

extension ModelNode {
    /// The context of a model that is anchored and not removed. A model never anchored
    /// reports (as other node operations do); a removed one does not.
    func aliveContext(_ function: StaticString = #function) -> Context<M>? {
        guard let context = readContext(function), !context.isDestructed else { return nil }
        return context
    }

    /// Runs `body` in its own task, cancelled when the model is removed or the caller is
    /// cancelled. Returns nil (for a successful `body`) when the model was removed before
    /// it returned; a failure is passed on for the caller to classify.
    private func runAlive<R: Sendable>(_ context: Context<M>, _ body: sending @escaping () async -> Result<R, Error>) async -> Result<R, Error>? {
        let scope = AliveScope(owner: TaskOwner(context), parent: AliveScope.current)
        defer { scope.close() }

        // A child task, so the removal can cancel `body` without cancelling the caller.
        let task = Task {
            await AliveScope.$current.withValue(scope) { await body() }
        }
        // Registering on a store the removal already sealed cancels at once.
        let cancellable = AnyCancellable(cancellations: context.cancellations) { task.cancel() }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        _ = context.cancellations.unregister(cancellable.id)

        if case .success = result, context.isDestructed { return nil }
        return result
    }
}

/// An open `ModelNode.ifAlive` scope. Writes it makes to removed models after its own model
/// was removed are expected (see `ModelAccess.isRemovedModelWork`). A task-local, so it
/// also covers the async `body`'s child tasks; it is closed when `ifAlive` returns, so a
/// `Task` that inherited it and outlives it is reported again.
final class AliveScope: Sendable {
    let owner: TaskOwner
    let parent: AliveScope?
    private let _isOpen = LockedValue(true)

    @TaskLocal static var current: AliveScope?

    init(owner: TaskOwner, parent: AliveScope?) {
        self.owner = owner
        self.parent = parent
    }

    func close() { _isOpen.setValue(false) }

    /// True when an open scope in the chain belongs to a model that was removed.
    var coversRemovedModelWork: Bool {
        var scope: AliveScope? = self
        while let current = scope {
            if current._isOpen.value, current.owner.context?.isDestructed ?? true { return true }
            scope = current.parent
        }
        return false
    }
}
