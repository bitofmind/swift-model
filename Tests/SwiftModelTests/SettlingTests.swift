import Testing
@testable import SwiftModel
import Observation
import Dependencies

// MARK: - Tests

@Suite(.modelTesting)
struct SettlingTests {

    // MARK: Basic settling

    @Test func settlingWaitsForActivationTask() async {
        let model = SettlingTaskModel().withAnchor()
        await settle { model.isReady == true }

        // Baseline is clean — post-settling changes are tracked normally.
        model.count += 1
        await expect { model.count == 1 }
    }

    @Test func settlingWithNoActivationTasks() async {
        let model = SettlingSyncModel().withAnchor()
        await settle { model.value == "sync" }

        model.value = "updated"
        await expect { model.value == "updated" }
    }

    // MARK: forEach patterns

    @Test func settlingWaitsForForEachTriggeredByMutation() async {
        let model = SettlingForEachModel().withAnchor()
        model.shouldLoad = true
        await settle { model.items == ["loaded"] }

        model.items.append("extra")
        await expect { model.items == ["loaded", "extra"] }
    }

    @Test func settlingWaitsForForEachWithInitialTrue() async {
        // initial: true means the forEach fires immediately during activation
        // with the current value. Settling must wait for that initial fire.
        let model = ForEachInitialModel().withAnchor()
        await settle { model.snapshots == [0] }

        model.count = 5
        await expect {
            model.count == 5
            model.snapshots == [0, 5]
        }
    }

    // MARK: Exhaustivity baseline reset

    @Test func settlingForgivesMutationsOnUnassertedProperties() async {
        let model = SettlingMultiPropertyModel().withAnchor()
        // onActivate sets both `a` and `b`. We only assert `a`.
        // Without .settling this would fail exhaustivity for `b`.
        // With .settling the baseline resets and `b` is forgiven.
        await settle { model.a == "activated" }

        // Only post-settling changes are tracked.
        model.a = "changed"
        await expect { model.a == "changed" }
    }

    @Test func settlingResetsEventBaseline() async {
        // Events sent during activation are forgiven by settling.
        let model = EventDuringActivationModel().withAnchor()
        await settle { model.activated == true }

        // Post-settling event is tracked normally.
        model.testNode.send(.userAction)
        await expect { model.didSend(.userAction) }
    }

    @Test func settlingResetsProbeBaseline() async {
        let probe = TestProbe("activationProbe")
        let model = ProbeDuringActivationModel().withAnchor {
            $0.activationProbe = probe
        }
        // onActivate calls the probe. Settling forgives that call.
        await settle { model.activated == true }

        // Post-settling probe call is tracked normally.
        probe.call("post-settling")
        await expect { probe.wasCalled(with: "post-settling") }
    }

    // MARK: Multiple concurrent tasks

    @Test func settlingWaitsForMultipleActivationTasks() async {
        let model = MultiTaskModel().withAnchor()
        // onActivate starts two concurrent tasks that each set a property.
        await settle {
            model.taskADone == true
            model.taskBDone == true
        }

        model.count += 1
        await expect { model.count == 1 }
    }

    // MARK: Child model activation

    @Test func settlingWaitsForChildActivationTasks() async {
        let model = ParentWithAsyncChild().withAnchor()
        // Parent's onActivate starts a task, and the child's onActivate
        // also starts a task. Settling must wait for both.
        await settle {
            model.parentReady == true
            model.child.childReady == true
        }

        model.child.value = "updated"
        await expect { model.child.value == "updated" }
    }

    // MARK: Task + forEach combined

    @Test func settlingWaitsForTaskAndForEachCombined() async {
        let model = TaskAndForEachModel().withAnchor()
        // onActivate starts a task that sets `taskDone = true` and a forEach that
        // counts transitions of taskDone. Due to a scheduling race, the forEach's
        // Observed stream may register before or after the task sets taskDone = true:
        //   - If it registers before: the true transition is delivered → observedCount = 1
        //   - If it registers after (common on fast hardware): the true value is the
        //     registration-time value and no transition fires → observedCount = 0
        // Either outcome is stable; settle() correctly returns in both cases.
        await settle {
            model.taskDone == true
        }
        // Don't assume a specific observedCount after settle — capture whatever it is.
        let baseCount = model.observedCount

        // Trigger one explicit taskDone transition. The forEach is now registered
        // (it started during activation), so exactly one more fire is guaranteed.
        model.taskDone = false
        await expect {
            model.taskDone == false
            model.observedCount == baseCount + 1
        }
    }

    // MARK: Sequential settling calls

    @Test func multipleSettlingCallsWork() async {
        let model = SettlingMultiPropertyModel().withAnchor()
        await settle { model.a == "activated" }

        // Second settling call after a mutation that triggers new work.
        model.a = "changed"
        // Plain expect (not settling) — should work fine after prior settle.
        await expect { model.a == "changed" }
    }

    // MARK: No-predicate settle

    @Test func settleWithoutPredicateSkipsActivation() async {
        let model = SettlingTaskModel().withAnchor()
        // No predicate — just settle and reset baseline.
        await settle()

        // Post-settle: isReady was set during activation but baseline is reset.
        // Now we can test user interactions without worrying about activation.
        model.count += 1
        await expect { model.count == 1 }
    }

    @Test func settleWithConcurrentWriterDoesNotRaceOnFrozenCopy() async {
        // Regression test for a data race between settle() (no predicates) and a
        // concurrently-running forEach body. frozenCopy reads _stateHolder outside
        // the hierarchy lock while the forEach task writes inside its own lock;
        // skipping frozenCopy when passedAccesses is empty eliminates the race.
        let model = SettleRaceOuter().withAnchor()
        await settle()

        model.trigger = true
        // settle() with no predicates must not race with the forEach body writing inner.value.
        await settle()

        await expect { model.inner.value == "iteration-99" }
    }

    // MARK: Partial exhaustivity reset

    @Test func settleResettingOnlyStateKeepsEvents() async {
        let model = EventDuringActivationModel().withAnchor()
        // Reset state only — events from activation are still tracked.
        await settle(resetting: .full.removing(.events)) { model.activated == true }

        // The .activated event sent during activation was NOT reset — assert it.
        await expect { model.didSend(.activated) }
    }

    @Test func settleResettingOnlyStateKeepsProbes() async {
        let probe = TestProbe("activationProbe")
        let model = ProbeDuringActivationModel().withAnchor {
            $0.activationProbe = probe
        }
        // Reset state only — probes from activation are still tracked.
        await settle(resetting: .full.removing(.probes)) { model.activated == true }

        // The probe call during activation was NOT reset — assert it.
        await expect { probe.wasCalled(with: "during-activation") }
    }
}

// MARK: - Test models

@Model
private struct SettlingTaskModel {
    var isReady = false
    var count = 0

    func onActivate() {
        node.task {
            isReady = true
        }
    }
}

@Model
private struct SettlingSyncModel {
    var value = "sync"
}

@Model
private struct SettlingForEachModel {
    var shouldLoad = false
    var items: [String] = []

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { shouldLoad }) { shouldLoad in
            if shouldLoad {
                items = ["loaded"]
            }
        }
    }
}

@Model
private struct ForEachInitialModel {
    var count = 0
    var snapshots: [Int] = []

    func onActivate() {
        node.forEach(Observed(initial: true, coalesceUpdates: false) { count }) { value in
            snapshots.append(value)
        }
    }
}

@Model
private struct SettlingMultiPropertyModel {
    var a = ""
    var b = ""

    func onActivate() {
        node.task {
            a = "activated"
            b = "also activated"
        }
    }
}

@Model
private struct EventDuringActivationModel {
    var activated = false

    enum Event: Equatable {
        case activated
        case userAction
    }

    var testNode: ModelNode<Self> { node }

    func onActivate() {
        node.send(.activated)
        node.task {
            activated = true
        }
    }
}

private enum ActivationProbeKey: DependencyKey {
    static let liveValue = TestProbe("default")
    static let testValue = TestProbe("test-default")
}

extension DependencyValues {
    fileprivate var activationProbe: TestProbe {
        get { self[ActivationProbeKey.self] }
        set { self[ActivationProbeKey.self] = newValue }
    }
}

@Model
private struct ProbeDuringActivationModel {
    var activated = false

    func onActivate() {
        node.task {
            @Dependency(\.activationProbe) var probe
            probe.call("during-activation")
            activated = true
        }
    }
}

@Model
private struct MultiTaskModel {
    var taskADone = false
    var taskBDone = false
    var count = 0

    func onActivate() {
        node.task("taskA") {
            taskADone = true
        }
        node.task("taskB") {
            taskBDone = true
        }
    }
}

@Model
private struct AsyncChild {
    var childReady = false
    var value = ""

    func onActivate() {
        node.task {
            childReady = true
        }
    }
}

@Model
private struct ParentWithAsyncChild {
    var parentReady = false
    var child = AsyncChild()

    func onActivate() {
        node.task {
            parentReady = true
        }
    }
}

@Model
private struct TaskAndForEachModel {
    var taskDone = false
    var observedCount = 0

    func onActivate() {
        node.task {
            taskDone = true
        }
        node.forEach(Observed(initial: false, coalesceUpdates: false) { taskDone }) { _ in
            observedCount += 1
        }
    }
}

@Model
private struct SettleRaceInner {
    var value: String = ""
}

@Model
private struct SettleRaceOuter {
    var inner = SettleRaceInner()
    var trigger = false

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { trigger }, cancelPrevious: true) { _ in
            for i in 0..<100 {
                inner.value = "iteration-\(i)"
            }
        }
    }
}

