import Foundation
import ConcurrencyExtras

public extension ModelNode {
    /// Starts an async task tied to the model's lifetime.
    ///
    /// The task starts immediately and is automatically cancelled when the model is deactivated.
    /// Call this from `onActivate()` to set up long-lived async work.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.task {
    ///         let result = await fetchData()
    ///         self.data = result
    ///     }
    /// }
    /// ```
    ///
    /// The returned `Cancellable` lets you cancel the task before the model deactivates. If the
    /// task throws and you need to handle the error, use the overload with a `catch:` parameter.
    ///
    /// - Parameters:
    ///   - isDetached: If `true`, starts the task as a detached task (not inheriting the caller's
    ///     actor context). Defaults to `false`.
    ///   - priority: The priority of the task. Defaults to `nil` (inherits from caller).
    ///   - operation: The async work to perform.
    ///   - catch: Called if `operation` throws an error.
    /// - Returns: A `Cancellable` to cancel the task before the model deactivates.
    @discardableResult
    func task(isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: @escaping @Sendable (Error) -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        return cancellationContext {
            _ = TaskCancellable(
                name: typeDescription,
                fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column),
                context: context,
                isDetached: isDetached,
                priority: priority,
                operation: operation,
                catch: `catch`
            )
        }
    }

    /// Starts a non-throwing async task tied to the model's lifetime.
    ///
    /// Convenience overload of `task(isDetached:priority:operation:catch:)` for operations that
    /// don't throw. The task is automatically cancelled when the model is deactivated.
    ///
    /// - Parameters:
    ///   - isDetached: If `true`, starts the task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task. Defaults to `nil` (inherits from caller).
    ///   - operation: The async work to perform.
    /// - Returns: A `Cancellable` to cancel the task before the model deactivates.
    @discardableResult
    func task(isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async -> Void) -> Cancellable {
        task(isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, operation: operation, catch: { _ in })
    }

    /// Iterates an async sequence for the lifetime of the model.
    ///
    /// For each element emitted by `sequence`, `operation` is called. Iteration stops when the
    /// model is deactivated or the sequence finishes. Use this in `onActivate()` to react to
    /// streams of values:
    ///
    /// ```swift
    /// func onActivate() {
    ///     // React to clock ticks
    ///     node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
    ///         elapsed += 1
    ///     }
    ///
    ///     // React to child events
    ///     node.forEach(node.event(fromType: ChildModel.self)) { event, child in
    ///         handleEvent(event, from: child)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - sequence: The async sequence to iterate.
    ///   - cancelPrevious: If `true`, cancels any in-flight work from a previous call to
    ///     `operation` before starting the next. Useful for "latest wins" semantics, e.g. search.
    ///     Defaults to `false`.
    ///   - abortIfOperationThrows: If `true`, a thrown error from `operation` stops iteration
    ///     and calls `catch`. Defaults to `false`.
    ///   - isDetached: If `true`, starts the underlying task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task. Defaults to `nil` (inherits from caller).
    ///   - operation: Called for each element in the sequence.
    ///   - catch: Called if the sequence throws, or if `operation` throws and
    ///     `abortIfOperationThrows` is `true`.
    /// - Returns: A `Cancellable` to stop iteration before the model deactivates.
#if swift(>=6.2)
    @discardableResult
    func forEach<S: AsyncSequence&Sendable>(_ sequence: S, cancelPrevious: Bool = false, abortIfOperationThrows: Bool = false, isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)? = nil) -> Cancellable where S.AsyncIterator: SendableMetatype, S.Element: Sendable {
        _forEachImpl(sequence, cancelPrevious: cancelPrevious, abortIfOperationThrows: abortIfOperationThrows, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, perform: operation, catch: onError)
    }
#else
    @discardableResult
    func forEach<S: AsyncSequence&Sendable>(_ sequence: S, cancelPrevious: Bool = false, abortIfOperationThrows: Bool = false, isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)? = nil) -> Cancellable where S.Element: Sendable {
        _forEachImpl(sequence, cancelPrevious: cancelPrevious, abortIfOperationThrows: abortIfOperationThrows, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, perform: operation, catch: onError)
    }
#endif

    private func _forEachImpl<S: AsyncSequence&Sendable>(_ sequence: S, cancelPrevious: Bool, abortIfOperationThrows: Bool, isDetached: Bool, priority: TaskPriority?, fileID: StaticString, filePath: StaticString, line: UInt, column: UInt, perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)?) -> Cancellable where S.Element: Sendable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        guard cancelPrevious else {
            return task(isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, operation: {
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

        let cancellable = task(priority: priority, fileID: fileID, filePath: filePath, line: line, column: column) {
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
