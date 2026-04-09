import Foundation
import Dependencies
import Observation
#if canImport(Dispatch)
import Dispatch
#endif

/// Returns whether the current execution context is the main thread.
/// On WASI (single-threaded), this is always true.
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

// Two purpose-specific queue types route observation callbacks:
//
// - `MainCallQueue` / `mainCall`: delivers SwiftUI ObservationRegistrar notifications on
//   the main actor. Fast-paths when already on the main thread. Supports synchronous
//   `drain()`/`drainIfOnMain()` for model writes that happen on the main thread.
//
// - `BackgroundCallQueue` / `backgroundCall`: delivers Observed pipeline updates on a
//   pre-started background Task (via AsyncStream). Never touches the main thread.
//   Supports `isIdle`/`waitUntilIdle()`/`waitForCurrentItems()` for the test assert loop.
//   A single drain task is started at init and reused for the queue's lifetime — no new
//   tasks are spawned when work arrives, avoiding cooperative-pool saturation on CI.

// MARK: - Shared State

/// Internal queue state shared by both call-queue types.
private struct CallQueueState {
    var task: Task<(), Never>
    var calls: [@Sendable () -> Void]
    /// One-shot callbacks fired when the task goes idle (after all calls drain and yield).
    var onIdleCallbacks: [@Sendable () -> Void] = []
}

// MARK: - Shared drain-loop (MainCallQueue only)

/// Async drain loop for `MainCallQueue`. Runs on `@MainActor` until the queue is empty,
/// then cancels the task and fires idle callbacks.
///
/// Uses `Task.yield()` between batches. `MainCallQueue` runs on `@MainActor` where there
/// is at most one active actor task at a time, so pool saturation is not a concern.
/// `BackgroundCallQueue` uses a separate `AsyncStream`-based design that does not need
/// this loop.
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
#if canImport(Dispatch)
            // DispatchQueue.asyncAfter registers a kernel-level timer immediately,
            // independent of the cooperative pool — safe under CI pool saturation.
            let now = DispatchTime.now().uptimeNanoseconds
            let delay = deadline > now ? deadline - now : 0
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                resumed.withValue { r in
                    guard !r else { return }
                    r = true
                    cont.resume()
                }
            }
#else
            Task.detached {
                let now = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                let delay = deadline > now ? deadline - now : 0
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
#if canImport(Dispatch)
                let now = DispatchTime.now().uptimeNanoseconds
                let delay = deadline > now ? deadline - now : 0
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                    resumed.withValue { r in
                        guard !r else { return }
                        r = true
                        cont.resume()
                    }
                }
#else
                Task.detached {
                    let now = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
                    let delay = deadline > now ? deadline - now : 0
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

    /// Suspends until the drain task goes idle (all calls flushed).
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

/// Delivers Observed pipeline updates on a background thread via `AsyncStream`.
///
/// A single drain `Task` is created at `init` and lives for the queue's lifetime,
/// suspended at `for await` when idle. When work arrives via `callAsFunction(_:)`,
/// the `AsyncStream` continuation resumes the already-scheduled task — no new `Task`
/// is ever spawned on the hot path. This avoids cooperative-pool saturation: on a
/// 2-vCPU CI runner with 100+ parallel tests, spawning `Task.detached` for every
/// observation callback queues behind hundreds of waiting tasks. Resuming a suspended
/// continuation is handled by the Swift runtime with much lower latency.
/// Multiple callbacks buffered while the drain task is between iterations are all
/// delivered without yielding (AsyncStream returns buffered items without suspending).
///
/// Works on WASM (no `libdispatch`): the single-threaded event loop has no pool
/// saturation, and `AsyncStream` is part of the Swift standard library.
struct BackgroundCallQueue: @unchecked Sendable {
    private struct WaitState {
        var pendingCount = 0
        var onIdleCallbacks: [@Sendable () -> Void] = []
    }

    private let streamCont: AsyncStream<@Sendable () -> Void>.Continuation
    private let drainTask: Task<Void, Never>
    private let waitState = LockIsolated(WaitState())

    init() {
        let (stream, cont) = AsyncStream.makeStream(
            of: (@Sendable () -> Void).self,
            bufferingPolicy: .unbounded
        )
        streamCont = cont
        let ws = waitState
        drainTask = Task.detached(priority: .userInitiated) {
            for await callback in stream {
                callback()
                let idle: [@Sendable () -> Void] = ws.withValue { s in
                    s.pendingCount -= 1
                    guard s.pendingCount == 0 else { return [] }
                    let cbs = s.onIdleCallbacks
                    s.onIdleCallbacks = []
                    return cbs
                }
                for f in idle { f() }
            }
        }
    }

    // MARK: Enqueue

    /// Resumes the drain task with `callback` (no new Task spawned).
    func callAsFunction(_ callback: @escaping @Sendable () -> Void) {
        waitState.withValue { $0.pendingCount += 1 }
        streamCont.yield(callback)
    }

    // MARK: Idle

    /// True when all enqueued callbacks have been processed.
    var isIdle: Bool { waitState.value.pendingCount == 0 }

    /// Suspends until all enqueued callbacks have been processed.
    /// Pass a `deadline` (absolute uptime nanoseconds) to bound the wait.
    func waitUntilIdle(deadline: UInt64 = .max) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = LockIsolated(false)
            let resume: @Sendable () -> Void = {
                resumed.withValue { r in
                    guard !r else { return }
                    r = true
                    cont.resume()
                }
            }
            let shouldResume = waitState.withValue { s -> Bool in
                guard s.pendingCount > 0 else { return true }
                s.onIdleCallbacks.append(resume)
                return false
            }
            if shouldResume { cont.resume(); return }
            if deadline < .max {
                Task.detached {
                    let now = monotonicNanoseconds()
                    let ns = deadline > now ? deadline - now : 0
                    try? await Task.sleep(nanoseconds: ns)
                    resume()
                }
            }
        }
    }

    /// Suspends until all items currently in the queue have been processed.
    func waitForCurrentItems(deadline: UInt64 = .max) async {
        if isIdle { return }
        let ws = waitState
        let sc = streamCont
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = LockIsolated(false)
            let resume: @Sendable () -> Void = {
                resumed.withValue { r in
                    guard !r else { return }
                    r = true
                    cont.resume()
                }
            }
            // Re-check under lock; enqueue sentinel that counts as one pending item.
            let skipSentinel = ws.withValue { s -> Bool in
                guard s.pendingCount > 0 else { return true }
                s.pendingCount += 1  // account for the sentinel callback below
                return false
            }
            if skipSentinel { cont.resume(); return }
            // Sentinel is enqueued after all current items. When it runs, those items
            // have been processed. It then decrements pendingCount and may fire idle callbacks.
            sc.yield {
                resume()
                let idle: [@Sendable () -> Void] = ws.withValue { s in
                    s.pendingCount -= 1
                    guard s.pendingCount == 0 else { return [] }
                    let cbs = s.onIdleCallbacks
                    s.onIdleCallbacks = []
                    return cbs
                }
                for f in idle { f() }
            }
            if deadline < .max {
                Task.detached {
                    let now = monotonicNanoseconds()
                    let ns = deadline > now ? deadline - now : 0
                    try? await Task.sleep(nanoseconds: ns)
                    resume()
                }
            }
        }
    }
}

/// Returns the current monotonic time in nanoseconds, used for deadline arithmetic.
/// On platforms with `libdispatch`, uses `DispatchTime`; on WASM falls back to
/// `ProcessInfo.systemUptime`.
private func monotonicNanoseconds() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
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
