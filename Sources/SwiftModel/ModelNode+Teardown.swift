import Foundation
import Dependencies
import ConcurrencyExtras

public extension ModelNode {
    /// SPIKE — async work that starts when this model is deactivated and is allowed to
    /// outlive it (an audio fade-out, a final analytics flush).
    ///
    /// Unlike starting a `Task` from `onCancel`, the work is registered while the model
    /// is still live, so it cannot be dropped by a teardown that has already sealed the
    /// tree. It captures this model's dependencies at registration and runs with them.
    ///
    /// The model is gone while `operation` runs: capture the values you need up front,
    /// and don't touch `node`. The work must tolerate cancellation.
    ///
    /// - Production: a plain task, owned by no model.
    /// - `.modelTesting`: hosted by the test — it runs on the test's executor, `settle()`
    ///   waits for it, and work still running at the end of the test is reported as an
    ///   active task.
    @discardableResult
    func onTeardown(_ name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, operation: @escaping @Sendable () async -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let taskName = name ?? "\(function) @ \(fileAndLine.description)"
        let modelName = typeDescription
        // Everything the work needs is resolved NOW, while the model is live: after
        // removal the context is sealed and its root may be gone.
        let dependencies = context.capturedDependencies
        let executor = _TestExecutorBox.current
        let access = context.rootParent.modelAccess
        let store = access?.teardownWorkStore

        return AnyCancellable(cancellations: context.cancellations) {
            _startTeardownWork(modelName: modelName, taskName: taskName, fileAndLine: fileAndLine, store: store, access: access, dependencies: dependencies, executor: executor, priority: priority, operation: operation)
        }
    }
}

private func _startTeardownWork(modelName: String, taskName: String, fileAndLine: FileAndLine, store: Cancellations?, access: ModelAccess?, dependencies: DependencyValues, executor: (any Sendable)?, priority: TaskPriority?, operation: @escaping @Sendable () async -> Void) {
    let hasStartedRunningBox = LockIsolated(false)
    let makeTask: @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Error> = { onDone in
        let body = { @Sendable () async throws -> Void in
            await DependencyValues.$_current.withValue(dependencies) {
                defer { onDone() }
                hasStartedRunningBox.setValue(true)
                access?.taskBodyStarted()
                await operation()
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

    guard let store else {
        // Production: nobody to report to — just run it.
        _ = makeTask {}
        return
    }
    _ = TaskCancellable(modelName: modelName, taskName: taskName, fileAndLine: fileAndLine, cancellations: store, hasStartedRunningBox: hasStartedRunningBox, task: makeTask)
}
