import Foundation
import Dependencies
import ConcurrencyExtras

/// One `onSignal` / `onTeardown` registration.
///
/// Registered in its model's `Cancellations`, so removal reaches it through the store's
/// drain (`onCancel()` on a sealed store). Each run is a task hosted OUTSIDE the model —
/// the model may be removed while it runs, or already be gone for the final `.removed`
/// call: a plain task in production, `ModelAccess.signalWorkStore` under test. Runs of
/// one handler are chained through `tail`, so they never overlap.
final class SignalHandler: Cancellable, InternalCancellable, @unchecked Sendable {
    enum Match { case any, key(CancellableKey), removalOnly }

    let id: Int
    weak var cancellations: Cancellations?
    let match: Match
    let once: Bool
    let cancelPrevious: Bool
    let modelName: String
    let taskName: String
    let fileAndLine: FileAndLine
    let host: Cancellations?
    let access: ModelAccess?
    let dependencies: DependencyValues
    let executor: (any Sendable)?
    let priority: TaskPriority?
    let operation: @Sendable (SignalCause) async -> Void

    private let lock = NSLock()
    private var hasRun = false
    private var isUnregistered = false
    private var tail: Task<Void, Error>?

    init(cancellations: Cancellations, match: Match, once: Bool, cancelPrevious: Bool, modelName: String, taskName: String, fileAndLine: FileAndLine, host: Cancellations?, access: ModelAccess?, dependencies: DependencyValues, executor: (any Sendable)?, priority: TaskPriority?, operation: @escaping @Sendable (SignalCause) async -> Void) {
        self.cancellations = cancellations
        self.id = cancellations.nextId
        self.match = match
        self.once = once
        self.cancelPrevious = cancelPrevious
        self.modelName = modelName
        self.taskName = taskName
        self.fileAndLine = fileAndLine
        self.host = host
        self.access = access
        self.dependencies = dependencies
        self.executor = executor
        self.priority = priority
        self.operation = operation
        cancellations.register(self)
    }

    func matches(_ key: CancellableKey?) -> Bool {
        switch match {
        case .removalOnly: return false
        case .any: return true
        case .key(let own): return key == nil || key == own
        }
    }

    /// From the model's store. A sealed store is a removal → the final call. Otherwise
    /// it is a user cancellation (`cancelAll(for:)`) → unregister only.
    func onCancel() {
        if cancellations?.isSealed ?? true {
            // The harness's own end-of-test teardown defers it past the exhaustion check.
            if access?.deferRemovalCall({ [self] in _ = self.start(.removed) }) == true { return }
            _ = start(.removed)
        } else {
            lock { isUnregistered = true }
        }
    }

    func cancel() {
        lock { isUnregistered = true }
        _ = cancellations?.unregister(id)
    }

    @discardableResult
    func cancel(for key: some Hashable & Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }

    /// Starts one run (serialized behind, or cancelling, the previous one). `nil` when
    /// the handler is unregistered or `once` and already run.
    func start(_ cause: SignalCause) -> Task<Void, Error>? {
        let operation = self.operation
        let dependencies = self.dependencies
        let access = self.access
        let executor = self.executor
        let priority = self.priority
        let taskName = self.taskName
        let started = LockIsolated(false)

        // Read the previous run AND publish this one in the same critical section:
        // two concurrent `signal`s must see each other, or both run unserialized.
        // Spawning inside the lock is safe — neither `Task.init` nor the host store's
        // `register` (never sealed) calls back into this handler.
        let (task, previous): (Task<Void, Error>?, Task<Void, Error>?) = lock {
            if isUnregistered { return (nil, nil) }
            if once && hasRun { return (nil, nil) }
            hasRun = true
            let previous = tail
            // Always wait for the previous run — with `cancelPrevious` it is cancelled
            // first, but runs of one handler never overlap (as `forEach(cancelPrevious:)`
            // starts the next body only after the previous one has fully unwound).
            let serialized = previous

            let makeTask: @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Error> = { onDone in
                let body = { @Sendable () async throws -> Void in
                    defer { onDone() }
                    _ = try? await serialized?.value
                    await DependencyValues.$_current.withValue(dependencies) {
                        started.setValue(true)
                        access?.taskBodyStarted()
                        await operation(cause)
                    }
                }
                #if canImport(Dispatch)
                if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
                   let exec = executor as? _DrainTestExecutor {
                    return Task(executorPreference: exec, priority: priority, operation: body)
                }
                #endif
                return Task(name: taskName, priority: priority, operation: body)
            }

            let task: Task<Void, Error>?
            if let host {
                task = TaskCancellable(modelName: modelName, taskName: taskName, fileAndLine: fileAndLine, cancellations: host, hasStartedRunningBox: started, task: makeTask).underlyingTask
            } else {
                task = makeTask {}
            }
            tail = task
            return (task, previous)
        }
        if cancelPrevious { previous?.cancel() }
        return task
    }
}
