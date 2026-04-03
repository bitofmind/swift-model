import Foundation
import Dependencies
import IssueReporting

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
    ///   - name: Optional human-readable name shown in diagnostics and Instruments. When omitted,
    ///     a name is synthesized from the calling function and call-site location.
    ///   - isDetached: If `true`, starts the task as a detached task (not inheriting the caller's
    ///     actor context). Defaults to `false`.
    ///   - priority: The priority of the task. Defaults to `nil` (inherits from caller).
    ///   - operation: The async work to perform.
    ///   - catch: Called if `operation` throws an error.
    /// - Returns: A `Cancellable` to cancel the task before the model deactivates.
    @discardableResult
    func task(_ name: String? = nil, function: StaticString = #function, isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: @escaping @Sendable (Error) -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }

        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let taskName = name ?? "\(function) @ \(fileAndLine.description)"
        return cancellationContext {
            _ = TaskCancellable(
                modelName: typeDescription,
                taskName: taskName,
                fileAndLine: fileAndLine,
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
    /// Convenience overload of `task(_:function:isDetached:priority:operation:catch:)` for
    /// operations that don't throw. The task is automatically cancelled when the model is deactivated.
    ///
    /// - Parameters:
    ///   - name: Optional human-readable name shown in diagnostics and Instruments. When omitted,
    ///     a name is synthesized from the calling function and call-site location.
    ///   - isDetached: If `true`, starts the task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task. Defaults to `nil` (inherits from caller).
    ///   - operation: The async work to perform.
    /// - Returns: A `Cancellable` to cancel the task before the model deactivates.
    @discardableResult
    func task(_ name: String? = nil, function: StaticString = #function, isDetached: Bool = false, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async -> Void) -> Cancellable {
        task(name, function: function, isDetached: isDetached, priority: priority, fileID: fileID, filePath: filePath, line: line, column: column, operation: operation, catch: { _ in })
    }

    /// Starts a task that is automatically restarted whenever `id` changes.
    ///
    /// Use `task(id:)` when async work depends on a value and must restart from scratch each time
    /// that value changes — for example, searching when a query changes, or loading details when
    /// a selected item changes.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.task(id: query) { query in
    ///         results = (try? await node.searchClient.search(query)) ?? []
    ///     }
    /// }
    /// ```
    ///
    /// The task runs once immediately on activation with the current value of `id`, and is
    /// cancelled and restarted each time `id` changes. Any in-flight work from the previous
    /// value is cancelled before the new task begins. The emission-time value of `id` is passed
    /// directly to `operation`, avoiding any race between when the task starts and when it reads
    /// from the model.
    ///
    /// This is a convenience over `node.forEach(Observed { id }, cancelPrevious: true) { value in ... }`,
    /// making the "restart on change" intent explicit at the call site.
    ///
    /// - Parameters:
    ///   - id: The value to observe. Whenever it changes, the in-flight task is cancelled and a new
    ///     one starts. Must be `Equatable` so duplicate values (no real change) don't trigger a restart.
    ///   - initial: If `true` (default), the task starts immediately on activation with the current
    ///     value. Pass `false` to skip the initial run and only react to subsequent changes.
    ///   - removeDuplicates: Skip restart if `id` changes to a value equal to the current one.
    ///     Defaults to `true`.
    ///   - coalesceUpdates: Coalesce rapid consecutive changes to `id` into a single restart rather
    ///     than one restart per change. Defaults to `true`.
    ///   - name: Optional human-readable name shown in diagnostics and Instruments.
    ///   - isDetached: If `true`, starts the task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - operation: The async work to perform. Receives the emission-time value of `id`.
    ///   - catch: Called if `operation` throws an error.
    /// - Returns: A `Cancellable` to stop the reactive task before the model deactivates.
    @discardableResult
    func task<Value: Equatable & Sendable>(
        id: @Sendable @autoclosure @escaping () -> Value,
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable (Value) async throws -> Void,
        `catch` onError: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        forEach(
            Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates) { id() },
            name: name,
            function: function,
            cancelPrevious: true,
            isDetached: isDetached,
            priority: priority,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        ) { value in
            try await operation(value)
        } catch: { onError($0) }
    }

    /// Starts a non-throwing task that is automatically restarted whenever `id` changes.
    ///
    /// Convenience overload of `task(id:operation:catch:)` for operations that don't throw.
    ///
    /// - Parameters:
    ///   - id: The value to observe. The task restarts whenever this changes.
    ///   - initial: If `true` (default), the task starts immediately on activation.
    ///   - removeDuplicates: Skip restart if `id` changes to an equal value. Defaults to `true`.
    ///   - coalesceUpdates: Coalesce rapid changes into a single restart. Defaults to `true`.
    ///   - name: Optional human-readable name shown in diagnostics and Instruments.
    ///   - isDetached: If `true`, starts the task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - operation: The non-throwing async work to perform. Receives the emission-time value of `id`.
    /// - Returns: A `Cancellable` to stop the reactive task before the model deactivates.
    @discardableResult
    func task<Value: Equatable & Sendable>(
        id: @Sendable @autoclosure @escaping () -> Value,
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable (Value) async -> Void
    ) -> Cancellable {
        forEach(
            Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates) { id() },
            name: name,
            function: function,
            cancelPrevious: true,
            isDetached: isDetached,
            priority: priority,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        ) { value in
            await operation(value)
        }
    }

    /// Starts a task that is automatically restarted whenever any of the observed values change.
    ///
    /// Use this overload when async work depends on multiple values and must restart whenever any
    /// of them changes — for example, searching when either a query or filter changes.
    ///
    /// ```swift
    /// func onActivate() {
    ///     node.task(id: { (query, filter) }) { (query, filter) in
    ///         results = (try? await node.searchClient.search(query, filter: filter)) ?? []
    ///     }
    /// }
    /// ```
    ///
    /// The task restarts whenever any value changes (element-wise comparison). Any in-flight
    /// work is cancelled before the new task begins. The emission-time tuple is passed to
    /// `operation` and can be destructured inline.
    ///
    /// - Parameters:
    ///   - id: A closure returning a tuple of all observed values. The task restarts whenever
    ///     any element changes.
    ///   - initial: If `true` (default), runs immediately on activation.
    ///   - removeDuplicates: Skip restart when no value has changed. Defaults to `true`.
    ///   - coalesceUpdates: Batch rapid changes into a single restart. Defaults to `true`.
    ///   - name: Optional human-readable name shown in diagnostics and Instruments.
    ///   - isDetached: If `true`, starts the task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - operation: The async work. Receives the emission-time values as a tuple.
    ///   - catch: Called if `operation` throws.
    /// - Returns: A `Cancellable` to stop the reactive task before the model deactivates.
    @discardableResult
    func task<each Value: Equatable & Sendable>(
        id: @Sendable @escaping () -> (repeat each Value),
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable ((repeat each Value)) async throws -> Void,
        `catch` onError: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        // Pass `operation` directly — no lambda wrapper. Wrapping would require calling a
        // pack-typed closure from inside a non-pack closure body, which triggers a Swift
        // SILGen crash (emitPackExpansionIntoPack). Passing by reference to forEach is safe:
        // forEach receives it as (S.Element) async throws -> Void and calls it in non-pack context.
        forEach(
            Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates) { id() },
            name: name,
            function: function,
            cancelPrevious: true,
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

    /// Starts a non-throwing task that is automatically restarted whenever any of the observed values change.
    ///
    /// Convenience overload of `task(id:operation:catch:)` for operations that don't throw.
    ///
    /// - Parameters:
    ///   - id: A closure returning a tuple of all observed values.
    ///   - initial: If `true` (default), runs immediately on activation.
    ///   - removeDuplicates: Skip restart when no value has changed. Defaults to `true`.
    ///   - coalesceUpdates: Batch rapid changes into a single restart. Defaults to `true`.
    ///   - name: Optional human-readable name shown in diagnostics and Instruments.
    ///   - isDetached: If `true`, starts the task as a detached task. Defaults to `false`.
    ///   - priority: The priority of the task.
    ///   - operation: The non-throwing async work. Receives the emission-time values as a tuple.
    /// - Returns: A `Cancellable` to stop the reactive task before the model deactivates.
    @discardableResult
    func task<each Value: Equatable & Sendable>(
        id: @Sendable @escaping () -> (repeat each Value),
        initial: Bool = true,
        removeDuplicates: Bool = true,
        coalesceUpdates: Bool = true,
        name: String? = nil,
        function: StaticString = #function,
        isDetached: Bool = false,
        priority: TaskPriority? = nil,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable ((repeat each Value)) async -> Void
    ) -> Cancellable {
        // Coerce to throwing so we can pass directly to forEach without a lambda.
        let op: @Sendable ((repeat each Value)) async throws -> Void = operation
        return forEach(
            Observed(initial: initial, removeDuplicates: removeDuplicates, coalesceUpdates: coalesceUpdates) { id() },
            name: name,
            function: function,
            cancelPrevious: true,
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


