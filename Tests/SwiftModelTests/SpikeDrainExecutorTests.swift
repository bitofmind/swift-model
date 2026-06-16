#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import Clocks
import SwiftModel

// MARK: - SPIKE: executor-drain quiescence (throwaway, not shipped)
//
// Goal: validate the one load-bearing unknown behind a ground-up rethink of
// SwiftModel's test determinism — can a *harness-owned* executor give a
// reliable, LOAD-INDEPENDENT "the model's async work has reached a fixpoint"
// signal, replacing wall-clock debounce (`waitUntilSettled`)?
//
// Today every model task body (`node.task`/`forEach` → `Cancellables`) and the
// Observed/memoize pump (`CallQueue`) run on the *uncontrolled global
// cooperative pool*; "done" is inferred by watching the wall clock for a quiet
// window. Under load the wall clock and the pool desynchronise → flakes.
//
// This spike runs a model-like workload on a custom `TaskExecutor` whose
// outstanding-ready-job count we own, and defines quiescence as a *logical*
// fixpoint (barrier hops until the ready queue stays empty), with a *logical*
// step cap as the runaway guard. No wall-clock anywhere in the decision.
//
// What it must answer:
//   1. Does "ready queue drained to a stable fixpoint" correctly mean "all
//      model work finished" for the on-executor case? (Test A)
//   2. Is that answer load-INDEPENDENT — identical under heavy CPU contention,
//      where the wall-clock path is documented to flake? (Test A under load)
//   3. Does a runaway (`while { yield }`) get caught DETERMINISTICALLY by the
//      logical step cap instead of a wall-clock budget? (Test B — the exact
//      case the budget-cap patch could not distinguish from an idle model)
//   4. Where is the hole? (Test C documents the off-executor / external-async
//      caveat honestly.)
//
// Custom task executors (SE-0417) need the Swift 6 concurrency runtime.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class DrainTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "spike.drain-executor")
    private let lock = NSLock()
    private var outstanding = 0
    private(set) var totalJobsRun = 0

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        lock.withLock { outstanding += 1 }
        queue.async {
            unowned.runSynchronously(on: self.asUnownedTaskExecutor())
            self.lock.withLock {
                self.outstanding -= 1
                self.totalJobsRun += 1
            }
        }
    }

    /// Drive the executor to a *logical* fixpoint: hop a barrier onto the same
    /// serial queue (raw GCD — not a tracked job) and read the ready-job count.
    /// Any continuation resumed ONTO this executor is enqueued FIFO ahead of a
    /// later barrier, so two consecutive barriers observing `outstanding == 0`
    /// means no on-executor ready work remains — a fixpoint.
    ///
    /// `maxSteps` is a LOGICAL cap (barrier-hop count), not wall-clock: a
    /// runaway that keeps re-enqueuing never reaches the stable-zero and trips
    /// it deterministically on every machine, regardless of load.
    ///
    /// Returns `true` if a stable fixpoint was reached, `false` if `maxSteps`
    /// was exceeded (runaway).
    func waitUntilQuiescent(maxSteps: Int = 100_000) async -> Bool {
        var consecutiveZero = 0
        var steps = 0
        while steps < maxSteps {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async { c.resume() }
            }
            let out = lock.withLock { outstanding }
            if out == 0 {
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

// MARK: - Modest, bounded CPU load (to test load-INDEPENDENCE)

/// Saturate ~half the cores with busy loops for the duration of `body`, then
/// stop them. Deliberately bounded (half the cores, scoped lifetime) so it
/// stresses scheduling without wedging a shared machine.
@Sendable
func underCPULoad<T>(_ body: () async -> T) async -> T {
    let stop = NSLock()
    nonisolated(unsafe) var running = true
    let burners = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    for _ in 0..<burners {
        Thread.detachNewThread {
            var x = 0.0
            while stop.withLock({ running }) {
                for _ in 0..<50_000 { x = (x + 1.0).squareRoot() }
            }
            _ = x
        }
    }
    defer { stop.withLock { running = false } }
    return await body()
}

// Mirrors ChildActivationTaskTests' models — a parent whose child items each
// spawn an onActivate task that sets `loaded` after a clock sleep. With an
// ImmediateClock the work is logically finite; the only reason the real test
// flakes is the cooperative pool not scheduling all of it within `expect`'s
// wall-clock budget under load.
@Model private struct SpikeParent: Sendable {
    var items: [SpikeItem] = []
}
@Model private struct SpikeItem: Sendable, Identifiable {
    let id: Int
    var loaded: Bool = false
    func onActivate() {
        node.task {
            try await node.continuousClock.sleep(for: .milliseconds(200))
            loaded = true
        } catch: { _ in }
    }
}

@Suite("SPIKE: executor-drain quiescence")
struct SpikeDrainExecutorTests {

    /// A model-like workload: a tree of tasks that each yield several times
    /// (needing many cooperative slots) and then write a "done" flag, with
    /// children and grandchildren — mirroring `ChildActivationTaskTests`
    /// (children load after a sleep) and the "N cooperative slots within a
    /// fixed budget" flake pattern from CLAUDE.md.
    final class Tree: @unchecked Sendable {
        let lock = NSLock()
        var doneCount = 0
        var expected = 0
        func markDone() { lock.withLock { doneCount += 1 } }
        var allDone: Bool { lock.withLock { doneCount == expected } }
    }

    @available(macOS 15.0, *)
    private func runWorkload(on exec: DrainTaskExecutor, tree: Tree, depth: Int, breadth: Int) {
        func spawn(_ level: Int) {
            tree.lock.withLock { tree.expected += 1 }
            Task(executorPreference: exec) {
                // Several suspension points: each needs a slot to resume.
                for _ in 0..<5 { await Task.yield() }
                tree.markDone()
                if level < depth {
                    for _ in 0..<breadth { spawn(level + 1) }
                }
            }
        }
        for _ in 0..<breadth { spawn(1) }
    }

    /// TEST A — the core claim. After `waitUntilQuiescent()` returns, ALL tree
    /// work is done, deterministically, on every iteration, INCLUDING under
    /// heavy CPU contention (where a wall-clock debounce is documented to flake).
    @Test func drainQuiescenceIsCompleteAndLoadIndependent() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        await underCPULoad {
            for _ in 0..<150 {
                let exec = DrainTaskExecutor()
                let tree = Tree()
                runWorkload(on: exec, tree: tree, depth: 3, breadth: 3)
                let reached = await exec.waitUntilQuiescent()
                #expect(reached, "should reach a fixpoint")
                #expect(tree.allDone, "every spawned task must have completed before quiescence (done=\(tree.doneCount)/\(tree.expected))")
            }
        }
    }

    /// TEST B — runaway detection is LOGICAL, not wall-clock. A `while { yield }`
    /// spinner never lets the ready queue stay empty, so the step cap trips
    /// deterministically. This is the exact case the budget-cap patch could not
    /// tell apart from an idle-but-starved model.
    @Test func runawayIsDetectedByLogicalStepCap() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let exec = DrainTaskExecutor()
        let stop = NSLock()
        nonisolated(unsafe) var run = true
        let spinner = Task(executorPreference: exec) {
            while stop.withLock({ run }) { await Task.yield() }
        }
        let reached = await exec.waitUntilQuiescent(maxSteps: 500)
        #expect(!reached, "a continuously-yielding runaway must NOT reach a fixpoint")
        stop.withLock { run = false }
        _ = await spinner.value
    }

    /// TEST D — END-TO-END through the real `.modelTesting` path. The wiring
    /// (`Cancellables` executorPreference + `_TestExecutorBox` task-local + the
    /// `expect` drive) is exercised here: a parent spawns 5 child `onActivate`
    /// tasks (clock-sleep → `loaded = true`) and `expect` asserts all loaded —
    /// the exact shape of the documented load-flaky
    /// `ChildActivationTaskTests.childTasksCompleteBeforeTeardown`. Looped under
    /// CPU load: with the executor drive, `expect` resolves by driving the model
    /// tasks to a fixpoint rather than waiting on the wall clock, so every
    /// iteration passes regardless of contention.
    @Test func realModelChildTasksAreLoadIndependentEndToEnd() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        // Opt-in: only meaningful with the experimental executor-drain wiring on.
        guard ProcessInfo.processInfo.environment["SWIFT_MODEL_EXPERIMENTAL_DRAIN"] == "1" else { return }
        await underCPULoad {
            for _ in 0..<40 {
                await withModelTesting(.off) {
                    let parent = SpikeParent().withAnchor { $0.continuousClock = ImmediateClock() }
                    parent.items = (0..<5).map { SpikeItem(id: $0) }
                    await expect(parent.items.count == 5 && parent.items.allSatisfy { $0.loaded })
                }
            }
        }
    }

    /// TEST E — FIRING SEMANTICS. With the fixpoint-primary drive, an
    /// unsatisfiable `expect` must FAIL the moment the model is quiescent (~ms
    /// when unloaded), NOT wait the 600 s wall-clock backstop. This is the
    /// "happy case never fires; a broken assertion fires fast interactively"
    /// contract — the timeout is a fixpoint check, not a time budget.
    @Test func brokenExpectFailsFastAtFixpoint() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        guard ProcessInfo.processInfo.environment["SWIFT_MODEL_EXPERIMENTAL_DRAIN"] == "1" else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        await withModelTesting(.off) {
            let m = SpikeItem(id: 0).withAnchor { $0.continuousClock = ImmediateClock() }
            await withKnownIssue("an unsatisfiable expect must fail at the fixpoint") {
                await expect(m.loaded && !m.loaded)   // never true
            }
        }
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("DIAG brokenExpect: elapsedMs=\(elapsedMs)")
        #expect(elapsedMs < 5_000, "broken expect must fail at the fixpoint (~ms), not wait the 600 s backstop")
    }

    /// TEST C — HONEST CAVEAT. Work that suspends on an OFF-executor async
    /// source (here a raw GCD timer, standing in for an uncontrolled real
    /// dependency) leaves the executor's ready queue empty while work is still
    /// pending elsewhere — so drain-quiescence reports a fixpoint *before* the
    /// work completes. This is the rule the real design must enforce: in tests,
    /// model effects must run on controlled dependencies, not uncontrolled
    /// real async. Documented as a known limitation, not a passing behaviour.
    @Test func offExecutorAsyncIsAGapToGuardAgainst() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let exec = DrainTaskExecutor()
        let done = NSLock()
        nonisolated(unsafe) var finished = false
        _ = Task(executorPreference: exec) {
            // Suspend on a GCD timer — resumes OFF this executor.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { c.resume() }
            }
            done.withLock { finished = true }
        }
        let reached = await exec.waitUntilQuiescent(maxSteps: 5_000)
        #expect(reached, "executor looks idle while the task is parked off-executor")
        let prematurelyQuiescent = !done.withLock { finished }
        #expect(prematurelyQuiescent, "KNOWN GAP: fixpoint declared before off-executor work finished — controlled deps are required")
    }
}
#endif
