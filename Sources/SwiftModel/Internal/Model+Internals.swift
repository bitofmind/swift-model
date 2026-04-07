import Foundation
import Dependencies
import Observation
#if canImport(Dispatch)
import Dispatch
#endif

/// Returns the current monotonic time in nanoseconds.
/// Uses DispatchTime on platforms that have it (Darwin, Linux, Android);
/// falls back to ProcessInfo.systemUptime on WASI.
private func monotonicNanoseconds() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

/// Returns whether the current execution context is on the main thread.
/// WASI is single-threaded so this is always true there.
private var isOnMainThread: Bool {
    #if os(WASI)
    return true
    #else
    return Thread.isMainThread
    #endif
}

/// Internal bridge so all framework code can access the model context directly
/// without going through the public `_context` access token.
extension Model {
    var modelContext: ModelContext<Self> {
        get { _context._$modelContext }
        set { _updateContext(ModelContextUpdate(newValue)) }
    }
}

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
        try modelContext.transaction(callback)
    }
}

extension Model {
    var noAccess: Self {
        var copy = self
        copy.modelContext.access = nil
        return copy
    }

    var shallowCopy: Self {
        switch modelContext.source {
        case .frozenCopy:
            return self

        case let .reference(reference):
            if let context = reference.context {
                var copy = context[\.self]
                copy.modelContext.source = .frozenCopy(id: copy.modelID)
                copy.modelContext.access = nil
                return copy
            } else if let last = reference.model {
                return last
            } else {
                return self
            }

        case let .lastSeen(id: id):
            var copy = self
            copy.modelContext.source = .frozenCopy(id: id)
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
        
        if isOnMainThread {
            context.mainObservationRegistrar?.access(self, keyPath: path)
        } else {
            context.backgroundObservationRegistrar?.access(self, keyPath: path)
        }
    }

    func willSet<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        let path = path as! KeyPath<Self, T>
        
        if isOnMainThread {
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
        
        if isOnMainThread {
            // On main: call didSet on both registrars after mutation
            context.mainObservationRegistrar?.didSet(self, keyPath: path)
            context.backgroundObservationRegistrar?.didSet(self, keyPath: path)
        } else {
            // On background: call didSet on background registrar immediately
            context.backgroundObservationRegistrar?.didSet(self, keyPath: path)
            
            // Dispatch willSet+didSet together to main registrar (for SwiftUI safety)
            if let mainReg = context.mainObservationRegistrar {
                context.mainCallQueue {
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
// Two purpose-specific types are used:
// - `MainCallQueue` / `mainCall`: runs callbacks on the MainActor (SwiftUI observation
//   registrar delivery). Fast-paths when already on the main thread. Supports
//   `drain()`/`drainIfOnMain()` for synchronous flush from main-thread code paths.
// - `BackgroundCallQueue` / `backgroundCall`: runs callbacks on a detached background task
//   (Observed pipeline). Never touches the main thread. Supports `isIdle`/`waitUntilIdle()`
//   for the test assert loop.

// MARK: - Shared State

/// Internal queue state shared by both call-queue types.
private struct CallQueueState {
    var task: Task<(), Never>
    var calls: [@Sendable () -> Void]
    /// One-shot callbacks fired when the task goes idle (after all calls drain and yield).
    var onIdleCallbacks: [@Sendable () -> Void] = []
}

// MARK: - Shared drain-loop

/// The shared async drain loop body. Runs until the queue is empty, firing idle
/// callbacks and executing each batch before yielding to the cooperative scheduler.
private func callQueueDrainLoop(state: LockIsolated<CallQueueState?>) async {
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

// MARK: - Shared idle/wait helpers (used by both queue types)

private func callQueueIsIdle(_ state: LockIsolated<CallQueueState?>) -> Bool {
    state.value == nil
}

private func callQueueWaitUntilIdle(_ state: LockIsolated<CallQueueState?>, deadline: UInt64 = .max) async {
    await withCheckedContinuation { cont in
        let resumed = LockIsolated(false)
        let shouldResume = state.withValue { s -> Bool in
            if s != nil {
                s!.onIdleCallbacks.append {
                    resumed.withValue { r in
                        guard !r else { return }
                        r = true
                        cont.resume()
                    }
                }
                return false
            }
            return true
        }
        if shouldResume {
            cont.resume()
            return
        }
        if deadline < .max {
            // Use DispatchQueue instead of Task for deadline enforcement.
            // A Task must be *scheduled* on the cooperative pool before it can
            // register its sleep timer.  Under pool saturation (many parallel tests
            // on a 2-vCPU CI runner) the Task may never start, leaving the
            // continuation permanently suspended.  DispatchQueue.asyncAfter
            // registers a kernel-level timer immediately, independent of the
            // cooperative pool.
            let now = monotonicNanoseconds()
            let delay = deadline > now ? deadline - now : 0
            #if canImport(Dispatch)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                resumed.withValue { r in
                    guard !r else { return }
                    r = true
                    cont.resume()
                }
            }
            #else
            Task.detached {
                try? await Task.sleep(nanoseconds: delay)
                resumed.withValue { r in
                    guard !r else { return }
                    r = true
                    cont.resume()
                }
            }
            #endif
        }
    }
}

private func callQueueWaitForCurrentItems(_ state: LockIsolated<CallQueueState?>, deadline: UInt64) async {
    await withCheckedContinuation { cont in
        let shouldResume = state.withValue { s -> Bool in
            guard s != nil else { return true }
            let resumed = LockIsolated(false)
            s!.calls.append {
                resumed.withValue { r in
                    guard !r else { return }
                    r = true
                    cont.resume()
                }
            }
            if deadline < .max {
                // Use DispatchQueue instead of Task — same rationale as
                // callQueueWaitUntilIdle above.
                let now = monotonicNanoseconds()
                let delay = deadline > now ? deadline - now : 0
                #if canImport(Dispatch)
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                    resumed.withValue { r in
                        guard !r else { return }
                        r = true
                        cont.resume()
                    }
                }
                #else
                Task.detached {
                    try? await Task.sleep(nanoseconds: delay)
                    resumed.withValue { r in
                        guard !r else { return }
                        r = true
                        cont.resume()
                    }
                }
                #endif
            }
            return false
        }
        if shouldResume { cont.resume() }
    }
}

// MARK: - MainCallQueue

/// Delivers SwiftUI ObservationRegistrar notifications on the main actor.
///
/// Fast-paths when already on the main thread by calling the callback directly instead of
/// enqueuing. Use `drain()`/`drainIfOnMain()` for a synchronous flush from main-thread
/// code paths (e.g. after a model write, to flush any notifications enqueued from a
/// background thread before this call).
struct MainCallQueue: @unchecked Sendable {
    private let state = LockIsolated<CallQueueState?>(nil)

    // MARK: Enqueue

    /// Enqueues `callback` for delivery on the main actor.
    ///
    /// If already on the main thread, `callback` is executed immediately (fast-path).
    /// Otherwise it is enqueued and a `@MainActor` drain task is spawned if one is not
    /// already running.
    func callAsFunction(_ callback: @escaping @Sendable () -> Void) {
        guard !isOnMainThread else {
            callback()
            return
        }
        state.withValue {
            if $0 == nil {
                $0 = CallQueueState(task: Task(priority: .userInitiated) { @MainActor in
                    await callQueueDrainLoop(state: self.state)
                }, calls: [callback])
            } else {
                $0!.calls.append(callback)
            }
        }
    }

    // MARK: Drain (main-thread synchronous flush)

    /// Synchronously drains all pending callbacks on the main thread.
    ///
    /// This flushes any notifications that were enqueued from a background thread and are
    /// waiting for the main actor. Must only be called from the main thread.
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

    /// Drains pending callbacks if currently on the main thread; no-op otherwise.
    func drainIfOnMain() {
        guard isOnMainThread else { return }
        drain()
    }

    // MARK: Idle

    /// True when no drain task is currently running.
    var isIdle: Bool { callQueueIsIdle(state) }

    /// Suspends until the drain task goes idle (all calls flushed including `Task.yield()`).
    /// Pass a `deadline` (absolute uptime nanoseconds) to bound the wait; defaults to `.max` (unbounded).
    func waitUntilIdle(deadline: UInt64 = .max) async {
        await callQueueWaitUntilIdle(state, deadline: deadline)
    }

    /// Suspends until all items currently in the queue have been processed, or the deadline passes.
    func waitForCurrentItems(deadline: UInt64 = .max) async {
        await callQueueWaitForCurrentItems(state, deadline: deadline)
    }
}

// MARK: - BackgroundCallQueue

/// Delivers Observed pipeline updates on a detached background task.
///
/// Never touches the main thread. Use `isIdle`/`waitUntilIdle()`/`waitForCurrentItems()`
/// in tests to wait for the pipeline to settle.
struct BackgroundCallQueue: @unchecked Sendable {
    private let state = LockIsolated<CallQueueState?>(nil)

    // MARK: Enqueue

    /// Enqueues `callback` for delivery on a detached background task.
    func callAsFunction(_ callback: @escaping @Sendable () -> Void) {
        state.withValue {
            if $0 == nil {
                $0 = CallQueueState(task: Task.detached(priority: .userInitiated) {
                    await callQueueDrainLoop(state: self.state)
                }, calls: [callback])
            } else {
                $0!.calls.append(callback)
            }
        }
    }

    // MARK: Idle

    /// True when no drain task is currently running.
    var isIdle: Bool { callQueueIsIdle(state) }

    /// Suspends until the drain task goes idle (all calls flushed including `Task.yield()`).
    /// Pass a `deadline` (absolute uptime nanoseconds) to bound the wait; defaults to `.max` (unbounded).
    func waitUntilIdle(deadline: UInt64 = .max) async {
        await callQueueWaitUntilIdle(state, deadline: deadline)
    }

    /// Suspends until all items currently in the queue have been processed, or the deadline passes.
    func waitForCurrentItems(deadline: UInt64 = .max) async {
        await callQueueWaitForCurrentItems(state, deadline: deadline)
    }
}

// MARK: - Global instances

/// Delivers SwiftUI ObservationRegistrar notifications on the main actor.
/// Fast-paths when already on the main thread (calls directly without enqueuing).
/// Use `drain()`/`drainIfOnMain()` for synchronous flush from main-thread code paths.
let mainCall = MainCallQueue()

/// Global fallback when no test-local queue is active.
private let _globalBackgroundCallQueue = BackgroundCallQueue()

/// Task-local override for `backgroundCall`. Set by `.modelTesting`'s `provideScope` so
/// each test runs against its own isolated queue — parallel tests cannot observe each
/// other's in-flight `Observed` updates.
enum _BackgroundCallLocals {
    @TaskLocal static var queue: BackgroundCallQueue? = nil
}

/// Delivers Observed pipeline updates on a background thread.
/// Use `isIdle`/`waitUntilIdle()` in tests to wait for the pipeline to settle.
/// Inside a `.modelTesting` test scope the task-local queue is returned, providing
/// per-test isolation; outside tests the global singleton is used.
var backgroundCall: BackgroundCallQueue {
    _BackgroundCallLocals.queue ?? _globalBackgroundCallQueue
}

// MARK: - Batched observation updates

/// Defers `ObservationRegistrar` `willSet`/`didSet` notifications during bulk writes.
///
/// Within the `body` closure, every call to `invokeDidModify` that would normally fire
/// registrar notifications inline instead appends those notifications to a thread-local
/// pending list. When `body` returns, all deferred notifications fire in order, followed
/// by a single `mainCall.drainIfOnMain()`.
///
/// `activeAccess` (`TestAccess`/`AccessCollector`) callbacks still fire per-write as usual —
/// only the registrar notifications are deferred.
///
/// Nesting is handled correctly: if a `withBatchedUpdates` scope is already active on this
/// thread, the inner call simply runs `body` directly without creating a second batch.
func _withBatchedUpdates<T>(_ mainCallQueue: MainCallQueue = mainCall, _ body: () throws -> T) rethrows -> T {
    guard threadLocals.pendingObservationNotifications == nil else {
        return try body()
    }
    threadLocals.pendingObservationNotifications = []
    defer {
        let pending = threadLocals.pendingObservationNotifications!
        threadLocals.pendingObservationNotifications = nil
        for notification in pending { notification() }
        mainCallQueue.drainIfOnMain()
    }
    return try body()
}
