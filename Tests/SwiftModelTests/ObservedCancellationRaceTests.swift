import Testing
import ConcurrencyExtras
import Foundation
@testable import SwiftModel

/// Regression tests for the AccessCollector-path cancellation race: cancelling an
/// observer while a write storm keeps `performUpdate` in flight must not let the
/// in-flight `collector.reset` re-register `context.onModify` subscriptions. The
/// registered modifyCallback closures strongly capture the collector, so a
/// subscription that survives cancellation keeps the observer recomputing on every
/// subsequent write for the life of the context (a zombie observer feeding a
/// finished consumer).
@Suite(.backgroundCallIsolation)
struct ObservedCancellationRaceTests {
    /// Non-coalescing: performUpdate runs inline as the writer's post-lock callback,
    /// so cancel() races the re-registering reset directly on the writer threads.
    @Test func cancelDuringWriteStormStopsRecomputes_NonCoalescing() async throws {
        await runCancelStorm(useCoalescing: false)
    }

    /// Coalescing: performUpdate is queued on the background call queue, so an
    /// already-queued update can start after cancel() has completed.
    @Test func cancelDuringWriteStormStopsRecomputes_Coalescing() async throws {
        await runCancelStorm(useCoalescing: true)
    }

    private func runCancelStorm(useCoalescing: Bool) async {
        // Repeat to widen the race window: the interesting interleaving is cancel()
        // landing while a performUpdate is mid-reset, which needs the storm and the
        // cancel to genuinely overlap.
        for _ in 1...20 {
            let model = StormModel().withAnchor()
            let accessCount = LockIsolated(0)

            let (cancel, _) = update(
                initial: true,
                isSame: { $0 == $1 },
                useWithObservationTracking: false,
                useCoalescing: useCoalescing,
                access: {
                    accessCount.withValue { $0 += 1 }
                    return model.value
                },
                onUpdate: { _ in }
            )

            // Write storm racing the cancel, so cancel lands while performUpdates
            // are in flight (inline post-lock callbacks or queued background calls).
            await withTaskGroup(of: Void.self) { group in
                for i in 1...20 {
                    group.addTask { model.value = i }
                }
                group.addTask { cancel() }
                await group.waitForAll()
            }

            // Drain any performUpdate that was already scheduled when cancel won.
            // Non-coalescing updates ran inline on the (now joined) writer tasks;
            // coalesced ones sit on the isolated background call queue.
            await backgroundCall.waitUntilIdle()

            // After cancellation no subscription may remain registered, so further
            // writes must not trigger a single recompute.
            let baseline = accessCount.value
            for i in 100...120 {
                model.value = i
            }
            await backgroundCall.waitUntilIdle()

            #expect(
                accessCount.value == baseline,
                "cancelled observer recomputed on post-cancel writes (zombie subscription)"
            )
        }
    }
}

@Model private struct StormModel {
    var value = 0
}
