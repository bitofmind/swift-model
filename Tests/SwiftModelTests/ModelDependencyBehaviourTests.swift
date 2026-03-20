import Observation
import Testing
import AsyncAlgorithms
@testable import SwiftModel
import SwiftModelTesting
import Dependencies

/// Tests covering the documented semantics of Model-as-dependency in SwiftModel.
///
/// When a @Model type conforms to DependencyKey and is accessed via a model's node
/// (either via `node[Dep.self]` or `@ModelDependency`), SwiftModel integrates it into
/// the context hierarchy:
///
/// - The dependency model is activated (`onActivate()` called) when first accessed.
/// - The dependency model is deactivated when the last host model is removed.
/// - The dependency model participates in `reduceHierarchy`/`mapHierarchy` when `.dependencies`
///   is included in the relation.
/// - Events sent with `to: [.self, .children, .dependencies]` reach the dependency model.
/// - Events sent *from* the dependency model with the default `to: [.self, .ancestors]`
///   reach the host model's event listeners.
/// - State changes in the dependency model are observable from parent models via `Observed`.
///
/// ## Important: events and `.dependencies` is opt-in, and requires `.children`
///
/// By default `node.send(event)` uses `to: [.self, .ancestors]`, which does NOT include
/// dependency models. To send an event to dependency models you must explicitly pass
/// a relation that includes both `.dependencies` AND `.children` or `.descendants`
/// (e.g. `to: [.self, .children, .dependencies]`). Using `.dependencies` alone without
/// `.children` or `.descendants` will NOT deliver events to dependency models, because
/// dependency contexts are traversed as children in the hierarchy.
struct ModelDependencyBehaviourTests {

    // MARK: - Hierarchy traversal

    /// The dependency model is NOT visited by default descendant traversal.
    /// It IS visited when `.dependencies` is included in the relation.
    @Test func testReduceHierarchyVisitsDependencyWithDependenciesRelation() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = HostModel().withAnchor {
                $0.testResult = testResult
                $0[SimpleDep.self] = SimpleDep(tag: "svc")
            }

            await expect(model.dep.tag == "svc")  // Force dep activation first so it appears in mapHierarchy

            await expect {
                // Normal descendants traversal does NOT include the dependency model
                let withoutDeps = model.node.mapHierarchy(for: [.self, .descendants]) { $0 as? SimpleDep }
                withoutDeps.isEmpty

                // Adding .dependencies DOES include the dependency model
                let withDeps = model.node.mapHierarchy(for: [.self, .descendants, .dependencies]) { $0 as? SimpleDep }
                withDeps.count == 1
                withDeps.first?.tag == "svc"
            }
        }
    }

    @Test func testMapHierarchyDoesNotVisitDependencyWithoutFlag() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = HostModel().withAnchor {
                $0.testResult = testResult
                $0[SimpleDep.self] = SimpleDep(tag: "hidden")
            }

            await expect(model.dep.tag == "hidden")  // Force dep activation

            await expect {
                let found = model.node.mapHierarchy(for: [.self, .descendants]) { $0 as? SimpleDep }
                found.isEmpty
            }
        }
    }

    /// A dependency on the root is visible from a child node via `.dependencies`
    /// because the dependency context is inherited by child contexts.
    /// Note: `.children` must be included alongside `.dependencies` to actually visit
    /// dependency contexts (they are treated as one-hop children in the traversal).
    @Test func testMapHierarchyWithDependenciesOnChildNode() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = ParentHostModel().withAnchor {
                $0.testResult = testResult
                $0[SimpleDep.self] = SimpleDep(tag: "root-dep")
            }

            await expect(model.child.dep.tag == "root-dep")  // Force dep activation via child — this sets up the dependency context

            await expect {
                // From the parent node we can find the dep via child node since dep is
                // on the child's context. .children is required to actually visit dep contexts.
                let fromParent = model.node.mapHierarchy(for: [.self, .descendants, .dependencies]) { $0 as? SimpleDep }
                fromParent.count == 1

                // From the child node we can also find the dep (it's directly on the child context)
                let fromChild = model.child.node.mapHierarchy(for: [.self, .children, .dependencies]) { $0 as? SimpleDep }
                fromChild.count == 1
                fromChild.first?.tag == "root-dep"
            }
        }
    }

    // MARK: - Events: sending TO dependency model

    /// Events reach dependency models only when `.dependencies` is in the relation alongside
    /// `.children` or `.descendants` (dependency contexts are treated as children in traversal).
    @Test func testEventReachesDependencyModelWhenRelationIncludesDependencies() async {
        let testResult = TestResult()
        await withModelTesting(exhaustivity: .off) {
            let model = HostModelWithEvents().withAnchor {
                $0.testResult = testResult
                $0[ListeningDep.self] = ListeningDep()
            }

            // Access dependency to ensure it's set up in the hierarchy
            await expect(model.dep.lifetime == .active)

            // Send an event including .children and .dependencies
            // Note: .children is required because dep contexts are visited as children.
            // Using just [.self, .dependencies] would NOT reach the dep context.
            model.node.send(HostEvent.ping, to: [.self, .children, .dependencies])

            await expect(testResult.value.contains("ping-received"))
        }
        #expect(testResult.value.contains("ping-received"))
    }

    /// With the default relation `[.self, .ancestors]`, dependency models are NOT reached.
    @Test func testEventDoesNotReachDependencyModelWithDefaultRelation() async {
        let testResult = TestResult()
        await withModelTesting(exhaustivity: .off) {
            let model = HostModelWithEvents().withAnchor {
                $0.testResult = testResult
                $0[ListeningDep.self] = ListeningDep()
            }

            await expect(model.dep.lifetime == .active)

            // Default relation is [.self, .ancestors] — does NOT include .dependencies
            model.node.send(HostEvent.ping)

            await expect(!testResult.value.contains("ping-received"))
        }
    }

    // MARK: - Events: sending FROM dependency model upward

    /// Events sent from a dependency model with the default `to: [.self, .ancestors]`
    /// travel up to the host because the dep's context has the host as a parent.
    @Test func testEventFromDependencyReachesHostAncestor() async {
        let testResult = TestResult()
        await withModelTesting(exhaustivity: .off) {
            let model = HostListeningForDepEvents().withAnchor {
                $0.testResult = testResult
                $0[SendingDep.self] = SendingDep()
            }

            await expect(model.dep.lifetime == .active)
            model.dep.triggerEvent()

            await expect(testResult.value.contains("dep-event-received"))
        }
        #expect(testResult.value.contains("dep-event-received"))
    }

    // MARK: - Observation: parent observing dependency model's property

    /// A host model can observe a dependency model's properties via `Observed`.
    ///
    /// The dependency context inherits `disableObservationRegistrar` from its parent context,
    /// so the same observation semantics apply whether using ObservationRegistrar or AccessCollector.
    @Test(arguments: ObservationPath.allCases)
    func testParentCanObserveDependencyModelProperty(observationPath: ObservationPath) async {
        let testResult = TestResult()
        await withModelTesting {
            let model = ObservingHostModel().withAnchor(options: observationPath.options) {
                $0.testResult = testResult
                $0[SimpleDep.self] = SimpleDep(tag: "initial")
            }

            await expect(model.dep.tag == "initial")

            model.dep.tag = "updated"

            await expect {
                model.dep.tag == "updated"
                testResult.value.contains("tag=updated")
            }
        }
        #expect(testResult.value.contains("tag=updated"))
    }

    // MARK: - Lifecycle: activation and deactivation

    @Test func testDependencyModelActivatedOnFirstAccess() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = HostModel().withAnchor {
                $0.testResult = testResult
                $0[SimpleDep.self] = SimpleDep(tag: "svc")
            }

            await expect {
                model.dep.tag == "svc"
                testResult.value.contains("D:svc")
            }
        }
        #expect(testResult.value.contains("D:svc"))
        #expect(testResult.value.contains("d:svc"))
    }

    // MARK: - Shared dependency instance

    /// When two child models share the same dependency type from the root, they receive
    /// the same dependency context — it is activated once and deactivated once.
    @Test func testSharedDependencyActivatedOnceAcrossMultipleChildren() async {
        let testResult = TestResult()
        await withModelTesting {
            let model = MultiChildHost().withAnchor {
                $0.testResult = testResult
                $0[SimpleDep.self] = SimpleDep(tag: "shared")
            }

            await expect {
                // Both children see the same dep instance
                model.child1.dep.tag == "shared"
                model.child2.dep.tag == "shared"
            }

            // Mutating via one child is visible on the other — they share a context
            model.child1.dep.tag = "updated"

            await expect {
                model.child2.dep.tag == "updated"
                testResult.value.contains("tag-changed:updated")
            }
        }
        // Activation is prefixed "D:", deactivation "d:".
        // The dep is activated with tag "shared" → "D:shared".
        // After mutation, tag becomes "updated". onCancel captures `node` (live reference),
        // so it logs "d:updated" (the tag at deactivation time, not activation time).
        let value = testResult.value
        #expect(value.contains("D:shared"), "Expected activation log 'D:shared' but got: \(value)")
        #expect(value.contains("d:updated"), "Expected deactivation log 'd:updated' but got: \(value)")
        // Verify activation happened exactly once
        #expect(value.components(separatedBy: "D:shared").count - 1 == 1, "Full log: \(value)")
    }
}

// MARK: - Supporting models and dependencies

private enum HostEvent: Sendable {
    case ping
}

private enum DepEvent: Sendable {
    case fired
}

/// A simple dependency model that logs activation/deactivation and property changes.
@Model private struct SimpleDep {
    var tag: String

    func onActivate() {
        node.testResult.add("D:\(tag)")
        node.onCancel {
            node.testResult.add("d:\(tag)")
        }
        node.forEach(Observed(initial: false, coalesceUpdates: false) { tag }) { newTag in
            node.testResult.add("tag-changed:\(newTag)")
        }
    }
}

extension SimpleDep: DependencyKey {
    static let liveValue = SimpleDep(tag: "live")
    static let testValue = SimpleDep(tag: "test")
}

/// A dependency that listens for HostEvent.ping sent to it explicitly.
@Model private struct ListeningDep {
    func onActivate() {
        node.forEach(node.event(ofType: HostEvent.self)) { event in
            switch event {
            case .ping:
                node.testResult.add("ping-received")
            }
        }
    }
}

extension ListeningDep: DependencyKey {
    static let liveValue = ListeningDep()
    static let testValue = ListeningDep()
}

/// A dependency that sends a DepEvent upward via the normal ancestor route.
@Model private struct SendingDep {
    func triggerEvent() {
        node.send(DepEvent.fired)
    }
}

extension SendingDep: DependencyKey {
    static let liveValue = SendingDep()
    static let testValue = SendingDep()
}

/// Host that exposes SimpleDep via @ModelDependency.
@Model private struct HostModel {
    @ModelDependency var dep: SimpleDep
}

/// Host that exposes ListeningDep.
@Model private struct HostModelWithEvents {
    @ModelDependency var dep: ListeningDep
}

/// Host that listens for DepEvent.fired from its SendingDep dependency.
@Model private struct HostListeningForDepEvents {
    @ModelDependency var dep: SendingDep

    func onActivate() {
        node.forEach(node.event(ofType: DepEvent.self)) { event in
            switch event {
            case .fired:
                node.testResult.add("dep-event-received")
            }
        }
    }
}

/// Host that observes its dependency's `tag` property.
@Model private struct ObservingHostModel {
    @ModelDependency var dep: SimpleDep

    func onActivate() {
        node.forEach(Observed(initial: false, coalesceUpdates: false) { dep.tag }) { newTag in
            node.testResult.add("tag=\(newTag)")
        }
    }
}

/// Two children sharing the same dependency type from the root.
@Model private struct ChildHostModel {
    @ModelDependency var dep: SimpleDep
}

@Model private struct MultiChildHost {
    var child1: ChildHostModel = ChildHostModel()
    var child2: ChildHostModel = ChildHostModel()
}

@Model private struct ParentHostModel {
    var child: HostModel = HostModel()
}
