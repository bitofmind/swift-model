import Testing
@testable import SwiftModel
import ConcurrencyExtras
import Clocks
import Foundation
import IssueReporting

// SPIKE acceptance tests for `node.onTeardown` — async work that starts when a model
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

    // Removed by the harness's own end-of-test teardown: the fade is started (not
    // dropped), but — like `onActivate` tasks — cancelled after cleanup rather than
    // reported, even when it parks on a clock nobody advances.
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
        // Cancellation reaches the parked sleep asynchronously.
        try? await waitUntil(events.count == 1)
        #expect(events.values.map { "\($0)" } == ["cancelled at 1"])
        #expect(reporter.messages.isEmpty, "\(reporter.messages)")
    }
}

// Production path (no harness): the whole tree is released, and the fade — which a
// `node.task` started from `onCancel` would lose — still runs to completion.
struct TeardownWorkReleaseTests {
    @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
    @Test func fadeRunsWhenWholeTreeIsReleased() async throws {
        let events = TestProbe()
        await waitUntilRemoved {
            PlayerHost(player: FadingPlayer(events: events)).withAnchor {
                $0.continuousClock = ImmediateClock()
            }
        }
        try await waitUntil(events.values.map { "\($0)" } == ["stopped"])
    }
}
