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
    func _driveToStableFixpoint(hangDeadlineNs: UInt64) async -> Bool {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           let exec = _TestExecutorBox.current as? _DrainTestExecutor {
            let bg = backgroundCall
            // Short, NON-STARVABLE debounce that the fixpoint must persist for —
            // bridges the suspend→resume gap of a task parked on a clock/await
            // (it re-enqueues on resume, bumping `lastEnqueueNs`, resetting this
            // window). Confirmed via GTS, never `.background` QoS, so it doesn't
            // starve under load. Tunable knob (runtime vs robustness).
            let debounceNs: UInt64 = 25_000_000   // 25 ms
            while !Task.isCancelled {
                let now = _drainMonotonicNs()
                if now >= hangDeadlineNs { return false }
                await exec.waitUntilIdleOrDeadline(hangDeadlineNs)
                if !bg.isIdle { await bg.waitForCurrentItems(deadline: hangDeadlineNs) }
                // NOTE: `mainCall` is PROCESS-GLOBAL (not per-test) — gating on it
                // would make a test's drive wait on every OTHER parallel test's
                // main-queue work (never idle → hang). Per-test signals only: the
                // executor (per-test) and `bg` (per-test task-local). Headless
                // `.modelTesting` model work doesn't hop the MainActor queue.
                let idleNow = exec.isExecutorIdle && bg.isIdle && !self.context.hasPendingStartTask
                if idleNow {
                    let sinceEnqueue = _drainMonotonicNs() &- exec.lastEnqueueNs
                    if sinceEnqueue >= debounceNs {
                        return true   // idle, and quiet for a full debounce since the last enqueue
                    }
                    // Idle but a recent enqueue — wait out the remainder of the
                    // window (non-starvable), then re-check; a resuming task will
                    // have re-enqueued and reset it by then.
                    await _gtsSleep(debounceNs &- sinceEnqueue, hangDeadlineNs: hangDeadlineNs)
                }
            }
            return false
        }
        #endif
        return true
    }

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

    /// `expect`'s driver: on each stable fixpoint, resolve the reactive predicate
    /// (`_noteActivity` → pass if now true) and then fail any still-unmet
    /// predicate (`_resolveUnmetPredicatesAtFixpoint` → `.timeout`). Loops to
    /// cover the registration race (the driver starts before `awaitPredicate`
    /// registers) and to re-confirm; `expect` cancels it once the wait resolves.
    func _startExecutorDrive() -> Task<Void, Never>? {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           _TestExecutorBox.current is _DrainTestExecutor {
            let hang = _executorHangDeadlineNs()
            return Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let reached = await self._driveToStableFixpoint(hangDeadlineNs: hang)
                    self._noteActivity()   // resolve now-true predicates as .passed
                    // RE-CONFIRM before failing: a `loaded`-style write may still
                    // be propagating to the predicate evaluator under parallel
                    // load. Drive to a SECOND stable fixpoint (gives a racing
                    // write a debounce window to land + fire `_noteActivity`); only
                    // a predicate STILL unmet after that is a genuine failure.
                    let reached2 = await self._driveToStableFixpoint(hangDeadlineNs: hang)
                    self._noteActivity()
                    self._resolveUnmetPredicatesAtFixpoint()  // fail still-unmet predicates
                    if !reached || !reached2 { break }        // watchdog tripped (deadlock)
                    await Task.yield()
                }
            }
        }
        #endif
        return nil
    }

    /// Resolve every pending `.predicate` (`expect`) wait as `.timeout` — the
    /// model is quiescent with the predicate still unmet, so it will not become
    /// true. Settle/quiet-window entries are left to their own resolution.
    func _resolveUnmetPredicatesAtFixpoint() {
        var wakes: [CheckedContinuation<PredicateOutcome, Never>] = []
        lock {
            for i in (0..<_pendingExpects.count).reversed() {
                let pending = _pendingExpects[i]
                if case .predicate = pending.mode {
                    pending.cancelAllHandles()
                    wakes.append(pending.continuation)
                    _pendingExpects.remove(at: i)
                }
            }
        }
        for cont in wakes { cont.resume(returning: .timeout) }
    }

    /// Implementation of the erased `ModelAccess` hook (the `override` itself
    /// must live in the class body — Swift forbids overriding in an extension).
    func _driveToStableFixpointErasedImpl() async -> Bool {
        guard _isExecutorDriveActive else { return true }
        return await _driveToStableFixpoint(hangDeadlineNs: _executorHangDeadlineNs())
    }
}
