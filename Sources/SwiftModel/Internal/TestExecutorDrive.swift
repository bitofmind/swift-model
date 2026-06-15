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
/// A harness-owned `TaskExecutor` that runs jobs on a serial queue and tracks
/// the count of ready-but-not-finished jobs, so a drain to a *logical* fixpoint
/// (no ready work) can stand in for wall-clock quiescence — load-independent by
/// construction. See the design note and `SpikeDrainExecutorTests`.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class _DrainTestExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "swift-model.test-drain-executor")
    private let lock = NSLock()
    private var outstanding = 0

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.withLock { outstanding += 1 }
        queue.async {
            unowned.runSynchronously(on: self.asUnownedTaskExecutor())
            self.lock.withLock { self.outstanding -= 1 }
        }
    }

    /// Drive to a logical fixpoint: hop a barrier onto the same serial queue
    /// (raw GCD — not a tracked job) and read the ready-job count. Any
    /// continuation resumed ONTO this executor is enqueued FIFO ahead of a
    /// later barrier, so two consecutive barriers observing zero ready jobs
    /// means no on-executor ready work remains — a fixpoint. `maxSteps` is a
    /// LOGICAL cap (barrier-hop count, not wall-clock): a runaway that keeps
    /// re-enqueuing never reaches the stable zero and trips it deterministically
    /// on every machine. Returns `true` at a stable fixpoint, `false` if the
    /// step cap tripped (runaway / off-executor stall).
    func waitUntilQuiescent(maxSteps: Int = 100_000) async -> Bool {
        var consecutiveZero = 0
        var steps = 0
        while steps < maxSteps {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async { c.resume() }
            }
            if lock.withLock({ outstanding }) == 0 {
                consecutiveZero += 1
                if consecutiveZero >= 2 { return true }
            } else {
                consecutiveZero = 0
            }
            steps += 1
        }
        return false
    }
}
#endif

extension TestAccess {
    /// If a per-test harness executor is active, start a background driver that
    /// drives model work to a fixpoint and then nudges a final predicate
    /// re-evaluation (`_noteActivity`). Additive to the reactive wait — model
    /// writes already wake `expect`/`settle` as they happen, so transient
    /// assertions still resolve mid-drive; this just guarantees forward progress
    /// without depending on the wall clock. Returns the driver `Task` (cancel it
    /// once the wait resolves) or `nil` when no executor is active.
    func _startExecutorDrive() -> Task<Void, Never>? {
        #if canImport(Dispatch)
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
           let exec = _TestExecutorBox.current as? _DrainTestExecutor {
            return Task { [weak self] in
                _ = await exec.waitUntilQuiescent()
                self?._noteActivity()
            }
        }
        #endif
        return nil
    }
}
