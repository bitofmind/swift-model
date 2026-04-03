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

@Suite(.modelTesting)
struct ClockTests {
    /// TestClock lets you advance time explicitly and assert intermediate states.
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test func testClockStepByStep() async {
        let clock = TestClock()
        let model = TimerModel().withAnchor {
            $0.continuousClock = clock
        }

        await clock.advance(by: .seconds(1))
        await expect(model.secondsElapsed == 1)

        await clock.advance(by: .seconds(1))
        await expect(model.secondsElapsed == 2)

        await clock.advance(by: .seconds(1))
        await expect(model.secondsElapsed == 3)
    }

    /// ImmediateClock fires all timer intervals synchronously, so the model
    /// reaches its final state without explicit clock advancement.
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test(.modelTesting(exhaustivity: .off)) func testImmediateClock() async {
        let model = TimerModel().withAnchor {
            $0.continuousClock = ImmediateClock()
        }
        // ImmediateClock drives the timer as fast as the model processes it;
        // we just need to let it settle before asserting.
        await expect(model.secondsElapsed > 0)
    }
}
