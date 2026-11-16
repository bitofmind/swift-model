import Testing
import Foundation
import Clocks
import AsyncAlgorithms
import ConcurrencyExtras
@testable import SwiftModel

// A plain `Task {}` has no task-executor preference, so its jobs run on the global
// executor, where the drive used to be blind to them. Third-party operators such as
// AsyncAlgorithms' `combineLatest` start such a task internally. `GlobalJobRouting`
// hands global jobs enqueued by a `.modelTesting` test to that test's drain executor,
// so `settle()` waits for them.
//
// Each test makes the off-executor step deliberately slow (a blocking delay, standing
// in for a loaded CI runner) so that, without the routing, `settle()` returns before
// the step has run and the test fails deterministically
// (`SWIFT_MODEL_ROUTE_GLOBAL_JOBS=0` turns the routing off).

/// Blocks for this long, once armed, each time `SlowHop` hands on an element.
private let hopDelay = LockIsolated<Double>(0)

/// Pass-through sequence that blocks after each upstream element while `hopDelay` is
/// set. Inside `combineLatest` its `next()` runs on combineLatest's own `Task`.
private struct SlowHop<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element: Sendable {
    typealias Element = Base.Element
    let base: Base

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        mutating func next() async throws -> Element? {
            let element = try await base.next()
            let delay = hopDelay.value
            if delay > 0 { usleep(UInt32(delay * 1_000_000)) }
            return element
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: base.makeAsyncIterator()) }
}

@Model private struct DebouncedCommitModel {
    var a = 0
    var b = 0
    var committed = 0

    func onActivate() {
        node.forEach(combineLatest(SlowHop(base: Observed { a }), Observed { b }), cancelPrevious: true) { _, _ in
            guard (try? await node.continuousClock.sleep(for: .milliseconds(250))) != nil else { return }
            committed += 1
        }
    }
}

@Model private struct PlainTaskModel {
    var value = 0

    func startWork() {
        Task {
            usleep(300_000)
            value = 1
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off), .serialized)
struct GlobalJobRoutingTests {
    /// The parallel-apple editor debounce: a write reaches a `TestClock` sleep through
    /// `combineLatest`'s own task. `settle()` must wait until the sleep is registered,
    /// or the `advance` below misses it and the commit never happens.
    @Test func settleWaitsForCombineLatestTask() async {
        let clock = TestClock()
        let model = DebouncedCommitModel().withAnchor { $0.continuousClock = clock }
        await settle()
        await clock.advance(by: .milliseconds(250))
        await expect(model.committed == 1)

        hopDelay.setValue(0.3)
        defer { hopDelay.setValue(0) }
        model.a = 1
        await settle()
        await clock.advance(by: .milliseconds(249))
        await clock.advance(by: .milliseconds(1))
        await expect(model.committed == 2)
    }

    /// A model's own `Task {}`: `settle()` waits for it to finish.
    @Test func settleWaitsForPlainTask() async {
        let model = PlainTaskModel().withAnchor()
        await settle()
        model.startWork()
        await settle()
        #expect(model.value == 1)
    }
}
