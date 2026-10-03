#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Regression coverage for `settle()` spinning while a model task is pending its first run.
///
/// **The bug.** `_driveToStableFixpoint` holds its quiet window open while any registered task
/// has not started running (`hasPendingStartWork`). With the drain executor, background queue
/// and main-observation queue all idle, each of the loop's waits resolved synchronously — a
/// continuation resumed inside its own body does not suspend the task — so the loop re-checked
/// in a tight spin without ever giving up its thread. A task whose first job needs that thread
/// can then never start: a task spawned without the harness executor (e.g. from a main-queue
/// callback) runs on the cooperative pool, and once enough tests spin at once they hold every
/// pool thread. The pool-hosted trait-cap watchdogs are starved too, so nothing ever cancels
/// the wait. Downstream this pinned ~10 cores for 23+ minutes in one `settle()`.
///
/// **The test.** The same deadlock on one thread. `settle()` runs on a single-thread task
/// executor, and a registered task that has not started yet needs that thread to get going:
/// its body yields on the thread many times before it counts as started, so it cannot finish
/// during the few suspensions `settle` makes before its drive loop. Without the fix the loop
/// spins on the thread, the task never runs again, and settle only ends when the trait cap
/// cancels it. With the fix settle suspends while it waits, the task starts, and settle
/// reaches its fixpoint at once.
@Suite(.modelTesting)
struct SettlePendingStartSpinTests {
    @Model
    struct Counter {
        var count = 0
    }

    @Test func settleYieldsItsThreadWhileATaskIsPendingStart() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let model = Counter().withAnchor()
        await settle()

        let thread = SingleThreadTaskExecutor()
        await withTaskExecutorPreference(thread) {
            // Hop onto `thread` first: the preference only takes effect at a suspension point.
            await Task.yield()
            let started = LockedValue(false)
            _ = TaskCancellable(
                modelName: "Counter", taskName: "pending start", fileAndLine: FileAndLine(fileID: #fileID, filePath: #filePath, line: #line, column: #column),
                cancellations: model.node._context!.cancellations, hasStartedRunningBox: started
            ) { onDone in
                Task(executorPreference: thread) {
                    defer { onDone() }
                    // Each yield needs `thread` again, so this reaches "started" only while
                    // `settle` gives the thread up.
                    for _ in 0..<1_000 { await Task.yield() }
                    started.setValue(true)
                    model.count = 1
                }
            }
            await settle()
            #expect(started.value)
        }
        await expect(model.count == 1)
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private final class SingleThreadTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SettlePendingStartSpinTests.single-thread")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
#endif
