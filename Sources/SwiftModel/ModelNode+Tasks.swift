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
}
