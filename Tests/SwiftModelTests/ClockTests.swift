import Testing
import SwiftModel
import SwiftModel
import Observation
import Clocks

@available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
@Model
private struct TimerModel {
    var secondsElapsed = 0

    func onActivate() {
        node.forEach(node.continuousClock.timer(interval: .seconds(1))) { _ in
            secondsElapsed += 1
        }
    }
}

// `.serialized` so the suite's three clock tests never run concurrently *with
// each other*. `testImmediateClock` drives an ImmediateClock `timer(...)`, which
// is an unbounded producer — it fires intervals as fast as the model can process
// them for the whole lifetime of the test. Running that infinite producer
// alongside the registration-sensitive `testClockStepByStep` (which needs its
// `clock.sleep` subscription to land between `advance`es) starved both under
// parallel load: the producer monopolised in-process cooperative slots while the
// step-by-step test's precise scheduling was waiting for them. Serializing the
// suite removes that intra-suite self-amplification. (The sibling load
// sensitivity in `childTasksCompleteBeforeTeardown` is addressed there by moving
// the child task's async work *onto* the drain executor so the trait cap's
// inactivity watchdog sees continuous progress; `testImmediateClock`'s unbounded
// producer can't lean on that — its `expect` resolves on the first tick and then
// an infinite stream of ticks keeps the executor busy regardless — so reducing
// its in-suite concurrency is the available test-side lever.)
@Suite(.modelTesting, .serialized)
struct ClockTests {
    /// TestClock lets you advance time explicitly and assert intermediate states.
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test func testClockStepByStep() async {
        let clock = TestClock()
        let model = TimerModel().withAnchor {
            $0.continuousClock = clock
        }
        // The `forEach(clock.timer(...))` consumer subscribes to the clock
        // lazily, on its first `next()`. Settling here (and between steps)
        // guarantees the timer has registered its next sleep *before* we
        // advance — otherwise `advance` can fire before the subscription
        // exists and that tick is lost. This is a TestClock registration
        // ordering property, not a model invariant; `settle()` is the
        // documented way to make it deterministic.
        await settle()

        await clock.advance(by: .seconds(1))
        await expect(model.secondsElapsed == 1)
        await settle()

        await clock.advance(by: .seconds(1))
        await expect(model.secondsElapsed == 2)
        await settle()

        await clock.advance(by: .seconds(1))
        await expect(model.secondsElapsed == 3)
    }

    /// ImmediateClock fires all timer intervals synchronously, so the model
    /// reaches its final state without explicit clock advancement.
    /// .removing(.state) because the timer fires indefinitely, producing a continuous
    /// stream of secondsElapsed changes that can't all be enumerated.
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test(.modelTesting(.removing(.state))) func testImmediateClock() async {
        let model = TimerModel().withAnchor {
            $0.continuousClock = ImmediateClock()
        }
        // ImmediateClock drives the timer as fast as the model processes it;
        // we just need to let it settle before asserting.
        await expect(model.secondsElapsed > 0)
    }
}
