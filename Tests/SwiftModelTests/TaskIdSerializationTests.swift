import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Verifies that `node.task(id:)` (and the underlying `forEach(_, cancelPrevious: true)`)
/// never runs two bodies for the same stream concurrently — even when a body's sync tail
/// after its last suspension point is long enough to overlap with the next body's prefix.
///
/// Background: `node.task(id:) { value in … }` desugars to
/// `forEach(Observed { id }, cancelPrevious: true) { value in … }`. When `id` changes,
/// the in-flight body's underlying `Task` is `.cancel()`-ed, but `Task.cancel()` only
/// flips a flag — a body that doesn't hit another suspension point (or that has already
/// passed its last one) keeps running to completion. Without explicit serialization the
/// previous body's sync tail can race the next body's prefix and interleave writes
/// through the model context lock, producing "last-writer-wins on stale state" bugs.
///
/// The flake that motivated this test was in `OnboardingTests.shortUsernameShowsInlineError`:
/// the initial `task(id: trimmedUsername)` body (with id == "") wrote
/// `availabilityError = nil` AFTER the test-write's body (with id == "ab") had already
/// written `availabilityError = "Username must be at least 3 characters"`, leaving the
/// state stuck at `nil`. See the fix in `_forEachImpl`'s `cancelPrevious` branch in
/// `Sources/SwiftModel/ModelNode+Reactive.swift`.
@Suite(.modelTesting)
struct TaskIdSerializationTests {

    /// Regression test for the cancel-before-init deadlock that the first
    /// `task(id:)`-serialization attempt suffered from. The Onboarding flake's
    /// `shortUsernameShowsInlineError` exercises this path: the test writes the next
    /// `id` value SYNCHRONOUSLY after `withAnchor()` returns — before the outer
    /// for-await loop has had a chance to schedule the initial body. With a naive
    /// implementation that uses an `inside-the-body` defer to signal completion,
    /// the next iteration's cancellation can land before the body is scheduled and
    /// the `guard !Task.isCancelled` returns early without invoking the user closure,
    /// the signal never fires, and the loop deadlocks waiting on it.
    ///
    /// The body must still eventually run for the second `id`, and the final value
    /// must reach the model.
    @Test func taskIdNoDeadlockWhenIdChangesBeforeBodyStarts() async {
        let model = ImmediateChangeModel().withAnchor()
        // Synchronously bump id before the for-await loop has a chance to run the
        // initial body. This is the exact pattern the Onboarding flake exercises.
        model.id = 1
        // The body for id=1 must eventually run and record its arrival.
        await expect {
            model.id == 1
            model.lastSeen == 1
        }
    }

    /// Synthetic race: each body increments a shared in-flight counter, yields, spins on
    /// a tight CPU loop (no cancellation observability), decrements, and records. With
    /// the serialization fix in place, `maxConcurrentBodies` stays at 1 no matter how
    /// many times we change `id` while a body is mid-flight.
    @Test func taskIdBodiesNeverRunConcurrently() async {
        await _taskIdBodiesNeverRunConcurrentlyBody()
    }

    /// AccessCollector-path variant of the above. Originally added as a
    /// diagnostic baseline while diagnosing the `withObservationTracking`
    /// registration-gap race (the AccessCollector path was naturally race-free
    /// because its `context.onModify` subscriptions register synchronously
    /// inside `willAccess` rather than after the closure). Kept as a
    /// permanent regression test for the AccessCollector path, alongside the
    /// `withObservationTracking` variant above which now also passes thanks
    /// to the persistent shadow `AccessCollector` in `ObservationTracking.observe()`.
    @Test func taskIdBodiesNeverRunConcurrently_accessCollector() async {
        await ModelOption.$current.withValue([.disableObservationRegistrar]) {
            await _taskIdBodiesNeverRunConcurrentlyBody()
        }
    }

    private func _taskIdBodiesNeverRunConcurrentlyBody() async {
        let model = BodyRaceModel().withAnchor()
        // Wait for the initial body (id == 0) to fully complete before pushing more
        // changes. settle() returns when the model has been quiet for the debounce window.
        await settle { model.completed.count == 1 }

        // Rapid-fire id changes. Each change cancels the previous body and starts a new
        // one. The cancelled body's sync CPU tail and the new body's prefix overlap in
        // wall-clock time absent serialization.
        for newId in 1...10 {
            model.id = newId
            // Give the runtime a turn so the new body's iteration starts before we
            // change again — without this, coalesceUpdates (default) may collapse all
            // changes into a single emission and we never exercise the race.
            await Task.yield()
        }

        // Wait for everything to drain.
        await expect {
            model.id == 10
            model.completed.contains(10)
        }
        await settle()

        // Behaviour B assertion: bodies are strictly serialized.
        #expect(model.maxConcurrentBodies.value == 1,
                "Expected at most one body in flight at a time; observed \(model.maxConcurrentBodies.value).")
        // Sanity: the last body that ran is the one whose id won the race.
        #expect(model.completed.last == 10)
    }
}

@Model fileprivate struct BodyRaceModel {
    var id: Int = 0
    var completed: [Int] = []

    // Off-model atomic counters. Using LockIsolated keeps the read-modify-write
    // genuinely atomic regardless of how the @Model macro handles compound mutation
    // on tracked properties — the test is about body serialization, not about the
    // context lock's per-write atomicity.
    let inFlight = LockIsolated(0)
    let maxConcurrentBodies = LockIsolated(0)

    func onActivate() {
        node.task(id: id) { id in
            // Atomic increment, snapshot the post-increment count.
            let now = inFlight.withValue { value -> Int in
                value += 1
                return value
            }
            maxConcurrentBodies.withValue { max in
                if now > max { max = now }
            }

            // Suspension point: gives Task.cancel() a chance to land if id has changed.
            await Task.yield()

            // Sync CPU tail. Mimics the post-suspension tail of a real task(id:) body
            // (e.g. "write the awaited result back to the model"). No cancellation
            // observability — `Task.isCancelled` is checked nowhere in this loop, so
            // the body runs to completion regardless of cancellation. This is the
            // window in which two bodies could otherwise overlap.
            var x: UInt64 = 0
            for i in 0..<200_000 { x &+= UInt64(i) }
            blackHole(x)

            inFlight.withValue { $0 -= 1 }
            completed.append(id)
        }
    }
}

/// Prevents the compiler from optimizing away the CPU-loop result.
@inline(never)
fileprivate func blackHole<T>(_ value: T) {
    _ = value
}

/// Model that mutates `id` from `0 → 1` before its `task(id:)` body has a chance to
/// run. Exercises the cancel-before-init deadlock case in `_forEachImpl`'s
/// body-serialization logic.
@Model fileprivate struct ImmediateChangeModel {
    var id: Int = 0
    var lastSeen: Int = -1

    func onActivate() {
        node.task(id: id) { id in
            lastSeen = id
        }
    }
}
