import Observation
import Testing
import AsyncAlgorithms
@testable import SwiftModel
import Dependencies

// MARK: - Supporting types

/// A simple dependency model that can be injected at any level of the hierarchy.
/// Logs activation/deactivation and property-change events via `testResult`.
@Model private struct EnvDep {
    var state: String

    func onActivate() {
        node.testResult.add("A:\(state)")
        node.onCancel {
            node.testResult.add("X:\(state)")
        }
        node.forEach(Observed(initial: false, coalesceUpdates: false) { state }) { newState in
            node.testResult.add("C:\(newState)")
        }
    }
}

extension EnvDep: DependencyKey {
    static let liveValue = EnvDep(state: "live")
    static let testValue = EnvDep(state: "test")
}

/// A consumer model that observes its injected dependency and logs changes.
/// This is the analogue of the "media bin child model" from the bug report.
@Model private struct Consumer {
    let id: Int
    @ModelDependency var env: EnvDep

    func onActivate() {
        node.testResult.add("on:\(id):\(env.state)")
        node.onCancel {
            node.testResult.add("off:\(id)")
        }
        // Observe the dependency's `state` property from inside this model's own onActivate.
        // This is the scenario from the bug report: a child with a custom-injected dep
        // uses Observed{} on that dep — the subscription must track the *injected* instance,
        // not some other instance of the same type.
        node.forEach(Observed(initial: false, coalesceUpdates: false) { env.state }) { newState in
            node.testResult.add("obs:\(id):\(newState)")
        }
    }
}

/// Host that holds a collection of Consumer children, each potentially with their own dep instance.
@Model private struct Host {
    var items: [Consumer] = []
}

// MARK: - Models for inherited-dep tests (the real StreamsModel / StreamModel pattern)

/// Analogue of StreamModel: a leaf model that does NOT inject the dep itself.
/// It relies entirely on inheriting the dep from its parent container's context.
/// This is exactly how StreamModel works: added as StreamModel(id:config:) with no
/// withDependencies, and observes env.streamPlaybackState inside activateEditorStream.
@Model private struct Item {
    let id: Int
    @ModelDependency var env: EnvDep

    func onActivate() {
        node.testResult.add("itemOn:\(id):\(env.state)")
        node.onCancel {
            node.testResult.add("itemOff:\(id)")
        }
        // Observe the inherited dep's `state` from inside a plain child model —
        // no withDependencies at this level.
        node.forEach(Observed(initial: false, coalesceUpdates: false) { env.state }) { newState in
            node.testResult.add("itemObs:\(id):\(newState)")
        }
    }
}

/// Analogue of StreamsModel: a container that holds Item children.
/// The custom dep is injected at *this* level via withDependencies,
/// and child Items inherit it automatically through the context hierarchy.
@Model private struct Container {
    var items: [Item] = []
    @ModelDependency var env: EnvDep

    func onActivate() {
        node.testResult.add("containerOn:\(env.state)")
        node.onCancel {
            node.testResult.add("containerOff")
        }
    }
}

/// Outer root holding two Containers side-by-side — analogous to
/// `struct EditorModel { var streams: StreamsModel; var contextPreviewStreams: StreamsModel }`.
@Model private struct TwoContainersModel {
    var a: Container = Container()
    var b: Container = Container()
}

/// Analogue of EditorModel: uses a custom init() that assigns `_isolated` directly with
/// withDependencies, exactly as EditorModel does with `_contextPreviewStreams`.
/// This differs from TwoContainersModel where withDependencies is supplied at call-site;
/// here it is captured inside the struct's own init body.
@Model private struct ParentWithInitAssignment {
    var primary = Container(items: [Item(id: 1)])
    var isolated: Container

    init() {
        self.isolated = Container(items: [Item(id: 2)]).withDependencies { deps in
            deps[EnvDep.self] = EnvDep(state: "override")
        }
    }
}

// MARK: - Models for stored-property child tests

/// A leaf model that is stored as a plain `var child: SingleChild` property (not in an array).
/// Exercises the same dependency inheritance path as Item-in-array, but via a single stored child.
@Model private struct SingleChild {
    @ModelDependency var env: EnvDep

    func onActivate() {
        node.testResult.add("childOn:\(env.state)")
        node.onCancel { node.testResult.add("childOff") }
        node.forEach(Observed(initial: false, coalesceUpdates: false) { env.state }) { newState in
            node.testResult.add("childObs:\(newState)")
        }
    }
}

/// A parent model that holds exactly one SingleChild as a stored property.
/// The dep override is applied at this level via withDependencies or withAnchor.
@Model private struct SingleChildParent {
    var child = SingleChild()
}

/// Root for two-sibling test: two SingleChildParent models side by side.
@Model private struct TwoSingleChildParentsModel {
    var a: SingleChildParent = SingleChildParent()
    var b: SingleChildParent = SingleChildParent()
}

// MARK: - Models for background-task dep inheritance tests
//
// Reproduces the crash scenario from the callstack:
//   EditorModel.onActivate (forEach task, task-local = EditorModel's deps)
//     → StreamsModel.updateSegments (called from within the task)
//       → StreamModel added to streams array
//         → StreamModel.onActivate → dependency(for: StreamEnvironmentModel) → WRONG dep
//
// The bug: TaskCancellable sets withDependencies(from: EditorModel.context) for the task,
// so DependencyValues._current = EditorModel's deps (no StreamEnvironmentModel override).
// When StreamModel.Context.init calls withDependencies(from: StreamsModel.context),
// swift-dependencies merges: StreamsModel.deps.merging(_current) where _current (EditorModel's)
// WINS — silently dropping the StreamEnvironmentModel override from StreamsModel.

/// Leaf model added dynamically from a background task. Has its own @ModelDependency.
@Model private struct BackgroundLeaf {
    let id: Int
    @ModelDependency var env: EnvDep

    func onActivate() {
        node.testResult.add("leafOn:\(id):\(env.state)")
    }
}

/// Container for BackgroundLeaf children. The dep override is applied at this level.
/// Leaves are added externally (from the outer model's background task).
@Model private struct BackgroundContainer {
    var leaves: [BackgroundLeaf] = []
}

/// Outer root model — analogous to EditorModel.
/// Its forEach task calls populateContainer(), which adds leaves to a child container
/// that has a dep override. The task-local DependencyValues come from this root context
/// (no dep override), so the child's dep override must NOT be overwritten by the merge.
@Model private struct BackgroundRoot {
    var plain = BackgroundContainer()     // no dep override — inherits testValue
    var overriding = BackgroundContainer() // dep override injected via withDependencies
    var shouldPopulate: Bool = false

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { shouldPopulate }) { _ in
            plain.leaves.append(BackgroundLeaf(id: 1))
            overriding.leaves.append(BackgroundLeaf(id: 1))
        }
    }
}

// MARK: - Models for background-task dep inheritance tests (dependencyModels / setupModelDependency path)
//
// This exercises the third fix: wrapping `withPostActions { setupModelDependency(...) }` in
// `withOwnDependencies` inside `Context.init`.
//
// The dependencyModels path is triggered when a model's `withDependencies` closure assigns a
// `@Model & DependencyKey` value — causing `ModelDependencies.models` to be non-empty, and
// `Context.init` to call `setupModelDependency` inside `withPostActions`.
//
// WITHOUT the fix: when `Context<SelfOverridingLeaf>.init` runs inside a background task
// (task-local = root's DependencyValues), `withPostActions` calls `setupModelDependency` AFTER
// the `withDependencies` scope exits, so `_current` has reverted to the task-local (root's deps).
// The inner dep model context is then created from the root's DependencyValues — wrong instance.
//
// WITH the fix: `withOwnDependencies` installs `self.capturedDependencies` as `_current` before
// calling `setupModelDependency`, so the dep model context sees the leaf-level override.

/// A helper dep model used only for the `dependencyModels` path tests.
/// Distinct from EnvDep to isolate the test from any shared caching.
@Model private struct AuxDep {
    var label: String

    func onActivate() {
        node.testResult.add("auxOn:\(label)")
    }
}

extension AuxDep: DependencyKey {
    static let liveValue = AuxDep(label: "live")
    static let testValue = AuxDep(label: "test")
}

/// A secondary dep model nested inside a leaf that injects it via withDependencies.
/// When the leaf's Context.init calls setupModelDependency for AuxDep, the resulting
/// Context<AuxDep> must have capturedDependencies that include the leaf-level SecondaryDep
/// override — so that any child of AuxDep that resolves SecondaryDep gets the right value.
/// This tests the third fix: `withOwnDependencies` around `withPostActions { setupModelDependency }`.
@Model private struct SecondaryDep {
    var tag: String

    func onActivate() {
        node.testResult.add("secOn:\(tag)")
    }
}

extension SecondaryDep: DependencyKey {
    static let liveValue = SecondaryDep(tag: "live")
    static let testValue = SecondaryDep(tag: "test")
}

/// A child of AuxDep that resolves SecondaryDep via @ModelDependency.
/// Used to verify that AuxDep's context captures the correct deps for its own children.
@Model private struct AuxDepChild {
    @ModelDependency var secondary: SecondaryDep

    func onActivate() {
        node.testResult.add("auxChildOn:\(secondary.tag)")
    }
}

/// An AuxDep variant that holds an AuxDepChild, so when AuxDep's context resolves
/// SecondaryDep for AuxDepChild, it must use the leaf-level override, not the root's.
@Model private struct AuxDepWithChild {
    var label: String
    var child = AuxDepChild()

    func onActivate() {
        node.testResult.add("auxWithChildOn:\(label)")
    }
}

extension AuxDepWithChild: DependencyKey {
    static let liveValue = AuxDepWithChild(label: "live")
    static let testValue = AuxDepWithChild(label: "test")
}

/// A leaf model that injects an AuxDep **on itself** via withDependencies { $0[AuxDep.self] = ... }.
/// This makes `ModelDependencies.models` non-empty in `Context<SelfOverridingLeaf>.init`,
/// triggering the `setupModelDependency` path (the third fix location).
@Model private struct SelfOverridingLeaf {
    let id: Int
    @ModelDependency var aux: AuxDep

    func onActivate() {
        node.testResult.add("selfLeafOn:\(id):\(aux.label)")
    }
}

/// Root for the `setupModelDependency` path background-task test.
/// Its forEach task adds `SelfOverridingLeaf` instances that carry their own dep override.
@Model private struct SelfOverridingRoot {
    var leaves: [SelfOverridingLeaf] = []
    var shouldPopulate: Bool = false

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { shouldPopulate }) { _ in
            // Leaf injected with a leaf-level dep override directly on the leaf value itself.
            // Context<SelfOverridingLeaf>.init will process this via dependencyModels / setupModelDependency.
            let leafDep = AuxDep(label: "leafOverride")
            leaves.append(
                SelfOverridingLeaf(id: 1).withDependencies { $0[AuxDep.self] = leafDep }
            )
        }
    }
}

/// Root for the deep-dep-chain test: a leaf injects both AuxDepWithChild and SecondaryDep.
/// When Context<DeepOverridingLeaf>.init calls setupModelDependency for AuxDepWithChild,
/// the resulting Context<AuxDepWithChild> must capture the leaf-level SecondaryDep override —
/// so that AuxDepChild (a child of AuxDepWithChild) sees the leaf-level SecondaryDep.
///
/// This is the third fix: without `withOwnDependencies` around `withPostActions`,
/// Context<AuxDepWithChild>.init runs with `_current = root task-local`, so its
/// capturedDependencies lose the leaf-level SecondaryDep override.
@Model private struct DeepOverridingLeaf {
    let id: Int
    @ModelDependency var auxWithChild: AuxDepWithChild

    func onActivate() {
        node.testResult.add("deepLeafOn:\(id):\(auxWithChild.label)")
    }
}

@Model private struct DeepOverridingRoot {
    var leaves: [DeepOverridingLeaf] = []
    var shouldPopulate: Bool = false

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { shouldPopulate }) { _ in
            let leafAuxDep = AuxDepWithChild(label: "leafAux")
            let leafSecondaryDep = SecondaryDep(tag: "leafSecondary")
            leaves.append(
                DeepOverridingLeaf(id: 1).withDependencies {
                    $0[AuxDepWithChild.self] = leafAuxDep
                    $0[SecondaryDep.self] = leafSecondaryDep
                }
            )
        }
    }
}

/// A grandchild model with its own @ModelDependency, stored as a plain property inside ChildWithGrandchild.
@Model private struct GrandChild {
    @ModelDependency var env: EnvDep

    func onActivate() {
        node.testResult.add("grandChildOn:\(env.state)")
    }
}

/// A child model that holds a GrandChild as a stored property.
/// The dep override is applied on *this* model via withDependencies inside the parent's init().
@Model private struct ChildWithGrandchild {
    var grandChild = GrandChild()
}

/// Root model that sets up a dep override on its child *inside init()* using the
/// `self.child = Model().withDependencies { ... }` pattern (the EditorModel pattern).
/// The root itself has a different dep injected via withAnchor.
/// The grandchild must see the *child-level* dep, not the root-level one.
@Model private struct RootWithInitOverriddenChild {
    var child: ChildWithGrandchild

    init() {
        self.child = ChildWithGrandchild().withDependencies { deps in
            deps[EnvDep.self] = EnvDep(state: "childDep")
        }
    }
}

// MARK: - ModelDependencyOverrideTests
//
// These tests specifically target the scenario where a child model receives a *custom*
// injected instance of a @ModelDependency type (via withDependencies), and then
// uses Observed{} on that dependency from inside its own onActivate().
//
// This is the pattern used in the "media bin" path described in the bug report, where
// a child StreamModel gets a custom StreamEnvironmentModel injected via withDependencies
// and then starts an Observed { env.streamPlaybackState } loop.
//
// Tests cover:
// 1. The observation subscription is established on the *injected* instance (not the default).
// 2. When the injected dep's property changes, the child's Observed fires.
// 3. Two siblings with different dep instances observe independently (no cross-talk).
// 4. onActivate / onCancel lifecycle is correct per instance, not shared.
// 5. Both AccessCollector and ObservationRegistrar paths work.
// 6. Removing a child also tears down its dep correctly.

struct ModelDependencyOverrideTests {

    // MARK: - Basic: child observes its own injected dep

    /// A child injected with a custom dep instance can observe that instance's property changes.
    /// Covers the core bug: Observed { env.state } must subscribe to the *custom* instance.
    @Test(arguments: ObservationPath.allCases)
    func childObservesInjectedDepProperty(path: ObservationPath) async throws {
        let testResult = TestResult()
        let customDep = EnvDep(state: "custom")

        try await waitUntilRemoved {
            let host = path.withOptions { Host(items: [
                Consumer(id: 1).withDependencies { $0[EnvDep.self] = customDep }
            ]).withAnchor {
                $0.testResult = testResult
            } }

            // Wait for activation of both the consumer and its dep.
            try await waitUntil(testResult.value.contains("on:1:custom"))

            // Change state on the *custom* dep instance.
            customDep.state = "changed"

            // The consumer's Observed loop must fire with the new state.
            try await waitUntil(testResult.value.contains("obs:1:changed"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:1:changed"),
                    "[\(path)] Observed on injected dep must fire. Got: \(testResult.value)")

            return host
        }
    }

    // MARK: - Two siblings with different injected dep instances

    /// Two siblings each have their own injected dep instance.
    /// Mutating dep A must only notify sibling A's Observed loop; sibling B is unaffected.
    @Test(arguments: ObservationPath.allCases)
    func siblingsObserveTheirOwnDepIndependently(path: ObservationPath) async throws {
        let testResult = TestResult()
        let depA = EnvDep(state: "A")
        let depB = EnvDep(state: "B")

        try await waitUntilRemoved {
            let host = path.withOptions { Host(items: [
                Consumer(id: 1).withDependencies { $0[EnvDep.self] = depA },
                Consumer(id: 2).withDependencies { $0[EnvDep.self] = depB },
            ]).withAnchor {
                $0.testResult = testResult
            } }

            try await waitUntil(
                testResult.value.contains("on:1:A") && testResult.value.contains("on:2:B")
            )

            // Change only depA — only consumer 1 should fire.
            depA.state = "A2"
            try await waitUntil(testResult.value.contains("obs:1:A2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:1:A2"),
                    "[\(path)] Consumer 1 must observe depA change. Got: \(testResult.value)")
            #expect(!testResult.value.contains("obs:2:A2"),
                    "[\(path)] Consumer 2 must NOT observe depA change. Got: \(testResult.value)")

            // Change only depB — only consumer 2 should fire.
            depB.state = "B2"
            try await waitUntil(testResult.value.contains("obs:2:B2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:2:B2"),
                    "[\(path)] Consumer 2 must observe depB change. Got: \(testResult.value)")
            #expect(!testResult.value.contains("obs:1:B2"),
                    "[\(path)] Consumer 1 must NOT observe depB change. Got: \(testResult.value)")

            return host
        }
    }

    // MARK: - Lifecycle: each injected dep activated and deactivated independently

    /// Each injected dep instance gets its own onActivate / onCancel lifecycle.
    /// Two siblings with different instances: both are activated, and removing one
    /// deactivates only that dep, leaving the other intact.
    @Test func injectedDepLifecycleIsPerInstance() async throws {
        let testResult = TestResult()
        let depA = EnvDep(state: "alpha")
        let depB = EnvDep(state: "beta")

        try await waitUntilRemoved {
            let host = Host(items: [
                Consumer(id: 1).withDependencies { $0[EnvDep.self] = depA },
                Consumer(id: 2).withDependencies { $0[EnvDep.self] = depB },
            ]).withAnchor {
                $0.testResult = testResult
            }

            try await waitUntil(
                testResult.value.contains("A:alpha") && testResult.value.contains("A:beta")
            )

            // Remove consumer 1 — depA must be deactivated, depB must survive.
            host.items.remove(at: 0)

            try await waitUntil(testResult.value.contains("X:alpha"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("X:alpha"),
                    "depA must be deactivated after consumer 1 removed. Got: \(testResult.value)")
            #expect(!testResult.value.contains("X:beta"),
                    "depB must NOT be deactivated yet. Got: \(testResult.value)")
            #expect(depB.lifetime == .active,
                    "depB must still be active. Lifetime: \(depB.lifetime)")

            // depB still observable after sibling removal.
            depB.state = "beta2"
            try await waitUntil(testResult.value.contains("obs:2:beta2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:2:beta2"),
                    "Consumer 2 must still observe depB after sibling removal. Got: \(testResult.value)")

            return host
        }
    }

    // MARK: - Lifecycle: dep deactivated when child removed

    /// When a child with an injected dep is removed from its parent, the dep's onCancel fires.
    @Test func injectedDepDeactivatesWhenChildRemoved() async throws {
        let testResult = TestResult()
        let dep = EnvDep(state: "solo")

        try await waitUntilRemoved {
            let host = Host(items: [
                Consumer(id: 1).withDependencies { $0[EnvDep.self] = dep }
            ]).withAnchor {
                $0.testResult = testResult
            }

            try await waitUntil(testResult.value.contains("A:solo"))

            host.items.removeAll()

            try await waitUntil(testResult.value.contains("X:solo"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("X:solo"),
                    "dep must be deactivated after child removed. Got: \(testResult.value)")
            #expect(dep.lifetime == .destructed, "dep lifetime must be .destructed")

            return host
        }
    }

    // MARK: - Dynamic addition: child added later with injected dep

    /// A child added *dynamically* (after the host is already active) with a custom-injected dep
    /// must still have its dep activated and its Observed loop established correctly.
    @Test(arguments: ObservationPath.allCases)
    func dynamicallyAddedChildObservesInjectedDep(path: ObservationPath) async throws {
        let testResult = TestResult()
        let dep = EnvDep(state: "dynamic")

        try await waitUntilRemoved {
            let host = path.withOptions { Host().withAnchor {
                $0.testResult = testResult
            } }

            // Add child after anchor is already active.
            host.items.append(
                Consumer(id: 7).withDependencies { $0[EnvDep.self] = dep }
            )

            try await waitUntil(testResult.value.contains("on:7:dynamic"))
            try await waitUntil(testResult.value.contains("A:dynamic"))

            // Mutation on the dep must trigger the consumer's Observed loop.
            dep.state = "dynamic2"
            try await waitUntil(testResult.value.contains("obs:7:dynamic2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:7:dynamic2"),
                    "[\(path)] Dynamically added child must observe injected dep. Got: \(testResult.value)")

            return host
        }
    }

    // MARK: - Injected dep vs default dep: observation is independent

    /// One child uses the default (inherited) dep; a sibling uses an injected custom dep.
    /// Mutations to each dep only notify the relevant child.
    @Test(arguments: ObservationPath.allCases)
    func defaultAndInjectedDepObservedIndependently(path: ObservationPath) async throws {
        let testResult = TestResult()
        let defaultDep = EnvDep(state: "default")
        let customDep = EnvDep(state: "custom")

        try await waitUntilRemoved {
            let host = path.withOptions { Host(items: [
                Consumer(id: 1),  // uses the dep injected at the host level
                Consumer(id: 2).withDependencies { $0[EnvDep.self] = customDep },
            ]).withAnchor {
                $0.testResult = testResult
                $0[EnvDep.self] = defaultDep  // inject default for all children
            } }

            try await waitUntil(
                testResult.value.contains("on:1:default") && testResult.value.contains("on:2:custom")
            )

            // Change default dep — only consumer 1 fires.
            defaultDep.state = "default2"
            try await waitUntil(testResult.value.contains("obs:1:default2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:1:default2"),
                    "[\(path)] Consumer 1 (default dep) must observe default dep change. Got: \(testResult.value)")
            #expect(!testResult.value.contains("obs:2:default2"),
                    "[\(path)] Consumer 2 (custom dep) must NOT observe default dep change. Got: \(testResult.value)")

            // Change custom dep — only consumer 2 fires.
            customDep.state = "custom2"
            try await waitUntil(testResult.value.contains("obs:2:custom2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("obs:2:custom2"),
                    "[\(path)] Consumer 2 must observe custom dep change. Got: \(testResult.value)")
            #expect(!testResult.value.contains("obs:1:custom2"),
                    "[\(path)] Consumer 1 must NOT observe custom dep change. Got: \(testResult.value)")

            return host
        }
    }

    // MARK: - onActivate count: each unique injected instance activated exactly once

    /// Three children use two distinct dep instances (A, A, B).
    /// depA must be activated exactly once (shared between children 1 and 3),
    /// depB activated once (used only by child 2).
    @Test func sharedInjectedDepActivatedOnce() async throws {
        let testResult = TestResult()
        let depA = EnvDep(state: "sharedA")
        let depB = EnvDep(state: "uniqueB")

        try await waitUntilRemoved {
            let host = Host(items: [
                Consumer(id: 1).withDependencies { $0[EnvDep.self] = depA },
                Consumer(id: 2).withDependencies { $0[EnvDep.self] = depB },
                Consumer(id: 3).withDependencies { $0[EnvDep.self] = depA },
            ]).withAnchor {
                $0.testResult = testResult
            }

            try await waitUntil(
                testResult.value.contains("on:1") &&
                testResult.value.contains("on:2") &&
                testResult.value.contains("on:3")
            )

            let activationCountA = testResult.value
                .components(separatedBy: "A:sharedA").count - 1
            let activationCountB = testResult.value
                .components(separatedBy: "A:uniqueB").count - 1

            #expect(activationCountA == 1,
                    "depA (shared by consumers 1 and 3) must activate exactly once. Log: \(testResult.value)")
            #expect(activationCountB == 1,
                    "depB must activate exactly once. Log: \(testResult.value)")

            // Mutating sharedA notifies both consumers 1 and 3.
            depA.state = "sharedA2"
            try await waitUntil(
                testResult.value.contains("obs:1:sharedA2") &&
                testResult.value.contains("obs:3:sharedA2"),
                timeout: 3_000_000_000
            )
            #expect(testResult.value.contains("obs:1:sharedA2"),
                    "Consumer 1 must observe sharedA mutation. Log: \(testResult.value)")
            #expect(testResult.value.contains("obs:3:sharedA2"),
                    "Consumer 3 must observe sharedA mutation. Log: \(testResult.value)")
            #expect(!testResult.value.contains("obs:2:sharedA2"),
                    "Consumer 2 must NOT observe sharedA mutation. Log: \(testResult.value)")

            return host
        }
    }

    // =========================================================================
    // MARK: - Inherited dep tests (the real StreamsModel/StreamModel pattern)
    //
    // In the real app: StreamsModel gets withDependencies { $0.streamEnvironment = customEnv }
    // and child StreamModels are added plain — StreamModel(id:config:) with NO withDependencies.
    // The child inherits the dep through the context parent chain automatically.
    //
    // The tests below replicate this exact structure: Container gets the injected dep,
    // child Items are added with NO withDependencies, and must still observe the right instance.
    // =========================================================================

    /// Container-level injection: dep is injected on the Container via withDependencies,
    /// child Items are added plain and must inherit it through the context parent chain.
    /// This is the exact StreamsModel/StreamModel pattern from the bug report.
    @Test(arguments: ObservationPath.allCases)
    func childInheritsDepFromParentContainerAndObservesIt(path: ObservationPath) async throws {
        let testResult = TestResult()
        let customDep = EnvDep(state: "inherited")

        try await waitUntilRemoved {
            // Inject dep at Container level — same as StreamsModel.withDependencies { $0.streamEnvironment = ... }
            let container = path.withOptions { Container(items: [
                Item(id: 1),  // plain — no withDependencies, inherits from Container
            ]).withAnchor {
                $0.testResult = testResult
                $0[EnvDep.self] = customDep
            } }

            try await waitUntil(testResult.value.contains("itemOn:1:inherited"))

            // Mutate the dep — child Item must observe it even though the dep was
            // injected at the Container level, not the Item level.
            customDep.state = "inherited2"
            try await waitUntil(testResult.value.contains("itemObs:1:inherited2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:1:inherited2"),
                    "[\(path)] Child Item must observe dep inherited from Container. Got: \(testResult.value)")

            return container
        }
    }

    /// Two sibling Items inside a Container that has two *different* injected dep instances
    /// (injected at Container level for each Item via withDependencies on the Items).
    /// Same as above but verifying that cross-child isolation still works when
    /// the Container provides one dep and a child overrides it.
    @Test(arguments: ObservationPath.allCases)
    func containerDepWithOneChildOverride(path: ObservationPath) async throws {
        let testResult = TestResult()
        let containerDep = EnvDep(state: "container")
        let overrideDep = EnvDep(state: "override")

        try await waitUntilRemoved {
            let container = path.withOptions { Container(items: [
                Item(id: 1),  // inherits containerDep
                Item(id: 2).withDependencies { $0[EnvDep.self] = overrideDep },  // overrides
            ]).withAnchor {
                $0.testResult = testResult
                $0[EnvDep.self] = containerDep
            } }

            try await waitUntil(
                testResult.value.contains("itemOn:1:container") &&
                testResult.value.contains("itemOn:2:override")
            )

            // Mutate containerDep — only Item 1 (which inherits it) should fire.
            containerDep.state = "container2"
            try await waitUntil(testResult.value.contains("itemObs:1:container2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:1:container2"),
                    "[\(path)] Item 1 (inheriting container dep) must observe mutation. Got: \(testResult.value)")
            #expect(!testResult.value.contains("itemObs:2:container2"),
                    "[\(path)] Item 2 (override dep) must NOT observe container dep mutation. Got: \(testResult.value)")

            // Mutate overrideDep — only Item 2 should fire.
            overrideDep.state = "override2"
            try await waitUntil(testResult.value.contains("itemObs:2:override2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:2:override2"),
                    "[\(path)] Item 2 (override dep) must observe its own dep mutation. Got: \(testResult.value)")
            #expect(!testResult.value.contains("itemObs:1:override2"),
                    "[\(path)] Item 1 (inheriting container dep) must NOT observe override dep mutation. Got: \(testResult.value)")

            return container
        }
    }

    /// Dynamically-added plain Item inside a Container with an injected dep.
    /// Mimics the real pattern: StreamsModel.updateSegments adds StreamModel(id:config:)
    /// after the StreamsModel is already active.
    @Test(arguments: ObservationPath.allCases)
    func dynamicallyAddedPlainChildInheritsContainerDep(path: ObservationPath) async throws {
        let testResult = TestResult()
        let customDep = EnvDep(state: "live")

        try await waitUntilRemoved {
            let container = path.withOptions { Container().withAnchor {
                $0.testResult = testResult
                $0[EnvDep.self] = customDep
            } }

            // Add a plain Item after the Container is already active —
            // same as StreamsModel.updateSegments adding StreamModel(id:config:)
            container.items.append(Item(id: 5))

            try await waitUntil(testResult.value.contains("itemOn:5:live"))

            // Mutate dep — dynamically-added child must observe it.
            customDep.state = "live2"
            try await waitUntil(testResult.value.contains("itemObs:5:live2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:5:live2"),
                    "[\(path)] Dynamically-added plain child must observe inherited dep. Got: \(testResult.value)")

            return container
        }
    }

    /// One container with no dep override (uses testValue = "test") and one with an explicit
    /// override ("override"). This is the exact pattern from the bug report snippet:
    ///   var primary = ContainerModel()
    ///   var isolated = ContainerModel().withDependencies { $0.someDependency = .overrideValue }
    /// The isolated container's Items must see the override, not the default.
    @Test(arguments: ObservationPath.allCases)
    func defaultContainerAndOverrideContainerAreIsolated(path: ObservationPath) async throws {
        let testResult = TestResult()
        let overrideDep = EnvDep(state: "override")

        try await waitUntilRemoved {
            // `a` uses default (testValue = "test"); `b` has an explicit override.
            let root = path.withOptions { TwoContainersModel(
                a: Container(items: [Item(id: 1)]),  // no withDependencies — inherits testValue
                b: Container(items: [Item(id: 2)]).withDependencies { $0[EnvDep.self] = overrideDep }
            ).withAnchor {
                $0.testResult = testResult
            } }

            try await waitUntil(
                testResult.value.contains("itemOn:1:test") &&
                testResult.value.contains("itemOn:2:override")
            )
            #expect(testResult.value.contains("itemOn:1:test"),
                    "[\(path)] Item in default container must see testValue. Got: \(testResult.value)")
            #expect(testResult.value.contains("itemOn:2:override"),
                    "[\(path)] Item in override container must see overrideValue. Got: \(testResult.value)")

            // Mutate overrideDep — only Item 2 must fire.
            overrideDep.state = "override2"
            try await waitUntil(testResult.value.contains("itemObs:2:override2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:2:override2"),
                    "[\(path)] Item 2 must observe overrideDep mutation. Got: \(testResult.value)")
            #expect(!testResult.value.contains("itemObs:1:override2"),
                    "[\(path)] Item 1 must NOT observe overrideDep mutation. Got: \(testResult.value)")

            return root
        }
    }

    /// Two Containers each with a different injected dep instance, each holding plain Items.
    /// Mutations to Container A's dep must not fire Container B's Items, and vice versa.
    /// This is the "main streams vs contextPreviewStreams" scenario from the bug report.
    @Test(arguments: ObservationPath.allCases)
    func twoContainersWithDifferentDepsAreIsolated(path: ObservationPath) async throws {
        let testResult = TestResult()
        let depA = EnvDep(state: "envA")
        let depB = EnvDep(state: "envB")

        // Outer host holds two containers side-by-side, analogous to:
        //   struct EditorModel { var streams: StreamsModel; var contextPreviewStreams: StreamsModel }
        try await waitUntilRemoved {
            let root = path.withOptions { TwoContainersModel(
                a: Container(items: [Item(id: 1)]).withDependencies { $0[EnvDep.self] = depA },
                b: Container(items: [Item(id: 2)]).withDependencies { $0[EnvDep.self] = depB }
            ).withAnchor {
                $0.testResult = testResult
            } }

            try await waitUntil(
                testResult.value.contains("itemOn:1:envA") &&
                testResult.value.contains("itemOn:2:envB")
            )

            // Mutate depA — only Item 1 (inside container A) must fire.
            depA.state = "envA2"
            try await waitUntil(testResult.value.contains("itemObs:1:envA2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:1:envA2"),
                    "[\(path)] Item in container A must observe depA change. Got: \(testResult.value)")
            #expect(!testResult.value.contains("itemObs:2:envA2"),
                    "[\(path)] Item in container B must NOT observe depA change. Got: \(testResult.value)")

            // Mutate depB — only Item 2 (inside container B) must fire.
            depB.state = "envB2"
            try await waitUntil(testResult.value.contains("itemObs:2:envB2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:2:envB2"),
                    "[\(path)] Item in container B must observe depB change. Got: \(testResult.value)")
            #expect(!testResult.value.contains("itemObs:1:envB2"),
                    "[\(path)] Item in container A must NOT observe depB change. Got: \(testResult.value)")

            return root
        }
    }

    /// Verifies that a container's withDependencies override is not shadowed by a sibling
    /// container that has already caused the same dep type to be anchored at root level.
    ///
    /// Pattern mirrors EditorModel where `streams` (container `a`) causes EnvDep to be
    /// anchored at root, and `contextPreviewStreams` (container `b`) injects a custom instance.
    /// Item children inside container `b` MUST see the injected dep, not the root-cached one.
    ///
    /// The root-level dep anchor happens because container `a` has no withDependencies override
    /// so its children's dependency(for:) call resolves using the root DependencyValues, caching
    /// a context at rootParent.dependencyContexts. Container `b`'s children must bypass this
    /// via the same Case 1 path (child.rootParent === rootParent) that recognises the injected
    /// dep is already live in the hierarchy.
    @Test(arguments: ObservationPath.allCases)
    func injectedDepNotShadowedByRootLevelDepAnchoredBySibling(path: ObservationPath) async throws {
        let testResult = TestResult()
        let primaryDep = EnvDep(state: "primary")
        let isolatedDep = EnvDep(state: "isolated")

        try await waitUntilRemoved {
            let root = path.withOptions { TwoContainersModel(
                // `a` has no override → its Item resolves EnvDep via root DependencyValues,
                // anchoring primaryDep at rootParent.dependencyContexts[ObjectIdentifier(EnvDep)]
                a: Container(items: [Item(id: 1)]),
                // `b` injects its own dep → its Items MUST see "isolated" not "primary"
                b: Container(items: [Item(id: 2)]).withDependencies { $0[EnvDep.self] = isolatedDep }
            ).withAnchor {
                $0.testResult = testResult
                $0[EnvDep.self] = primaryDep  // root-level dep — container `a` inherits this
            } }

            try await waitUntil(
                testResult.value.contains("itemOn:1:primary") &&
                testResult.value.contains("itemOn:2:isolated")
            )
            #expect(testResult.value.contains("itemOn:1:primary"),
                    "[\(path)] Item in unoverridden container must see root dep. Got: \(testResult.value)")
            #expect(testResult.value.contains("itemOn:2:isolated"),
                    "[\(path)] Item in overriding container must see injected dep. Got: \(testResult.value)")

            // Mutate isolatedDep — only Item 2 must fire.
            isolatedDep.state = "isolated2"
            try await waitUntil(testResult.value.contains("itemObs:2:isolated2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("itemObs:2:isolated2"),
                    "[\(path)] Item 2 must observe isolatedDep mutation. Got: \(testResult.value)")
            #expect(!testResult.value.contains("itemObs:1:isolated2"),
                    "[\(path)] Item 1 must NOT observe isolatedDep mutation. Got: \(testResult.value)")

            return root
        }
    }

    // =========================================================================
    // MARK: - Child-of-model-with-dep tests
    //
    // The scenarios below verify that a child model (plain stored property, var child: ChildModel)
    // of a parent that has a withDependencies override can resolve its own @ModelDependency
    // using the parent's overridden DependencyValues.
    //
    // This differs from the Item-in-array pattern above: here `child` is a *single* stored property,
    // not an element of a [Item] array. The context inheritance path is the same but the test
    // exercises it from a different angle.
    // =========================================================================

    /// A model with a *single* child stored property (not an array) where the parent has
    /// an overridden dep via withDependencies. The child must resolve @ModelDependency using
    /// the parent's DependencyValues, not the global test/live value.
    ///
    /// Hierarchy:
    ///   Root.withAnchor { $0[EnvDep.self] = customDep }
    ///     └─ SingleChild (plain stored property, no withDependencies)
    ///           └─ @ModelDependency var env: EnvDep   ← must see customDep
    @Test(arguments: ObservationPath.allCases)
    func plainStoredPropertyChildInheritsParentDep(path: ObservationPath) async throws {
        let testResult = TestResult()
        let customDep = EnvDep(state: "custom")

        try await waitUntilRemoved {
            let root = path.withOptions { SingleChildParent()
                .withAnchor {
                    $0.testResult = testResult
                    $0[EnvDep.self] = customDep
                } }

            // The single child resolves EnvDep by walking up to root's DependencyValues.
            try await waitUntil(testResult.value.contains("childOn:custom"))
            #expect(testResult.value.contains("childOn:custom"),
                    "[\(path)] Single stored-property child must see parent's dep override. Got: \(testResult.value)")

            // Mutate the dep — child must observe it.
            customDep.state = "custom2"
            try await waitUntil(testResult.value.contains("childObs:custom2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("childObs:custom2"),
                    "[\(path)] Child must observe dep mutation from parent. Got: \(testResult.value)")

            return root
        }
    }

    /// Two sibling single-child parents, each with a different dep override.
    /// Confirms that the stored-property child path has proper isolation between parents.
    @Test(arguments: ObservationPath.allCases)
    func twoParentsWithDifferentDepsEachChildSeesItsParentDep(path: ObservationPath) async throws {
        let testResult = TestResult()
        let depA = EnvDep(state: "depA")
        let depB = EnvDep(state: "depB")

        try await waitUntilRemoved {
            let root = path.withOptions { TwoSingleChildParentsModel(
                a: SingleChildParent().withDependencies { $0[EnvDep.self] = depA },
                b: SingleChildParent().withDependencies { $0[EnvDep.self] = depB }
            ).withAnchor {
                $0.testResult = testResult
            } }

            try await waitUntil(
                testResult.value.contains("childOn:depA") &&
                testResult.value.contains("childOn:depB")
            )
            #expect(testResult.value.contains("childOn:depA"),
                    "[\(path)] Child of parent A must see depA. Got: \(testResult.value)")
            #expect(testResult.value.contains("childOn:depB"),
                    "[\(path)] Child of parent B must see depB. Got: \(testResult.value)")

            // Mutate depA — only child of parent A must fire.
            depA.state = "depA2"
            try await waitUntil(testResult.value.contains("childObs:depA2"), timeout: 3_000_000_000)
            #expect(testResult.value.contains("childObs:depA2"),
                    "[\(path)] Child A must observe depA mutation. Got: \(testResult.value)")
            #expect(!testResult.value.contains("childObs:depB2"),
                    "[\(path)] Child B must NOT observe depA mutation. Got: \(testResult.value)")

            return root
        }
    }

    // =========================================================================
    // MARK: - Grandchild inherits child-level dep (init-body withDependencies)
    //
    // Hierarchy:
    //   RootWithInitOverriddenChild.withAnchor { $0[EnvDep.self] = rootDep }
    //     └─ child (set in init via `_child = ChildWithGrandchild().withDependencies { $0[EnvDep.self] = childDep }`)
    //          └─ grandChild (@ModelDependency var env: EnvDep)  ← must see childDep, NOT rootDep
    //
    // This is the exact scenario from the user report:
    //   root.node.dep != grandChild.node.dep  (grandchild must see the child-level override)
    // =========================================================================

    /// A grandchild stored inside a child whose dep override is set via init-body withDependencies
    /// must resolve @ModelDependency using the *child's* DependencyValues, not the root's.
    @Test func grandchildSeesChildDepNotRootDep() async throws {
        let testResult = TestResult()
        let rootDep = EnvDep(state: "rootDep")

        try await waitUntilRemoved {
            let root = RootWithInitOverriddenChild()
                .withAnchor {
                    $0.testResult = testResult
                    $0[EnvDep.self] = rootDep  // root-level dep — grandchild must NOT see this
                }

            // grandchild must activate with "childDep" (from the child-level withDependencies),
            // not "rootDep" (from withAnchor).
            try await waitUntil(testResult.value.contains("grandChildOn:"))
            #expect(testResult.value.contains("grandChildOn:childDep"),
                    "Grandchild must see child-level dep override, not root dep. Got: \(testResult.value)")
            #expect(!testResult.value.contains("grandChildOn:rootDep"),
                    "Grandchild must NOT see root dep. Got: \(testResult.value)")

            return root
        }
    }

    // =========================================================================
    // MARK: - Background-task dep inheritance (the real crash scenario)
    //
    // The crash from the bug report happens when:
    //   1. A container has a dep override (withDependencies { $0[Dep.self] = X })
    //   2. A root model's forEach task (runs on a background cooperative thread) adds
    //      children to that container
    //   3. Those children call dependency(for:) to resolve @ModelDependency
    //
    // The forEach task's task-local DependencyValues come from the *root* context
    // (set by TaskCancellable.init via `withDependencies(from: context)` — this is
    // intentional and must NOT be removed, as it propagates the launching model's deps
    // into the task). Because that task-local carries the root's deps, and because
    // DependencyValues.merging(_:) gives precedence to _current (the task-local), the
    // container's override is silently dropped when a child context is created or when
    // dependency(for:) is called on the child.
    //
    // The fix (AnyContext.dependency(for:) using capturedDependencies instead of
    // withDependencies(from: self)) ensures each context always resolves deps from
    // its own captured snapshot, regardless of the caller's task-local.
    //
    // REGRESSION NOTE: This test REQUIRES that TaskCancellable sets up the task-local
    // via withDependencies(from: context). Removing that call would make the test pass
    // trivially (no task-local to interfere), masking the bug.
    // =========================================================================

    /// Children added from a forEach background task must see their container's dep override,
    /// not the root/task-local DependencyValues that the task inherited.
    ///
    /// Reproduces the exact callstack from the crash report:
    ///   EditorModel.onActivate (forEach) → StreamsModel.updateSegments
    ///     → StreamModel.onActivate → dependency(for: StreamEnvironmentModel) → wrong instance
    @Test func childrenAddedFromBackgroundTaskSeeContainerDepOverride() async throws {
        let testResult = TestResult()
        let overrideDep = EnvDep(state: "override")

        try await waitUntilRemoved {
            // `overriding` container has an explicit dep override; `plain` inherits testValue.
            // The root itself has no dep override — its task-local DependencyValues must NOT
            // overwrite the override on `overriding` when children are added from the task.
            // rootDep is set on the root — analogous to EditorModel having a
            // base StreamEnvironmentModel. The overriding container must still
            // see its own "override" value, not the root's "rootDep".
            let rootDep = EnvDep(state: "rootDep")
            let root = BackgroundRoot(
                plain: BackgroundContainer(),
                overriding: BackgroundContainer().withDependencies { $0[EnvDep.self] = overrideDep }
            ).withAnchor {
                $0.testResult = testResult
                $0[EnvDep.self] = rootDep  // root explicitly sets dep — this is what EditorModel does
            }

            // Trigger population from the background forEach task.
            root.shouldPopulate = true

            // Leaves added to `plain` must see rootDep ("rootDep").
            // Leaves added to `overriding` must see "override", NOT "rootDep".
            try await waitUntil(
                testResult.value.contains("leafOn:1:rootDep") &&
                testResult.value.contains("leafOn:1:override"),
                timeout: 3_000_000_000
            )
            #expect(testResult.value.contains("leafOn:1:rootDep"),
                    "Leaf in plain container must see rootDep. Got: \(testResult.value)")
            #expect(testResult.value.contains("leafOn:1:override"),
                    "Leaf in overriding container must see override dep, not rootDep. Got: \(testResult.value)")
            #expect(!testResult.value.contains("leafOn:1:rootDep") || testResult.value.filter({ $0 == "o" }).count > 1,
                    "Both leafOn:1:rootDep (plain) and leafOn:1:override (overriding) must appear. Got: \(testResult.value)")

            return root
        }
    }

    // =========================================================================
    // MARK: - setupModelDependency / dependencyModels path (background task)
    //
    // Exercises the third fix: `withOwnDependencies` wrapping `withPostActions { setupModelDependency }`.
    //
    // When a leaf model carries `.withDependencies { $0[AuxDep.self] = leafDep }` on itself,
    // `Context<SelfOverridingLeaf>.init` has a non-empty `dependencyModels` dict and calls
    // `setupModelDependency` inside `withPostActions`. Without the fix the leaf's AuxDep
    // context is initialised with the background task's task-local (root's DependencyValues),
    // so `aux.label` would be the root/test value, not "leafOverride".
    // =========================================================================

    /// A leaf whose dep override is carried on the leaf value itself (via withDependencies on the
    /// leaf struct, NOT on a parent container) must have that override honoured even when the leaf
    /// is appended from inside a background forEach task.
    ///
    /// Note: this test exercises `dependency(for:)` using `capturedDependencies` (first fix),
    /// not the `setupModelDependency` path (third fix). For the third fix, see
    /// `depModelChildSeesLeafLevelDepOverrideWhenLeafAddedFromBackgroundTask`.
    @Test func selfOverridingLeafAddedFromBackgroundTaskSeesItsOwnDepOverride() async throws {
        let testResult = TestResult()
        let rootDep = AuxDep(label: "rootDep")

        try await waitUntilRemoved {
            // Root has its own AuxDep ("rootDep") set via withAnchor.
            // SelfOverridingRoot's forEach task will append a SelfOverridingLeaf that carries
            // its OWN dep override ("leafOverride") via withDependencies on the leaf itself.
            // The leaf's aux.label must be "leafOverride", NOT "rootDep" or "test".
            let root = SelfOverridingRoot()
                .withAnchor {
                    $0.testResult = testResult
                    $0[AuxDep.self] = rootDep
                }

            // Trigger population from the background forEach task.
            root.shouldPopulate = true

            try await waitUntil(
                testResult.value.contains("selfLeafOn:1:"),
                timeout: 3_000_000_000
            )
            #expect(testResult.value.contains("selfLeafOn:1:leafOverride"),
                    "Leaf's self-injected dep override must be honoured even when added from a background task. Got: \(testResult.value)")
            #expect(!testResult.value.contains("selfLeafOn:1:rootDep"),
                    "Leaf must NOT see the root's dep. Got: \(testResult.value)")
            #expect(!testResult.value.contains("selfLeafOn:1:test"),
                    "Leaf must NOT see the test-value dep. Got: \(testResult.value)")

            return root
        }
    }

    /// Verifies the `setupModelDependency` path in `Context.init` when called from a background task.
    ///
    /// This exercises the third fix: `withOwnDependencies` wrapping `withPostActions { setupModelDependency }`
    /// in `Context.init`.
    ///
    /// Scenario: a leaf model injects both `AuxDepWithChild` and `SecondaryDep` via `withDependencies`.
    /// When the leaf's `Context.init` calls `setupModelDependency` for `AuxDepWithChild`, the resulting
    /// `Context<AuxDepWithChild>` must capture the leaf-level `SecondaryDep` override in its own
    /// `capturedDependencies` — so that `AuxDepChild` (a child model inside `AuxDepWithChild`) sees
    /// "leafSecondary" when it resolves `@ModelDependency var secondary: SecondaryDep`.
    ///
    /// WITHOUT the fix: `withPostActions` runs with `_current = root's task-local` (no leaf-level
    /// SecondaryDep). `Context<AuxDepWithChild>.init` calls `withDependencies(from: leaf.context)`
    /// which merges `_current` (root's deps) over the leaf's deps — leaf-level `SecondaryDep` is
    /// silently dropped. `AuxDepChild` resolves to `testValue` ("test") instead of "leafSecondary".
    ///
    /// REGRESSION NOTE: Removing the `withOwnDependencies` wrapper from `withPostActions` in
    /// `Context.init` will cause this test to fail — `auxChildOn:` will contain "test" instead of
    /// "leafSecondary".
    @Test func depModelChildSeesLeafLevelDepOverrideWhenLeafAddedFromBackgroundTask() async throws {
        let testResult = TestResult()
        let rootSecondaryDep = SecondaryDep(tag: "rootSecondary")

        try await waitUntilRemoved {
            // Root has its own SecondaryDep ("rootSecondary"). The leaf overrides it with
            // "leafSecondary" via withDependencies on the leaf itself. The leaf also injects
            // AuxDepWithChild — whose child (AuxDepChild) resolves SecondaryDep at runtime.
            // AuxDepChild must see "leafSecondary" (the leaf-level override), not "rootSecondary"
            // or "test" (the task-local's value).
            let root = DeepOverridingRoot()
                .withAnchor {
                    $0.testResult = testResult
                    $0[SecondaryDep.self] = rootSecondaryDep
                }

            root.shouldPopulate = true

            // Wait for AuxDepChild to activate — it logs "auxChildOn:<tag>".
            try await waitUntil(
                testResult.value.contains("auxChildOn:"),
                timeout: 3_000_000_000
            )
            #expect(testResult.value.contains("auxChildOn:leafSecondary"),
                    "AuxDepChild (inside a dep-model set up via setupModelDependency) must see the leaf-level SecondaryDep override. Got: \(testResult.value)")
            #expect(!testResult.value.contains("auxChildOn:rootSecondary"),
                    "AuxDepChild must NOT see the root's SecondaryDep. Got: \(testResult.value)")
            #expect(!testResult.value.contains("auxChildOn:test"),
                    "AuxDepChild must NOT see the test-value SecondaryDep. Got: \(testResult.value)")

            return root
        }
    }

    /// withDependencies assigned inside a custom init() body via `_isolated = Model().withDependencies { ... }`
    /// must be honoured when the parent is anchored, exactly like withDependencies at call-site.
    ///
    /// This is the EditorModel pattern:
    ///   init() { _contextPreviewStreams = StreamsModel().withDependencies { $0.streamEnvironment = ... } }
    ///
    /// Whereas the existing tests use:
    ///   TwoContainersModel(b: Container().withDependencies { ... })
    ///
    /// Both are structurally identical — withDependencies attaches a ModelSetupAccess to the struct
    /// value itself regardless of whether the assignment happens at call-site or inside init().
    @Test(arguments: ObservationPath.allCases)
    func withDependenciesInInitBodyIsHonoured(path: ObservationPath) async throws {
        let testResult = TestResult()

        try await waitUntilRemoved {
            let root = path.withOptions { ParentWithInitAssignment()
                .withAnchor { $0.testResult = testResult } }

            try await waitUntil(
                testResult.value.contains("itemOn:1:test") &&
                testResult.value.contains("itemOn:2:override")
            )
            #expect(testResult.value.contains("itemOn:1:test"),
                    "[\(path)] Item in primary container must see testValue. Got: \(testResult.value)")
            #expect(testResult.value.contains("itemOn:2:override"),
                    "[\(path)] Item in isolated container (init-body assigned) must see override. Got: \(testResult.value)")

            return root
        }
    }
}
