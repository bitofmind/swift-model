import Foundation
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(Synchronization)
import Synchronization
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

/// Process-wide executor-activity snapshot across ALL per-test drain executors,
/// used by `expect`'s GLOBAL-quiescence fail-gate. `(0, 0)` where unavailable.
func _DrainTestExecutorGlobalSnapshot() -> (outstanding: Int, sinceActivityNs: UInt64) {
    #if canImport(Dispatch)
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
        return _DrainTestExecutor._globalSnapshot()
    }
    #endif
    return (0, 0)
}

@inline(__always) func _drainMonotonicNs() -> UInt64 {
    #if canImport(Dispatch)
    return DispatchTime.now().uptimeNanoseconds
    #else
    return UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    #endif
}

/// Build a fresh per-test executor box, or `nil` where custom task executors
/// aren't available — those keep the wall-clock wait path.
///
/// Under `.modelTesting`, the wait verbs (`settle`/`expect`/`waitUntil`) resolve
/// on a non-starvable executor-drain fixpoint instead of a wall-clock budget.
/// This is **unconditional** wherever it can run — macOS 15+ / iOS 18+ /
/// Linux-Swift-6 (custom `TaskExecutor` needs the Swift 6 runtime). There is no
/// opt-out: the drive is the validated default, not an experiment.
///
/// The wall-clock path is NOT a toggle — it survives only as the automatic
/// fallback for test HOSTS that can't run the drive: pre-macOS-15 / pre-iOS-18
/// (e.g. an older simulator), older Swift on Linux, and WASM (no `Dispatch` at
/// all). The `#available` / `#if canImport(Dispatch)` checks select it; nothing
/// else does. (To compare the two paths, check out the pre-removal history — the
/// `SWIFT_MODEL_EXPERIMENTAL_DRAIN` env var and the `drain=0` CI rows lived there.)
func _makeTestExecutorBox() -> (any Sendable)? {
    #if canImport(Dispatch)
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
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
    /// Birth time — the floor for `activityNs` so a test that hasn't yet
    /// enqueued any executor work reads "active as of now", not the epoch. (The
    /// raw timestamps below start at 0; `monotonicNs` is a large uptime value,
    /// so without this floor the inactivity watchdog would see `0 + window` as
    /// already elapsed and trip instantly.)
    private let _birthNs: UInt64 = _drainMonotonicNs()
    private var _lastEnqueueNs: UInt64 = 0
    private var _lastCompletionNs: UInt64 = 0
    /// Closures that fire (at most once each) when `outstanding` hits 0.
    private var idleWaiters: [(id: UInt64, fire: @Sendable () -> Void)] = []
    private var nextWaiterId: UInt64 = 0

    // Process-wide executor activity across ALL per-test drain executors. Powers
    // `expect`'s GLOBAL-quiescence fail-gate: a still-unmet `expect` is failed
    // only when the WHOLE process is quiescent (no ready job in any test + no
    // global activity for the grace), not merely when this one test looks idle —
    // so a premature per-test fixpoint (e.g. a child parked mid-`clock.sleep`
    // while the run is busy) defers the fail until the work actually finishes.
    // Lock-free (relaxed atomics): this is bumped on every executor enqueue and
    // completion across all parallel tests, so it must not contend. The two
    // loads in `_globalSnapshot` need not be a consistent pair — the gate is a
    // heuristic guarded by a grace window, not a linearizable invariant.
    static let _globalOutstanding = Atomic<Int>(0)
    static let _globalLastActivityNs = Atomic<UInt64>(0)
    static func _globalSnapshot() -> (outstanding: Int, sinceActivityNs: UInt64) {
        let now = _drainMonotonicNs()
        let last = _globalLastActivityNs.load(ordering: .relaxed)
        // Floor `last` at (now − 1000 s) so a never-yet-active global counter
        // (last == 0) reads as a large-but-bounded idle span instead of the whole
        // monotonic uptime. NOTE: this expression CAPS `sinceActivityNs` at the
        // lookback constant, so the constant must stay far above every grace
        // window (`_expectGraceNs` is 2 s × scale) — a smaller "tidier" value
        // like 1 s silently closes the global fail-gate forever (fails then only
        // surface via the 120 s watchdog / test budgets; the deliberate-timeout
        // meta-tests go from ~2 s to end-of-run).
        return (_globalOutstanding.load(ordering: .relaxed), now &- max(last, now &- 1_000_000_000_000))
    }

    /// Monotonic-ns of the most recent `enqueue`. A task suspended mid-`await`
    /// (e.g. on a clock) re-enqueues when it resumes, bumping this — so the drive
    /// can require executor-idle to *persist* for a debounce window since the
    /// last enqueue, bridging the suspend→resume gap that an instantaneous idle
    /// check slips through (premature fixpoint).
    var lastEnqueueNs: UInt64 { lock.withLock { _lastEnqueueNs } }

    /// Per-test "is this test making progress?" signal for the trait-cap
    /// inactivity watchdog (`_parkUntilInactiveOrCancel`). Returns `now` while
    /// any job is running/ready (the test is actively working), otherwise the
    /// most recent enqueue/completion timestamp. The watchdog resets its window
    /// on every advance, so a healthy-but-slow test under full-parallel load —
    /// whose jobs queue behind hundreds on the shared drain queue but keep
    /// draining — never trips; only a test with NO executor activity for the
    /// full window (a genuine deadlock/runaway with a stalled executor) does.
    /// This is per-test isolated (each test owns its `_DrainTestExecutor`), so
    /// unlike a process-global signal it still catches a single hung test while
    /// the rest of the suite is busy.
    var activityNs: UInt64 {
        lock.withLock {
            outstanding > 0 ? _drainMonotonicNs() : max(_birthNs, max(_lastEnqueueNs, _lastCompletionNs))
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.withLock { outstanding += 1; _lastEnqueueNs = _drainMonotonicNs() }
        Self._globalOutstanding.wrappingAdd(1, ordering: .relaxed)
        Self._globalLastActivityNs.store(_drainMonotonicNs(), ordering: .relaxed)
        _sharedDrainQueue.async {
            unowned.runSynchronously(on: self.asUnownedTaskExecutor())
            let toFire: [@Sendable () -> Void] = self.lock.withLock {
                self.outstanding -= 1
                self._lastCompletionNs = _drainMonotonicNs()
                guard self.outstanding == 0 else { return [] }
                let fns = self.idleWaiters.map(\.fire)
                self.idleWaiters.removeAll()
                return fns
            }
            Self._globalOutstanding.wrappingSubtract(1, ordering: .relaxed)
            Self._globalLastActivityNs.store(_drainMonotonicNs(), ordering: .relaxed)
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
            // The per-test main-registrar observation queue. Off-main model
            // writes deliver `withObservationTracking` / `Observed` / `onChange`
            // notifications by enqueueing the main registrar's willSet/didSet on
            // `context.mainCallQueue`, which drains on the shared `@MainActor`.
            // This is the queue earlier iterations EXCLUDED (Update 9) — but that
            // conflated it with the process-global `mainCall` global; the
            // observation-delivery queue is actually PER-CONTEXT (root context
            // owns it, children inherit), so the drive can safely wait on it: the
            // shared main thread always drains this test's items in finite time,
            // so the wait is bounded by the watchdog, never an inter-test hang.
            // Including it closes the observation-delivery gap that false-failed
            // onChange/Observed/event `expect`s under parallel load — the
            // satisfying consumer write was merely pending on this queue past the
            // grace (the dominant residual item-2 race). See
            // docs/test-determinism-executor-drain.md (Update 12).
            let main = self.context.mainCallQueue
            // Quiescence = executor idle AND bg idle AND main-observation idle AND
            // no task pending its first run AND NO ACTIVITY OF ANY KIND for a
            // `graceNs` grace window. The grace debounces against the most recent
            // of (a) any `_noteActivity` — model write / event / probe /
            // task-body-start — and (b) any executor enqueue. So ANY activity (a
            // clock-parked task resuming and writing, an enqueue, an event,
            // an onChange consumer firing off the main drain) resets the window:
            // on a single test the system is quiet at once and the grace elapses
            // fast; under stress every resuming task keeps resetting it, so the
            // wait lasts as long as necessary and only declares quiescence once
            // the system is genuinely done. NON-STARVABLE throughout (counter +
            // GTS, never `.background`).
            while !Task.isCancelled {
                if _drainMonotonicNs() >= hangDeadlineNs { return false }
                await exec.waitUntilIdleOrDeadline(hangDeadlineNs)
                if !bg.isIdle { await bg.waitForCurrentItems(deadline: hangDeadlineNs) }
                if !main.isIdle { await main.waitForCurrentItems(deadline: hangDeadlineNs) }
                let idleNow = exec.isExecutorIdle && bg.isIdle && main.isIdle && !self.context.hasPendingStartTask
                if idleNow {
                    let lastActivity = max(self._lastActivityNsLocked, exec.lastEnqueueNs)
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
    /// slightly early settle just means the next line re-settles), so it uses a
    /// short grace. Tunable knob.
    static var _settleGraceNs: UInt64 { 30_000_000 }   // 30 ms

    /// **`expect` inactivity-fail window (option A — see Update 12/13).** `expect`
    /// NEVER self-fails at a mere fixpoint sample: a predicate that becomes true
    /// resolves *reactively and instantly* via `_noteActivity` (`.passed`), never
    /// via the drive. The drive's fixpoint only governs the FAIL path, and Update
    /// 8's theorem says no finite single-sample grace can distinguish "quiescent,
    /// never true" from "quiescent, a delayed resume is about to land." So instead
    /// of failing at the first 250 ms-quiet sample (which false-failed
    /// event/onChange/transition `expect`s whose satisfying work landed just after
    /// — the dominant residual), `expect` fails only after a *sustained* window of
    /// genuine inactivity: every `_noteActivity` / executor enqueue / queue drain
    /// resets it (the drive loops), so under contention the fail simply DEFERS
    /// until the model is truly quiet — no false fail. The window only bounds how
    /// fast a genuinely-wrong assertion surfaces when a human runs one test
    /// (the model goes quiet at once → fail in ~one window). 2 s default keeps
    /// that interactive fail reasonably fast while being robust to realistic
    /// resume delays; scaled by `timeoutScale` so CI gets proportionally more
    /// slack. (The deadlock watchdog, `_executorHangDeadlineNs`, remains the
    /// last-resort cap for a model that never goes quiet at all.)
    static var _expectGraceNs: UInt64 {
        UInt64(2_000_000_000 * ModelTestingTraitOptions.timeoutScale)
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
            let grace = Self._expectGraceNs
            return Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    let reached = await self._driveToStableFixpoint(hangDeadlineNs: hang, graceNs: grace)
                    // CRITICAL: bail the instant this driver is cancelled, BEFORE
                    // touching the shared `_pendingExpects`. `expect()` cancels its
                    // driver the moment its own `awaitPredicate` resolves; the very
                    // next sequential `expect` then registers a fresh predicate into
                    // the SAME per-test `_pendingExpects`. If this just-cancelled
                    // driver were to run `_resolveUnmetPredicatesAtFixpoint` on its
                    // way out, it would spuriously fail that next predicate as
                    // `.timeout` before its satisfying write/event arrived — a
                    // fast, window-independent false failure (the dominant
                    // executor-drive residual: lost last element of an accumulated
                    // Observed/onChange sequence). `_driveToStableFixpoint` returns
                    // `false` on BOTH cancellation and the hang watchdog, so gate on
                    // `Task.isCancelled` specifically.
                    if Task.isCancelled { break }
                    self._noteActivity()                      // resolve now-true predicates as .passed
                    // GLOBAL-quiescence gate on the FAIL (not per-test): only commit
                    // a fail when the WHOLE process is quiescent — no ready job in ANY
                    // parallel test's executor, and no global activity for `grace`.
                    // Rationale (trace-confirmed): the premature-fixpoint false-fails
                    // fire while THIS test looks idle (a child parked mid-`clock.sleep`
                    // is not a ready job) but the global system is still BUSY and the
                    // child is about to resume + write. Deferring the fail until a
                    // genuine global lull lets that work finish → the predicate passes
                    // reactively → no false fail. Under continuous parallel load the
                    // fail defers until the run winds down (slow-but-correct, the
                    // intended behaviour); serially/interactively the global system is
                    // quiet at once, so a genuinely-broken expect still fails promptly.
                    // settle() is unaffected — it uses `_driveToStableFixpoint`
                    // directly (per-test quiescence), not this driver.
                    let g = _DrainTestExecutorGlobalSnapshot()
                    let globalQuiescent = g.outstanding == 0 && g.sinceActivityNs >= grace
                    if globalQuiescent {
                        self._resolveUnmetPredicatesAtFixpoint()  // fail still-unmet predicates
                        if !reached { break }                     // watchdog tripped (deadlock)
                        await Task.yield()
                    } else {
                        // Per-test quiescent but the global system is busy — defer the
                        // fail and re-check soon (cheap poll; non-starvable GTS sleep).
                        if !reached { break }
                        await self._gtsSleep(min(grace, 50_000_000), hangDeadlineNs: hang)
                    }
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
            // Re-check cancellation INSIDE the lock. `expect()` cancels its
            // driver before returning, and the test's *next* `expect` registers
            // its predicate into `_pendingExpects` under this same lock — so if
            // a fresh predicate is visible here, the cancel that preceded its
            // registration is visible too (lock acquire orders both). The loop
            // head's `Task.isCancelled` gate alone leaves a window where a stale
            // driver, already past that check (e.g. its own `_noteActivity`
            // resolved the current expect, which triggered the cancel), would
            // fail the next predicate as `.timeout`.
            guard !Task.isCancelled else { return }
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
        return await _driveToStableFixpoint(hangDeadlineNs: _executorHangDeadlineNs(), graceNs: Self._expectGraceNs)
    }
}
