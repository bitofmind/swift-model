import Foundation
import Dependencies

struct EmptyCancellable: Cancellable {
    func cancel() {}

    func cancel(for key: some Hashable & Sendable, cancelInFlight: Bool) -> EmptyCancellable { self }
}


final class AnyCancellable: Cancellable, InternalCancellable, @unchecked Sendable {
    weak var cancellations: Cancellations?
    let id: Int
    private let _onCancel: @Sendable () -> Void

    init(cancellations: Cancellations, onCancel: @escaping @Sendable () -> Void) {
        self.cancellations = cancellations
        id = cancellations.nextId
        _onCancel = onCancel
        cancellations.register(self)
    }

    func onCancel() {
        _onCancel()
    }

    public func cancel() {
        cancellations?.cancel(self)
    }

    @discardableResult
    public func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }

    @TaskLocal static var contexts: [CancellableKey] = []
    @TaskLocal static var inheritedContexts: [CancellableKey] = []
}

final class TaskCancellable: Cancellable, InternalCancellable, @unchecked Sendable {
    let id: Int
    weak var cancellations: Cancellations?
    var task: Task<Void, Error>!
    let modelName: String
    let taskName: String
    let fileAndLine: FileAndLine
    let lock = NSLock()
    var hasBeenCancelled = false

    /// `true` once the wrapped Task's body has begun executing on the
    /// cooperative pool. Read by `TestAccess.settle()` (via
    /// `Cancellations.hasPendingStartTask` and `AnyContext.hasPendingStartTask`)
    /// to keep its quiet window open until every freshly-registered task has
    /// had at least one CPU slot. See the `ModelAccess.taskBodyStarted`
    /// doc-comment for why this matters.
    ///
    /// Set via a `LockIsolated<Bool>` captured by the body wrapper in the
    /// convenience init (see below). The box is created BEFORE `self.init`
    /// runs (since the factory closure is constructed before designated-init
    /// completes), then stored on the instance afterwards. The brief window
    /// where `register(self)` has run inside the designated init but
    /// `_hasStartedRunningBox` is still `nil` reports `hasStartedRunning ==
    /// false` (the safe default — settle keeps waiting), so a settle racing
    /// this init never declares quiet prematurely.
    var _hasStartedRunningBox: LockIsolated<Bool>?
    var hasStartedRunning: Bool { _hasStartedRunningBox?.value ?? false }

    init(modelName: String, taskName: String, fileAndLine: FileAndLine, context: AnyContext, task: @escaping @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Error>) {
        self.cancellations = context.cancellations
        let id = context.cancellations.nextId
        self.id = id
        self.modelName = modelName
        self.taskName = taskName
        self.fileAndLine = fileAndLine
        self.task = nil

        context.cancellations.register(self)

        lock {
            guard !self.hasBeenCancelled else {
                // Task was cancelled before init reached the task-creation point;
                // the underlying Task stays nil and never runs.
                return
            }
            self.task = task { [weak cancellations = context.cancellations] in
                _ = cancellations?.unregister(id)
            }
        }
    }

    func onCancel() {
        lock {
            self.hasBeenCancelled = true
            return self.task
        }?.cancel()
    }

    public func cancel() {
        cancellations?.cancel(self)
    }

    @discardableResult
    public func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }
}

extension TaskCancellable {
    /// The underlying Swift `Task<Void, Error>`, or `nil` if the task was cancelled
    /// before `init` could schedule it. Awaiting `.value` on this Task resolves once
    /// the wrapped Task's outer `defer { onDone() }` runs — which is unconditional
    /// (it fires regardless of whether the inner cancellation guard let the user
    /// closure execute). Used by `_forEachImpl`'s body-serialization logic to
    /// guarantee the next body starts only after the previous body's full unwind.
    var underlyingTask: Task<Void, Error>? {
        lock { self.task }
    }

    convenience init(modelName: String, taskName: String, fileAndLine: FileAndLine, context: AnyContext, isDetached: Bool, priority: TaskPriority?, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: (@Sendable (Error) -> Void)?) {
        // Constructed BEFORE self.init so the factory closure can capture it.
        // Stored on `self` AFTER self.init completes — see `_hasStartedRunningBox`.
        let hasStartedRunningBox = LockIsolated(false)

        self.init(modelName: modelName, taskName: taskName, fileAndLine: fileAndLine, context: context) { onDone in
            let contexts = AnyCancellable.contexts
            let operation = { @Sendable in
                do {
                    // Use context.capturedDependencies directly (not withDependencies(from: context))
                    // so the task inherits exactly the context's dep overrides. withDependencies(from:)
                    // would merge against DependencyValues._current, potentially losing overrides.
                    try await DependencyValues.$_current.withValue(context.capturedDependencies) {
                        try await ModelAccess.$isInModelTaskContext.withValue(true) {
                            try await AnyCancellable.$inheritedContexts.withValue(contexts) {
                                try await AnyCancellable.$contexts.withValue([]) {
                                    defer { onDone() }

                                    guard !Task.isCancelled, !context.isDestructed else { return }

                                    // Signal that the body has now actually started executing —
                                    // see `ModelAccess.taskBodyStarted` and
                                    // `TaskCancellable._hasStartedRunningBox`. Setting the box
                                    // BEFORE notifying the access avoids a window where settle
                                    // could re-check `hasPendingStartTask`, see this task still
                                    // not-started, and re-arm pointlessly.
                                    hasStartedRunningBox.setValue(true)
                                    ModelAccess.current?.taskBodyStarted()

                                    try await operation()
                                }
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    `catch`?(error)
                }
            }

            if isDetached {
                return Task.detached(name: taskName, priority: priority, operation: operation)
            } else {
                return Task(name: taskName, priority: priority, operation: operation)
            }
        }
        // Install the box on the now-initialised instance. Readers that
        // grab the cancellable through `Cancellations` after this point
        // see the box; readers that race the init see `nil` →
        // `hasStartedRunning` returns its default (`true`), which is
        // conservatively "fine to settle" — strictly less safe than
        // gating, but the race window is sub-microsecond.
        self._hasStartedRunningBox = hasStartedRunningBox
    }
}

