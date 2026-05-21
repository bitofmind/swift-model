import Foundation
import Dependencies
#if canImport(Dispatch)
import Dispatch
#endif

// - `BackgroundCallQueue` / `backgroundCall`: delivers Observed pipeline updates on a
//   detached cooperative-pool Task. Never touches the main thread. Supports
//   `isIdle`/`waitUntilIdle()`/`waitForCurrentItems()` for the test assert loop.

// MARK: - Shared State

/// Internal queue state shared by both call-queue types.
private struct CallQueueState {
    var task: Task<(), Never>
    var calls: [@Sendable () -> Void]
    /// One-shot callbacks fired when the task goes idle (after all calls drain and yield).
    var onIdleCallbacks: [@Sendable () -> Void] = []
}

// MARK: - Drain loops

/// Drain loop for `MainCallQueue`. Runs on `@MainActor` until the queue is empty,
/// then cancels the task and fires idle callbacks.
@MainActor
private func mainCallQueueDrainLoop(state: LockIsolated<CallQueueState?>) async {
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

/// Task-based drain for `BackgroundCallQueue`.
///
/// Earlier iterations dispatched drains through `DispatchQueue.global(.userInitiated)`
/// to mask a heap-use-after-free in `AnyContext.onRemoval` — see commit a9e240b.
/// The actual race (cross-hierarchy `removeParent` not acquiring `self.lock`) is now
/// fixed at the source in `AnyContext.removeParent`/`addParent`, so the drain can go
/// back to a simple cooperative-pool Task.
///
/// Bonus: per-test `BackgroundCallQueue` drains no longer all compete for
/// `DispatchQueue.global(.userInitiated)`'s bounded kernel pool, removing a
/// shared-resource contention bottleneck under parallel test load.
private func backgroundCallQueueDrainLoop(state: LockIsolated<CallQueueState?>) async {
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

/// Schedules `body` to fire at the absolute monotonic deadline (or
/// immediately if the deadline is already in the past). Returns a
/// cancel handle; calling it before the deadline fires guarantees the
/// callback will not run. Idempotent — cancel after fire is a no-op.
///
/// Routed through `GlobalTickScheduler` on platforms that have
/// `Dispatch` so all test-infrastructure deadlines share one ticker.
/// Falls back to `Task.detached { Task.sleep }` on platforms without
/// Dispatch (WASI), where the cancel handle is a no-op.
///
/// **History**: a previous iteration of this code routed deadlines
/// through GTS but **discarded the cancel handle** — entries piled up
/// in `GTS.pending` until their original deadline elapsed, and an
/// observed ~3 % hang in x100 stress was attributed to that
/// accumulation pressure. The current implementation cancels the GTS
/// entry as soon as the wait resolves via any other path (idle
/// callback, cancellation), so `pending` only contains entries that
/// genuinely need their deadline to fire.
@discardableResult
func scheduleAfter(deadline: UInt64, _ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    #if canImport(Dispatch)
    return GlobalTickScheduler.shared.schedule(deadlineNs: deadline, callback: body)
    #else
    let cancelled = LockIsolated(false)
    Task.detached {
        let nowNs = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let delayNs = deadline > nowNs ? deadline - nowNs : 0
        try? await Task.sleep(nanoseconds: delayNs)
        if !cancelled.value { body() }
    }
    return { cancelled.setValue(true) }
    #endif
}

private func callQueueIsIdle(_ state: LockIsolated<CallQueueState?>) -> Bool {
    state.value == nil
}

private func callQueueWaitUntilIdle(_ state: LockIsolated<CallQueueState?>, deadline: UInt64 = .max) async {
    await callQueueWait(state: state, deadline: deadline) { s, callback in
        s.onIdleCallbacks.append(callback)
    }
}


private func callQueueWaitForCurrentItems(_ state: LockIsolated<CallQueueState?>, deadline: UInt64) async {
    await callQueueWait(state: state, deadline: deadline) { s, callback in
        s.calls.append(callback)
    }
}

/// Shared implementation of `waitUntilIdle` and `waitForCurrentItems`.
///
/// The two functions differ only in where they enqueue the resumption
/// callback inside `CallQueueState` — onIdleCallbacks (fires when the
/// queue drains to empty) vs `calls` (fires when its position in the
/// queue is reached). Everything else — the deadline-timer plumbing,
/// the cancellation-aware continuation, the at-most-once resolve race
/// against deadline / queue / cancel — is identical, and bug-fix-once
/// is easier than duplicate.
///
/// Resolution paths (whichever fires first wins; the others find
/// `resumed == true` and no-op):
///   • queue-side callback (registered via `appendCallback`)
///   • deadline timer (registered via GTS through `scheduleAfter`)
///   • Task cancellation (`onCancel` handler)
///
/// **Race window for `contSlot`**: must be assigned INSIDE the same
/// `state.withValue` critical section that appends the queue callback.
/// If set after releasing `state`'s lock, the drain could fire our
/// callback (which would see `contSlot == nil` and no-op) before we
/// set it — the continuation then leaks with no one to resume it.
/// Latent bug observable under heavy parallel load. Inside the lock,
/// the drain can't run our callback because it must take the same
/// lock to dequeue.
///
/// **Cancel-on-resolve**: when any path resolves, the GTS timer entry
/// is cancelled inside the same `resumed.withValue` block. This is
/// safe (no lock-ordering deadlock): GTS callbacks are invoked OUTSIDE
/// the GTS internal lock, and `GTS.cancel(id)` only briefly acquires
/// that lock to remove the entry — no thread acquires GTS's lock then
/// `resumed`'s. Without cancel-on-resolve, the GTS `pending` list
/// would accumulate stale entries up to each entry's original
/// deadline, which a previous migration attempt correlated with a ~3 %
/// hang under x100 stress.
private func callQueueWait(
    state: LockIsolated<CallQueueState?>,
    deadline: UInt64,
    appendCallback: @Sendable @escaping (inout CallQueueState, @escaping @Sendable () -> Void) -> Void
) async {
    let resumed = LockIsolated(false)
    let contSlot = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let timerCancel = LockIsolated<(@Sendable () -> Void)?>(nil)

    @Sendable func resolve() {
        let toResume: CheckedContinuation<Void, Never>? = resumed.withValue { r in
            guard !r else { return nil }
            r = true
            // Cancel the GTS timer entry now that we're resolving via
            // some other path; otherwise the entry lingers in
            // `GTS.pending` until its deadline fires.
            timerCancel.value?()
            timerCancel.setValue(nil)
            return contSlot.withValue { slot -> CheckedContinuation<Void, Never>? in
                let c = slot
                slot = nil
                return c
            }
        }
        toResume?.resume()
    }

    await withTaskCancellationHandler {
        await withCheckedContinuation { cont in
            let shouldResume = state.withValue { s -> Bool in
                if s != nil {
                    contSlot.setValue(cont)
                    appendCallback(&s!, resolve)
                    return false
                }
                return true
            }
            if shouldResume {
                cont.resume()
                return
            }
            if deadline < .max {
                let cancel = scheduleAfter(deadline: deadline, resolve)
                // Race-tolerant: if `resolve()` already fired between
                // schedule and now (deadline already past, or queue
                // callback / cancellation raced us), cancelling here is
                // a no-op. If not, storing the cancel handle lets
                // future `resolve()` calls release the entry.
                let stillNeedsHandle = resumed.withValue { r -> Bool in
                    if r {
                        return false
                    }
                    timerCancel.setValue(cancel)
                    return true
                }
                if !stillNeedsHandle {
                    cancel()
                }
            }
        }
    } onCancel: {
        resolve()
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
                    await mainCallQueueDrainLoop(state: self.state)
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

/// Delivers Observed pipeline updates on a detached cooperative-pool Task.
struct BackgroundCallQueue: @unchecked Sendable {
    private let state = LockIsolated<CallQueueState?>(nil)

    // MARK: Enqueue

    /// Enqueues `callback`. Starts a drain if the queue was idle.
    func callAsFunction(_ callback: @escaping @Sendable () -> Void) {
        state.withValue {
            if $0 == nil {
                $0 = CallQueueState(task: Task.detached(priority: .userInitiated) {
                    await backgroundCallQueueDrainLoop(state: self.state)
                }, calls: [callback])
            } else {
                $0!.calls.append(callback)
            }
        }
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

    /// Observe the next idle transition.
    ///
    /// If the queue is currently idle, `callback` fires **immediately** on
    /// the calling thread before this method returns. If the queue is
    /// currently busy, `callback` fires once when the drain finishes the
    /// last enqueued item and transitions to idle — the same firing point
    /// as `waitUntilIdle()`'s wake-up.
    ///
    /// **One-shot**: the callback fires at most once per `onIdle` call.
    /// Subsequent idle transitions are not delivered — re-register if you
    /// need to observe again.
    ///
    /// **Cancellation**: the returned closure cancels the registration.
    /// Idempotent: cancelling after the callback has fired (or after a
    /// previous cancel) is a no-op. Cancellation racing with firing is
    /// safe — the callback runs **at most once**.
    ///
    /// This is the building block `TestAccess.awaitSettled` uses to
    /// detect "all bg pipeline work has drained" without polling. It
    /// covers the case where a memoize `performUpdate` runs but is
    /// silent — no `didModify` fires (value unchanged via `isSame`), so
    /// the wait observer would not otherwise learn the work has
    /// completed.
    ///
    /// Thread-safety: callable from any thread.
    @discardableResult
    func onIdle(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let fired = LockIsolated(false)
        // Wrap so a late cancel can still no-op the firing, and a late
        // fire can't run twice.
        let wrapped: @Sendable () -> Void = {
            let shouldFire = fired.withValue { f -> Bool in
                guard !f else { return false }
                f = true
                return true
            }
            if shouldFire { callback() }
        }

        let fireImmediately = state.withValue { s -> Bool in
            if s == nil { return true }
            s!.onIdleCallbacks.append(wrapped)
            return false
        }
        if fireImmediately {
            wrapped()
            // Cancel is a no-op — already fired.
            return {}
        }
        // Cancel: flip `fired` so the queued wrapper sees it and no-ops
        // when the drain finally fires onIdleCallbacks. The wrapper
        // closure remains in `onIdleCallbacks` until the drain consumes
        // it on the next idle transition — acceptable; idle transitions
        // happen frequently in active tests.
        return {
            fired.withValue { $0 = true }
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
        // Drain pending main-thread observation work. Non-Apple platforms never enqueue to
        // `mainCallQueue` (every context has `useMainThreadObservation == false`), so the
        // drain is pure overhead there — skip it. `drainIfOnMain` is otherwise a no-op when
        // off the main thread or when the queue is empty, but eliding the call eliminates a
        // redundant `Thread.isMainThread` syscall on Linux/Android/WASM.
        #if canImport(Darwin)
        mainCallQueue.drainIfOnMain()
        #endif
    }
    return try body()
}
