import Testing
import AsyncAlgorithms
@testable import SwiftModel
import Observation
import Foundation

struct CancellationTests {
    @Test func testDestroyCancellation() {
        @Locked var count = 0

        do {
            let model = CounterModel(count: 0).withAnchor().testNode

            model.onCancel {
                $count.wrappedValue += 5
            }
        }

        #expect(count == 5)
    }

    @Test func testDoubleDestroyCancellation() {
        @Locked var count = 0

        do {
            let model = CounterModel(count: 0).withAnchor().testNode

            model.onCancel {
                $count.wrappedValue += 5
            }

            model.onCancel {
                $count.wrappedValue += 3
            }
        }

        #expect(count == 8)
    }

    @Test func testKeyCancellation() {
        @Locked var count = 0

        do {
            let model = TwoCountersModel(counter1: CounterModel(count: 1), counter2: CounterModel(count: 2)).withAnchor()

            let counter1 = model.counter1
            let counter2 = model.counter2

            counter1.testNode.onCancel {
                $count.wrappedValue += 5
            }
            .cancel(for: CancelKey.one)

            counter2.testNode.onCancel {
                $count.wrappedValue += 3
            }
            .cancel(for: CancelKey.one)

            #expect(count == 0)
            model.testNode.cancelAll(for: CancelKey.one)
            #expect(count == 0)
            counter1.testNode.cancelAll(for: CancelKey.one)
            #expect(count == 5)
            counter2.testNode.cancelAll(for: CancelKey.one)
            #expect(count == 8)
        }

        #expect(count == 8)
    }

    @Test func testCancellationContext() {
        @Locked var count = 0

        do {
            let model = CounterModel(count: 0).withAnchor().testNode

            model.cancellationContext {
                model.onCancel {
                    $count.wrappedValue += 5
                }
            }.cancel(for: CancelKey.one)
            
            model.cancelAll(for: CancelKey.two)
            #expect(count == 0)
            model.cancelAll(for: CancelKey.one)
            #expect(count == 5)
        }

        #expect(count == 5)
    }

    @Test func testCancelInFlight() async throws {
        @Locked var count = 0
        let inHandler = AsyncChannel<()>()

        do {
            let model = CounterModel(count: 0).withAnchor().testNode

            model.task {
                try await withTaskCancellationHandler {
                    // Signal that the cancellation handler is now registered, then sleep.
                    // Using a long sleep so the task cannot complete naturally before being cancelled.
                    await inHandler.send(())
                    try await Task.sleep(nanoseconds: nanosPerSecond * 60)
                } onCancel: {
                    $count.wrappedValue += 1
                }
                $count.wrappedValue += 5
            } catch: { _ in }
            .cancel(for: CancelKey.one, cancelInFlight: true)

            // Block until the task is inside withTaskCancellationHandler with onCancel registered.
            // After this rendezvous the handler is guaranteed to be installed, so the subsequent
            // cancelInFlight call will fire onCancel { count += 1 } synchronously on this thread.
            var it = inHandler.makeAsyncIterator()
            _ = await it.next()

            #expect(count == 0)

            model.onCancel {
                $count.wrappedValue += 3
            }
            .cancel(for: CancelKey.one, cancelInFlight: true)

            // onCancel { count += 1 } fires synchronously when cancelInFlight cancels the task
            try await waitUntil(count == 1, timeout: 60_000_000_000)

            model.cancelAll(for: CancelKey.one)

            // Wait for the final cancellation handler to complete
            try await waitUntil(count == 4, timeout: 60_000_000_000)
        }

        #expect(count == 4)
    }


    @Test func testForEachCancelPrevious() async throws {
        @Locked var count = 0
        let channel = AsyncChannel<Int>()
        let sync = AsyncChannel<()>()

        let model = TwoCountersModel(counter1: CounterModel(count: 0), counter2: CounterModel(count: 1)).withAnchor().testNode

        model.forEach(channel, cancelPrevious: true) {
            $count.wrappedValue += $0
            await sync.send(())
        }
        .cancel(for: CancelKey.one)

        var it = sync.makeAsyncIterator()
        #expect(count == 0)
        await channel.send(1)
        await it.next()
        #expect(count == 1)

        await channel.send(10)
        await it.next()
        #expect(count == 11)

        await channel.send(100)
        await it.next()
        #expect(count == 111)

        model.cancelAll(for: CancelKey.one)
    }
}

enum CancelKey {
    case one, two
}

@Model private struct CounterModel {
    var count: Int

    func increment() {
        count += 1
    }

    var testNode: ModelNode<Self> { node }
}

@Model private struct TwoCountersModel {
    var counter1: CounterModel
    var counter2: CounterModel

    var testNode: ModelNode<Self> { node }
}
