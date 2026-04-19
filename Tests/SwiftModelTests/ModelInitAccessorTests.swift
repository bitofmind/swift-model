import Testing
@testable import SwiftModel

// MARK: - Test models

/// Simple model with a default-value property.
@Model
private struct SimpleCounterModel {
    var count = 0
}

/// Model with NO default value — verifies `self.prop = x` works in user-written inits.
@Model
private struct ActivationCountModel {
    var activateCount: Int

    init(activateCount: Int = 0) {
        self.activateCount = activateCount
    }
}

/// Model with multiple properties including one without a default.
@Model
private struct MultiPropModel {
    var count = 0
    var name: String
    var flag = false

    init(name: String, count: Int = 0) {
        self.name = name
        self.count = count
        // flag gets its default (false) automatically
    }
}

/// Model with didSet — verify the willSet/didSet expansion still works.
@Model
private struct ObservingModel {
    var count = 0 {
        didSet { sideEffect += 1 }
    }
    var sideEffect = 0
}

/// Mixed model: some properties with defaults, one without, no user-written init.
@Model
private struct MixedModel {
    var count = 0
    var label: String       // no default — becomes a generated-init parameter
    var flag = false
}

/// Model with a child @Model property.
@Model
private struct ParentModel {
    var counter = SimpleCounterModel()
    var label = "hello"
}

/// Model with a `let` property and an `@_ModelIgnored` stored var.
@Model
private struct LetAndIgnoredModel {
    let id: Int                    // explicit type, no default → required init param
    @_ModelIgnored var tag: String // explicit type, no default → required init param
    var count = 0                  // inferred type → NOT in init params (init accessor fires via default)
}

// MARK: - Feature models (lifecycle, events, tasks, dependencies, child)

/// Child model with lifecycle callbacks and events.
@Model
private struct ChildFeatureModel {
    var value = 0

    enum Event: Equatable {
        case bumped(Int)
    }

    func onActivate() {
        node.testResult.add("C")
        node.onCancel {
            node.testResult.add("c")
        }
    }

    func bump() {
        value += 1
        node.send(.bumped(value))
    }

    var testNode: ModelNode<Self> { node }
}

/// Top-level feature model — exercises all integration points.
@Model
private struct FeatureModel {
    var count = 0
    var taskDone = false
    var receivedEvents: [ChildFeatureModel.Event] = []
    var child = ChildFeatureModel()

    func onActivate() {
        node.testResult.add("F")
        node.onCancel {
            node.testResult.add("f")
        }
        node.task {
            node.testResult.add("task")
            taskDone = true
        }
        node.forEach(node.event(fromType: ChildFeatureModel.self)) { event, _ in
            receivedEvents.append(event)
        }
    }

    func increment() {
        count += 1
    }
}

// MARK: - Tests

/// Lifecycle test lives outside `.modelTesting` so the anchor can actually deallocate
/// when `waitUntilRemoved`'s closure exits. Inside a `.modelTesting` suite the
/// framework holds the anchor for the full test duration, which would time out.
@Test func featureLifecycle() async {
    let testResult = TestResult()
    await waitUntilRemoved {
        FeatureModel().withAnchor { $0.testResult = testResult }
    }
    #expect(testResult.value.contains("F"))
    #expect(testResult.value.contains("C"))
    #expect(testResult.value.contains("f"))
    #expect(testResult.value.contains("c"))
}

@Suite("@Model — init-accessor based storage", .modelTesting)
struct ModelInitAccessorTests {

    // MARK: Basic read/write

    @Test func defaultInit() async {
        let m = SimpleCounterModel().withAnchor()
        await expect { m.count == 0 }
    }

    @Test func setProperty() async {
        let m = SimpleCounterModel().withAnchor()
        m.count = 42
        await expect { m.count == 42 }
    }

    // MARK: Custom init

    @Test func customInitNoDefaultValue() async {
        let m = ActivationCountModel(activateCount: 7).withAnchor()
        await expect { m.activateCount == 7 }
    }

    @Test func customInitDefaultParameter() async {
        let m = ActivationCountModel().withAnchor()
        await expect { m.activateCount == 0 }
    }

    @Test func customInitMultipleProperties() async {
        let m = MultiPropModel(name: "test", count: 5).withAnchor()
        await expect { m.name == "test" }
        await expect { m.count == 5 }
        await expect { m.flag == false }
    }

    // MARK: didSet still works

    @Test func didSetFires() async {
        let m = ObservingModel().withAnchor()
        m.count = 1
        await expect { m.count == 1 && m.sideEffect == 1 }
        m.count = 2
        await expect { m.count == 2 && m.sideEffect == 2 }
    }

    // MARK: Pre-anchor mutations

    @Test func preAnchorMutation() async {
        var m = SimpleCounterModel()
        m.count = 99
        let live = m.withAnchor()
        await expect { live.count == 99 }
    }

    @Test func preAnchorThenCustomInit() async {
        var m = ActivationCountModel(activateCount: 3)
        m.activateCount = 10
        let live = m.withAnchor()
        await expect { live.activateCount == 10 }
    }

    // MARK: Mixed default / no-default with generated init

    @Test func mixedGeneratedInit() async {
        let m = MixedModel(label: "hello").withAnchor()
        await expect { m.count == 0 && m.label == "hello" && m.flag == false }
    }

    @Test func mixedGeneratedInitWithMutations() async {
        let m = MixedModel(label: "world").withAnchor()
        m.count = 7
        m.flag = true
        await expect { m.count == 7 && m.label == "world" && m.flag == true }
    }

    @Test func mixedPreAnchorMutation() async {
        var m = MixedModel(label: "pre")
        m.count = 3
        m.flag = true
        let live = m.withAnchor()
        await expect { live.count == 3 && live.label == "pre" && live.flag == true }
    }

    // MARK: Child model

    @Test func childModel() async {
        let m = ParentModel().withAnchor()
        m.counter.count = 5
        await expect { m.counter.count == 5 }
        await expect { m.label == "hello" }
    }

    // MARK: let property and @_ModelIgnored

    @Test func letPropertyInInit() async {
        let m = LetAndIgnoredModel(id: 42, tag: "hello").withAnchor()
        await expect { m.id == 42 && m.tag == "hello" && m.count == 0 }
    }

    @Test func letPropertyIsConstant() async {
        let m = LetAndIgnoredModel(id: 7, tag: "world").withAnchor()
        m.count = 99
        await expect { m.id == 7 && m.count == 99 }
    }

    // MARK: Feature integration

    @Test func featureTask() async {
        let testResult = TestResult()
        let m = FeatureModel().withAnchor { $0.testResult = testResult }
        await settle { m.taskDone == true }
        #expect(testResult.value.contains("task"))
    }

    @Test func featurePropertyWrite() async {
        let testResult = TestResult()
        let m = FeatureModel().withAnchor { $0.testResult = testResult }
        await settle { m.taskDone == true }
        m.increment()
        m.increment()
        await expect { m.count == 2 }
    }

    @Test func featureEvents() async {
        let testResult = TestResult()
        let m = FeatureModel().withAnchor { $0.testResult = testResult }
        await settle { m.taskDone == true }
        m.child.bump()
        await expect {
            m.child.value == 1
            m.child.didSend(ChildFeatureModel.Event.bumped(1))
            m.receivedEvents == [.bumped(1)]
        }
        m.child.bump()
        await expect {
            m.child.value == 2
            m.child.didSend(ChildFeatureModel.Event.bumped(2))
            m.receivedEvents == [.bumped(1), .bumped(2)]
        }
    }

    @Test func featureChildObservation() async {
        let testResult = TestResult()
        let m = FeatureModel().withAnchor { $0.testResult = testResult }
        await settle { m.taskDone == true }
        m.child.value = 42
        await expect { m.child.value == 42 }
    }
}
