import Foundation
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

/// Regression: child @Model property with NO default value, assigned in a user-written init.
/// Before the fix, the synthesised _modify of subscript<T:Model>(write:access:) read the
/// zero-initialised child via keyPath, trapping in KeyPath._projectReadOnly / _pop<Header>.
@Model
private struct OuterWithNoDefaultChild {
    var flag = false          // FIRST — has default
    var child: SimpleCounterModel   // no default → zero-init until assigned in init body
    var label = ""            // LAST — has default

    init(startCount: Int) {
        flag = true                           // pre-anchor write before child is set
        child = SimpleCounterModel()          // ← was the crash site
        child.count = startCount             // in-place modify of assigned child
    }
}

/// Same shape as `OuterWithNoDefaultChild`, but the no-default property is a plain
/// (non-Model) Equatable struct. Reproduces the same KeyPath._projectReadOnly trap
/// — the `subscript<T:Equatable>(write:access:)` overload (used for non-Model
/// Equatable fields) has the same zero-init read pattern as the `T: Model` overload
/// did before its fix.
///
/// Mirrors the production crash: `StreamEnvironmentModel.init(date:isPaused:)`
/// where `self.streamPlaybackState = StreamPlaybackState(...)` traps in
/// `_ModelSourceBox.subscript.modify` → `swift_readAtKeyPath` →
/// `_pop<RawKeyPathComponent.Header>` because `streamPlaybackState` is zero-init
/// until that line runs.
private struct StreamPlaybackStateMock: Hashable, Sendable {
    var startDate: Date
    var pausedOffset: Double?
    var streamOffsets: [String: Int] = [:]
}

/// Mirrors the production `StreamEnvironmentModel` shape that crashed:
/// - The no-default property is **first** in declaration order.
/// - The init body assigns *only* that one property; every other field is
///   initialised via its declaration-site default.
/// - The no-default property's type is a non-Model `Hashable`/`Sendable` struct
///   that itself contains a `Dictionary`.
///
/// The combination matters: when the user's init assigns to the first-declared
/// no-default property, Swift's init-accessor model treats that as the slot
/// being initialised — but the synthesised `_modify` for the property fires
/// against a `_ModelSourceBox` whose underlying `_State` storage is still
/// zero-initialised. Reading `reference.state[keyPath: \._State.first]` via
/// keypath traps in `_pop<RawKeyPathComponent.Header>` ("UnsafeRawBufferPointer
/// with negative count"), exactly the production stack trace.
@Model
private struct OuterFirstNoDefaultEquatable {
    var state: StreamPlaybackStateMock   // FIRST, no default
    var hasStarted = false
    var name: String = "MISSING"
    var values: [String: Double] = [:]
    var tags: Set<String> = []

    init(date: Date, isPaused: Bool = false) {
        // Exactly the production pattern — single assignment to the first
        // no-default property, no pre-touch of any other field.
        state = StreamPlaybackStateMock(startDate: date, pausedOffset: isPaused ? 0 : nil)
    }
}

/// Same shape, but the no-default-property type is a plain (non-Equatable, non-Model)
/// struct. Reproduces the same trap via the disfavoured generic
/// `subscript<T>(write:access:)` overload.
private struct OpaqueState: Sendable {
    var startDate: Date
    var pausedOffset: Double?
}

@Model
private struct OuterFirstNoDefaultGeneric {
    var state: OpaqueState   // FIRST, no default
    var hasStarted = false
    var name: String = "MISSING"

    init(date: Date, isPaused: Bool = false) {
        state = OpaqueState(startDate: date, pausedOffset: isPaused ? 0 : nil)
    }
}

/// First-declared no-default property is a tuple — exercises the
/// `subscript<each T: Equatable>(write:access:)` parameter-pack overload.
@Model
private struct OuterFirstNoDefaultTuple {
    var pair: (Int, String)   // FIRST, no default
    var flag = false
    var label = ""

    init(int: Int, string: String) {
        pair = (int, string)
    }
}

/// Type-alias wrapper that exposes `OuterFirstNoDefaultEquatable` through a
/// static-let `liveValue`, mirroring the production
/// `StreamEnvironmentModel: DependencyKey` shape that runs the model's `init`
/// inside zero-init static storage. The crash trace in the production app
/// went `liveValue.getter → one-time-init → init(date:isPaused:) → property
/// _modify → _ModelSourceBox.subscript.modify → trap`.
private enum LiveValueDependencyHost {
    static let liveValue = OuterFirstNoDefaultEquatable(date: Date(timeIntervalSince1970: 100))
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
        let m = SimpleCounterModel()
        m.count = 99
        let live = m.withAnchor()
        await expect { live.count == 99 }
    }

    @Test func preAnchorThenCustomInit() async {
        let m = ActivationCountModel(activateCount: 3)
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
        let m = MixedModel(label: "pre")
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

    /// Regression: assigning a @Model-typed var with no default in a user-written init
    /// previously trapped in KeyPath._projectReadOnly when the synthesised _modify of
    /// subscript<T:Model>(write:access:) tried to read the zero-initialised field.
    @Test func childModelNoDefaultAssignedInInit() async {
        let m = OuterWithNoDefaultChild(startCount: 7).withAnchor()
        await expect { m.flag == true }
        await expect { m.child.count == 7 }
    }

    @Test func childModelNoDefaultPreAnchorMutate() async {
        var m = OuterWithNoDefaultChild(startCount: 3)
        m.child.count = 99
        let live = m.withAnchor()
        await expect { live.child.count == 99 }
    }

    /// Production-crash reproducer: a non-Model `Equatable` property declared
    /// **first** in declaration order with no default value, where the user's
    /// init assigns only that property. Mirrors `StreamEnvironmentModel`'s
    /// shape exactly. Before the fix this trapped in
    /// `_ModelSourceBox.subscript.modify` → `swift_readAtKeyPath` →
    /// `_pop<RawKeyPathComponent.Header>` with "UnsafeRawBufferPointer
    /// with negative count" because the `subscript<T: Equatable>(write:)`
    /// overload reads `reference.state[keyPath: statePath]` against
    /// still-zero-initialised storage.
    @Test func firstNoDefaultEquatableAssignedInInit() async {
        let now = Date()
        let m = OuterFirstNoDefaultEquatable(date: now).withAnchor()
        await expect { m.state.startDate == now }
        await expect { m.hasStarted == false }
        await expect { m.name == "MISSING" }
    }

    /// Same shape, plus a subsequent `nonmutating` mutation through the
    /// fully-anchored path — confirms both the init-time _modify *and* the
    /// post-anchor _modify work for this property layout.
    @Test func firstNoDefaultEquatableMutateAfterAnchor() async {
        let m = OuterFirstNoDefaultEquatable(date: .distantPast).withAnchor()
        m.state.pausedOffset = 99
        await expect { m.state.pausedOffset == 99 }
    }

    /// Production-crash reproducer for the disfavoured generic
    /// `subscript<T>(write:)` overload (chosen for non-Equatable, non-Model,
    /// non-Container types).
    @Test func firstNoDefaultGenericAssignedInInit() async {
        let now = Date()
        let m = OuterFirstNoDefaultGeneric(date: now).withAnchor()
        await expect { m.state.startDate == now }
        await expect { m.hasStarted == false }
    }

    /// Production-crash reproducer for the `subscript<each T: Equatable>(write:)`
    /// parameter-pack overload (chosen for tuple-typed fields).
    @Test func firstNoDefaultTupleAssignedInInit() async {
        let m = OuterFirstNoDefaultTuple(int: 42, string: "ok").withAnchor()
        await expect { m.pair.0 == 42 }
        await expect { m.pair.1 == "ok" }
        await expect { m.flag == false }
    }

    /// Production-flavoured reproducer that also wraps the model behind a
    /// `DependencyKey.liveValue` static-let, matching the swift-dependencies
    /// `CachedValues` initialisation that the crash trace went through —
    /// static-let storage is zero-init, and the one-time init function runs
    /// in that zero-init region before any field has been assigned.
    @Test func firstNoDefaultEquatableViaLiveValueDependency() async {
        // Access through the dependency keypath the way StreamsDemoModel did:
        // it goes through swift-dependencies' CachedValues, hits the static
        // `liveValue` initialiser, runs `StreamEnvironmentModel(date: .now)`.
        let value = LiveValueDependencyHost.liveValue
        #expect(value.state.startDate.timeIntervalSince1970 > 0)
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
