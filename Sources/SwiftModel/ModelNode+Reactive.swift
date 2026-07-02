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

        // Construct the Observed on the caller's thread so observation registration completes
        // before this call returns — matching forEach(Observed(...)), task(id:), and the pack
        // onChange overloads. Constructing it inside the task closure would leave a window
        // (until the cooperative pool schedules the body) where a write is missed entirely;
        // with `initial: false` that transition would be silently dropped. Emissions landing
        // between registration and iteration are held by the stream's buffer.
        let observed = Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates, idClosure)

        guard cancelPrevious else {
            return task(name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column) {
                for await newValue in observed {
                    guard !Task.isCancelled, !context.isDestructed else { return }

                    let oldValue = previous.withValue { stored in
                        defer { stored = newValue }
                        return stored ?? newValue
                    }

                    do {
                        try await operation(oldValue, newValue)
                    } catch {
                        onError(error)
                    }
                }
            }
        }

        let cancelPreviousKey = UUID()
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let modelName = typeDescription
        let innerTaskName = name ?? "\(function) @ \(fileAndLine.description)"

        return task(name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column) {
            // Behaviour B (body serialization), mirroring `_forEachImpl`'s cancelPrevious
            // branch: cancel the previous body's underlying Task AND await its full exit
            // (including defers) before spawning the next one. `Task.cancel()` only flips a
            // flag — without the await, the cancelled body's sync tail can interleave with the
            // next body's prefix, producing "last writer wins on stale state" bugs. The inner
            // TaskCancellable is constructed directly (rather than via `task(...)`) so we can
            // await its `underlyingTask.value`; its unconditional outer `defer { onDone() }`
            // makes that await deadlock-free even when cancellation lands before the body is
            // scheduled. See `_forEachImpl` for the full rationale.
            var previousInner: TaskCancellable? = nil

            for await newValue in observed {
                guard !Task.isCancelled, !context.isDestructed else { break }

                // Step 1: cancel the previous body so it observes cancellation at its next
                // suspension point (cooperative cancellation).
                previousInner?.cancel()
                // Step 2: await the previous body's wrapped Task to fully unwind before
                // spawning the next one.
                if let t = previousInner?.underlyingTask {
                    _ = try? await t.value
                }
                previousInner = nil

                // Update `previous` in the outer iteration loop BEFORE spawning the inner
                // task, so cancelled inner tasks don't corrupt the previous-value tracking.
                let oldValue = previous.withValue { stored in
                    defer { stored = newValue }
                    return stored ?? newValue
                }

                // Build the inner TaskCancellable inside a `cancellationContext` block so the
                // body gets its own cancellation scope (matches the behaviour of calling
                // `task(isDetached:priority:)` directly — preserves `inheritCancellationContext`
                // propagation for any tasks the user closure itself spawns).
                var captured: TaskCancellable? = nil
                let cancellableWrapper = cancellationContext {
                    captured = TaskCancellable(
                        modelName: modelName,
                        taskName: innerTaskName,
                        fileAndLine: fileAndLine,
                        context: context,
                        isDetached: isDetached,
                        priority: priority,
                        operation: { try await operation(oldValue, newValue) },
                        catch: { onError($0) }
                    )
                }
                _ = cancellableWrapper
                    .cancel(for: cancelPreviousKey, cancelInFlight: true)
                    .inheritCancellationContext()
                previousInner = captured
            }
            // Await the final body's wrapped Task before the outer task ends — so its
            // lifecycle (cancellation, teardown side effects, test-settling counters) is
            // fully observed by anyone waiting on the outer task's completion.
            if let t = previousInner?.underlyingTask {
                _ = try? await t.value
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
            let fireFL = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
            return task(name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, operation: {
                for try await value in sequence {
                    guard !Task.isCancelled, !context.isDestructed else { return }
                    // Count this delivery for the settle-timeout runaway diagnostic
                    // (no-op outside tests). See ModelAccess.reactiveBodyFired.
                    ModelAccess.current?.reactiveBodyFired(fireFL)

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
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let modelName = typeDescription
        let innerTaskName = name ?? "\(function) @ \(fileAndLine.description)"

        let cancellable = task(name, function: function, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column) {
            // Behaviour B (body serialization). When `cancelPrevious: true`, we cancel the
            // previous body's underlying Task AND await its full exit before spawning the
            // next one. Without the await, the cancelled body's sync tail (after its last
            // suspension point) can race the next body's prefix — both bodies acquire the
            // model's context lock in turn but interleave between writes, leading to "last
            // writer wins on stale state" bugs. `Task.cancel()` only flips a flag; a body
            // that never hits another suspension point (e.g. a long sync section, or a
            // simple "assign result" tail) runs to completion regardless.
            //
            // We construct the inner TaskCancellable directly (rather than going through
            // the public `task(...)` API) so we can hold a reference and await on its
            // underlying `Task<Void, Error>.value`. That Task's outermost `defer { onDone() }`
            // (in TaskCancellable's convenience init) runs UNCONDITIONALLY — including when
            // the inner `guard !Task.isCancelled` returns early without invoking the user
            // closure. An earlier attempt that placed the completion signal inside the user
            // closure deadlocked whenever cancellation arrived before the body was scheduled.
            var previousInner: TaskCancellable? = nil

            for try await value in sequence {
                // Count this delivery for the settle-timeout runaway diagnostic
                // (no-op outside tests). See ModelAccess.reactiveBodyFired.
                ModelAccess.current?.reactiveBodyFired(fileAndLine)
                // Step 1: cancel the previous body so it observes cancellation at its next
                // suspension point (cooperative cancellation).
                previousInner?.cancel()
                // Step 2: await the previous body's wrapped Task to fully unwind. The wrapper's
                // outer defer runs regardless of whether the user closure executed. If the
                // underlying Task was never scheduled (defensive — currently unreachable in
                // this flow since cancellation can't reach the TaskCancellable between its
                // `init` and our key-registration), the optional chain skips the await.
                if let t = previousInner?.underlyingTask {
                    _ = try? await t.value
                }
                previousInner = nil

                // Build the inner TaskCancellable inside a `cancellationContext` block so the
                // body gets its own cancellation scope (matches the behaviour of calling
                // `task(isDetached:priority:)` directly — preserves `inheritCancellationContext`
                // propagation for any tasks the user closure itself spawns).
                var captured: TaskCancellable? = nil
                let cancellableWrapper = cancellationContext {
                    captured = TaskCancellable(
                        modelName: modelName,
                        taskName: innerTaskName,
                        fileAndLine: fileAndLine,
                        context: context,
                        isDetached: isDetached,
                        priority: priority,
                        operation: { try await operation(value) },
                        catch: {
                            if abortIfOperationThrows {
                                // Set the flag BEFORE cancelling: if this body throws before the
                                // caller has registered the outer cancellable under `abortKey`,
                                // `cancelAll` is a no-op and the caller's `hasBeenAborted` check
                                // below is the only thing that stops the outer iteration.
                                hasBeenAborted.setValue(true)
                                cancelAll(for: abortKey)
                                reportCatch($0)
                            }
                        }
                    )
                }
                _ = cancellableWrapper
                    .cancel(for: cancelPreviousKey, cancelInFlight: true)
                    .inheritCancellationContext()
                previousInner = captured
            }
            // Await the final body's wrapped Task before the outer task ends — so its
            // lifecycle (cancellation, teardown side effects, test-settling counters) is
            // fully observed by anyone waiting on the outer task's completion.
            if let t = previousInner?.underlyingTask {
                _ = try? await t.value
            }
        } catch: { reportCatch($0) }.cancel(for: abortKey)

        if hasBeenAborted.value {
            cancellable.cancel()
        }

        return cancellable
    }
}
