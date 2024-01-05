import Foundation
import AsyncAlgorithms
import ConcurrencyExtras

public extension ModelNode {
    /// Perform a task for the life time of the model
    /// - Parameter isDetached:If true, start task as detached (defaults to false).
    /// - Parameter priority: The priority of the  task.
    /// - Parameter operation: The operation to perform.
    /// - Parameter catch: Called if the task throws an error
    /// - Returns: A cancellable to optionally allow cancelling before deactivation.
    @discardableResult
    func task(isDetached: Bool = false, priority: TaskPriority? = nil, file: StaticString = #file, line: UInt = #line, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: @escaping @Sendable (Error) -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        return cancellationContext {
            _ = TaskCancellable(
                name: typeDescription,
                fileAndLine: FileAndLine(file: file, line: line),
                context: context,
                isDetached: isDetached,
                priority: priority,
                operation: operation,
                catch: `catch`
            )
        }
    }

    /// Perform a task for the life time of the model
    /// - Parameter isDetached:If true, start task as detached (defaults to false).
    /// - Parameter priority: The priority of the  task.
    /// - Parameter operation: The operation to perform.
    /// - Returns: A cancellable to optionally allow cancelling before deactivation.
    @discardableResult
    func task(isDetached: Bool = false, priority: TaskPriority? = nil, file: StaticString = #file, line: UInt = #line, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async -> Void) -> Cancellable {
        task(isDetached: isDetached, priority: priority, file: file, line: line, operation: operation, catch: { _ in })
    }

    /// Iterate an async sequence for the life time of the model
    ///
    /// - Parameter sequence: The sequence to iterate.
    /// - Parameter cancelPrevious:  If true, will cancel any preciously async work initiated from`operation`, defaults to false
    /// - Parameter abortIfOperationThrows: If true, any thrown error from`operation` will abort iteration and `onError` is called with the error, defaults to false
    /// - Parameter isDetached:If true, start task as detached (defaults to false).
    /// - Parameter priority: The priority of the  task.
    /// - Parameter operation: The operation to perform for each element in the sequence.
    /// - Parameter catch: Called if the sequence throws an error or if operation throws and error and abortIfOperationThrows == true
    /// - Returns: A cancellable to optionally allow cancelling before deactivation.
    @discardableResult
    func forEach<S: AsyncSequence&Sendable>(_ sequence: S, cancelPrevious: Bool = false, abortIfOperationThrows: Bool = false, isDetached: Bool = false, priority: TaskPriority? = nil, file: StaticString = #file, line: UInt = #line, @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)? = nil) -> Cancellable where S.Element: Sendable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        guard cancelPrevious else {
            return task(isDetached: isDetached, priority: priority, file: file, line: line, operation: {
                for try await value in sequence {
                    guard !Task.isCancelled, !context.isDestructed else { return }

                    do {
                        try await operation(value)
                    } catch {
                        if abortIfOperationThrows {
                            throw error
                        }
                    }
                }
            }, catch: { onError?($0) })
        }

        let cancelPreviousKey = UUID()
        let abortKey = UUID()
        let hasBeenAborted = LockIsolated(false)

        let cancellable = task(priority: priority, file: file, line: line) {
            for try await value in sequence {
                task(isDetached: isDetached, priority: priority) {
                    try await operation(value)
                } catch: {
                    if abortIfOperationThrows {
                        cancelAll(for: abortKey)
                        hasBeenAborted.setValue(true)
                        onError?($0)
                    }
                }
                    .cancel(for: cancelPreviousKey, cancelInFlight: true)
                    .inheritCancellationContext()
            }
        } catch: { onError?($0) }.cancel(for: abortKey)

        if hasBeenAborted.value {
            cancellable.cancel()
        }

        return cancellable
    }
}
