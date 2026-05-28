import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

/// Regression tests for the writer-vs-reader lock-order race in `Context._modify`
/// and `Context.stateTransaction`.
///
/// Before the fix, the writer's `acquire context.lock → write reference.state →
/// release context.lock → acquire TestAccess.lock → append valueUpdates` sequence
/// opened a window between the two `release/acquire` operations. Concurrently, a
/// reader (a predicate evaluator running on the test thread) holds `TestAccess.lock`
/// from the outside and then takes `context.lock` to read `reference.state`. If the
/// reader slipped into the gap, it would observe the new `reference.state` value but
/// no `valueUpdates` entry, run its clearing pass against an empty entry list, and
/// return `.passed`. The writer's `valueUpdates` append would then land too late —
/// leaving the entry to survive to the trait's end-of-test exhaustion check.
///
/// The race was only observable for `@ModelContainer` / `@Model`-typed properties
/// because `isEqualIncludingIds` short-circuits on those (`isContainerTypeValue` /
/// `isModelTypeValue` returns `result`), bypassing the in-flight detection that
/// would otherwise have caught the inconsistency (`capturedValue != lastState`).
///
/// The fix: `Context._modify` and `Context.stateTransaction` now call
/// `activeAccess.acquireWriteLock()` BEFORE acquiring `context.lock`, so the
/// writer's lock order matches the reader's (`access.lock → context.lock`). The
/// writer holds `access.lock` across the entire write + `valueUpdates` append +
/// `_noteActivity` sequence; readers cannot observe an inconsistent intermediate
/// state.

/// Direct unit test: verify the writer's lock-order contract — `acquireWriteLock`
/// fires before each write and `releaseWriteLock` fires after, in strict pairs.
/// Catches accidental removal of the `acquireWriteLock` / `releaseWriteLock` calls
/// in `Context._modify` / `Context.stateTransaction` (e.g. a refactor that drops
/// them) without depending on timing-sensitive race reproduction.
///
/// Plain `@Test` — no `.modelTesting` trait — because the trait auto-injects its
/// own `TestAccess` and we want our `RecordingAccess` to be the one whose
/// `acquireWriteLock` / `releaseWriteLock` Context._modify calls.
@Test func writerAcquiresAccessWriteLockAroundEachContextWrite() async {
    let access = RecordingAccess(useWeakReference: false)
    let model = LockOrderRegularModel().withAccess(access)
    let (anchored, anchor) = model.returningAnchor()
    _ = anchor  // keep anchor alive for the test duration

    // Each property write goes through Context._modify which must call
    // `acquireWriteLock` → write reference.state → release context.lock →
    // run activeAccessCallback → `releaseWriteLock` (via the deferred release).
    anchored.count = 1
    anchored.count = 2
    anchored.count = 3

    let recorded = access.log.value
    #expect(recorded == [
        "acquireWriteLock", "releaseWriteLock",
        "acquireWriteLock", "releaseWriteLock",
        "acquireWriteLock", "releaseWriteLock",
    ], "Got: \(recorded)")
}

/// End-to-end behavioural test: an activation task writes a `ModelContainer`-typed
/// property; the test thread uses `require` to capture the new value. Without the
/// lock-order fix, the writer's `release-context.lock → acquire-test-access.lock`
/// gap could let `require`'s predicate evaluator observe the new value before the
/// `valueUpdates` entry was appended, leaving the entry to survive to end-of-test
/// exhaustion. Looping the scenario maximises the chance of catching any regression
/// — with the fix in place every iteration's entry must be cleared by `require`'s
/// trailing expect.
@Test(.modelTesting) func taskWriteOfContainerPropertyIsAssertedByRequire() async throws {
    let model = ContainerRaceModel().withAnchor()
    _ = try await require(model.child)
    // require's trailing expect cleared valueUpdates[childPath]; if the race
    // fired, the entry would survive — the trait's end-of-test exhaustion
    // check catches it.
}

// MARK: - Test models / helpers

/// `ModelAccess` subclass that records each `acquireWriteLock` / `releaseWriteLock`
/// call in order. `shouldPropagateToChildren: true` mirrors `TestAccess` so the
/// access stamping reaches the live model the test writes into.
fileprivate final class RecordingAccess: ModelAccess, @unchecked Sendable {
    let log = LockIsolated<[String]>([])

    override var shouldPropagateToChildren: Bool { true }

    override func acquireWriteLock() {
        log.withValue { $0.append("acquireWriteLock") }
    }
    override func releaseWriteLock() {
        log.withValue { $0.append("releaseWriteLock") }
    }
}

@Model fileprivate struct LockOrderRegularModel {
    var count: Int = 0
}

/// Activation-task writer that triggers the lock-order race on a `ModelContainer`
/// property. `Optional<RaceChild>` is a `ModelContainer` (Optional conforms when
/// `Wrapped: ModelContainer`, and `@Model` types are `ModelContainer`), so
/// `isContainerTypeValue` is `true` for this property — bypassing the
/// `isEqualIncludingIds` in-flight detection and exposing the race.
@Model fileprivate struct ContainerRaceModel {
    var child: RaceChild? = nil

    func onActivate() {
        node.task {
            child = RaceChild()
        }
    }
}

@Model fileprivate struct RaceChild {}
