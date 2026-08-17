import Testing
import Foundation
@testable import SwiftModel

// Regression test for an AB-BA deadlock between the context hierarchy lock
// (`AnyContext.lock` — the recursive lock shared by every context in a
// hierarchy; call it H) and a per-`TaskCancellable` `NSLock` (T).
//
// The cycle:
//
//   • task-registration thread — `TaskCancellable.init` took T (`lock { … }`)
//     and, INSIDE that critical section, evaluated the capture-list expression
//     `context.cancellations`. `AnyContext.cancellations` always takes H. So a
//     task being registered ran T→H. Capture lists are evaluated at closure-
//     FORMATION time, i.e. inside the enclosing lock — which is what made this
//     easy to miss on a read.
//
//   • teardown thread — `node.transaction` holds H across its whole body; a
//     subtree replacement inside it reaches `AnyContext.onRemoval` →
//     `Cancellations.cancelAll()` → `TaskCancellable.onCancel`, which blocks on
//     T. So teardown ran H→T.
//
//   Two threads, opposite orders → permanent hang, 0% CPU.
//
// Fix: hoist `let cancellations = context.cancellations` above the `lock { }`
// and capture the local, making the order uniformly H-before-T. It costs
// nothing — `init` already needed that value on its first line.
//
// Same family as `HierarchyLockOrderDeadlockTests` (#29, `reduceHierarchy`) and
// `MemoizeLockOrderDeadlockTests` (#30, `memoize` first access). It differs from
// both in one important way: those two inverted against the `TestAccess` write
// lock, which does not exist in production (`ModelAccess.acquireWriteLock()` is
// a no-op there), so they could only ever wedge a test plan. **This pair is H and
// a plain `NSLock`, both of which exist in a shipping app** — so this one is a
// latent PRODUCTION hang, not merely a test-plan one. It is, however,
// UNOBSERVED in production; the drain executor raises the odds by tearing down
// several models' tasks at once.
//
// NOTE ON REPRODUCIBILITY: like #29 and #30, the window is narrow and a small
// synthetic graph does not reliably land it. This is therefore a CONCURRENCY
// SMOKE TEST — it drives the exact shape (back-to-back subtree replacements
// inside one transaction, while the previous subtree's activation tasks are
// still registering) and asserts each iteration settles. The durable guard is
// the lock ordering itself, which is now correct by construction.
//
// The shape is taken from the downstream reproduction: two mutations, each
// followed by its own rebuild, with NO await between them — so the second
// teardown's `cancelAll` lands while the first rebuild's activation tasks are
// still under construction. Siblings that await between mutations do not wedge.

@Model private struct CancelLeaf: Identifiable {
    let id: Int
    var ticks = 0

    func onActivate() {
        // Each of these registers a `TaskCancellable` — the T→H arm pre-fix.
        node.task {
            for _ in 0 ..< 8 { await Task.yield() }
        }
        node.onChange(of: ticks, initial: true) { _, _ in }
    }
}

@Model private struct CancelBranch: Identifiable {
    let id: Int
    var leaves: [CancelLeaf] = []
}

@Model private struct CancelRoot {
    var branch = CancelBranch(id: 0)

    /// Back-to-back subtree replacements inside a SINGLE transaction: the
    /// transaction holds H throughout, and the second assignment's teardown runs
    /// `cancelAll` while the first assignment's leaves are still registering
    /// their activation tasks. That is the H→T arm meeting the T→H arm.
    func replaceTwice(seed: Int) {
        // Ids offset clear of the initial `CancelBranch(id: 0)` — a matching id is
        // continuity rather than replacement (see `CancelForest.replaceAll`).
        let base = 1_000_000 &+ seed
        node.transaction {
            branch = CancelBranch(id: base, leaves: (0 ..< 5).map { CancelLeaf(id: base &+ $0) })
            branch = CancelBranch(id: base &+ 1, leaves: (0 ..< 5).map { CancelLeaf(id: base &+ 100 &+ $0) })
        }
    }
}

/// Several sibling subtrees under ONE anchored hierarchy, all replaced inside a
/// single transaction — so teardown and task-registration overlap across
/// contexts rather than within one.
///
/// Deliberately one root, not several: anchoring multiple hierarchies in a single
/// test does not keep them all retained, and the writes then land on dead
/// contexts (observed as `[5, 0, 0, 0]` while developing this test) — which would
/// have made this pass for the wrong reason.
@Model private struct CancelForest {
    var branches: [CancelBranch] = (0 ..< 4).map { CancelBranch(id: $0) }

    func replaceAll(seed: Int) {
        node.transaction {
            for i in branches.indices {
                // Offset well clear of the initial ids (0..<4) and of every sibling's:
                // assigning a model whose `.id` matches the existing child is CONTINUITY,
                // not replacement — the new instance's state is deliberately ignored — and
                // two siblings sharing an id is a reported contract violation. Either would
                // make this test measure the wrong thing (seen as `[0, 5, 5, 5]`).
                let base = 1_000_000 &+ seed &+ (i &* 1000)
                branches[i] = CancelBranch(id: base, leaves: (0 ..< 5).map { CancelLeaf(id: base &+ $0) })
                branches[i] = CancelBranch(id: base &+ 1, leaves: (0 ..< 5).map { CancelLeaf(id: base &+ 100 &+ $0) })
            }
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct CancellableLockOrderDeadlockTests {

    /// Smoke test: repeated back-to-back subtree replacements, each tearing down
    /// a subtree whose tasks are still being registered. Pre-fix this could wedge
    /// on the AB-BA inversion and never reach a `settle()` fixpoint; with the fix
    /// every iteration settles and the final subtree is intact.
    ///
    /// Reaching the end at all is the assertion that matters — a deadlock here
    /// does not fail, it hangs (and swift-model's own inactivity watchdog cannot
    /// catch this class: `_DrainTestExecutor.activityNs` reports `now` whenever
    /// `outstanding > 0`, and deadlocked jobs stay outstanding forever). The
    /// `.modelTesting` trait's wall-clock cap is what surfaces it.
    @Test func backToBackSubtreeReplacementStaysSettled() async {
        let root = CancelRoot().withAnchor()
        await settle()

        for i in 0 ..< 40 {
            root.replaceTwice(seed: i &* 1000)
            await settle()
            #expect(root.branch.leaves.count == 5)
        }
    }

    /// Same inversion reached across sibling subtrees, so teardown and
    /// task-registration overlap between contexts rather than within one.
    @Test func siblingSubtreesReplacedTogetherStaySettled() async {
        let forest = CancelForest().withAnchor()
        await settle()

        for i in 0 ..< 12 {
            forest.replaceAll(seed: i &* 10_000)
            await settle()
            #expect(forest.branches.map(\.leaves.count) == [5, 5, 5, 5])
        }
    }
}
