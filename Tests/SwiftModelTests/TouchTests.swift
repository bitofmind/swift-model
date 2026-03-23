import Testing
import Observation
@testable import SwiftModel
import SwiftModel

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

/// Model with a memoized property depending on two stored properties.
@Model private struct MemoTouchModel: Equatable {
    var a: Int = 1
    var b: Int = 2
    var notifications: [Int] = []

    var c: Int {
        node.memoize(for: "c") { a + b }
    }

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { c }) { c in
            notifications.append(c)
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct TouchTests {

    /// Verifies that writing the same Equatable value is silent by default (AccessCollector path).
    @Test func testSameValueWriteIsSilent() async {
        let model = TouchModel().withAnchor(options: [.disableObservationRegistrar])

        // Same-value write — no notification expected
        model.count = 5

        // Give any potential notification time to arrive
        try? await Task.sleep(nanoseconds: 10_000_000)

        await expect {
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
            let model = TouchModel().withAnchor(options: observationPath.options)
            model.node.touch(\.count)
            await expect {
                model.notifications == [5]
                model.count == 5
            }
        case .observationRegistrar:
            let model = TouchModelCoalescing().withAnchor(options: observationPath.options)
            model.node.touch(\.count)
            await expect {
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
            let model = TouchModel().withAnchor(options: observationPath.options)

            model.node.touch(\.count)
            await expect(model.notifications == [5])

            model.count = 7
            await expect {
                model.notifications == [5, 7]
                model.count == 7
            }
        case .observationRegistrar:
            let model = TouchModelCoalescing().withAnchor(options: observationPath.options)

            model.node.touch(\.count)
            await expect(model.notified == true)

            // Reset flag, then do a real write
            model.notified = false
            model.count = 7
            await expect {
                model.notified == true
                model.count == 7
            }
        }
    }

    /// Verifies that touch on a stored property propagates through a memoized computed property
    /// to observers of that computed property, even when the memoized value is unchanged.
    ///
    /// touch(\\.a) signals memoize's update() to bypass isSame on its next run (via forceNext).
    /// When memoize's onUpdate fires, it runs under threadLocals.forceObservation=true, so
    /// Observed { c } also bypasses its isSame check and delivers the notification.
    @Test func testTouchPropagatesThroughMemoize() async {
        let model = MemoTouchModel().withAnchor(options: [.disableObservationRegistrar])

        // Warm up the memoize cache — c == a + b == 3
        await expect(model.c == 3)

        // touch(\\.a) — a hasn't changed (still 1), but observers of c should be notified
        model.node.touch(\.a)

        await expect {
            // c is still 3, but the notification fired because force propagates through memoize
            model.notifications == [3]
            model.c == 3
        }
    }
}
