import Foundation
import Dependencies
import ConcurrencyExtras

// SPIKE — signals: an awaitable, repeatable request that reaches related models (like
// `send`), plus a guaranteed final call when a handler's model is removed. The removal
// call runs AFTER the model is gone, so it must not be hosted by the model: in
// production it is a plain task, in `.modelTesting` it is hosted by the test harness
// (runs on the test's executor, seen by `settle()`, reported if still running at the
// end of the test when the test itself triggered it).

/// Why a signal handler is running.
public enum SignalCause: Sendable, Equatable {
    /// `signal(_:to:)` reached the handler. The model is live: `node` may be used.
    case requested
    /// The handler's model was removed. The model is gone: use only captured values.
    case removed
}

public extension ModelNode {
    /// Registers an async handler for `signal(key, to:)` requests.
    ///
    /// The handler also gets exactly one final call with `.removed` when this model is
    /// removed (unless `once` and it already ran). Runs of one handler are serialized
    /// (a new request waits for the running one), or with `cancelPrevious` the new one
    /// cancels it. Different handlers always run concurrently.
    ///
    /// Cancelling the returned `Cancellable` (or `cancelAll(for:)` on a key it was
    /// registered under) unregisters the handler: it won't run again, not even on removal.
    @discardableResult
    func onSignal(_ key: some Hashable & Sendable, once: Bool = false, cancelPrevious: Bool = false, name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, perform: @escaping @Sendable (SignalCause) async -> Void) -> Cancellable {
        _registerSignalHandler(match: .key(CancellableKey(key: key)), once: once, cancelPrevious: cancelPrevious, name: name, function: function, priority: priority, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), perform: perform)
    }

    /// Registers an async handler for every `signal` request (any key), plus the final
    /// `.removed` call. See `onSignal(_:once:cancelPrevious:…)`.
    @discardableResult
    func onSignal(once: Bool = false, cancelPrevious: Bool = false, name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, perform: @escaping @Sendable (SignalCause) async -> Void) -> Cancellable {
        _registerSignalHandler(match: .any, once: once, cancelPrevious: cancelPrevious, name: name, function: function, priority: priority, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), perform: perform)
    }

    /// Async work that starts when this model is removed and may outlive it — a
    /// removal-only handler (never reached by `signal`). Capture what you need up front.
    @discardableResult
    func onTeardown(_ name: String? = nil, function: StaticString = #function, priority: TaskPriority? = nil, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, operation: @escaping @Sendable () async -> Void) -> Cancellable {
        _registerSignalHandler(match: .removalOnly, once: true, cancelPrevious: false, name: name, function: function, priority: priority, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)) { _ in
            await operation()
        }
    }

    /// Runs every handler registered for `key` on the models `relation` reaches,
    /// concurrently, and returns when all of those runs have finished.
    func signal(_ key: some Hashable & Sendable, to relation: ModelRelation = [.self, .descendants]) async {
        await _signal(CancellableKey(key: key), to: relation)
    }

    /// Runs every signal handler (any key) on the models `relation` reaches.
    func signal(to relation: ModelRelation = [.self, .descendants]) async {
        await _signal(nil, to: relation)
    }
}

private extension ModelNode {
    func _registerSignalHandler(match: SignalHandler.Match, once: Bool, cancelPrevious: Bool, name: String?, function: StaticString, priority: TaskPriority?, fileAndLine: FileAndLine, perform: @escaping @Sendable (SignalCause) async -> Void) -> Cancellable {
        guard let context = enforcedContext() else { return EmptyCancellable() }
        // Resolved NOW, while the model is live: after removal the context is sealed
        // and its root may be gone.
        let access = context.rootParent.modelAccess
        return SignalHandler(
            cancellations: context.cancellations,
            match: match, once: once, cancelPrevious: cancelPrevious,
            modelName: typeDescription,
            taskName: name ?? "\(function) @ \(fileAndLine.description)",
            fileAndLine: fileAndLine,
            host: access?.teardownWorkStore, access: access,
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
        for run in runs {
            _ = try? await run.value
        }
    }
}

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
            // The harness's own end-of-test teardown: not the test's removal — skip.
            guard access?.isInHarnessTeardown != true else { return }
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
            let serialized = cancelPrevious ? nil : previous

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
