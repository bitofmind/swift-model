import Foundation
import Dependencies

struct EmptyCancellable: Cancellable {
    func cancel() {}

    func cancel(for key: some Hashable & Sendable, cancelInFlight: Bool) -> EmptyCancellable { self }
}


final class AnyCancellable: Cancellable, InternalCancellable, @unchecked Sendable {
    weak var cancellations: Cancellations?
    let id: Int
    private let _onCancel: @Sendable () -> Void

    init(cancellations: Cancellations, onCancel: @escaping @Sendable () -> Void) {
        self.cancellations = cancellations
        id = cancellations.nextId
        _onCancel = onCancel
        cancellations.register(self)
    }

    func onCancel() {
        _onCancel()
    }

    public func cancel() {
        cancellations?.cancel(self)
    }

    @discardableResult
    public func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }

    @TaskLocal static var contexts: [CancellableKey] = []
    @TaskLocal static var inheritedContexts: [CancellableKey] = []
}

final class TaskCancellable: Cancellable, InternalCancellable, @unchecked Sendable {
    let id: Int
    weak var cancellations: Cancellations?
    var task: Task<Void, Error>!
    let modelName: String
    let taskName: String
    let fileAndLine: FileAndLine
    let lock = NSLock()
    var hasBeenCancelled = false

    /// `true` once the wrapped Task's body has begun executing on the
    /// cooperative pool. Read by `TestAccess.settle()` (via
    /// `Cancellations.hasPendingStartTask` and `AnyContext.hasPendingStartTask`)
    /// to keep its quiet window open until every freshly-registered task has
    /// had at least one CPU slot. See the `ModelAccess.taskBodyStarted`
    /// doc-comment for why this matters.
    ///
    /// Set via a `LockIsolated<Bool>` captured by the body wrapper in the
    /// convenience init, which creates the box BEFORE `self.init` (the factory
    /// closure is constructed before designated-init completes) and passes it
    /// in. It is a `let` assigned before `register(self)` publishes this
    /// instance, so a settle thread reaching it through `Cancellations` reads an
    /// immutable reference — the box's own lock covers the `Bool`.
    ///
    /// It used to be a `var` installed after `self.init` under `lock`, read
    /// without that lock on the theory that a racing reader sees `nil` and
    /// reports the safe default. That is a data race on the reference itself,
    /// and TSan caught it (`_driveToStableFixpoint` → `hasPendingStartTask`
    /// racing a `forEach` task registration). Passing the box in removes the
    /// window rather than defending it; the observable value is unchanged
    /// (`false` until the body runs).
    ///
    /// The box is a `ModelWorkUnit`, which also carries this task's
    /// running/parked state for semantic quiescence. Same object, same
    /// publication rules — no extra allocation over the `LockIsolated<Bool>`
    /// it replaced.
    let workUnit: ModelWorkUnit
    var hasStartedRunning: Bool { workUnit.hasStartedRunning }

    init(modelName: String, taskName: String, fileAndLine: FileAndLine, context: AnyContext, workUnit: ModelWorkUnit, task: @escaping @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Error>) {
        // Assigned before `cancellations.register(self)` below publishes this
        // instance to any settle thread — see `workUnit`.
        self.workUnit = workUnit
        // Resolve the registry ONCE, before `lock` is taken. `AnyContext.cancellations`
        // acquires the per-context hierarchy lock (H); this instance's `lock` is T.
        // Evaluating `context.cancellations` *inside* `lock { }` — as the capture-list
        // expression below used to — orders this init T→H, while teardown runs H→T:
        // a subtree replacement reaches `AnyContext.onRemoval` →
        // `Cancellations.cancelAll()` → `TaskCancellable.onCancel`, which blocks on T.
        // That is an AB-BA cycle, and it hangs hard: 0% CPU, pinned indefinitely.
        //
        // READ THE H→T ARM CAREFULLY — `AnyContext.onRemoval()` drains its callbacks
        // OUTSIDE its own `lock`, so `cancelAll` looks unlocked and the arm looks
        // refuted. It isn't: what supplies H is the ENCLOSING `node.transaction`,
        // which holds it across its entire body (`Context.transaction`), so the drain
        // still runs under H. Citing `onRemoval` alone gets this dismissed on review.
        //
        // Hoisting is free — the value is needed on the first line anyway, so this
        // takes and releases H exactly where it already did, just once. The ordering
        // is now uniformly H-before-T and the cycle is gone by construction.
        //
        // Same family as the `reduceHierarchy` (#29) and `memoize` (#30) inversions:
        // whenever a leaf lock is held, do not evaluate anything that reaches a
        // context lock — including capture-list expressions, which are evaluated at
        // closure-formation time, i.e. inside the enclosing critical section.
        let cancellations = context.cancellations
        self.cancellations = cancellations
        let id = cancellations.nextId
        self.id = id
        self.modelName = modelName
        self.taskName = taskName
        self.fileAndLine = fileAndLine
        self.task = nil

        cancellations.register(self)

        let bodyWillNeverRun: Bool = lock {
            guard !self.hasBeenCancelled else {
                // Task was cancelled before init reached the task-creation point;
                // the underlying Task stays nil and never runs.
                return true
            }
            self.task = task { [weak cancellations] in
                _ = cancellations?.unregister(id)
                // Semantic quiescence: the body cannot run again, so the work
                // unit retires here and ONLY here — see
                // `Cancellations.liveWorkUnits`.
                cancellations?.retireWorkUnit(id)
            }
            return false
        }
        // Nothing will ever call `onDone` on this path, so the live work unit
        // has to be retired explicitly or it would pin the model as
        // non-quiescent forever. Done OUTSIDE `lock` (T): every other path into
        // `Cancellations` (C) runs with T released, and adding a T→C edge here
        // would be the only one in the file going that way — see the H→T
        // ordering note in `init` above.
        if bodyWillNeverRun {
            cancellations.retireWorkUnit(id)
        }
    }

    func onCancel() {
        lock {
            self.hasBeenCancelled = true
            return self.task
        }?.cancel()
    }

    public func cancel() {
        cancellations?.cancel(self)
    }

    @discardableResult
    public func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }
}

extension TaskCancellable {
    /// The underlying Swift `Task<Void, Error>`, or `nil` if the task was cancelled
    /// before `init` could schedule it. Awaiting `.value` on this Task resolves once
    /// the wrapped Task's outer `defer { onDone() }` runs — which is unconditional
    /// (it fires regardless of whether the inner cancellation guard let the user
    /// closure execute). Used by `_forEachImpl`'s body-serialization logic to
    /// guarantee the next body starts only after the previous body's full unwind.
    var underlyingTask: Task<Void, Error>? {
        lock { self.task }
    }

    convenience init(modelName: String, taskName: String, fileAndLine: FileAndLine, context: AnyContext, isDetached: Bool, priority: TaskPriority?, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: (@Sendable (Error) -> Void)?) {
        // Constructed BEFORE self.init so the factory closure can capture it.
        // Stored on `self` AFTER self.init completes — see `workUnit`.
        let workUnit = ModelWorkUnit()

        self.init(modelName: modelName, taskName: taskName, fileAndLine: fileAndLine, context: context, workUnit: workUnit) { onDone in
            let contexts = AnyCancellable.contexts
            let operation = { @Sendable in
                // UNREGISTER LAST — the work unit must outlive the whole task
                // body, `catch` handler included.
                //
                // `onDone()` unregisters this `TaskCancellable` from
                // `Cancellations`, which is what makes the unit disappear from
                // `hasRunningWorkUnit`. It used to sit in a `defer` INSIDE the
                // innermost task-local scope, i.e. it fired before the
                // `catch` block below ran — and `catch` is user code
                // (`node.task(catch:)`, `node.onChange(catch:)`) that routinely
                // writes model state:
                //
                //     node.task { try await mayFail() } catch: { error in
                //         self.error = "\(error)"          // <- model write
                //     }
                //
                // Under the scheduler-observing answer that window was covered
                // for free (the executor job is still outstanding), but under
                // semantic quiescence the registry would already read
                // "quiescent" while a model write was still to come — a
                // premature pass. Hoisting the `defer` to the closure's
                // outermost scope closes it: the unit is unregistered only once
                // nothing in the body can run again.
                //
                // Unconditional either way, so `underlyingTask.value` (which
                // `_forEachImpl` uses to serialise bodies) still resolves after
                // it, exactly as its doc-comment states.
                defer { onDone() }

                // Publish this body's work unit to the task-local so
                // `withModelParked` — called from anywhere inside the body,
                // including child tasks and library code the body calls into,
                // and including the `catch` handler — finds the right unit to
                // mark parked. Set once per body; see `ModelWorkUnit`.
                await ModelWorkUnit.$current.withValue(workUnit) {
                    do {
                        // Use context.capturedDependencies directly (not withDependencies(from: context))
                        // so the task inherits exactly the context's dep overrides. withDependencies(from:)
                        // would merge against DependencyValues._current, potentially losing overrides.
                        try await DependencyValues.$_current.withValue(context.capturedDependencies) {
                            try await ModelAccess.$isInModelTaskContext.withValue(true) {
                                try await AnyCancellable.$inheritedContexts.withValue(contexts) {
                                    try await AnyCancellable.$contexts.withValue([]) {
                                        guard !Task.isCancelled, !context.isDestructed else { return }

                                        // Signal that the body has now actually started executing —
                                        // see `ModelAccess.taskBodyStarted` and
                                        // `TaskCancellable.workUnit`. Setting the box
                                        // BEFORE notifying the access avoids a window where settle
                                        // could re-check `hasPendingStartTask`, see this task still
                                        // not-started, and re-arm pointlessly.
                                        workUnit.markBodyStarted()
                                        ModelAccess.current?.taskBodyStarted()

                                        try await operation()
                                    }
                                }
                            }
                        }
                    } catch {
                        if Task.isCancelled || error is CancellationError { return }
                        `catch`?(error)
                    }
                }
            }

            #if canImport(Dispatch)
            // EXPERIMENTAL (executor-drain quiescence): in `.modelTesting`, run
            // model task bodies on the per-test harness executor so the test can
            // drive them to a fixpoint instead of waiting on the wall clock. The
            // contextual `Task<Void, Error>` return type resolves the throwing
            // `executorPreference` overload, exactly as the plain spawns below.
            // (Name is dropped here only because the `name:`+`executorPreference:`
            // combined initializer isn't available across all supported toolchains.)
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
               let exec = _TestExecutorBox.current as? _DrainTestExecutor {
                if isDetached {
                    return Task.detached(executorPreference: exec, priority: priority, operation: operation)
                } else {
                    return Task(executorPreference: exec, priority: priority, operation: operation)
                }
            }
            #endif
            if isDetached {
                return Task.detached(name: taskName, priority: priority, operation: operation)
            } else {
                return Task(name: taskName, priority: priority, operation: operation)
            }
        }
    }
}

