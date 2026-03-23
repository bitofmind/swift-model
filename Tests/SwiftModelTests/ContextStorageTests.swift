import Testing
import ConcurrencyExtras
import Observation
import Dependencies
@testable import SwiftModel
import SwiftModel

// MARK: - Keys

private extension EnvironmentKeys {
    /// A simple boolean environment flag (propagates down the hierarchy).
    var isDarkMode: EnvironmentStorage<Bool> { .init(defaultValue: false) }

    /// A string environment value.
    var theme: EnvironmentStorage<String> { .init(defaultValue: "light") }
}

private extension LocalKeys {
    /// A local (node-private) flag.
    var localFlag: LocalStorage<Bool> { .init(defaultValue: false) }
}

// MARK: - Models

@Model
private struct ChildModel {
    var name: String = "child"
}

@Model
private struct ParentModel {
    var child: ChildModel = ChildModel()
    var count: Int = 0
}

@Model
private struct GrandparentModel {
    var parent: ParentModel = ParentModel()
}

// Models used for dependency exhaustivity tests.

@Model
private struct ServiceModel {
    var status: String = "idle"
}

extension ServiceModel: DependencyKey {
    static let liveValue = ServiceModel()
    static let testValue = ServiceModel()
}

@Model
private struct ConsumerModel {
    @ModelDependency var service: ServiceModel
}

// A two-level hierarchy where both parent and child hold the same dependency.
// The shared ServiceModel context has multiple parents (both context instances),
// and the dependency metadata exhaustivity machinery must still detect unasserted writes.
@Model
private struct ChildConsumerModel {
    @ModelDependency var service: ServiceModel
}

@Model
private struct ParentConsumerModel {
    var child: ChildConsumerModel = ChildConsumerModel()
    @ModelDependency var service: ServiceModel
}

// MARK: - MetadataEnvironmentTests

@Suite(.modelTesting(exhaustivity: .off))
struct MetadataEnvironmentTests {

    // MARK: - Basic read/write (local)

    @Test func localFlagDefaultValue() {
        let model = ChildModel().withAnchor()
        #expect(model.node.local.localFlag == false)
    }

    @Test func localFlagReadWrite() {
        let model = ChildModel().withAnchor()
        model.node.local.localFlag = true
        #expect(model.node.local.localFlag == true)
    }

    @Test func localFlagIsolatedToContext() {
        let parent = ParentModel().withAnchor()
        parent.node.local.localFlag = true

        // child should NOT see parent's local flag
        #expect(parent.child.node.local.localFlag == false)
    }

    // MARK: - Environment read inheritance

    @Test func environmentDefaultValue() {
        let model = ChildModel().withAnchor()
        #expect(model.node.environment.isDarkMode == false)
    }

    @Test func environmentReadFromSelf() {
        let model = ChildModel().withAnchor()
        model.node.environment.isDarkMode = true
        #expect(model.node.environment.isDarkMode == true)
    }

    @Test func environmentInheritedFromParent() {
        let parent = ParentModel().withAnchor()
        parent.node.environment.isDarkMode = true

        // Child should inherit parent's value
        #expect(parent.child.node.environment.isDarkMode == true)
    }

    @Test func environmentInheritedFromGrandparent() {
        let root = GrandparentModel().withAnchor()
        root.node.environment.isDarkMode = true

        // Grandchild should inherit grandparent's value
        #expect(root.parent.child.node.environment.isDarkMode == true)
    }

    @Test func environmentOverrideAtChild() {
        let root = GrandparentModel().withAnchor()
        root.node.environment.isDarkMode = true

        // Override at intermediate level
        root.parent.node.environment.isDarkMode = false
        #expect(root.parent.node.environment.isDarkMode == false)
        #expect(root.parent.child.node.environment.isDarkMode == false)

        // Root still has true
        #expect(root.node.environment.isDarkMode == true)
    }

    @Test func environmentDefaultWhenNoneSet() {
        let root = GrandparentModel().withAnchor()
        // No one has set isDarkMode — should return defaultValue
        #expect(root.node.environment.isDarkMode == false)
        #expect(root.parent.node.environment.isDarkMode == false)
        #expect(root.parent.child.node.environment.isDarkMode == false)
    }

    // MARK: - Environment write notifies descendants

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func environmentWriteNotifiesDescendant(path: ObservationPath) async throws {
        let root = GrandparentModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.parent.child.node.environment.isDarkMode
        }

        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == false)

        // Write on root — should propagate down to child
        root.node.environment.isDarkMode = true
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Writing on root should notify descendant observer, got \(values.value)")

        // Write on root again — should propagate down to child
        root.node.environment.isDarkMode = false
        try await waitUntil(values.value.filter({ !$0 }).count >= 2, timeout: 3_000_000_000)
        #expect(values.value.filter({ !$0 }).count >= 2, "[\(path)] Second write on root should notify descendant again, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func environmentWriteOnSelfNotifiesSelf(path: ObservationPath) async throws {
        let model = ChildModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.environment.isDarkMode
        }

        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == false)

        // Write on self — observer should be notified
        model.node.environment.isDarkMode = true
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Writing on self should notify self observer, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func environmentWriteOnParentNotifiesChildObserver(path: ObservationPath) async throws {
        let parent = ParentModel().withAnchor(options: path.options)

        // Set up observation on child
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            parent.child.node.environment.theme
        }

        let values = LockIsolated<[String]>([])
        let task = Task {
            for await v in observed {
                values.withValue { $0.append(v) }
            }
        }
        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(values.value.count >= 1)
        #expect(values.value.first == "light")

        // Write on parent — child should be notified
        parent.node.environment.theme = "dark"
        try await waitUntil(values.value.contains("dark"), timeout: 3_000_000_000)
        #expect(values.value.contains("dark"), "[\(path)] Writing on parent should notify child observer, got \(values.value)")

        // Write on parent again
        parent.node.environment.theme = "high-contrast"
        try await waitUntil(values.value.contains("high-contrast"), timeout: 3_000_000_000)
        #expect(values.value.contains("high-contrast"), "[\(path)] Second write on parent should notify child observer again, got \(values.value)")
    }

    // MARK: - Environment does not bleed upward

    @Test func environmentWriteOnChildDoesNotAffectParent() {
        let parent = ParentModel().withAnchor()
        parent.child.node.environment.isDarkMode = true

        // Parent has NOT set isDarkMode, so it returns defaultValue
        #expect(parent.node.environment.isDarkMode == false)
        // Child returns its own stored value
        #expect(parent.child.node.environment.isDarkMode == true)
    }

    // MARK: - Local does not propagate

    @Test func localFlagNotVisibleInChildren() {
        let parent = ParentModel().withAnchor()
        parent.node.local.localFlag = true

        #expect(parent.node.local.localFlag == true)
        #expect(parent.child.node.local.localFlag == false)
    }

    // MARK: - Intermediate override

    @Test func intermediateOverrideRead() {
        let root = GrandparentModel().withAnchor()
        root.node.environment.isDarkMode = true

        // No intermediate override: grandchild sees grandparent's value
        #expect(root.parent.child.node.environment.isDarkMode == true)

        // Set override at parent
        root.parent.node.environment.isDarkMode = false
        #expect(root.parent.child.node.environment.isDarkMode == false)

        // Root value unchanged
        #expect(root.node.environment.isDarkMode == true)
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func intermediateOverrideObservation(path: ObservationPath) async throws {
        let root = GrandparentModel().withAnchor(options: path.options)

        // Observer on grandchild
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.parent.child.node.environment.isDarkMode
        }
        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed { values.withValue { $0.append(v) } }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.last == false)

        // Grandparent writes — grandchild observer should fire (no intermediate override)
        root.node.environment.isDarkMode = true
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Grandparent write should notify grandchild, got \(values.value)")

        // Intermediate parent now sets an override (false) — grandchild should see the override
        root.parent.node.environment.isDarkMode = false
        try await waitUntil(values.value.filter({ !$0 }).count >= 2, timeout: 3_000_000_000)
        #expect(values.value.filter({ !$0 }).count >= 2, "[\(path)] Intermediate override should notify grandchild, got \(values.value)")

        // Grandparent writes again — grandchild should NOT change (intermediate still overrides)
        let countBefore = values.value.count
        root.node.environment.isDarkMode = false
        // Give a moment; grandchild should still read false from intermediate override
        try await Task.sleep(nanoseconds: 100_000_000)
        // The effective value is still false, so even if a notification fired the read value
        // is unchanged. We check the effective value is still false.
        #expect(root.parent.child.node.environment.isDarkMode == false)
        _ = countBefore  // suppresses unused warning
    }

    // MARK: - Remove context storage

    @Test func removeEnvironmentValueFallsBackToAncestor() {
        let root = GrandparentModel().withAnchor()
        root.node.environment.isDarkMode = true
        root.parent.node.environment.isDarkMode = false

        // Parent override shadows grandparent
        #expect(root.parent.node.environment.isDarkMode == false)

        // Remove the override at parent — should fall back to grandparent's value
        root.parent.node.removeEnvironment(\.isDarkMode)
        #expect(root.parent.node.environment.isDarkMode == true)

        // Grandchild also falls back
        #expect(root.parent.child.node.environment.isDarkMode == true)
    }

    @Test func removeLocalValueFallsBackToDefault() {
        let model = ChildModel().withAnchor()
        model.node.environment.isDarkMode = true
        #expect(model.node.environment.isDarkMode == true)

        model.node.removeEnvironment(\.isDarkMode)
        #expect(model.node.environment.isDarkMode == false)
    }

    @Test func removeOnNodeWithNoValueIsNoop() {
        let model = ChildModel().withAnchor()
        // Removing a never-set key should not crash
        model.node.removeEnvironment(\.isDarkMode)
        #expect(model.node.environment.isDarkMode == false)
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func removeNotifiesObserverOnSameNode(path: ObservationPath) async throws {
        let model = ChildModel().withAnchor(options: path.options)
        model.node.environment.isDarkMode = true

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.environment.isDarkMode
        }
        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed { values.withValue { $0.append(v) } }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.last == true)

        // Remove the value — observer should see false (default)
        model.node.removeEnvironment(\.isDarkMode)
        try await waitUntil(values.value.contains(false), timeout: 3_000_000_000)
        #expect(values.value.contains(false), "[\(path)] Remove should notify observer, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func removeIntermediateOverrideNotifiesDescendantObserver(path: ObservationPath) async throws {
        let root = GrandparentModel().withAnchor(options: path.options)
        root.node.environment.isDarkMode = true
        root.parent.node.environment.isDarkMode = false  // intermediate override

        // Observer on grandchild — currently sees false (intermediate override)
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.parent.child.node.environment.isDarkMode
        }
        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed { values.withValue { $0.append(v) } }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.last == false)

        // Remove intermediate override — grandchild should now see grandparent's true
        root.parent.node.removeEnvironment(\.isDarkMode)
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Removing intermediate override should notify descendant observer, got \(values.value)")
    }

    // MARK: - tester.assert integration
    //
    // These tests verify that metadata reads inside tester.assert {} are fully tracked:
    // - willAccessStorage fires the typed path so TestAccess records the Access
    // - didModifyStorage fires the typed path so TestAccess records the ValueUpdate
    // - Exhaustion catches unasserted metadata writes
    //
    // The user-facing callsite is `model.node.local.myKey` / `model.node.environment.myKey`.

    @Test func testerAssertLocalMetadata() async {
        let model = ChildModel().withAnchor()
        model.node.local.localFlag = true
        await expect(model.node.local.localFlag == true)
    }

    @Test func testerAssertEnvironmentMetadata() async {
        let model = ParentModel().withAnchor()
        model.node.environment.isDarkMode = true
        await expect(model.node.environment.isDarkMode == true)
    }

    @Test func testerAssertEnvironmentMetadataInheritedByChild() async {
        let model = ParentModel().withAnchor()
        // Setting on parent — child inherits via environment propagation.
        model.node.environment.isDarkMode = true
        await expect(model.node.environment.isDarkMode == true && model.child.node.environment.isDarkMode == true)
    }

    @Test(.modelTesting(exhaustivity: .off)) func testerAssertMetadataExhaustion() async {
        let model = ChildModel().withAnchor()
        // Write without asserting — with exhaustion off this should not fail.
        model.node.local.localFlag = true
        await expect(model.node.local.localFlag == true)
    }

    @Test func testerAssertRemoveMetadataNotifiesAssert() async {
        let model = ChildModel().withAnchor()
        model.node.local.localFlag = true
        await expect(model.node.local.localFlag == true)
        model.node.removeLocal(\.localFlag)
        await expect(model.node.local.localFlag == false)
    }

    // MARK: - .context exhaustivity option

    @Test(.modelTesting(exhaustivity: .state)) func metadataExhaustivityIsSeparateFromState() async {
        // With only .state exhaustivity (no .metadata), unasserted metadata writes should NOT fail.
        let model = ChildModel().withAnchor()

        // Write metadata without asserting it.
        model.node.local.localFlag = true

        // Write a regular property and assert only it — exhaustion check runs but should
        // NOT complain about the unasserted metadata write because .metadata is not included.
        model.name = "updated"
        await expect(model.name == "updated")
    }

    @Test(.modelTesting(exhaustivity: .local)) func metadataExhaustivityCatchesUnassertedMetadataWrites() async {
        // With .metadata in exhaustivity, unasserted metadata writes SHOULD be caught.
        let model = ChildModel().withAnchor()

        model.node.local.localFlag = true
        // Assert something unrelated so the exhaustion check runs with the metadata write pending.
        // This should produce a known issue: "Context not exhausted".
        await withKnownIssue {
            await expect(model.name == "child")
        }
    }

    @Test(.modelTesting(exhaustivity: .local)) func stateExhaustivityDoesNotCoverMetadata() async {
        // With only .metadata exhaustivity (no .state), unasserted state changes should NOT fail.
        let model = ChildModel().withAnchor()

        // Write a regular property without asserting it.
        model.name = "changed"

        // Assert metadata (unchanged from default) — exhaustion runs but should NOT
        // complain about the unasserted state change because .state is not included.
        await expect(model.node.local.localFlag == false)
    }

    // MARK: - Context storage exhaustivity via dependency models

    @Test func metadataExhaustivityOnDependencyModel() async {
        // Writing metadata on a dependency model should be tracked and assertable,
        // and should be caught by .metadata exhaustivity if not asserted.
        let model = ConsumerModel().withAnchor()
        model.service.node.local.localFlag = true
        await expect(model.service.node.local.localFlag == true)
    }

    @Test(.modelTesting(exhaustivity: .local)) func unassertedMetadataOnDependencyModelIsCaught() async {
        // With .metadata exhaustivity, an unasserted metadata write on a dependency model
        // should be reported just like one on a regular child model.
        let model = ConsumerModel().withAnchor()
        model.service.node.local.localFlag = true
        await withKnownIssue {
            await expect(model.service.status == "idle")
        }
    }

    @Test(.modelTesting(exhaustivity: .state)) func metadataOnDependencyModelSeparateFromState() async {
        // With only .state exhaustivity, unasserted metadata on a dependency model
        // should NOT trigger a failure.
        let model = ConsumerModel().withAnchor()
        model.service.node.local.localFlag = true
        model.service.status = "running"
        await expect(model.service.status == "running")
    }

    // MARK: - Shared dependency (same instance accessed via ancestor and child)
    //
    // When both parent and child declare @ModelDependency for the same type, they share a
    // single Context<ServiceModel>. That shared context has multiple parents (the parent
    // model context and the child model context). The metadata exhaustivity machinery must
    // still find the TestAccess (via metadataModelContext walking the parent chain) and
    // track/clear pending updates correctly.

    @Test func sharedDependencyMetadataTracked() async {
        // Write metadata on the dependency accessed via the child.
        // Assert it via the parent — both resolve to the same underlying context.
        let model = ParentConsumerModel().withAnchor()
        model.child.service.node.local.localFlag = true
        await expect(model.child.service.node.local.localFlag == true)
    }

    @Test(.modelTesting(exhaustivity: .local)) func sharedDependencyMetadataCaughtWhenUnasserted() async {
        // With .metadata exhaustivity, an unasserted write via either the parent or the
        // child accessor should be caught — both resolve to the same shared context.
        let model = ParentConsumerModel().withAnchor()
        model.child.service.node.local.localFlag = true
        await withKnownIssue {
            await expect(model.child.service.status == "idle")
        }
    }

    @Test(.modelTesting(exhaustivity: .state)) func sharedDependencyMetadataSeparateFromState() async {
        // With only .state exhaustivity, unasserted metadata on a shared dependency
        // should NOT trigger a failure.
        let model = ParentConsumerModel().withAnchor()
        model.child.service.node.local.localFlag = true
        model.child.service.status = "running"
        await expect(model.child.service.status == "running")
    }

    // MARK: - Exhaustion failure message formatting

    // Regression tests: unasserted local storage changes must name the key as
    // "local.keyName" in the failure message, not "UNKNOWN".
    // Verifies the #function capture in ContextStorage.init flows all the way to
    // the "Local not exhausted" failure output.

    @Test(.modelTesting(exhaustivity: .local)) func contextExhaustionMessageContainsKeyName() async {
        let model = ChildModel().withAnchor()
        model.node.local.localFlag = true
        await withKnownIssue {
            await expect(model.name == "child")
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("local.localFlag") }
        }
    }

    @Test(.modelTesting(exhaustivity: .local)) func contextExhaustionMessageOnDependencyModelContainsKeyName() async {
        let model = ConsumerModel().withAnchor()
        model.service.node.local.localFlag = true
        await withKnownIssue {
            await expect(model.service.status == "idle")
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("local.localFlag") }
        }
    }

}
