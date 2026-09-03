import Foundation
import Testing
@testable import SwiftModel

// MARK: - Models

/// Grandchild the host swaps in on every write. Mirrors `MediaPlayerController`
/// in the field report — a `@Model` reached through an `Optional` slot.
@Model private struct TornReadController: Identifiable {
    let id: Int
    var outcome: Int = 0
}

/// `Optional` is a `ModelContainer` (not a `Model`), so writes to this property
/// route through `_ModelSourceBox.subscript<T: ModelContainer>(write:)`.
@Model private struct TornReadOptionalHost {
    var controller: TornReadController? = nil
}

/// Non-optional `@Model` child → `_ModelSourceBox.subscript<T: Model>(write:)`.
@Model private struct TornReadChild: Identifiable {
    let id: Int
    var outcome: Int = 0
}

@Model private struct TornReadModelHost {
    var child: TornReadChild = TornReadChild(id: 0)
}

/// `MutableCollection` whose `Element` is `ModelContainer & Identifiable` but NOT
/// `Model` → `_ModelSourceBox._performContainerCollectionSet`.
@ModelContainer
private enum TornReadStep: Identifiable {
    case leaf(TornReadController)
    var id: Int { if case .leaf(let leaf) = self { return leaf.id }; return -1 }
}

@Model private struct TornReadCollectionHost {
    var steps: [TornReadStep] = []
}

/// Holds both single-child hosts so the mixed-shape test can drive them concurrently
/// from one anchored tree — a scope tracks one root, and two peer `withAnchor()` calls
/// would leave the second host torn down and its writes unobserved.
@Model private struct TornReadMixedHost {
    var optional = TornReadOptionalHost()
    var model = TornReadModelHost()
}

// MARK: - Tests

/// Concurrent-writer coverage for the **post-transaction re-activation** step of the
/// `@Model`-child write paths (`_ModelSourceBox`).
///
/// Each of those paths runs its `stateTransaction` under the hierarchy lock and then,
/// once the lock is released, projects the stored child back out of `reference.state`
/// to activate it. Those projections must go through `_snapshotUnderLock` — an
/// unlocked `reference.state[keyPath:]` read there is a memory-safety bug, because the
/// key-path projection loads the slot and only then retains what it loaded, so a
/// concurrent writer dropping the old child's last reference in between hands that
/// retain a freed object. The observed production failure is a `SIGSEGV` in
/// `swift_retain` ← `initializeWithCopy` ← `swift_getAtKeyPath` ← the re-activation
/// closure. `_performCollectionSet` was fixed this way in 6c9ca91; the other four
/// sites were missed and are fixed alongside these tests.
///
/// **What these tests can and cannot do.** They drive every one of those sites from
/// genuinely concurrent writers and assert the hierarchy survives. They do **not**
/// detect the unlocked read directly, and neither sanitizer can: both the load and the
/// retain happen inside uninstrumented `libswiftCore`, so TSan and ASan are
/// structurally blind to it. Measured on the unfixed code, the site was reached 24 000
/// times from four concurrent OS threads with zero reports from TSan, ASan or
/// `MallocScribble`, and no crash. So a clean sanitizer run is **not** evidence that a
/// raw `reference.state[keyPath:]` read outside the lock is safe — route it through
/// `_snapshotUnderLock` instead.
@Suite(.modelTesting(exhaustivity: .off))
private struct PostTransactionActivateTornReadTests {

    /// Writes per task. Enough that the writers genuinely overlap; deliberately modest,
    /// because these tests share the parallel test run with every other suite.
    private static let writes = 150

    /// Runs `body` on `count` concurrent detached tasks and waits for all of them.
    ///
    /// `Task.detached`, not a task group: `.modelTesting` installs a serializing drive
    /// executor and task-group children inherit it, which schedules the writers one
    /// after another — no overlap, nothing exercised.
    private func concurrently(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) async {
        let tasks = (0..<count).map { index in Task.detached { body(index) } }
        for task in tasks { _ = await task.result }
    }

    /// The ids these tests ever write, plus `0` for a model's birth value.
    ///
    /// This is the assertion that matters. Concurrent last-write-wins says nothing
    /// about *which* generation ends up stored — a losing read-modify-write can even
    /// restore the birth value — so the winner is not assertable. What IS assertable is
    /// that the stored value is one this test actually produced: a projection that read
    /// a freed or half-updated slot yields an id from nowhere (or faults outright).
    private static func isLegitimateWrittenID(_ id: Int) -> Bool {
        if id == 0 || id == -1 { return true }           // birth value / empty enum case
        let writer = id / 1_000_000
        let offset = id % 1_000_000
        return (0...3).contains(writer) && (0...(writes * 10 + 4)).contains(offset)
    }

    /// `Optional<@Model>` — the `subscript<T: ModelContainer>(write:)` setter, whose
    /// re-activation read is the faulting frame of the production crash.
    @Test func concurrentOptionalModelChildWrites() async {
        let host = TornReadOptionalHost().withAnchor()

        await concurrently(2) { writer in
            for i in 0..<Self.writes {
                // Distinct ids per writer so every write is a genuine replacement
                // and the re-activation step always runs.
                host.controller = TornReadController(id: writer * 1_000_000 + i + 1)
            }
        }
        await settle()

        #expect(host.controller != nil, "concurrent replacement lost the child entirely")
        #expect(Self.isLegitimateWrittenID(host.controller?.id ?? 0), "stored child id was never written — projection read corrupt state")
    }

    /// Non-optional `@Model` child — the `subscript<T: Model>(write:)` setter, which
    /// projects the stored child twice: the `!== newValue.context` guard before the
    /// transaction, and the `context?.onActivate()` re-activation after it.
    @Test func concurrentModelChildWrites() async {
        let host = TornReadModelHost().withAnchor()

        await concurrently(2) { writer in
            for i in 0..<Self.writes {
                host.child = TornReadChild(id: writer * 1_000_000 + i + 1)
            }
        }
        await settle()

        #expect(Self.isLegitimateWrittenID(host.child.id), "stored child id was never written — projection read corrupt state")
    }

    /// `[ModelContainer & Identifiable]` — `_performContainerCollectionSet`, whose
    /// re-activation loop iterates the stored collection. A multi-word stored value
    /// can additionally be read half-updated, not merely stale.
    @Test func concurrentContainerCollectionWrites() async {
        let host = TornReadCollectionHost().withAnchor()

        await concurrently(2) { writer in
            for i in 0..<Self.writes {
                // Vary the element count so the stored array's buffer changes shape,
                // not just its contents.
                let count = (i % 4) + 1
                host.steps = (0..<count).map { .leaf(TornReadController(id: writer * 1_000_000 + i * 10 + $0 + 1)) }
            }
        }
        await settle()

        #expect(!host.steps.isEmpty, "concurrent replacement emptied the collection")
        #expect(host.steps.allSatisfy { Self.isLegitimateWrittenID($0.id) },
                "a stored element id was never written — projection read corrupt state")
    }

    /// Both child shapes driven at once, with concurrent readers of the stored children,
    /// so the locked read path overlaps the post-transaction re-activation.
    @Test func concurrentMixedChildWritesAndReads() async {
        let host = TornReadMixedHost().withAnchor()
        let optionalHost = host.optional
        let modelHost = host.model

        await concurrently(3) { worker in
            for i in 0..<Self.writes {
                switch worker {
                case 0: optionalHost.controller = TornReadController(id: i + 1)
                case 1: modelHost.child = TornReadChild(id: i + 1)
                default:
                    optionalHost.controller?.outcome = i
                    modelHost.child.outcome = i
                }
            }
        }
        await settle()

        #expect(Self.isLegitimateWrittenID(optionalHost.controller?.id ?? 0))
        #expect(Self.isLegitimateWrittenID(modelHost.child.id))
    }
}
