import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

// MARK: - Executor-drain quiescence (primary resolution for expect/settle/waitUntil)
//
// The durable fix for `.modelTesting` load-flakiness (see
// docs/test-determinism-executor-drain.md). Under `.modelTesting`, model tasks
// run on a per-test harness executor; the wait verbs resolve on the EXECUTOR
// DRAIN FIXPOINT — a load-independent, non-starvable "the model is quiescent"
// signal — rather than a wall-clock budget or a `.background`-QoS quiet-check
// (which macOS starves under parallel load — the disease this replaces).
//
// Semantics (the contract):
//   • pass the instant the target is met (reactive `_noteActivity`, as before);
//   • for `expect`/`waitUntil`: fail the instant the model is QUIESCENT with the
//     target still unmet (fast interactively; "as long as necessary" under load);
//   • `settle`: succeed when quiescent;
//   • the wall clock is only a generous deadlock watchdog (`_executorHangNs`).
//
// "Quiescent" = a STABLE fixpoint: executor has no ready jobs AND bg pump idle
// AND MainActor queue idle AND no task pending its first run — observed across
// two consecutive checks (a task suspended mid-`await` re-enqueues between
// checks, so a single idle instant is not trusted; this 2-consecutive gate is
// what iteration 3 proved prevents premature fixpoints).

/// Per-test harness executor box (task-local), set by the `.modelTesting` scope.
/// `(any Sendable)?` so the declaration compiles where `TaskExecutor` is
/// unavailable (macOS < 15, WASM); readers downcast under `if #available`.
enum _TestExecutorBox {
    @TaskLocal static var current: (any Sendable)?
}

/// Generous deadlock watchdog: how long a wait will drive toward a fixpoint
/// before giving up and reporting (a true deadlock / runaway never reaches a
/// fixpoint). NOT a per-wait budget — a healthy wait resolves at its fixpoint
/// long before this. **Tunable knob** (maintainer judgment): large enough to
/// never fire on a healthy wait under heavy parallel load; small enough that an
/// interactive deadlock surfaces in reasonable time.
func _executorHangDeadlineNs() -> UInt64 {
    _drainMonotonicNs() &+ 120_000_000_000   // 120 s
}

private final class _GTSSleepState: @unchecked Sendable {
    var cont: CheckedContinuation<Void, Never>?
    var cancel: (@Sendable () -> Void)?
    var done = false
}

@inline(__always) func _drainMonotonicNs() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

/// Build a fresh per-test executor box, or `nil` where custom task executors
/// aren't available. Opt-in via `SWIFT_MODEL_EXPERIMENTAL_DRAIN=1` while the
/// approach is validated; inert otherwise (every wait keeps its current path).
func _makeTestExecutorBox() -> (any Sendable)? {
    #if canImport(Dispatch)
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
       ProcessInfo.processInfo.environment["SWIFT_MODEL_EXPERIMENTAL_DRAIN"] == "1" {
        return _DrainTestExecutor()
    }
    #endif
    return nil
}

#if canImport(Dispatch)
/// ONE process-wide concurrent queue backs every per-test executor — a per-test
/// `.concurrent` queue would explode GCD's worker pool under full-parallel test
/// runs. Each executor keeps its own `outstanding` counter, so per-test
/// quiescence detection stays isolated.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private let _sharedDrainQueue = DispatchQueue(label: "swift-model.test-drain.shared", attributes: .concurrent)

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class _DrainTestExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var _lastEnqueueNs: UInt64 = 0
    /// Closures that fire (at most once each) when `outstanding` hits 0.
    private var idleWaiters: [(id: UInt64, fire: @Sendable () -> Void)] = []
    private var nextWaiterId: UInt64 = 0

    /// Monotonic-ns of the most recent `enqueue`. A task suspended mid-`await`
    /// (e.g. on a clock) re-enqueues when it resumes, bumping this — so the drive
    /// can require executor-idle to *persist* for a debounce window since the
    /// last enqueue, bridging the suspend→resume gap that an instantaneous idle
    /// check slips through (premature fixpoint).
    var lastEnqueueNs: UInt64 { lock.withLock { _lastEnqueueNs } }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.withLock { outstanding += 1; _lastEnqueueNs = _drainMonotonicNs() }
        _sharedDrainQueue.async {
            unowned.runSynchronously(on: self.asUnownedTaskExecutor())
            let toFire: [@Sendable () -> Void] = self.lock.withLock {
                self.outstanding -= 1
                guard self.outstanding == 0 else { return [] }
                let fns = self.idleWaiters.map(\.fire)
                self.idleWaiters.removeAll()
                return fns
            }
            for f in toFire { f() }
        }
    }

    /// No executor job is ready/running this instant.
    var isExecutorIdle: Bool { lock.withLock { outstanding == 0 } }

    /// Suspend until `outstanding == 0` (event-driven — fired from `enqueue`'s
    /// completion, non-starvable, no QoS dependency), OR the GTS `deadlineNs`
    /// fires (the deadlock watchdog — `.userInitiated`, also non-starvable), OR
    /// the Task is cancelled. At-most-once resolution across all three.
    func waitUntilIdleOrDeadline(_ deadlineNs: UInt64) async {
        final class State: @unchecked Sendable {
            var cont: CheckedContinuation<Void, Never>?
            var timerCancel: (@Sendable () -> Void)?
            var resumed = false
        }
        let state = State()
        let id = lock.withLock { () -> UInt64 in nextWaiterId += 1; return nextWaiterId }

        let resolve: @Sendable () -> Void = { [self] in
            let cont: CheckedContinuation<Void, Never>? = lock.withLock {
                guard !state.resumed else { return nil }
                state.resumed = true
                state.timerCancel?()
                state.timerCancel = nil
                idleWaiters.removeAll { $0.id == id }
                let c = state.cont
                state.cont = nil
                return c
            }
            cont?.resume()
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let immediate: Bool = lock.withLock {
                    if Task.isCancelled || outstanding == 0 { state.resumed = true; return true }
                    state.cont = c
                    idleWaiters.append((id, { resolve() }))
                    return false
                }
                if immediate { c.resume(); return }
                let cancel = scheduleAfter(deadline: deadlineNs) { resolve() }
                let stale = lock.withLock { () -> Bool in
                    if state.resumed { return true }
                    state.timerCancel = cancel
                    return false
                }
                if stale { cancel() }
            }
        } onCancel: {
            resolve()
        }
    }
}
#endif

extension TestAccess {
    /// True when a per-test harness executor is installed (flag on, macOS 15+).
    var _isExecutorDriveActive: Bool {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            return _TestExecutorBox.current is _DrainTestExecutor
        }
        #endif
        return false
    }

    /// Drive the model to a STABLE fixpoint (quiescent across two consecutive
    /// checks). Returns `true` at the fixpoint, `false` if the deadlock watchdog
    /// (`hangDeadlineNs`) fires or the Task is cancelled. No executor → `true`
    /// (callers gate on `_isExecutorDriveActive`).
    func _driveToStableFixpoint(hangDeadlineNs: UInt64, graceNs: UInt64) async -> Bool {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           let exec = _TestExecutorBox.current as? _DrainTestExecutor {
            let bg = backgroundCall
            // Quiescence = executor idle AND bg idle AND no task pending its first
            // run AND NO ACTIVITY OF ANY KIND for a `graceNs` grace window. The
            // grace debounces against the most recent of (a) any `_noteActivity`
            // — model write / event / probe / task-body-start — and (b) any
            // executor enqueue. So ANY activity (a clock-parked task resuming and
            // writing, an enqueue, an event) resets the window: on a single test
            // the system is quiet at once and the grace elapses fast; under stress
            // every resuming task keeps resetting it, so the wait lasts as long as
            // necessary and only declares quiescence once the system is genuinely
            // done. NON-STARVABLE throughout (counter + GTS, never `.background`).
            // `mainCall` is excluded — it's process-global, not per-test.
            while !Task.isCancelled {
                if _drainMonotonicNs() >= hangDeadlineNs { return false }
                await exec.waitUntilIdleOrDeadline(hangDeadlineNs)
                if !bg.isIdle { await bg.waitForCurrentItems(deadline: hangDeadlineNs) }
                let idleNow = exec.isExecutorIdle && bg.isIdle && !self.context.hasPendingStartTask
                if idleNow {
                    let lastActivity = max(self._lastActivityNs, exec.lastEnqueueNs)
                    let sinceActivity = _drainMonotonicNs() &- lastActivity
                    if sinceActivity >= graceNs {
                        return true   // idle, and no activity of any kind for a full grace window
                    }
                    // Idle but recent activity — wait out the remainder of the
                    // grace (non-starvable), then re-check; a resuming task will
                    // have produced fresh activity and reset it by then.
                    await _gtsSleep(graceNs &- sinceActivity, hangDeadlineNs: hangDeadlineNs)
                }
            }
            return false
        }
        #endif
        return true
    }

    /// Grace window for `settle`'s fixpoint debounce. `settle` is forgiving (a
    /// slightly early settle just means the next line re-settles), so a short
    /// grace suffices. Tunable knob (runtime vs robustness).
    static var _settleGraceNs: UInt64 { 30_000_000 }   // 30 ms

    /// Non-starvable sleep for `ns` (or until `hangDeadlineNs`), via GTS — used
    /// by the drive's debounce. Cancellation-aware.
    func _gtsSleep(_ ns: UInt64, hangDeadlineNs: UInt64) async {
        #if canImport(Dispatch)
        let target = min(_drainMonotonicNs() &+ ns, hangDeadlineNs)
        let s = _GTSSleepState(); let lk = NSLock()
        let fire: @Sendable () -> Void = {
            let c: CheckedContinuation<Void, Never>? = lk.withLock {
                guard !s.done else { return nil }
                s.done = true; s.cancel?(); s.cancel = nil
                let c = s.cont; s.cont = nil; return c
            }
            c?.resume()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let immediate = lk.withLock { () -> Bool in
                    if Task.isCancelled || s.done { return true }
                    s.cont = c; return false
                }
                if immediate { c.resume(); return }
                let cancel = scheduleAfter(deadline: target) { fire() }
                let stale = lk.withLock { () -> Bool in if s.done { return true }; s.cancel = cancel; return false }
                if stale { cancel() }
            }
        } onCancel: { fire() }
        #endif
    }
}
