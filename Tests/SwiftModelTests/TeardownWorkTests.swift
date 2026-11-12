import Testing
@testable import SwiftModel
import ConcurrencyExtras
import Clocks
import Foundation
import IssueReporting

// Tests for `node.onTeardown` — async work that starts when a model
// is deactivated and outlives it. The motivating case is an audio fade that must keep
// running after its player's model is removed (a stream switch), stepping on an
// injected clock. Started as a raw `Task` from `onCancel`, such work is invisible to
// `settle()`/`expect` and starves under parallel test load; started with `node.task`
// from `onCancel`, it is dropped because the model's store is already sealed.

@Model private struct FadingPlayer {
    let events: TestProbe

    func onActivate() {
        // Captured while live: the model is gone when the fade runs.
        let clock = node.continuousClock
        let events = events
        node.onTeardown("fade") {
            for step in 1...10 {
                do {
                    try await clock.sleep(for: .milliseconds(30))
                } catch {
                    events("cancelled at \(step)")
                    return
                }
            }
            events("stopped")
        }
    }
}

@Model private struct ReleasingPlayer {
    let released: LockIsolated<Bool>

    func onActivate() {
        let clock = node.continuousClock
        let released = released
        node.onTeardown("fade") {
            defer { released.setValue(true) }      // stop/release even when cancelled
            try? await clock.sleep(for: .seconds(1))
        }
    }
}

@Model private struct PlayerHost {
    var player: FadingPlayer?
}

@Suite(.modelTesting)
struct TeardownWorkTests {
    // A stream switch: only the player is removed. The fade parks on a frozen clock
    // and steps forward only as the test advances it — deterministic, no polling.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func fadeParksOnFrozenClockAndStepsWithIt() async {
        let clock = TestClock()
        let events = TestProbe()
        let host = PlayerHost(player: FadingPlayer(events: events)).withAnchor {
            $0.continuousClock = clock
        }

        host.player = nil
        for _ in 1...9 {
            await settle()                               // fade parked on its next sleep
            await clock.advance(by: .milliseconds(30))
        }
        await settle()
        #expect(events.count == 0)                       // one step left: still fading

        await clock.advance(by: .milliseconds(30))
        await expect(events.wasCalled(with: "stopped"))
    }

    // End of test with the fade still parked: the harness reports it as a running task
    // instead of silently leaking it.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func fadeStillRunningAtEndOfTestIsReported() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                let host = PlayerHost(player: FadingPlayer(events: TestProbe())).withAnchor {
                    $0.continuousClock = TestClock()
                }
                host.player = nil
                await settle()
            }
        }
        #expect(reporter.messages.contains { $0.contains("Active task 'fade' of `FadingPlayer` still running") })
    }

    // Removed by the harness's own end-of-test teardown: the fade starts after the
    // exhaustion check (unchecked, unreported), runs until quiet, and — parked on a
    // clock nobody advances — is then cancelled.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func fadeStartedByEndOfTestTeardownIsCancelledNotReported() async {
        let reporter = CapturingIssueReporter()
        let events = TestProbe()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                _ = PlayerHost(player: FadingPlayer(events: events)).withAnchor {
                    $0.continuousClock = TestClock()
                }
            }
        }
        #expect(events.values.map { "\($0)" } == ["cancelled at 1"])   // unwound before return
        #expect(reporter.messages.isEmpty, "\(reporter.messages)")
    }
}

extension TeardownWorkTests {
    // A fade parked at scope exit is cancelled, and its cleanup has run by the time
    // `withModelTesting` returns — no polling needed.
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func cancelledFadeHasUnwoundWhenScopeReturns() async {
        let released = LockIsolated(false)
        await withModelTesting {
            _ = ReleasingPlayer(released: released).withAnchor {
                $0.continuousClock = TestClock()
            }
        }
        #expect(released.value)
    }
}

// Production path (no harness): the whole tree is released, and the fade — which a
// `node.task` started from `onCancel` would lose — still runs to completion.
struct TeardownWorkReleaseTests {
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func fadeRunsWhenWholeTreeIsReleased() async throws {
        let events = TestProbe()
        await waitUntilRemoved {
            // Not `ImmediateClock`: its `sleep` hops through detached `.background`
            // tasks (`megaYield`), which starve under parallel load. Not a real clock
            // either: ten 30 ms wake-ups each queue for a pool thread, and on the
            // macOS TSan runner that took the test to 25 s of its 30 s `waitUntil`.
            // `InlineClock` still throws if the fade were cancelled, which is the
            // point of the test.
            PlayerHost(player: FadingPlayer(events: events)).withAnchor {
                $0.continuousClock = InlineClock()
            }
        }
        // The fade always ends with exactly one event, "stopped" or "cancelled at
        // N", so that event is the verdict. This suite has no drive, so a fixed
        // `waitUntil` budget here was a wall-clock verdict: it failed on the macOS
        // TSan runner after 30 s (5 s × scale 6) while the fade was still waiting
        // for a thread. The trait's absolute ceiling is only the hang catcher, for
        // a teardown handler that never starts.
        let hangCeilingNs = UInt64(30 * ModelTestingTraitOptions.absoluteCeilingMultiple) * 1_000_000_000
        try await waitUntil(!events.values.isEmpty, timeout: hangCeilingNs)
        #expect(events.values.map { "\($0)" } == ["stopped"])
    }
}

/// A clock whose `sleep` returns at once on the calling task, throwing only if
/// the task is cancelled.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private struct InlineClock: Clock {
    typealias Instant = ContinuousClock.Instant
    var now: Instant { ContinuousClock.now }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
    }
}
