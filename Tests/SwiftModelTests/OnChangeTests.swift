import Testing
@testable import SwiftModel
import Clocks

// MARK: - Tests

@Suite(.modelTesting)
struct OnChangeTests {

    // MARK: - task(id:) value passing

    @Test func testTaskIdPassesEmissionTimeValue() async {
        let model = TaskIdModel().withAnchor()
        // initial: true (default) → task runs immediately with current id value
        await settle { model.received == [0] }

        model.id = 42
        await expect {
            model.id == 42
            model.received == [0, 42]
        }

        model.id = 99
        await expect {
            model.id == 99
            model.received == [0, 42, 99]
        }
    }

    @Test func testTaskIdInitialFalseSkipsInitialRun() async {
        let model = TaskIdNoInitialModel().withAnchor()
        await settle {}  // No initial run expected

        model.id = 1
        await expect {
            model.id == 1
            model.received == [1]
        }

        model.id = 2
        await expect {
            model.id == 2
            model.received == [1, 2]
        }
    }

    // MARK: - onChange initial emission semantics

    @Test func testOnChangeInitialCallHasOldEqualsNew() async {
        let model = OnChangeLogModel().withAnchor()
        // initial: true (default) — first call has oldValue == newValue == current
        await settle { model.log == ["0→0"] }
    }

    @Test func testOnChangeTracksOldValueAcrossChanges() async {
        let model = OnChangeLogModel().withAnchor()
        await settle { model.log == ["0→0"] }

        model.value = 1
        await expect {
            model.value == 1
            model.log == ["0→0", "0→1"]
        }

        model.value = 2
        await expect {
            model.value == 2
            model.log == ["0→0", "0→1", "1→2"]
        }
    }

    @Test func testOnChangeInitialFalseSeededWithActivationValue() async {
        // When initial: false, the old value for the first change should be
        // the value at activation time (0), not some zero/nil default.
        let model = OnChangeNoInitialModel().withAnchor()
        await settle {}  // No initial emission expected

        model.value = 1
        await expect {
            model.value == 1
            model.log == ["0→1"]
        }

        model.value = 2
        await expect {
            model.value == 2
            model.log == ["0→1", "1→2"]
        }
    }

    // MARK: - cancelPrevious

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test func testOnChangeCancelPreviousDiscardsStalework() async {
        let clock = TestClock()
        let model = OnChangeCancelPreviousModel().withAnchor {
            $0.continuousClock = clock
        }
        // initial: false — no initial emission
        await settle {}

        // Trigger two rapid changes with coalesceUpdates: false to ensure both emit separately.
        // Task 1 starts sleeping; task 2 cancels task 1 and starts its own sleep.
        model.value = 1
        await Task.yield()
        await Task.yield()
        model.value = 2
        // clock.advance yields internally, giving the outer task a chance to process value=2,
        // cancel task 1's sleep (via CancellationError), and register task 2's sleep.
        await clock.advance(by: .seconds(1))
        await expect {
            model.value == 2
            model.completions == [2]
        }
    }

    // MARK: - removeDuplicates

    @Test func testOnChangeRemoveDuplicatesSkipsRepeatedValue() async {
        let model = OnChangeLogModel().withAnchor()
        await settle { model.log == ["0→0"] }

        model.value = 1
        await expect {
            model.value == 1
            model.log == ["0→0", "0→1"]
        }

        // Assign the same value — onChange should NOT fire again (log stays the same)
        model.value = 1
        await expect { model.value == 1 }
        #expect(model.log == ["0→0", "0→1"])
    }

    // MARK: - Two-value overloads

    @Test(arguments: UpdatePath.allCases)
    func testTaskIdTwoValuesPassesEmissionTimeValues(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { TaskIdTwoValuesModel().withAnchor() }
        await settle { model.received == [":0"] }

        model.query = "swift"
        await expect {
            model.query == "swift"
            model.received == [":0", "swift:0"]
        }

        model.filter = 1
        await expect {
            model.filter == 1
            model.received == [":0", "swift:0", "swift:1"]
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testTaskIdTwoValuesRestartsOnEitherChange(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { TaskIdTwoValuesModel().withAnchor() }
        await settle { model.received == [":0"] }

        // Changing only the second value still triggers a restart
        model.filter = 5
        await expect {
            model.filter == 5
            model.received == [":0", ":5"]
        }

        // Changing only the first value restarts again
        model.query = "test"
        await expect {
            model.query == "test"
            model.received == [":0", ":5", "test:5"]
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testOnChangeTwoValuesInitialCallFiresWithCurrentValues(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { OnChangeTwoValuesModel().withAnchor() }
        // initial: true (default) — first call fires immediately with current values
        await settle { model.log == ["(0,0)"] }
    }

    @Test(arguments: UpdatePath.allCases)
    func testOnChangeTwoValuesTracksChanges(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { OnChangeTwoValuesModel().withAnchor() }
        await settle { model.log == ["(0,0)"] }

        model.a = 1
        await expect {
            model.a == 1
            model.log == ["(0,0)", "(1,0)"]
        }

        model.b = 2
        await expect {
            model.b == 2
            model.log == ["(0,0)", "(1,0)", "(1,2)"]
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testOnChangeTwoValuesInitialFalse(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { OnChangeTwoValuesNoInitialModel().withAnchor() }
        await settle {}

        model.a = 3
        await expect {
            model.a == 3
            model.log == ["(3,0)"]
        }
    }

    // MARK: - error forwarding

    @Test func testOnChangeErrorForwardedToCatch() async {
        let model = OnChangeThrowingModel().withAnchor()
        await settle { model.log == ["ok:0→0"] }

        model.value = 1  // triggers throw
        await expect {
            model.value == 1
            model.caughtErrors == ["err:1"]
        }
    }
}

// MARK: - Test models

@Model private struct TaskIdModel {
    var id = 0
    var received: [Int] = []

    func onActivate() {
        node.task(id: id) { id in
            received.append(id)
        }
    }
}

@Model private struct TaskIdNoInitialModel {
    var id = 0
    var received: [Int] = []

    func onActivate() {
        node.task(id: id, initial: false) { id in
            received.append(id)
        }
    }
}

@Model private struct OnChangeLogModel {
    var value = 0
    var log: [String] = []

    func onActivate() {
        node.onChange(of: value) { old, new in
            log.append("\(old)→\(new)")
        }
    }
}

@Model private struct OnChangeNoInitialModel {
    var value = 0
    var log: [String] = []

    func onActivate() {
        node.onChange(of: value, initial: false) { old, new in
            log.append("\(old)→\(new)")
        }
    }
}

@available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
@Model private struct OnChangeCancelPreviousModel {
    var value = 0
    var completions: [Int] = []

    func onActivate() {
        // coalesceUpdates: false ensures both rapid changes emit separately.
        // The throwing variant with catch: { _ in } ensures CancellationError from
        // the cancelled sleep is handled properly, preventing the stale append.
        node.onChange(of: value, initial: false, coalesceUpdates: false, cancelPrevious: true, perform: { _, new in
            try await node.continuousClock.sleep(for: .seconds(1))
            completions.append(new)
        }, catch: { _ in })
    }
}

@Model private struct OnChangeThrowingModel {
    var value = 0
    var log: [String] = []
    var caughtErrors: [String] = []

    func onActivate() {
        node.onChange(of: value, perform: { old, new in
            if new > 0 { throw OnChangeTestError(value: new) }
            log.append("ok:\(old)→\(new)")
        }, catch: { error in
            if let e = error as? OnChangeTestError {
                caughtErrors.append("err:\(e.value)")
            }
        })
    }
}

private struct OnChangeTestError: Error {
    let value: Int
}

@Model private struct TaskIdTwoValuesModel {
    var query = ""
    var filter = 0
    var received: [String] = []

    func onActivate() {
        node.task(id: { (query, filter) }) { (q, f) in
            received.append("\(q):\(f)")
        }
    }
}

@Model private struct OnChangeTwoValuesModel {
    var a = 0
    var b = 0
    var log: [String] = []

    func onActivate() {
        node.onChange(of: { (a, b) }) { (a, b) in
            log.append("(\(a),\(b))")
        }
    }
}

@Model private struct OnChangeTwoValuesNoInitialModel {
    var a = 0
    var b = 0
    var log: [String] = []

    func onActivate() {
        node.onChange(of: { (a, b) }, initial: false) { (a, b) in
            log.append("(\(a),\(b))")
        }
    }
}
