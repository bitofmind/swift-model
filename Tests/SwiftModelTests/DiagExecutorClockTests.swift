#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import Clocks
import SwiftModel

// MARK: - DIAGNOSIS: does a task RESUME on a custom TaskExecutor after a clock sleep?
//
// Iteration 2 of the executor-drain wiring hung `childTasksCompleteBeforeTeardown`
// — the child `onActivate` task (which awaits `node.continuousClock.sleep`) never
// completed on the custom executor. This file isolates the suspect from ALL of
// SwiftModel's machinery: a bare `Task(executorPreference:)` over (a) plain
// yields, (b) an ImmediateClock sleep, (c) a real ContinuousClock sleep. We
// instrument the executor's `enqueue` count so we can see whether the
// post-sleep continuation is delivered back to the executor at all.
//
// Reading the result:
//  • control (yields) completes  → harness sound, executor runs jobs.
//  • ImmediateClock completes? enqueue count after the sleep?
//  • ContinuousClock completes? enqueue count after the sleep?
// If a clock variant does NOT complete, the bug is fundamental to
// executorPreference + that clock's resumption — not SwiftModel. If they DO
// complete here, the stall is in SwiftModel's task wrapper / settle, and we look
// there next.

final class DiagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _done = false
    func markDone() { lock.withLock { _done = true } }
    var done: Bool { lock.withLock { _done } }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class DiagExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "diag.executor", attributes: .concurrent)
    private let lock = NSLock()
    private var _enqueues = 0
    var enqueues: Int { lock.withLock { _enqueues } }

    func enqueue(_ job: consuming ExecutorJob) {
        lock.withLock { _enqueues += 1 }
        let unowned = UnownedJob(job)
        queue.async { unowned.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

@Model private struct DiagModel: Sendable {
    var flag = false
    func onActivate() {
        node.task {
            try await node.continuousClock.sleep(for: .milliseconds(50))
            flag = true
        } catch: { _ in }
    }
}

@Suite("DIAG: executor + clock resumption")
struct DiagExecutorClockTests {

    /// Await `t` but give up after `seconds` (so a stalled task fails the test
    /// instead of hanging it). Returns whether `t` completed in time.
    private func completes(within seconds: Double, _ t: Task<Void, Never>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await t.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func control_plainYieldsCompleteOnExecutor() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let exec = DiagExecutor()
        let box = DiagBox()
        let t = Task(executorPreference: exec) {
            for _ in 0..<5 { await Task.yield() }
            box.markDone()
        }
        let ok = await completes(within: 3, t)
        print("DIAG control(yields): completed=\(ok) enqueues=\(exec.enqueues)")
        #expect(ok, "control: plain-yield task must complete on the executor")
        #expect(box.done)
    }

    @Test func immediateClockSleepResumesOnExecutor() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let exec = DiagExecutor()
        let box = DiagBox()
        let clock = ImmediateClock()
        let t = Task(executorPreference: exec) {
            try? await clock.sleep(for: .milliseconds(50))
            box.markDone()
        }
        let ok = await completes(within: 3, t)
        print("DIAG ImmediateClock.sleep: completed=\(ok) enqueues=\(exec.enqueues)")
        #expect(ok, "ImmediateClock-hopping task must complete on the executor (this is the childTasks shape)")
        #expect(box.done)
    }

    /// LAYER 3 — a real `@Model` `node.task` (the childTasks shape), but polled
    /// DIRECTLY for completion instead of via `expect`/`settle`. This separates
    /// "does the model task complete on the executor?" from "does the wait detect
    /// it?". Runs inside `withModelTesting`, so the experimental executor box is
    /// installed (when the flag is on). Reports `flag` either way.
    @Test func realModelNodeTaskCompletesOnExecutor() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let flagOn = ProcessInfo.processInfo.environment["SWIFT_MODEL_EXPERIMENTAL_DRAIN"] == "1"
        await withModelTesting(.off) {
            let m = DiagModel().withAnchor { $0.continuousClock = ImmediateClock() }
            var ok = false
            for _ in 0..<300 {              // poll up to ~3 s, off the executor
                if m.flag { ok = true; break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            print("DIAG realModel(node.task): executorFlag=\(flagOn) completed=\(ok) flag=\(m.flag)")
            #expect(ok, "real model node.task must complete (executorFlag=\(flagOn))")
        }
    }

    @Test func continuousClockSleepResumesOnExecutor() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let exec = DiagExecutor()
        let box = DiagBox()
        let clock = ContinuousClock()
        let t = Task(executorPreference: exec) {
            try? await clock.sleep(for: .milliseconds(50))
            box.markDone()
        }
        let ok = await completes(within: 3, t)
        print("DIAG ContinuousClock.sleep: completed=\(ok) enqueues=\(exec.enqueues)")
        #expect(ok, "real-clock-hopping task must complete on the executor")
        #expect(box.done)
    }
}
#endif
