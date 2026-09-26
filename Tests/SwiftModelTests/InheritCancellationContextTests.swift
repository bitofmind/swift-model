import Testing
import AsyncAlgorithms
import Foundation
import ConcurrencyExtras
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
                    } onCancel: { [$cancelCount] in
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
            try await waitUntil($cancelCount.value == 1)
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

// MARK: - Keying into an already-cancelled context

/// A child is spawned first and keyed into its parent's context afterwards, so the
/// parent's context can be cancelled in between. Its cancel has then already run; the
/// late child must be cancelled at once, not left running with nothing to cancel it.
/// (`forEach(cancelPrevious:)` hit exactly this: cancelling the subscription while a body
/// had just started left the body running — `testForEachCancelPreviousInheritsContext`
/// timed out when `subscription.cancel()` landed in that window.)
struct CancelledContextKeyingTests {
    @Test func inheritingAnAlreadyCancelledContextCancelsImmediately() async throws {
        let model = InheritModel().withAnchor().testNode
        let started = AsyncChannel<Void>()
        let childCancelled = LockIsolated(false)
        let parentDone = LockIsolated(false)

        let parent = model.task {
            await started.send(())
            while !Task.isCancelled { await Task.yield() }   // our context is now cancelled
            model.onCancel { childCancelled.setValue(true) }.inheritCancellationContext()
            parentDone.setValue(true)
        }

        var it = started.makeAsyncIterator()
        await it.next()
        parent.cancel()
        try await waitUntil(parentDone.value)
        #expect(childCancelled.value)
    }

    @Test func registeringUnderACancelledOneShotContextCancelsImmediately() {
        let cancellations = Cancellations()
        let context = ContextToken()
        let inside = Recording(id: cancellations.nextId)
        AnyCancellable.$contexts.withValue([CancellableKey(key: context)]) {
            cancellations.register(inside)
        }

        cancellations.cancelAll(for: context)
        #expect(inside.cancelled.value)

        // Keyed in after the cancel (`inheritCancellationContext` / `cancel(for:)`).
        let keyedLate = Recording(id: cancellations.nextId)
        cancellations.register(keyedLate)
        cancellations.cancel(keyedLate, for: context, cancelInFlight: false)
        #expect(keyedLate.cancelled.value)

        // Registered inside the cancelled context.
        let registeredLate = Recording(id: cancellations.nextId)
        AnyCancellable.$contexts.withValue([CancellableKey(key: context)]) {
            cancellations.register(registeredLate)
        }
        #expect(registeredLate.cancelled.value)
    }

    @Test func userKeysStayReusableAfterCancelAll() {
        let cancellations = Cancellations()
        let first = Recording(id: cancellations.nextId)
        cancellations.register(first)
        cancellations.cancel(first, for: "reload", cancelInFlight: false)
        cancellations.cancelAll(for: "reload")
        #expect(first.cancelled.value)

        let second = Recording(id: cancellations.nextId)
        cancellations.register(second)
        cancellations.cancel(second, for: "reload", cancelInFlight: false)
        #expect(!second.cancelled.value)   // a user key is not one-shot
    }
}

private final class Recording: InternalCancellable, Sendable {
    let id: Int
    let cancelled = LockIsolated(false)
    init(id: Int) { self.id = id }
    func onCancel() { cancelled.setValue(true) }
}

// MARK: - Supporting types

enum InheritKey { case outer }

@Model private struct InheritModel {
    var testNode: ModelNode<Self> { node }
}
