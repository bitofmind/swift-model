import Testing
import Foundation
import Observation
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

// MARK: - Coalesced main-registrar notifications

/// `MainCallQueue.notifyRegistrar` collapses repeated off-main `willSet`/`didSet`
/// pairs for the same (context, key path) into one per drain, delivers distinct
/// pairs in first-insertion order, and places the whole bundle at the point the
/// first pair was enqueued relative to general closures.
@Suite("MainCallQueue — coalesced registrar notifications")
struct MainCallQueueCoalescingTests {

    /// Counts registrar deliveries for one key path by re-observing synchronously
    /// inside `onChange`. Every delivered `willSet` fires the live registration,
    /// which immediately re-registers, so the count equals the number of
    /// `willSet`s the registrar actually received.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    private final class DeliveryCounter: @unchecked Sendable {
        let registrar = ObservationRegistrar()
        let keyPath: KeyPath<_StateObserver<Int>, AnyHashable>
        let count = LockIsolated(0)

        init(keyPath: KeyPath<_StateObserver<Int>, AnyHashable>) {
            self.keyPath = keyPath
            observe()
        }

        func observe() {
            withObservationTracking {
                registrar.access(_StateObserver<Int>(), keyPath: keyPath)
            } onChange: { [self] in
                count.withValue { $0 += 1 }
                observe()
            }
        }
    }

    /// Coalescing is per drain cycle: pairs that arrive while main is busy collapse
    /// into one delivery. Main is held busy for the whole enqueue phase here so the
    /// burst lands in a single cycle; with main draining concurrently the same burst
    /// is delivered in as many cycles as the drain manages to interleave, each one
    /// coalesced.
    @Test func repeatedPairsForOneKeyPathDeliverOnce() async {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let queue = MainCallQueue()
        let kp: KeyPath<_StateObserver<Int>, AnyHashable> = \_StateObserver<Int>[contextID: 1, propID: 1]
        let counter = DeliveryCounter(keyPath: kp)
        nonisolated(unsafe) let kpRef = kp
        let gate = LockIsolated(false)
        let parked = LockIsolated(false)

        await Task.detached {
            // Park the drain (runs on main) until every pair below is queued, and
            // only start enqueuing once it IS parked — a pair that lands before the
            // drain takes its first batch would be delivered in that earlier cycle.
            queue { parked.setValue(true); while !gate.value { usleep(100) } }
            while !parked.value { usleep(100) }
            for _ in 0..<1_000 {
                queue.notifyRegistrar(counter.registrar, contextID: 1, keyPath: kpRef)
            }
            gate.setValue(true)
        }.value
        await queue.waitUntilIdle()

        #expect(counter.count.value == 1, "1000 off-main pairs for one key path must coalesce to one delivery, got \(counter.count.value)")
        #expect(queue.pendingCount == 0)
    }

    @Test func pendingIsBoundedByDistinctPairs() async {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let queue = MainCallQueue()
        let registrar = ObservationRegistrar()
        let kps: [KeyPath<_StateObserver<Int>, AnyHashable>] = (0..<3).map { \_StateObserver<Int>[contextID: 7, propID: UInt($0)] }
        nonisolated(unsafe) let kpsRef = kps

        // Block the drain so nothing is taken while we enqueue, then look at the depth.
        let gate = LockIsolated(false)
        await Task.detached {
            queue {
                // Runs on main; park the drain until the enqueues below are done.
                while !gate.value { usleep(100) }
            }
            for i in 0..<3_000 {
                queue.notifyRegistrar(registrar, contextID: 7, keyPath: kpsRef[i % 3])
            }
        }.value
        let depth = queue.pendingCount
        gate.setValue(true)
        await queue.waitUntilIdle()

        // One parked closure + at most one pair per distinct key path.
        #expect(depth <= 1 + 3, "queue depth must be bounded by distinct (context, key path) pairs, got \(depth)")
    }

    @Test func distinctPairsDeliverInFirstInsertionOrder() async {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let queue = MainCallQueue()
        let kps: [KeyPath<_StateObserver<Int>, AnyHashable>] = (0..<4).map { \_StateObserver<Int>[contextID: 3, propID: UInt($0)] }
        let order = LockIsolated<[Int]>([])
        // One registrar per key path so each delivery can be attributed.
        let registrars = (0..<4).map { _ in ObservationRegistrar() }
        for i in 0..<4 {
            withObservationTracking {
                registrars[i].access(_StateObserver<Int>(), keyPath: kps[i])
            } onChange: {
                order.withValue { $0.append(i) }
            }
        }
        nonisolated(unsafe) let kpsRef = kps

        await Task.detached {
            // Insert 2, 0, 3, 1 first, then repeat everything many times.
            for i in [2, 0, 3, 1] {
                queue.notifyRegistrar(registrars[i], contextID: 3, keyPath: kpsRef[i])
            }
            for _ in 0..<100 {
                for i in 0..<4 {
                    queue.notifyRegistrar(registrars[i], contextID: 3, keyPath: kpsRef[i])
                }
            }
        }.value
        await queue.waitUntilIdle()

        #expect(order.value == [2, 0, 3, 1], "pairs must fire in first-insertion order, got \(order.value)")
    }

    /// The bundle is delivered at the position of its *first* pair: a general closure
    /// enqueued before it runs first, one enqueued after it runs after — even when
    /// later pairs joined the bundle after that closure.
    @Test func bundleDeliveredAtFirstPairPosition() async {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let queue = MainCallQueue()
        let kpA: KeyPath<_StateObserver<Int>, AnyHashable> = \_StateObserver<Int>[contextID: 5, propID: 0]
        let kpB: KeyPath<_StateObserver<Int>, AnyHashable> = \_StateObserver<Int>[contextID: 5, propID: 1]
        let log = LockIsolated<[String]>([])
        let regA = ObservationRegistrar(), regB = ObservationRegistrar()
        withObservationTracking { regA.access(_StateObserver<Int>(), keyPath: kpA) } onChange: { log.withValue { $0.append("A") } }
        withObservationTracking { regB.access(_StateObserver<Int>(), keyPath: kpB) } onChange: { log.withValue { $0.append("B") } }
        nonisolated(unsafe) let a = kpA, b = kpB

        await Task.detached {
            queue { log.withValue { $0.append("c1") } }
            queue.notifyRegistrar(regA, contextID: 5, keyPath: a)
            queue { log.withValue { $0.append("c2") } }
            queue.notifyRegistrar(regB, contextID: 5, keyPath: b)
            queue { log.withValue { $0.append("c3") } }
        }.value
        await queue.waitUntilIdle()

        // c1 precedes the bundle; B joined after c2 but is delivered with A, before c2.
        #expect(log.value == ["c1", "A", "B", "c2", "c3"], "got \(log.value)")
    }

    /// On the main thread the pair fires inline, so main-thread callers keep the strict
    /// synchronous semantics of the closure form.
    ///
    /// Darwin-only: the inline path is gated on `isOnMainThread`, and on Linux the Swift
    /// concurrency runtime does not bind `@MainActor` to the OS main thread (see the
    /// note on `singleCallbackDeliveredOnMainThread`), so there the pair is queued instead.
    @Test @MainActor func onMainFiresInline() {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        #if !canImport(Darwin)
        return
        #endif
        let queue = MainCallQueue()
        let kp: KeyPath<_StateObserver<Int>, AnyHashable> = \_StateObserver<Int>[contextID: 9, propID: 0]
        let counter = DeliveryCounter(keyPath: kp)
        queue.notifyRegistrar(counter.registrar, contextID: 9, keyPath: kp)
        queue.notifyRegistrar(counter.registrar, contextID: 9, keyPath: kp)
        #expect(counter.count.value == 2)
        #expect(queue.isIdle)
    }

    /// `drainIfOnMain()` with nothing queued must not spin up state or a drain task.
    @Test @MainActor func drainIfOnMainWithNothingPendingIsANoOp() {
        let queue = MainCallQueue()
        queue.drainIfOnMain()
        #expect(queue.isIdle)
        #expect(queue.lastProgressNs == 0)
    }
}
