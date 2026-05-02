import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Regression tests for MainCallQueue delivery guarantees.
///
/// The drain loop (`mainCallQueueDrainLoop`) must be `@MainActor` so that every batch —
/// including batches after the first `await Task.yield()` suspension — runs on the main
/// thread. Without the annotation, Swift resumes the loop on the cooperative pool after the
/// first yield, firing `objectWillChange.send()` off the main thread, which breaks SwiftUI
/// on the iOS 16 AccessCollector path (ViewAccess).
@Suite("MainCallQueue — main-thread delivery")
struct MainCallQueueTests {

    /// A callback enqueued from a background thread must execute on the main thread.
    /// This covers the first batch (before any yield).
    ///
    /// Note: the main-thread assertion is Darwin-only. On Linux, `@MainActor` isolation
    /// is correct but the Swift concurrency runtime does not bind the main actor to the
    /// OS main thread, so `Thread.isMainThread` returns false.
    @Test func singleCallbackDeliveredOnMainThread() async {
        let queue = MainCallQueue()
        let ranOnMain = LockIsolated(false)

        await Task.detached {
            queue {
                ranOnMain.setValue(isOnMainThread)
            }
        }.value

        await queue.waitUntilIdle()
        #if canImport(Darwin)
        #expect(ranOnMain.value, "MainCallQueue callback must run on the main thread")
        #else
        _ = ranOnMain.value  // callback fired; main-thread check skipped on Linux
        #endif
    }

    /// Multiple callbacks enqueued from a background thread across separate enqueue calls
    /// must ALL execute on the main thread, including batches delivered after `Task.yield()`
    /// inside the drain loop.
    ///
    /// This is the key regression: before the `@MainActor` fix, the drain loop lost main-actor
    /// isolation after the first yield, so subsequent batches fired off-main.
    @Test func multipleCallbacksAllDeliveredOnMainThread() async {
        let queue = MainCallQueue()
        let results = LockIsolated<[Bool]>([])

        // Enqueue a first batch from a background thread, then yield to let the drain
        // loop process it and hit its first `await Task.yield()`. Then enqueue a second
        // batch — this batch arrives while the drain loop may have already lost @MainActor
        // isolation (the regression scenario).
        await Task.detached {
            queue {
                results.withValue { $0.append(isOnMainThread) }
            }
        }.value

        // Let the drain loop process the first batch and reach Task.yield().
        await queue.waitForCurrentItems()

        // Now enqueue a second batch — this is the one the regression would deliver off-main.
        await Task.detached {
            queue {
                results.withValue { $0.append(isOnMainThread) }
            }
        }.value

        await queue.waitUntilIdle()

        let delivered = results.value
        #expect(delivered.count == 2, "Both callbacks should have been delivered")
        #if canImport(Darwin)
        #expect(delivered.allSatisfy { $0 }, "All callbacks must run on the main thread, got: \(delivered)")
        #endif
    }

    /// Verifies that when `mainCall` is used from a background thread to deliver
    /// `objectWillChange`-style notifications, all deliveries reach the main thread.
    /// This mirrors the ViewAccess code path that was broken pre-fix.
    @Test func mainCallGlobalDeliveredOnMainThread() async {
        let results = LockIsolated<[Bool]>([])

        // Simulate the ViewAccess pattern: model mutated from background → mainCall enqueue
        for _ in 0..<5 {
            await Task.detached {
                mainCall {
                    results.withValue { $0.append(isOnMainThread) }
                }
            }.value
            // Small yield to allow the drain loop to process and potentially lose isolation.
            await Task.yield()
        }

        await mainCall.waitUntilIdle()

        let delivered = results.value
        #expect(delivered.count == 5)
        #if canImport(Darwin)
        #expect(delivered.allSatisfy { $0 }, "All mainCall deliveries must be on main thread, got: \(delivered)")
        #endif
    }
}
