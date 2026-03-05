import Foundation
import Dependencies

extension Model {
    func assertInitialState(function: String = #function) {
        if lifetime != .initial {
            reportIssue("Calling \(function) on an anchored model is not allowed and has no effect")
        }
    }

    func withSetupAccess(modify: (ModelSetupAccess<Self>) -> Void, function: String = #function) -> Self {
        assertInitialState(function: function)

        let access = (access as? ModelSetupAccess<Self>) ?? ModelSetupAccess<Self>()
        modify(access)
        return withAccess(access)
    }

    var modelSetup: ModelSetupAccess<Self>? {
        access as? ModelSetupAccess<Self>
    }
}

final class ModelSetupAccess<M: Model>: ModelAccess, @unchecked Sendable {
    var dependencies: [(inout ModelDependencies) -> Void] = []
    var activations: [(M) -> Void] = []

    var allDependencies: ((inout ModelDependencies) -> Void)? {
        if dependencies.isEmpty { return nil }
        return { [dependencies = dependencies] in
            for dependency in dependencies {
                dependency(&$0)
            }
        }
    }

    init() {
        super.init(useWeakReference: false)
    }
}

extension Model {
    var typeDescription: String {
        String(describing: type(of: self))
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        try _$modelContext.transaction(callback)
    }
}

extension Model {
    var noAccess: Self {
        withAccess(nil)
    }

    var shallowCopy: Self {
        switch _$modelContext.source {
        case .frozenCopy:
            return self

        case let .reference(reference):
            if let context = reference.context {
                var copy = context[\.self]
                copy.withSource(.frozenCopy(id: copy.modelID))
                return copy.withAccess(nil)
            } else if let last = reference.model {
                return last
            } else {
                return self
            }

        case let .lastSeen(id: id):
            var copy = self
            copy.withSource(.frozenCopy(id: id))
            return copy
        }
    }
}

extension Model {
    func enforcedContext(_ function: StaticString = #function) -> Context<Self>? {
        enforcedContext("Calling \(function) on an unanchored model is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<Self>? {
        guard let context else {
            reportIssue(message())
            return nil
        }

        return context
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension Model where Self: Observable {
    func access<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        let path = path as! KeyPath<Self, T>
        
        if Thread.isMainThread {
            context.mainObservationRegistrar?.access(self, keyPath: path)
        } else {
            context.backgroundObservationRegistrar?.access(self, keyPath: path)
        }
    }

    func willSet<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        let path = path as! KeyPath<Self, T>
        
        if Thread.isMainThread {
            // On main: call willSet on both registrars before mutation
            context.mainObservationRegistrar?.willSet(self, keyPath: path)
            context.backgroundObservationRegistrar?.willSet(self, keyPath: path)
        } else {
            // On background: only call willSet on background registrar
            // Main registrar will get willSet+didSet together via mainCall (after mutation)
            context.backgroundObservationRegistrar?.willSet(self, keyPath: path)
        }
    }

    func didSet<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        let path = path as! KeyPath<Self, T>&Sendable
        
        if Thread.isMainThread {
            // On main: call didSet on both registrars after mutation
            context.mainObservationRegistrar?.didSet(self, keyPath: path)
            context.backgroundObservationRegistrar?.didSet(self, keyPath: path)
        } else {
            // On background: call didSet on background registrar immediately
            context.backgroundObservationRegistrar?.didSet(self, keyPath: path)
            
            // Dispatch willSet+didSet together to main registrar (for SwiftUI safety)
            if let mainReg = context.mainObservationRegistrar {
                mainCall {
                    mainReg.willSet(self, keyPath: path)
                    mainReg.didSet(self, keyPath: path)
                }
            }
        }
    }
}

// Batches multiple callbacks into a single Task, draining them all before yielding.
//
// This serves two purposes:
// 1. Breaks synchronous call stacks via Task.yield() to prevent stack overflow.
// 2. Amortizes Task creation overhead by batching multiple callbacks into one Task.
//
// Note: This does NOT implement "coalescing" (deduplication). That logic lives in callers.
//
// Two instances are used:
// - `mainCall`: runs callbacks on the MainActor (SwiftUI observation registrar delivery).
//   Supports `drain()`/`drainIfOnMain()` and has an early-exit when already on main.
// - `backgroundCall`: runs callbacks on a detached background task (Observed pipeline).
//   Supports `isIdle`/`waitUntilIdle()` for the test assert loop.
struct BatchedCalls: @unchecked Sendable {
    struct State {
        var task: Task<(), Never>
        var calls: [@Sendable () -> Void]
        /// One-shot callbacks fired when the task goes idle (after all calls drain and yield).
        var onIdleCallbacks: [@Sendable () -> Void] = []
    }

    private let state = LockIsolated<State?>(nil)
    /// Called to spawn a new drain task. Receives the `state` lock so the loop can call `nextBatch`.
    private let makeTask: @Sendable (LockIsolated<State?>) -> Task<(), Never>
    /// When set, `callAsFunction` fast-paths by calling immediately instead of enqueuing.
    private let shouldCallDirectly: @Sendable () -> Bool

    init(
        makeTask: @escaping @Sendable (LockIsolated<State?>) -> Task<(), Never>,
        shouldCallDirectly: @escaping @Sendable () -> Bool = { false }
    ) {
        self.makeTask = makeTask
        self.shouldCallDirectly = shouldCallDirectly
    }

    // MARK: Drain (main-thread synchronous flush)

    /// Synchronously drains all pending callbacks. Must only be called from the main thread.
    func drain() {
        let calls: [@Sendable () -> Void] = state.withValue {
            guard $0 != nil else { return [] }
            let calls = $0!.calls
            $0!.calls.removeAll()
            return calls
        }
        guard !calls.isEmpty else { return }
        MainActor.assumeIsolated {
            for call in calls { call() }
        }
    }

    func drainIfOnMain() {
        guard Thread.isMainThread else { return }
        drain()
    }

    // MARK: Idle (background settle detection)

    /// True when no drain task is currently running.
    var isIdle: Bool { state.value == nil }

    /// Suspends until the drain task goes idle (all calls flushed including `Task.yield()`).
    /// Returns immediately if already idle.
    func waitUntilIdle() async {
        await withCheckedContinuation { cont in
            let shouldResume = state.withValue { s -> Bool in
                if s != nil {
                    s!.onIdleCallbacks.append { cont.resume() }
                    return false
                }
                return true
            }
            if shouldResume { cont.resume() }
        }
    }

    // MARK: Enqueue

    func callAsFunction(_ callback: @escaping @Sendable () -> Void) {
        guard !shouldCallDirectly() else {
            callback()
            return
        }
        state.withValue {
            if $0 == nil {
                $0 = State(task: makeTask(state), calls: [callback])
            } else {
                $0!.calls.append(callback)
            }
        }
    }

    // MARK: Drain loop

    /// The shared async drain loop body. Runs until the queue is empty, firing idle
    /// callbacks and executing each batch before yielding to the cooperative scheduler.
    static func drainLoop(state: LockIsolated<State?>) async {
        while !Task.isCancelled {
            let (batch, onIdle): ([@Sendable () -> Void], [@Sendable () -> Void]) = state.withValue {
                guard $0 != nil else { return ([], []) }
                if $0!.calls.isEmpty {
                    $0!.task.cancel()
                    let idle = $0!.onIdleCallbacks
                    $0 = nil
                    return ([], idle)
                }
                let batch = $0!.calls
                $0!.calls.removeAll()
                return (batch, [])
            }
            for f in onIdle { f() }
            guard !batch.isEmpty else { break }
            for call in batch { call() }
            await Task.yield()
        }
    }
}

/// Delivers SwiftUI ObservationRegistrar notifications on the main actor.
/// Fast-paths when already on the main thread (calls directly without enqueuing).
/// Use `drain()`/`drainIfOnMain()` for synchronous flush from main-thread code paths.
let mainCall = BatchedCalls(
    makeTask: { state in
        Task(priority: .userInitiated) { @MainActor in
            await BatchedCalls.drainLoop(state: state)
        }
    },
    shouldCallDirectly: { Thread.isMainThread }
)

/// Delivers Observed pipeline updates on a background thread.
/// Use `isIdle`/`waitUntilIdle()` in tests to wait for the pipeline to settle.
let backgroundCall = BatchedCalls(
    makeTask: { state in
        Task.detached(priority: .userInitiated) {
            await BatchedCalls.drainLoop(state: state)
        }
    }
)


