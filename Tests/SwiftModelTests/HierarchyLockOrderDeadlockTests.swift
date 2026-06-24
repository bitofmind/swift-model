import Testing
import Foundation
@testable import SwiftModel

// Regression test for an AB-BA deadlock between the shared hierarchy/context lock
// (`AnyContext.lock` — a recursive lock shared by every context in a hierarchy) and
// the `TestAccess` lock.
//
// The cycle, captured live with lldb on a wedged process:
//
//   • Writer thread — `Context._modify` of any @Model property acquires the
//     TestAccess lock FIRST (`acquireWriteLock()`), then the context lock — the
//     `TestAccess → context` order the WriteLockOrdering fix established.
//
//   • Traversal thread — a hierarchy walk that registers parent-relationship
//     observation: `reduceHierarchy(observeParents:)` → `observedParents` →
//     `willAccessParents()` → `TestAccess.willAccess` → `registerReadOnlyPathWake`.
//     The last step takes the TestAccess lock, but pre-fix the walk ran the whole
//     `lock(observedParents)` under the context lock — acquiring the TestAccess lock
//     while ALREADY holding the context lock, the opposite `context → TestAccess`
//     order. `registerReadOnlyPathWake`'s own comment assumes that opposite order.
//
//   Two threads, opposite lock orders → the writer holds TestAccess and waits for
//   context; the traversal holds context and waits for TestAccess → permanent hang.
//
// Reading an `@EnvironmentStorage` value walks ancestors via that
// `reduceHierarchy(observeParents:)` path; the deeper the reader sits below where the
// value was set, the longer the context lock is held, widening the window. So a deep
// leaf reading a root-set environment value during activation, concurrently with a
// writer's `Context._modify`, hits the inversion and never reaches a `settle()`
// fixpoint.
//
// The fix hoists `willAccessParents()` out of the context lock in
// `AnyContext.reduce`, so the registration runs on the same `TestAccess → context`
// order as every writer.
//
// NOTE ON REPRODUCIBILITY: the deadlock's timing window is extremely narrow and only
// reliably reproduces against a large, deeply-nested real model graph activating
// under load — the authoritative reproduction is the downstream `ParallelEditorTests`
// suite (504 tests), which hung 100% before this fix and passes 100% after. A minimal
// synthetic graph does NOT reliably hit the window, and TestAccess's locks cannot be
// hooked to force the interleaving deterministically without adding production test
// seams. This test is therefore a CONCURRENCY SMOKE TEST: it drives the exact code
// path (concurrent activation: deep environment-read traversals + `Context._modify`
// writes) and asserts it completes and stays correct — it is not a guaranteed-failing
// deadlock repro. Semantic regression protection for the `reduce` change comes from
// the environment/observation suites (`EnvironmentModelTests`,
// `CrossModelObservationTests`, `MemoizeDirtyObservationTests`, …) all passing.

private extension EnvironmentKeys {
    var deadlockFlag: EnvironmentStorage<Bool> { .init(defaultValue: false) }
}

/// Deepest level: reads the root-set environment value directly during activation,
/// walking the whole ancestor chain via `reduceHierarchy(observeParents:)` (holding
/// the context lock across the walk), and also writes a property (drives a concurrent
/// `Context._modify`).
@Model private struct DeepLeaf {
    var ticks = 0
    var written = 0

    func onActivate() {
        for _ in 0 ..< 12 {
            if node.environment.deadlockFlag { ticks &+= 1 }
        }
        node.onChange(of: ticks, initial: true) { _, _ in
            for _ in 0 ..< 12 { self.written &+= 1 }
        }
    }
}

@Model private struct DeepC {
    var leaves: [DeepLeaf] = []
    var written = 0
    func onActivate() {
        node.onChange(of: written, initial: true) { _, _ in self.written &+= 0 }
    }
}

@Model private struct DeepB {
    var children: [DeepC] = []
}

@Model private struct DeepA {
    var children: [DeepB] = []
}

/// Root sets the environment value every reader walks up to find.
@Model private struct DeepRoot {
    var children: [DeepA] = []
    func onActivate() {
        node.environment.deadlockFlag = true
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct HierarchyLockOrderDeadlockTests {

    /// Smoke test: deep concurrent activation — leaves read a root-set environment
    /// value (`reduceHierarchy(observeParents:)` over the full ancestor chain,
    /// context→TestAccess order pre-fix) while writers fire `Context._modify`
    /// (TestAccess→context). With the fix every iteration settles and stays correct.
    /// (See the file header on why this is a smoke test, not a deterministic repro.)
    @Test func deepConcurrentActivationReadAndWriteStaySettled() async {
        for _ in 0 ..< 30 {
            let root = DeepRoot(children: (0 ..< 3).map { _ in
                DeepA(children: (0 ..< 3).map { _ in
                    DeepB(children: (0 ..< 3).map { _ in
                        DeepC(leaves: (0 ..< 3).map { _ in DeepLeaf() })
                    })
                })
            }).withAnchor()
            await settle()
            #expect(root.children.count == 3)
        }
    }
}
