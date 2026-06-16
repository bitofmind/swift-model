import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

// MARK: - EXPERIMENTAL: executor-drain quiescence wiring
//
// First real-code step of the "drive-to-completion instead of wait-and-infer"
// rethink (see docs/test-determinism-executor-drain.md). Under `.modelTesting`,
// model-spawned tasks (`Cancellables`) run on a per-test harness executor, and
// the wait verbs (`expect`/`settle`) drive that executor to a logical fixpoint
// concurrently with the existing reactive wait. This is ADDITIVE: it can only
// make a passing test resolve sooner and load-independently; it never changes
// failure reporting or transient-state semantics (model writes still wake the
// reactive evaluator as they happen). The wall-clock path remains as fallback.

/// Holds the per-test harness executor for the duration of a `.modelTesting`
/// body, as a task-local so the spawn path and the wait verbs can find it.
/// Typed `(any Sendable)?` so the declaration compiles where `TaskExecutor` is
/// unavailable (macOS < 15, WASM); readers downcast under `if #available`.
enum _TestExecutorBox {
    @TaskLocal static var current: (any Sendable)?
}

/// Build a fresh per-test executor box, or `nil` where custom task executors
/// aren't available. Called once per `.modelTesting` scope.
///
/// **Opt-in (`SWIFT_MODEL_EXPERIMENTAL_DRAIN=1`).** This wiring is INERT by
/// default — returning `nil` makes the spawn path and the wait verbs behave
/// exactly as before. A naive single-serial-queue executor *deadlocks* real
/// model settle/teardown (model context locks + the off-executor bg pump +
/// `@MainActor` hops do not compose with one serial queue), so it must not be
/// on by default. Enabling the flag is for experimenting with the next design
/// iteration (a counted concurrent executor whose fixpoint unions the bg /
/// MainActor queues). See docs/test-determinism-executor-drain.md §6.
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
/// A harness-owned `TaskExecutor` that runs model tasks on a **concurrent**
/// queue and counts ready-but-not-finished jobs, so a drain to a *logical*
/// fixpoint (no ready work) can stand in for wall-clock quiescence —
/// load-independent by construction. See the design note and
/// `SpikeDrainExecutorTests`.
///
/// **Concurrent, not serial.** A single serial queue deadlocks real model work:
/// a task that contends on a model context lock, or awaits a peer effect, would
/// head-of-line-block the one thread while the work it needs sits behind it in
/// the same queue. A concurrent queue lets independent model tasks make progress
/// on separate threads; the `outstanding` counter + a `.barrier` hop still give
/// a precise "no ready jobs" signal.
/// ONE process-wide concurrent queue backs every per-test executor. Per-test
/// instances each created their own `.concurrent` queue, which under full
/// PARALLEL test execution (dozens of suites at once, each with its own
/// executor) exploded GCD's worker-thread pool — executors couldn't get threads,
/// tasks stalled, and `settle` timed out everywhere. A single shared concurrent
/// queue bounds total threads (GCD manages the pool); each executor keeps its
/// OWN `outstanding` counter, so per-test quiescence detection is unaffected.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private let _sharedDrainQueue = DispatchQueue(label: "swift-model.test-drain.shared", attributes: .concurrent)

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class _DrainTestExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.withLock { outstanding += 1 }
        _sharedDrainQueue.async {
            unowned.runSynchronously(on: self.asUnownedTaskExecutor())
            let waiters: [CheckedContinuation<Void, Never>] = self.lock.withLock {
                self.outstanding -= 1
                guard self.outstanding == 0 else { return [] }
                let w = self.idleWaiters
                self.idleWaiters.removeAll()
                return w
            }
            for w in waiters { w.resume() }
        }
    }

    /// No executor job is ready/running this instant.
    var isExecutorIdle: Bool { lock.withLock { outstanding == 0 } }

    /// Suspend until no executor job is ready (`outstanding == 0`); resume
    /// immediately if already idle. **Event-driven via the counter — never a
    /// `.barrier`.** A `.barrier` on a concurrent queue is a read-WRITE barrier
    /// that blocks all other jobs while pending, so polling with one throttles
    /// the very model work we're waiting on (that hung iteration 2). The counter
    /// is decremented when a job returns (completes or suspends), so reaching 0
    /// means no ready work without blocking anything. Cancellation-aware so the
    /// driver unwinds promptly when the wait it serves resolves (e.g. on a
    /// runaway, where 0 is never reached).
    func waitUntilIdle() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if outstanding == 0 { return true }
                    idleWaiters.append(c)
                    return false
                }
                if resumeNow { c.resume() }
            }
        } onCancel: {
            let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
                let w = idleWaiters
                idleWaiters.removeAll()
                return w
            }
            for w in waiters { w.resume() }
        }
    }
}
#endif

extension TestAccess {
    /// True when a per-test harness executor is installed (flag on, macOS 15+).
    /// `expect` uses this to know the fixpoint drive — not the wall clock — is
    /// the resolution authority, so it arms only a generous hang-catcher deadline.
    var _isExecutorDriveActive: Bool {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            return _TestExecutorBox.current is _DrainTestExecutor
        }
        #endif
        return false
    }

    /// **Fixpoint-PRIMARY resolution for `expect`.** When a per-test executor is
    /// active, this driver makes the *fixpoint* — not a wall-clock budget — decide
    /// an `expect`'s outcome:
    ///   • target met → the reactive `_noteActivity` path resolves it `.passed`
    ///     (the instant it's true — transients still caught);
    ///   • model reaches a fixpoint with the target still unmet →
    ///     `_resolveUnmetPredicatesAtFixpoint` resolves it `.timeout` (= fail),
    ///     which under no load is milliseconds (fast feedback) and under load is
    ///     "as long as necessary" (never a false fire).
    ///
    /// The fixpoint is the UNION of every place model-affecting work can live: the
    /// executor's ready jobs, the per-test `BackgroundCallQueue` (Observed/memoize
    /// pump), the `@MainActor` `MainCallQueue`, and any task registered but not yet
    /// started (`hasPendingStartTask`). We do NOT `break` on first fixpoint: the
    /// driver is started before `awaitPredicate` registers its entry, so we keep
    /// re-confirming the fixpoint and resolving until the wait is gone (then
    /// `expect` cancels us). `waitUntilIdle` is event-driven, so this only spins
    /// in the sub-µs registration window, never while real work is in flight.
    ///
    /// Returns the driver `Task` (cancel once the wait resolves) or `nil`.
    func _startExecutorDrive() -> Task<Void, Never>? {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           let exec = _TestExecutorBox.current as? _DrainTestExecutor {
            return Task { [weak self] in
                guard let self else { return }
                let bg = backgroundCall   // task-local per-test queue (inherited)
                while !Task.isCancelled {
                    await exec.waitUntilIdle()
                    if !bg.isIdle { await bg.waitForCurrentItems(deadline: .max) }
                    let atFixpoint = exec.isExecutorIdle
                        && bg.isIdle
                        && mainCall.isIdle
                        && !self.context.hasPendingStartTask
                    if atFixpoint {
                        self._noteActivity()                      // resolve now-true predicates as .passed
                        self._resolveUnmetPredicatesAtFixpoint()  // resolve still-unmet predicates as .timeout (fail)
                        await Task.yield()                        // re-confirm (registration race / late re-enqueue)
                    }
                }
            }
        }
        #endif
        return nil
    }

    /// Resolve every pending `.predicate` (`expect`) wait as `.timeout` because
    /// the model has reached a fixpoint with the predicate still false — i.e. it
    /// will not become true, so this is a genuine assertion failure, surfaced
    /// immediately rather than after a wall-clock budget. Settle/quiet-window
    /// (`.settled`/`.debounce`) entries are left alone — they have their own
    /// resolution. Continuations are resumed OUTSIDE the lock.
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
}
