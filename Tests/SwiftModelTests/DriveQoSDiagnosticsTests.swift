import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

#if canImport(Darwin)
import Dispatch

// TEMPORARY DIAGNOSTIC — prints, for CI log comparison, where drive jobs and
// their yielded continuations actually run (QoS + dispatch queue label), and the
// timing of the settle() fixpoint relative to the children's completion.
// Same shape as ExecutorDrainSettleTests.settleIsLoadIndependentAcrossChildTasks.

private struct Sample: Sendable, CustomStringConvertible {
    let child: Int, step: String, qos: UInt32, queue: String, tNs: UInt64
    var description: String { "child\(child) \(step) qos=\(qos) queue=\(queue) t=\(tNs / 1000)µs" }
}
private let samples = LockIsolated<[Sample]>([])
private let t0 = LockIsolated<UInt64>(0)
private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds &- t0.value }
private func record(_ child: Int, _ step: String) {
    let label = String(cString: __dispatch_queue_get_label(nil))
    samples.withValue { $0.append(Sample(child: child, step: step, qos: qos_class_self().rawValue, queue: label, tNs: now())) }
}

@Model private struct DiagItem: Sendable, Identifiable {
    let id: Int
    var done = false
    func onActivate() {
        node.task {
            record(id, "start")
            for i in 0..<6 { await Task.yield(); record(id, "yield\(i)") }
            done = true
            record(id, "done")
        }
    }
}
@Model private struct DiagParent: Sendable {
    var items: [DiagItem] = []
}

@Sendable private func underCPULoad<T>(_ body: () async -> T) async -> T {
    let stop = NSLock()
    nonisolated(unsafe) var running = true
    for _ in 0..<max(2, ProcessInfo.processInfo.activeProcessorCount / 2) {
        Thread.detachNewThread {
            var x = 0.0
            while stop.withLock({ running }) { for _ in 0..<50_000 { x = (x + 1).squareRoot() } }
            _ = x
        }
    }
    defer { stop.withLock { running = false } }
    return await body()
}

@Suite("DIAG drive QoS")
struct DriveQoSDiagnosticsTests {
    @Test func whereDoDriveJobsAndYieldsRun() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        print("DIAG drainQueueQoS=\(_drainQueueQoS) cores=\(ProcessInfo.processInfo.activeProcessorCount) testThreadQoS=\(qos_class_self().rawValue) testQueue=\(String(cString: __dispatch_queue_get_label(nil)))")
        let failures = LockIsolated(0)
        await underCPULoad {
            for iteration in 0..<40 {
                samples.setValue([]); t0.setValue(DispatchTime.now().uptimeNanoseconds)
                await withModelTesting(.off) {
                    let parent = DiagParent().withAnchor()
                    parent.items = (0..<4).map { DiagItem(id: $0) }
                    await settle()
                    let settledAt = now()
                    let allDone = parent.items.allSatisfy { $0.done }
                    if !allDone || iteration < 2 {
                        if !allDone { failures.withValue { $0 += 1 } }
                        print("DIAG iteration=\(iteration) allDone=\(allDone) settledAt=\(settledAt / 1000)µs")
                        for s in samples.value { print("DIAG   \(s)") }
                    }
                }
            }
        }
        print("DIAG premature settles: \(failures.value)/40")
    }
}
#endif
