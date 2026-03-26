import Foundation
import Dependencies

/// Receives notifications about task lifecycle events for test instrumentation.
/// Conformed to by `TestAccess` — `nil` in production, so all call sites are free.
protocol TaskLifecycleDelegate: AnyObject, Sendable {
    /// Called on the creating thread when a task born from `onActivate()` is registered.
    func activationTaskCreated()
    /// Called from inside the task body when an `onActivate()` task begins executing.
    func activationTaskEntered()
    /// Called on the creating thread when any task is registered (Phase 5).
    func taskCreated()
    /// Called from inside any task body when it completes (Phase 5).
    func taskCompleted()
}

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

    init(modelName: String, taskName: String, fileAndLine: FileAndLine, context: AnyContext, task: @escaping @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Error>) {
        self.cancellations = context.cancellations
        let id = context.cancellations.nextId
        self.id = id
        self.modelName = modelName
        self.taskName = taskName
        self.fileAndLine = fileAndLine
        self.task = nil

        context.cancellations.register(self)

        // Notify lifecycle delegate (TestAccess in tests, nil in production).
        // Check the onActivate task-local *before* creating the Swift Task which may
        // start on a different context. `AnyCancellable.contexts` still holds the value
        // at this point because we're still on the creating thread inside `onActivate`.
        let delegate = context.rootParent.taskLifecycleDelegate
        let isActivationTask = delegate != nil && AnyCancellable.contexts.contains { ($0.key as? ContextCancellationKey) == .onActivate }
        if isActivationTask {
            delegate?.activationTaskCreated()
        }
        delegate?.taskCreated()

        lock {
            guard !self.hasBeenCancelled else {
                // Task was cancelled before it started; undo the counters
                // so the settling logic doesn't wait forever for a task that will never run.
                if isActivationTask {
                    delegate?.activationTaskEntered()
                }
                delegate?.taskCompleted()
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
    convenience init(modelName: String, taskName: String, fileAndLine: FileAndLine, context: AnyContext, isDetached: Bool, priority: TaskPriority?, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: (@Sendable (Error) -> Void)?) {
        // Capture the activation flag here on the creating thread, before `init` clears the
        // task-local via `$contexts.withValue([])` inside the Task body.
        // Note: the designated init also captures this flag and calls activationTaskCreated().
        // This capture is used to call activationTaskEntered() when the body begins.
        let isActivationTask = context.rootParent.taskLifecycleDelegate != nil && AnyCancellable.contexts.contains { ($0.key as? ContextCancellationKey) == .onActivate }
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
                                    // Task body has begun executing. Signal "entered" so the
                                    // activation counter can decrement (Phase 3).
                                    if isActivationTask {
                                        context.rootParent.taskLifecycleDelegate?.activationTaskEntered()
                                    }
                                    defer {
                                        onDone()
                                        context.rootParent.taskLifecycleDelegate?.taskCompleted()
                                    }

                                    guard !Task.isCancelled, !context.isDestructed else { return }
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
    }
}

