import Testing
@testable import SwiftModel
import ConcurrencyExtras
import Clocks
import Foundation
import IssueReporting

// Tests for `onSignal` / `signal`.

private enum Lifecycle: Hashable, Sendable { case flush, leave }

@Model private struct Reporter {
    let calls: TestProbe

    func onActivate() {
        let calls = calls
        node.onSignal(Lifecycle.flush) { cause in calls("flush \(cause)") }
    }
}

@Model private struct Player {
    let calls: TestProbe

    func onActivate() {
        let calls = calls
        node.onSignal(Lifecycle.leave, once: true) { cause in calls("leave \(cause)") }
    }
}

@Model private struct AnyListener {
    let calls: TestProbe

    func onActivate() {
        let calls = calls
        node.onSignal { cause in calls("any \(cause)") }
    }
}

@Model private struct Show {
    var reporter: Reporter?
    var player: Player?
    var listener: AnyListener?
}

@Suite(.modelTesting)
struct SignalTests {
    @Test func signalReachesDescendantsAndIsAwaited() async {
        let calls = TestProbe()
        let show = Show(reporter: Reporter(calls: calls)).withAnchor()

        await show.node.signal(Lifecycle.flush)
        #expect(calls.count == 1)          // already done when signal returns
        await expect(calls.wasCalled(with: "flush requested"))
    }

    @Test func keysSelectHandlers() async {
        let calls = TestProbe()
        let show = Show(reporter: Reporter(calls: calls), player: Player(calls: calls), listener: AnyListener(calls: calls)).withAnchor()

        await show.node.signal(Lifecycle.leave)
        await expect {
            calls.wasCalled(with: "leave requested")
            calls.wasCalled(with: "any requested")
        }
    }

    @Test func unkeyedSignalReachesEveryHandler() async {
        let calls = TestProbe()
        let show = Show(reporter: Reporter(calls: calls), player: Player(calls: calls)).withAnchor()

        await show.node.signal()
        await expect {
            calls.wasCalled(with: "flush requested")
            calls.wasCalled(with: "leave requested")
        }
    }

    @Test func signalIsRepeatable() async {
        let calls = TestProbe()
        let show = Show(reporter: Reporter(calls: calls)).withAnchor()

        await show.node.signal(Lifecycle.flush)
        await show.node.signal(Lifecycle.flush)
        await expect {
            calls.wasCalled(with: "flush requested")
            calls.wasCalled(with: "flush requested")
        }
    }

    @Test func removalGivesTheFinalCall() async {
        let calls = TestProbe()
        let show = Show(reporter: Reporter(calls: calls)).withAnchor()

        show.reporter = nil
        await expect {
            show.reporter == nil
            calls.wasCalled(with: "flush removed")
        }
    }

    @Test func onceRunsOnlyOnceAcrossSignalAndRemoval() async {
        let calls = TestProbe()
        let show = Show(player: Player(calls: calls)).withAnchor()

        await show.node.signal(Lifecycle.leave)
        await show.node.signal(Lifecycle.leave)
        show.player = nil
        await settle(resetting: .off)
        await expect {
            show.player == nil
            calls.wasCalled(with: "leave requested")   // exactly once (exhaustive)
        }
    }

    @Test func reachAncestors() async {
        let calls = TestProbe()
        let parent = SignalParent(calls: calls).withAnchor()

        await parent.child.node.signal(Lifecycle.flush, to: .ancestors)
        await expect(calls.wasCalled(with: "parent flush requested"))
    }

    @Test func cancelUnregisters() async {
        let calls = TestProbe()
        let model = Cancelling(calls: calls).withAnchor()

        model.unregister()
        await model.node.signal(Lifecycle.flush)
        await settle()
        #expect(calls.count == 0)   // not on the signal, and (at end of test) not on removal
    }

    @Test func runsOfOneHandlerAreSerialized() async {
        let log = LockIsolated<[String]>([])
        let model = Serial(log: log, cancelPrevious: false).withAnchor()

        async let a: Void = model.node.signal(Lifecycle.flush)
        async let b: Void = model.node.signal(Lifecycle.flush)
        _ = await (a, b)
        #expect(log.value == ["begin", "end", "begin", "end"], "\(log.value)")
    }

    // "Let the model go at scope exit, then assert its cleanup ran": the harness's own
    // teardown runs the final call after the exhaustion check — unchecked, so the probe
    // call isn't an unasserted-probe failure — and drives it to completion.
    @Test func finalCallAtScopeExitRunsUnchecked() async {
        let reporter = CapturingIssueReporter()
        let calls = TestProbe()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                _ = Show(reporter: Reporter(calls: calls)).withAnchor()
            }
        }
        #expect(calls.values.map { "\($0)" } == ["flush removed"])
        #expect(reporter.messages.isEmpty, "\(reporter.messages)")
    }

    // Cancelling the caller of `signal` cancels the runs it started (a deadline wrapped
    // around a signal must reach the handlers).
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func cancellingTheCallerCancelsItsRuns() async {
        let log = LockIsolated<[String]>([])
        let model = Parking(log: log).withAnchor { $0.continuousClock = TestClock() }

        let caller = Task { await model.node.signal(Lifecycle.flush) }
        await settle()                                   // run 1 parked on the frozen clock
        caller.cancel()
        await caller.value
        #expect(log.value == ["park", "cancelled"])
    }

    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func cancelPreviousCancelsTheRunningOne() async {
        let log = LockIsolated<[String]>([])
        let model = Parking(log: log).withAnchor { $0.continuousClock = TestClock() }

        let first = Task { await model.node.signal(Lifecycle.flush) }
        await settle()                                   // run 1 parked on the frozen clock
        await model.node.signal(Lifecycle.flush)         // run 2 cancels it
        await first.value
        #expect(log.value == ["park", "cancelled", "run 2"])
    }
}

@Model private struct Parking {
    let log: LockIsolated<[String]>

    func onActivate() {
        let log = log
        let clock = node.continuousClock
        let runs = LockIsolated(0)
        node.onSignal(Lifecycle.flush, cancelPrevious: true) { cause in
            guard cause == .requested else { return }
            let run = runs.withValue { $0 += 1; return $0 }
            guard run == 1 else { log.withValue { $0.append("run \(run)") }; return }
            log.withValue { $0.append("park") }
            do { try await clock.sleep(for: .seconds(1)) } catch { log.withValue { $0.append("cancelled") } }
        }
    }
}

@Model private struct SignalChild {}

@Model private struct SignalParent {
    let calls: TestProbe
    var child = SignalChild()

    func onActivate() {
        let calls = calls
        node.onSignal(Lifecycle.flush) { cause in calls("parent flush \(cause)") }
    }
}

@Model private struct Cancelling {
    let calls: TestProbe
    let registration = LockIsolated<(any Cancellable)?>(nil)

    func onActivate() {
        let calls = calls
        registration.setValue(node.onSignal(Lifecycle.flush) { cause in calls("flush \(cause)") })
    }

    func unregister() { registration.value?.cancel() }
}

@Model private struct Serial {
    let log: LockIsolated<[String]>
    let cancelPrevious: Bool

    func onActivate() {
        let log = log
        node.onSignal(Lifecycle.flush, cancelPrevious: cancelPrevious) { cause in
            guard cause == .requested else { return }
            log.withValue { $0.append("begin") }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
                log.withValue { $0.append("end") }
            } catch {
                log.withValue { $0.append("cancelled") }
            }
        }
    }
}
