import Testing
import Observation
@testable import SwiftModel

@Model private struct TouchModel: Equatable {
    var count: Int = 5
    var notifications: [Int] = []

    func onActivate() {
        // Use coalesceUpdates: false (AccessCollector path) for precise per-notification tracking.
        // Parameterised tests also run with the default coalescing to exercise the
        // withObservationTracking path (via ObservationPath.observationRegistrar).
        node.forEach(Observed(initial: false, coalesceUpdates: false) { count }) { count in
            notifications.append(count)
        }
    }
}

@Model private struct TouchModelCoalescing: Equatable {
    var count: Int = 5
    var notified: Bool = false

    func onActivate() {
        // Uses default coalescing — exercises the withObservationTracking path when
        // .disableObservationRegistrar is NOT set.
        node.forEach(Observed(initial: false) { count }) { _ in
            notified = true
        }
    }
}

struct TouchTests {

    /// Verifies that writing the same Equatable value is silent by default (AccessCollector path).
    @Test func testSameValueWriteIsSilent() async {
        let (model, tester) = TouchModel().andTester(options: [.disableObservationRegistrar], exhaustivity: .off)

        // Same-value write — no notification expected
        model.count = 5

        // Give any potential notification time to arrive
        try? await Task.sleep(nanoseconds: 10_000_000)

        await tester.assert {
            model.notifications == []
            model.count == 5
        }
    }

    /// Verifies that node.touch fires an observation notification without modifying the value.
    /// Exercises both the AccessCollector path and the withObservationTracking (coalescing) path.
    @Test(arguments: ObservationPath.allCases)
    func testTouchFiresNotificationWithoutChangingValue(observationPath: ObservationPath) async {
        switch observationPath {
        case .accessCollector:
            let (model, tester) = TouchModel().andTester(options: observationPath.options, exhaustivity: .off)
            model.node.touch(\.count)
            await tester.assert {
                model.notifications == [5]
                model.count == 5
            }
        case .observationRegistrar:
            let (model, tester) = TouchModelCoalescing().andTester(options: observationPath.options, exhaustivity: .off)
            model.node.touch(\.count)
            await tester.assert {
                model.notified == true
                model.count == 5
            }
        }
    }

    /// Verifies that touch followed by a real write produces two separate notifications.
    /// Exercises both the AccessCollector path and the withObservationTracking (coalescing) path.
    @Test(arguments: ObservationPath.allCases)
    func testTouchThenRealWrite(observationPath: ObservationPath) async {
        switch observationPath {
        case .accessCollector:
            let (model, tester) = TouchModel().andTester(options: observationPath.options, exhaustivity: .off)

            model.node.touch(\.count)
            await tester.assert {
                model.notifications == [5]
            }

            model.count = 7
            await tester.assert {
                model.notifications == [5, 7]
                model.count == 7
            }
        case .observationRegistrar:
            let (model, tester) = TouchModelCoalescing().andTester(options: observationPath.options, exhaustivity: .off)

            model.node.touch(\.count)
            await tester.assert { model.notified == true }

            // Reset flag, then do a real write
            model.notified = false
            model.count = 7
            await tester.assert {
                model.notified == true
                model.count == 7
            }
        }
    }
}
