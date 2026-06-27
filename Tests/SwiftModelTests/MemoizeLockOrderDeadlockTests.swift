import Testing
import Foundation
@testable import SwiftModel

// Regression test for an AB-BA deadlock between the context hierarchy lock
// (`AnyContext.lock` — the recursive lock shared by every context in a
// hierarchy; call it B) and the `TestAccess` write lock (A), on the `memoize`
// FIRST-ACCESS path.
//
// The cycle, captured live with `sample` on a wedged xctest:
//
//   • memoize thread — `memoize`'s first-access setup took the context lock B
//     (`context.lock { … }`) and only THEN, through the nested
//     `Context.transaction`, the TestAccess write lock A — i.e. B→A.
//
//   • writer thread — any `Context._modify` of a @Model property goes through
//     `Context.transaction`, which acquires A FIRST (`acquireWriteLock()`) and
//     then B (`lock`) — i.e. A→B (the canonical order the WriteLockOrdering /
//     #29 fixes established).
//
//   Two threads, opposite orders → the memoize thread holds B and waits for A;
//   the writer holds A and waits for B → permanent hang.
//
// Reachable ONLY under `.modelTesting`: the base `ModelAccess.acquireWriteLock()`
// is a no-op in production, so A does not exist there — this never wedges a
// shipping app, only the test plan. Same lock-pair / AB-BA family as
// `HierarchyLockOrderDeadlockTests` (#29); that fix hoisted `willAccessParents()`
// out of the context lock in `reduceHierarchy`, but the equivalent inversion on
// the `memoize` first-access path remained. The fix acquires A before B in
// `memoize`'s first-access block, restoring the A→B order.
//
// Authoritative reproduction: the downstream parallel-apple macOS package test
// plan (122 suites, serial) hung ~every run before this fix — a `SDKRootModel`
// activation whose `onActivate` read a memoized child value while drain-executor
// model tasks ran `Context._modify` writes — and passes after.
//
// NOTE ON REPRODUCIBILITY: like #29, the timing window is narrow; a small
// synthetic graph does not reliably hit it without test-only seams into
// TestAccess's locks. This is therefore a CONCURRENCY SMOKE TEST — it drives the
// exact path (memoize first-access during activation, concurrent with sibling
// `Context._modify` writes) across many fresh graphs and asserts each settles and
// stays correct. The deterministic guard is the downstream plan above.

@Model private struct MemoLeaf {
    var n = 0
    var written = 0

    func onActivate() {
        // First-access `memoize` on this fresh context — the B→A path under test.
        // (Each new leaf instance has its own `_memoizeCache`, so every activation
        // is a first access.) The returned value is irrelevant; we only need the
        // first-access lock dance to run concurrently with the writers below.
        _ = node.memoize(for: "doubled") { self.n &* 2 }

        // Concurrently fire a writer on the drain executor (`Context._modify` →
        // A→B) during the same activation wave, so some leaves are mid-memoize
        // (B held, awaiting A) while others run writes (A held, awaiting B).
        node.onChange(of: n, initial: true) { _, _ in
            for _ in 0 ..< 12 { self.written &+= 1 }
        }
    }
}

@Model private struct MemoBranch {
    var leaves: [MemoLeaf] = []
}

@Model private struct MemoRoot {
    var branches: [MemoBranch] = []
}

@Suite(.modelTesting(exhaustivity: .off))
struct MemoizeLockOrderDeadlockTests {

    /// Smoke test: many leaves activate concurrently, each reading a first-access
    /// memoized value (context→TestAccess order pre-fix) while writers fire
    /// `Context._modify` (TestAccess→context). Pre-fix this wedged on the AB-BA
    /// inversion and never reached a `settle()` fixpoint; with the fix every
    /// iteration settles and stays correct.
    @Test func memoizeFirstAccessConcurrentWithWritesStaysSettled() async {
        for _ in 0 ..< 40 {
            let root = MemoRoot(branches: (0 ..< 4).map { _ in
                MemoBranch(leaves: (0 ..< 5).map { i in MemoLeaf(n: i) })
            }).withAnchor()
            await settle()
            // Reaching here at all is the assertion that matters: pre-fix the
            // AB-BA deadlock meant `settle()` never returned (hung to the cap).
            #expect(root.branches.count == 4)
            #expect(root.branches.allSatisfy { $0.leaves.count == 5 })
        }
    }
}
