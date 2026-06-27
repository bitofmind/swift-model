import Testing
import AsyncAlgorithms
import Foundation
@testable import SwiftModel

struct InheritCancellationContextTests {

    // MARK: - Basic inheritance

    /// A cancellable that inherits a cancellation context is cancelled when the
    /// outer context's key is used with cancelAll(for:).
    @Test func testInheritedCancellableIsCancelledWithContext() async throws {
        @Locked var cancelCount = 0

        do {
            let model = InheritModel().withAnchor().testNode

            // Create an outer cancellation context keyed by .outer
            _ = model.cancellationContext(for: InheritKey.outer) {
                // The inner cancellable inherits that outer context key
                model.onCancel {
                    $cancelCount.wrappedValue += 1
                }.inheritCancellationContext()
            }

            #expect(cancelCount == 0)
            // Cancelling the outer key should also cancel the inherited work
            model.cancelAll(for: InheritKey.outer)
            #expect(cancelCount == 1)
        }
    }

    /// A task that inherits a cancellation context is cancelled when the outer context is cancelled.
    @Test func testInheritedTaskIsCancelledWithContext() async throws {
        @Locked var cancelCount = 0
        let inHandler = AsyncChannel<()>()

        do {
            let model = InheritModel().withAnchor().testNode

            _ = model.cancellationContext(for: InheritKey.outer) {
                model.task {
                    try await withTaskCancellationHandler {
                        // Signal that the handler is registered before sleeping.
                        // This guarantees cancelAll below fires onCancel synchronously.
                        await inHandler.send(())
                        try await Task.sleep(nanoseconds: nanosPerSecond * 60)
                    } onCancel: {
                        $cancelCount.wrappedValue += 1
                    }
                } catch: { _ in }
                    .inheritCancellationContext()
            }

            // Block until the task is inside withTaskCancellationHandler with onCancel registered
            var it = inHandler.makeAsyncIterator()
            _ = await it.next()

            #expect(cancelCount == 0)
            model.cancelAll(for: InheritKey.outer)
            // onCancel fires synchronously since handler is registered at this point
            try await waitUntil($cancelCount.value == 1, timeout: 5_000_000_000)
        }

        #expect(cancelCount == 1)
    }

    /// Without inheritCancellationContext(), cancelling the outer key does NOT cancel the inner work.
    @Test func testWithoutInheritanceOuterCancelDoesNotReachInner() async {
        @Locked var cancelCount = 0

        do {
            let model = InheritModel().withAnchor().testNode

            _ = model.cancellationContext(for: InheritKey.outer) {
                // Note: NOT calling .inheritCancellationContext()
                model.onCancel {
                    $cancelCount.wrappedValue += 1
                }
                // (not inheriting — the onCancel above is registered under outer context
                // because it's INSIDE the cancellationContext block, NOT because of inheritCancellationContext.
                // Actually the onCancel inside a cancellationContext(for:) block IS registered under that key.
                // So we need to create the inner work OUTSIDE the block to test isolation.
            }

            // Create a second cancel handler that is NOT inside a cancellation context
            model.onCancel {
                $cancelCount.wrappedValue += 10
            }

            model.cancelAll(for: InheritKey.outer)
            // The handler inside the context block is cancelled (count == 1)
            // The handler outside is NOT cancelled (count stays at 1, not 11)
            #expect(cancelCount == 1)
        }

        // On model destruction, the remaining handler fires
        #expect(cancelCount == 11)
    }

    // MARK: - forEach with cancelPrevious uses inheritCancellationContext internally

    /// forEach(cancelPrevious: true) uses inheritCancellationContext internally so that
    /// cancelling the outer forEach also cancels in-flight per-element tasks.
    @Test func testForEachCancelPreviousInheritsContext() async throws {
        @Locked var processedCount = 0
        @Locked var interruptedBeforeWork = false
        let channel = AsyncChannel<Int>()
        let workStarted = AsyncChannel<()>()

        do {
            let model = InheritModel().withAnchor().testNode

            let subscription = model.forEach(channel, cancelPrevious: true) { value in
                await workStarted.send(())
                // Per-element work long enough that the body can ONLY finish via
                // cancellation, never via the wall clock. (The old 500 ms sleep
                // raced the fixed post-cancel wait: under parallel CI load >500 ms
                // could elapse between work-start and the assert, the sleep then
                // completed and `+= value` ran → flaky `processedCount → 1`.)
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    // Cancellation interrupted the sleep before the write below.
                    $interruptedBeforeWork.wrappedValue = true
                    throw error
                }
                $processedCount.wrappedValue += value
            } catch: { _ in }

            var startIt = workStarted.makeAsyncIterator()

            // Send first value and let it start processing.
            await channel.send(1)
            await startIt.next()

            // Cancel the forEach before processing completes.
            subscription.cancel()

            // Deterministic: wait until the in-flight body actually observes the
            // cancellation (flag set in its catch), bounded generously so a
            // saturated CI box still converges. Resolves in ms once cancellation
            // propagates; if cancellation failed to interrupt the body this times
            // out and fails — which is the real regression this test guards.
            try await waitUntil($interruptedBeforeWork.value == true, timeout: 10_000_000_000)
            // …and the cancelled body never reached its write.
            #expect(processedCount == 0)
        }
    }
}

// MARK: - Supporting types

enum InheritKey { case outer }

@Model private struct InheritModel {
    var testNode: ModelNode<Self> { node }
}
