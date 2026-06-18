#if canImport(Dispatch)
import Foundation
import Dispatch
import Testing
import SwiftModel

// Regression coverage for executor-drain `settle()`. With the per-test harness
// executor active (macOS 15+ / iOS 18+ / Linux-Swift-6 — the unconditional
// default), `settle()` resolves on the model's drain FIXPOINT — a non-starvable,
// load-independent quiescence signal — instead of the `.deferential`/`.background`
// quiet-check that macOS starves under parallel load (the root cause of the
// false `settle() timed out: model still has active tasks`). See
// docs/test-determinism-executor-drain.md.

@Model private struct DrainParent: Sendable {
    var items: [DrainItem] = []
}
@Model private struct DrainItem: Sendable, Identifiable {
    let id: Int
    var done: Bool = false
    func onActivate() {
        // A short async chain on the per-test executor: several suspension
        // points (each needs a CPU slot), then a write — the shape that a
        // wall-clock/`.background` settle starves on under parallel load.
        node.task {
            for _ in 0..<6 { await Task.yield() }
            done = true
        }
    }
}

/// Saturate ~half the cores for the duration of `body`, then stop — enough to
/// stress scheduling without wedging a shared machine.
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

@Suite("executor-drain settle()")
struct ExecutorDrainSettleTests {
    /// `settle()` over a model whose children each run an async chain must
    /// resolve (no false timeout) on EVERY iteration, INCLUDING under heavy CPU
    /// load — the load-independence the drain provides. Only meaningful where the
    /// harness executor is active (skipped on older hosts that use the wall-clock
    /// fallback, where this guarantee doesn't hold).
    @Test func settleIsLoadIndependentAcrossChildTasks() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        await underCPULoad {
            for _ in 0..<60 {
                await withModelTesting(.off) {
                    let parent = DrainParent().withAnchor()
                    parent.items = (0..<4).map { DrainItem(id: $0) }
                    await settle()
                    // After settle, the children's chains have completed — the
                    // whole point: settle waited for genuine quiescence, not a
                    // wall-clock window that load could blow.
                    #expect(parent.items.count == 4 && parent.items.allSatisfy { $0.done })
                }
            }
        }
    }
}
#endif
