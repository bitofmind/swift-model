#if canImport(Dispatch)
import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

@Model private struct DrainWorker {
    var steps = 0

    func onActivate() {
        node.task {
            for _ in 0..<20 { steps += 1; await Task.yield() }
        }
    }
}

/// CPU-busy test bodies fill the cooperative pool. The harness's drain queue must still
/// get a thread: `settle` waits on model jobs that run there, not on the pool.
/// Whether a task resuming from `Task.yield` goes straight back to its preferred executor.
/// On older runtimes (macOS 15) every resume passes through the cooperative pool first,
/// so a full pool delays the model's own work whatever the drain queue's QoS, and this
/// test's premise does not hold there.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private func resumesStayOnTheTestExecutor() async -> Bool {
    let exec = _DrainTestExecutor()
    await Task(executorPreference: exec) {
        await Task.yield()
        await Task.yield()
    }.value
    return exec.enqueuesWhileBusy > 0
}

@Suite(.modelTesting(exhaustivity: .off))
struct DrainQueueStarvationTests {
    @Test func settleIsNotStarvedByBusyCooperativePool() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *),
              await resumesStayOnTheTestExecutor() else { return }
        let stop = LockIsolated(false)
        let spinnersHitCap = LockIsolated(false)
        let running = LockIsolated(0)
        let spinnerCount = ProcessInfo.processInfo.activeProcessorCount * 2
        let spinners = (0..<spinnerCount).map { _ in
            Task.detached {
                // Busy for 10 ms at a time, yielding in between: the pool stays full of
                // runnable work, as with CPU-bound test bodies. Stops when told, or at the cap.
                running.withValue { $0 += 1 }
                let capEnd = Date().addingTimeInterval(10)
                while !stop.value {
                    if Date() >= capEnd { spinnersHitCap.setValue(true); return }
                    let sliceEnd = Date().addingTimeInterval(0.01)
                    while Date() < sliceEnd {}
                    await Task.yield()
                }
            }
        }

        // Anchor only once the pool is full, so the model's jobs queue behind it.
        while running.value < spinnerCount { await Task.yield() }
        let worker = DrainWorker().withAnchor()
        await settle()
        stop.setValue(true)
        for spinner in spinners { await spinner.value }

        // Without a thread for the drain queue, settle resolves only once the spinners
        // give the pool back, at their cap.
        #expect(!spinnersHitCap.value)
        #expect(worker.steps == 20)
    }
}
#endif
