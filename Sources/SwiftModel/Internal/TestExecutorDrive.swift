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
    /// If a per-test harness executor is active, start a background driver that
    /// drives model work to a fixpoint and then nudges a final predicate
    /// re-evaluation (`_noteActivity`).
    ///
    /// The fixpoint is the UNION of every place model-affecting work can live:
    /// the executor's ready jobs, the per-test `BackgroundCallQueue` (Observed /
    /// memoize pump), the `@MainActor` `MainCallQueue`, and any task registered
    /// but not yet started (`hasPendingStartTask`). Draining task bodies alone is
    /// not enough — a write can hand work to the bg pump or hop to MainActor, and
    /// declaring "quiet" before those drain is exactly what made the naive serial
    /// wiring mis-resolve. We loop barrier → drain bg → re-check all four until
    /// they're *simultaneously* quiet across two rounds (a stable fixpoint), or a
    /// LOGICAL round cap trips (runaway). No wall clock in the decision.
    ///
    /// Additive to the reactive wait — model writes already wake `expect`/`settle`
    /// as they happen (so transient-state assertions still resolve mid-drive);
    /// this just guarantees forward progress without depending on the wall clock.
    /// Returns the driver `Task` (cancel it once the wait resolves) or `nil`.
    func _startExecutorDrive() -> Task<Void, Never>? {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           let exec = _TestExecutorBox.current as? _DrainTestExecutor {
            return Task { [weak self] in
                guard let self else { return }
                let bg = backgroundCall   // task-local per-test queue (inherited)
                var consecutiveQuiet = 0
                while !Task.isCancelled {
                    await exec.waitUntilIdle()
                    if !bg.isIdle { await bg.waitForCurrentItems(deadline: .max) }
                    let quiet = exec.isExecutorIdle
                        && bg.isIdle
                        && mainCall.isIdle
                        && !self.context.hasPendingStartTask
                    if quiet {
                        consecutiveQuiet += 1
                        if consecutiveQuiet >= 2 { break }
                        await Task.yield()   // let any in-flight resumption re-enqueue before re-confirming
                    } else {
                        consecutiveQuiet = 0
                    }
                }
                self._noteActivity()
            }
        }
        #endif
        return nil
    }
}
