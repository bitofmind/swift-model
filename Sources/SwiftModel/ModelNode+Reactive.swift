import Foundation
import Dependencies
import IssueReporting

public extension ModelNode {
    /// Reacts to changes in a value, calling `perform` with the old and new value on each change.
    ///
    /// Use `onChange(of:)` to take action whenever a value transitions from one state to another:
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.onChange(of: isLoggedIn) { wasLoggedIn, isNowLoggedIn in
    ///         if !wasLoggedIn && isNowLoggedIn {
    ///             await fetchUserProfile()
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// When `initial` is `true` (the default), `perform` is called immediately on activation
    /// with `oldValue == newValue`. When `initial` is `false`, the first call happens on the
    /// first real change, and `oldValue` reflects the value at activation time.
    ///
    /// Pass `cancelPrevious: true` to cancel any still-running `perform` when a new change
    /// arrives — analogous to `task(id:)` semantics where only the latest work survives.
    ///
    /// - Parameters:
    ///   - id: The value to observe.
    ///   - initial: If `true` (default), calls `perform` once immediately on activation
    ///     with `oldValue == newValue`. Pass `false` to skip the initial call.
    ///   - removeDuplicates: Skip the call if the value hasn't changed. Defaults to `true`.
    ///   - coalesceUpdates: Batch rapid changes into a single call. Defaults to `true`.
    ///   - cancelPrevious: If `true`, cancels any still-running `perform` from a prior change
    ///     before starting the new one. Defaults to `false`.
    ///   - name: Optional human-readable name shown in diagnostics.
    ///   - isDetached: If `true`, starts the underlying task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - perform: Called for each change, receiving `(oldValue, newValue)`.
    ///   - catch: Called if `perform` throws an error.
    /// - Returns: A `Cancellable` to stop observation before the model deactivates.
    @discardableResult
    func onChange<Value: Equatable & Sendable>(
        of id: @Sendable @autoclosure @escaping () -> Value,
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        cancelPrevious: Bool = false,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (Value, Value) async throws -> Void,
        `catch` onError: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        _onChangeImpl(id: id, initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates, cancelPrevious: cancelPrevious, name: name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, perform: operation, catch: onError)
    }

    /// Reacts to changes in a value, calling `perform` with the old and new value on each change.
    ///
    /// Non-throwing convenience overload of `onChange(of:perform:catch:)`.
    ///
    /// - Parameters:
    ///   - id: The value to observe.
    ///   - initial: If `true` (default), calls `perform` once immediately on activation.
    ///   - removeDuplicates: Skip the call if the value hasn't changed. Defaults to `true`.
    ///   - coalesceUpdates: Batch rapid changes into a single call. Defaults to `true`.
    ///   - cancelPrevious: Cancel any still-running `perform` on a new change. Defaults to `false`.
    ///   - name: Optional human-readable name shown in diagnostics.
    ///   - isDetached: If `true`, starts the underlying task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - perform: Called for each change, receiving `(oldValue, newValue)`.
    /// - Returns: A `Cancellable` to stop observation before the model deactivates.
    @discardableResult
    func onChange<Value: Equatable & Sendable>(
        of id: @Sendable @autoclosure @escaping () -> Value,
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        cancelPrevious: Bool = false,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (Value, Value) async -> Void
    ) -> Cancellable {
        _onChangeImpl(id: id, initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates, cancelPrevious: cancelPrevious, name: name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, perform: operation, catch: { _ in })
    }

    /// Reacts to changes in multiple observed values, calling `perform` with the new values on each change.
    ///
    /// Use this overload when you need to observe multiple values simultaneously and trigger
    /// an action when any of them changes. The closure receives the emission-time values:
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.onChange(of: { (query, filter) }) { (query, filter) in
    ///         await reload(query: query, filter: filter)
    ///     }
    /// }
    /// ```
    ///
    /// For a single value with old/new comparison, use `node.onChange(of: value) { old, new in ... }`.
    ///
    /// - Parameters:
    ///   - of: A closure returning a tuple of all observed values.
    ///   - initial: If `true` (default), calls `perform` immediately on activation.
    ///   - removeDuplicates: Skip when no value has changed. Defaults to `true`.
    ///   - coalesceUpdates: Batch rapid changes into a single call. Defaults to `true`.
    ///   - cancelPrevious: Cancel any still-running `perform` on a new change. Defaults to `false`.
    ///   - name: Optional human-readable name shown in diagnostics.
    ///   - isDetached: If `true`, starts the underlying task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - perform: Called for each change, receiving the emission-time values.
    ///   - catch: Called if `perform` throws.
    /// - Returns: A `Cancellable` to stop observation before the model deactivates.
    @discardableResult
    func onChange<each Value: Equatable & Sendable>(
        of id: @Sendable @escaping () -> (repeat each Value),
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        cancelPrevious: Bool = false,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable ((repeat each Value)) async throws -> Void,
        `catch` onError: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        // Pass `operation` directly — no lambda wrapper. Same SILGen constraint as pack task(id:):
        // wrapping would require calling a pack-typed closure from a non-pack closure body, which
        // triggers a compiler crash. forEach receives it as (S.Element) async throws -> Void and
        // calls it in non-pack context.
        forEach(
            Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates) { id() },
            name: name,
            function: function,
            cancelPrevious: cancelPrevious,
            isDetached: isDetached,
            priority: priority,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            perform: operation,
            catch: { onError($0) }
        )
    }

    /// Reacts to changes in multiple observed values, calling `perform` with the new values on each change.
    ///
    /// Non-throwing convenience overload of `onChange(of:perform:catch:)`.
    ///
    /// - Parameters:
    ///   - of: A closure returning a tuple of all observed values.
    ///   - initial: If `true` (default), calls `perform` immediately on activation.
    ///   - removeDuplicates: Skip when no value has changed. Defaults to `true`.
    ///   - coalesceUpdates: Batch rapid changes into a single call. Defaults to `true`.
    ///   - cancelPrevious: Cancel any still-running `perform` on a new change. Defaults to `false`.
    ///   - name: Optional human-readable name shown in diagnostics.
    ///   - isDetached: If `true`, starts the underlying task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - perform: Called for each change, receiving the emission-time values.
    /// - Returns: A `Cancellable` to stop observation before the model deactivates.
    @discardableResult
    func onChange<each Value: Equatable & Sendable>(
        of id: @Sendable @escaping () -> (repeat each Value),
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        cancelPrevious: Bool = false,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable ((repeat each Value)) async -> Void
    ) -> Cancellable {
        let op: @Sendable ((repeat each Value)) async throws -> Void = operation
        return forEach(
            Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates) { id() },
            name: name,
            function: function,
            cancelPrevious: cancelPrevious,
            isDetached: isDetached,
            priority: priority,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            perform: op,
            catch: { _ in }
        )
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
    ///   - name: Optional human-readable name shown in diagnostics and Instruments. When omitted,
    ///     a name is synthesized from the calling function and call-site location.
    ///   - cancelPrevious: If `true`, cancels any in-flight work from a previous call to
    ///     `operation` before starting the next. Useful for "latest wins" semantics, e.g. search.
    ///     Defaults to `false`.
    ///   - abortIfOperationThrows: If `true`, a thrown error from `operation` stops iteration
    ///     and calls `catch`. Defaults to `false`.
    ///   - isDetached: If `true`, starts the underlying task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task. Defaults to `nil` (inherits from caller).
    ///   - operation: Called for each element in the sequence.
    ///   - catch: Called if the sequence throws, or if `operation` throws and
    ///     `abortIfOperationThrows` is `true`. When omitted, unhandled errors are reported via
    ///     `reportIssue` (failing tests in test mode, triggering an assertion in debug builds).
    /// - Returns: A `Cancellable` to stop iteration before the model deactivates.
#if swift(>=6.2)
    @discardableResult
    func forEach<S: AsyncSequence&Sendable>(_ sequence: S, name: String? = nil, function: StaticString = #function, cancelPrevious: Bool = false, abortIfOperationThrows: Bool = false, isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)? = nil) -> Cancellable where S.AsyncIterator: SendableMetatype, S.Element: Sendable {
        _forEachImpl(sequence, name: name, function: function, cancelPrevious: cancelPrevious, abortIfOperationThrows: abortIfOperationThrows, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, perform: operation, catch: onError)
    }
#else
    @discardableResult
    func forEach<S: AsyncSequence&Sendable>(_ sequence: S, name: String? = nil, function: StaticString = #function, cancelPrevious: Bool = false, abortIfOperationThrows: Bool = false, isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)? = nil) -> Cancellable where S.Element: Sendable {
        _forEachImpl(sequence, name: name, function: function, cancelPrevious: cancelPrevious, abortIfOperationThrows: abortIfOperationThrows, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, perform: operation, catch: onError)
    }
#endif

    private func _onChangeImpl<Value: Equatable & Sendable>(
        id idClosure: @Sendable @escaping () -> Value,
        initial: Bool,
        removeDuplicates: Bool,
        coalesceUpdates: Bool,
        cancelPrevious: Bool,
        name: String?,
        function: StaticString,
        isDetached: Bool,
        priority: TaskPriority?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        perform operation: @escaping @Sendable (Value, Value) async throws -> Void,
        catch onError: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        // Track the previous emission. Seed with the current value when `initial: false` so
        // the first change correctly reports (activationValue, firstChangedValue). When
        // `initial: true` the first emission has oldValue == newValue (initial call semantics).
        let previous = LockIsolated<Value?>(initial ? nil : idClosure())
        let cancelPreviousKey = UUID()

        return task(name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column) {
            for await newValue in Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates, idClosure) {
                guard !Task.isCancelled, !context.isDestructed else { return }

                // Update `previous` in the outer iteration loop BEFORE spawning any inner task.
                // This ensures cancelled inner tasks (cancelPrevious: true) don't corrupt
                // the previous-value tracking state.
                let oldValue = previous.withValue { stored in
                    defer { stored = newValue }
                    return stored ?? newValue
                }

                if cancelPrevious {
                    task(isDetached: isDetached, priority: priority) {
                        try await operation(oldValue, newValue)
                    } catch: { onError($0) }
                        .cancel(for: cancelPreviousKey, cancelInFlight: true)
                        .inheritCancellationContext()
                } else {
                    do {
                        try await operation(oldValue, newValue)
                    } catch {
                        onError(error)
                    }
                }
            }
        }
    }

    private func _forEachImpl<S: AsyncSequence&Sendable>(_ sequence: S, name: String?, function: StaticString, cancelPrevious: Bool, abortIfOperationThrows: Bool, isDetached: Bool, priority: TaskPriority?, fileID: StaticString, filePath: StaticString, line: UInt, column: UInt, perform operation: @escaping @Sendable (S.Element) async throws -> Void, `catch` onError: (@Sendable (Error) -> Void)?) -> Cancellable where S.Element: Sendable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        // When no catch handler is provided, surface unhandled errors via reportIssue.
        // In test contexts this fails the test; in production debug builds it triggers an
        // assertion. Per-element errors when abortIfOperationThrows: false are always
        // silently swallowed — the caller opted into that behaviour.
        let reportCatch: @Sendable (Error) -> Void = onError ?? { [fileID, filePath, line, column] error in
            reportIssue(
                "Unhandled error in node.forEach: \(error)",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }

        guard cancelPrevious else {
            return task(name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, operation: {
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
            }, catch: { reportCatch($0) })
        }

        let cancelPreviousKey = UUID()
        let abortKey = UUID()
        let hasBeenAborted = LockIsolated(false)

        let cancellable = task(name, function: function, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column) {
            for try await value in sequence {
                task(isDetached: isDetached, priority: priority) {
                    try await operation(value)
                } catch: {
                    if abortIfOperationThrows {
                        cancelAll(for: abortKey)
                        hasBeenAborted.setValue(true)
                        reportCatch($0)
                    }
                }
                    .cancel(for: cancelPreviousKey, cancelInFlight: true)
                    .inheritCancellationContext()
            }
        } catch: { reportCatch($0) }.cancel(for: abortKey)

        if hasBeenAborted.value {
            cancellable.cancel()
        }

        return cancellable
    }
}
