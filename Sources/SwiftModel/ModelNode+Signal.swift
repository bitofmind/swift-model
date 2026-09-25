import Foundation

/// Why a signal handler is running.
///
/// See ``ModelNode/onSignal(_:once:cancelPrevious:name:function:priority:fileID:filePath:line:column:perform:)``.
public enum SignalCause: Sendable, Equatable {
    /// A ``ModelNode/signal(_:to:)`` call reached the handler. The model is live:
    /// `node`, its dependencies and its state can be used as usual.
    case requested

    /// The handler's model was removed; this is the handler's final call. The model is
    /// gone: use only values captured when the handler was registered, and don't touch
    /// `node`.
    case removed
}

public extension ModelNode {
    /// Registers an async handler that runs when a ``signal(_:to:)`` for `key` reaches
    /// this model, and one final time when the model is removed.
    ///
    /// Signals are for work a subtree does on request and must finish before the caller
    /// continues — flush analytics before leaving, save before syncing — and that should
    /// also happen, one last time, when the model goes away:
    ///
    /// ```swift
    /// enum Lifecycle: Hashable, Sendable { case flush }
    ///
    /// func onActivate() {
    ///     let reporter = node.reporter          // captured: the model may be gone
    ///     node.onSignal(Lifecycle.flush) { cause in
    ///         await reporter.flush(final: cause == .removed)
    ///     }
    /// }
    ///
    /// // Elsewhere — returns once every reached handler has finished:
    /// await session.node.signal(Lifecycle.flush)
    /// ```
    ///
    /// The final `.removed` call runs *after* the model is removed, so the handler must
    /// not depend on `node` then: capture what it needs when registering. Work started
    /// by it may outlive the model — an audio fade, a network flush — and is never
    /// dropped by the removal. It should tolerate cancellation.
    ///
    /// - Runs of one handler never overlap: a new request waits for the running one, or
    ///   with `cancelPrevious` cancels it and starts once it has unwound. Different
    ///   handlers always run concurrently.
    /// - With `once`, the handler runs at most one time in total — on the first request,
    ///   or on removal if no request reached it before.
    /// - Cancelling the returned ``Cancellable`` (or ``cancelAll(for:)`` on a key it was
    ///   registered under) unregisters the handler: it won't run again, not even on
    ///   removal.
    ///
    /// In tests, runs execute on the test's executor, `settle()`
    /// waits for them, and a run still going at the end of a test that removed its model
    /// is reported as an active task. Removals caused by the test harness's own
    /// end-of-test teardown run after the exhaustivity check (unchecked), and the scope
    /// waits for them — cancelling whatever is still parked, e.g. on a `TestClock` nobody
    /// advances — before it returns.
    ///
    /// - Parameters:
    ///   - key: The signal this handler answers to.
    ///   - once: Run at most one time in total. Defaults to `false`.
    ///   - cancelPrevious: A new run cancels the running one instead of waiting for it.
    ///   - name: Optional name for diagnostics; synthesized from the call site if omitted.
    ///   - perform: The work, given the ``SignalCause``.
    /// - Returns: A ``Cancellable`` that unregisters the handler.
    @discardableResult
    func onSignal(_ key: some Hashable & Sendable, once: Bool = false, cancelPrevious: Bool = false, name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, perform: @escaping @Sendable (SignalCause) async -> Void) -> Cancellable {
        _registerSignalHandler(match: .key(CancellableKey(key: key)), once: once, cancelPrevious: cancelPrevious, name: name, function: function, priority: priority, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), perform: perform)
    }

    /// Registers an async handler that runs for every ``signal(_:to:)`` reaching this
    /// model, whatever its key, and one final time when the model is removed.
    ///
    /// Same semantics as ``onSignal(_:once:cancelPrevious:name:function:priority:fileID:filePath:line:column:perform:)``.
    @discardableResult
    func onSignal(once: Bool = false, cancelPrevious: Bool = false, name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, perform: @escaping @Sendable (SignalCause) async -> Void) -> Cancellable {
        _registerSignalHandler(match: .any, once: once, cancelPrevious: cancelPrevious, name: name, function: function, priority: priority, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), perform: perform)
    }

    /// Registers async work that starts when this model is removed and may outlive it.
    ///
    /// Use it for cleanup that takes time — fading out audio, releasing a resource
    /// asynchronously — where ``onCancel(perform:)`` is too early to `await` and a `Task`
    /// started from it would be invisible to tests:
    ///
    /// ```swift
    /// func onActivate() {
    ///     let player = player                   // captured: the model will be gone
    ///     let clock = node.continuousClock
    ///     node.onTeardown {
    ///         defer { player.stop() }           // also when cancelled
    ///         await player.fadeOut(over: .seconds(1), on: clock)
    ///     }
    /// }
    /// ```
    ///
    /// It is a removal-only signal handler: never reached by ``signal(_:to:)``, run
    /// exactly once on removal. Capture what the work needs; don't touch `node` in it.
    /// Cancelling the returned ``Cancellable`` unregisters it.
    @discardableResult
    func onTeardown(_ name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, operation: @escaping @Sendable () async -> Void) -> Cancellable {
        _registerSignalHandler(match: .removalOnly, once: true, cancelPrevious: false, name: name, function: function, priority: priority, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)) { _ in
            await operation()
        }
    }

    /// Runs every handler registered for `key` on the models `relation` reaches — all
    /// concurrently — and returns when all of those runs have finished.
    ///
    /// Reach works like `send(_:to:)`: by default this model and its
    /// descendants; pass `.ancestors` to ask the models above, add `.dependencies` to
    /// include dependency models. Signals are repeatable. Cancelling the calling task
    /// cancels the runs this call started, so a deadline around a signal reaches the
    /// handlers:
    ///
    /// ```swift
    /// func leave() async {
    ///     await node.signal(Lifecycle.leave)    // announce while the tree is live
    ///     streams = []                          // then remove
    ///     await node.signal(Lifecycle.flush)
    /// }
    /// ```
    func signal(_ key: some Hashable & Sendable, to relation: ModelRelation = [.self, .descendants]) async {
        await _signal(CancellableKey(key: key), to: relation)
    }

    /// Runs every signal handler, whatever its key, on the models `relation` reaches,
    /// and returns when all of those runs have finished. See ``signal(_:to:)``.
    func signal(to relation: ModelRelation = [.self, .descendants]) async {
        await _signal(nil, to: relation)
    }
}

private extension ModelNode {
    func _registerSignalHandler(match: SignalHandler.Match, once: Bool, cancelPrevious: Bool, name: String?, function: StaticString, priority: TaskPriority?, fileAndLine: FileAndLine, perform: @escaping @Sendable (SignalCause) async -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }
        // Resolved NOW, while the model is live: by the final `.removed` call the context
        // is sealed and its root may be gone.
        let access = context.rootParent.modelAccess
        return SignalHandler(
            cancellations: context.cancellations,
            match: match, once: once, cancelPrevious: cancelPrevious,
            modelName: typeDescription,
            taskName: name ?? "\(function) @ \(fileAndLine.description)",
            fileAndLine: fileAndLine,
            host: access?.signalWorkStore, access: access,
            dependencies: context.capturedDependencies,
            executor: _TestExecutorBox.current,
            priority: priority, operation: perform
        )
    }

    func _signal(_ key: CancellableKey?, to relation: ModelRelation) async {
        guard let context = enforcedContext() else { return }
        let handlers = context.reduceHierarchy(for: relation, observeParents: false, transform: \.self, into: [SignalHandler]()) { result, context in
            let store = context.lock { context.cancellationsStore }
            result += store?.registered(of: SignalHandler.self).filter { $0.matches(key) } ?? []
        }
        let runs = handlers.compactMap { $0.start(.requested) }
        // Structured like a task group: cancelling the caller cancels the runs this call
        // started.
        await withTaskCancellationHandler {
            for run in runs {
                _ = try? await run.value
            }
        } onCancel: {
            for run in runs { run.cancel() }
        }
    }
}
