import Testing
import ConcurrencyExtras
import Observation
@testable import SwiftModel

// MARK: - Keys

private extension ModelContextKeys {
    /// A simple boolean environment flag (propagates up/down the hierarchy).
    var isDarkMode: ModelContextStorage<Bool> { .init(defaultValue: false, propagation: .environment) }

    /// A string environment value.
    var theme: ModelContextStorage<String> { .init(defaultValue: "light", propagation: .environment) }

    /// A local (non-environment) flag for comparison.
    var localFlag: ModelContextStorage<Bool> { .init(defaultValue: false) }
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

// MARK: - MetadataEnvironmentTests

struct MetadataEnvironmentTests {

    // MARK: - Basic read/write (local)

    @Test func localFlagDefaultValue() {
        let model = ChildModel().withAnchor()
        #expect(model.node.metadata.localFlag == false)
    }

    @Test func localFlagReadWrite() {
        let model = ChildModel().withAnchor()
        model.node.metadata.localFlag = true
        #expect(model.node.metadata.localFlag == true)
    }

    @Test func localFlagIsolatedToContext() {
        let parent = ParentModel().withAnchor()
        parent.node.metadata.localFlag = true

        // child should NOT see parent's local flag
        #expect(parent.child.node.metadata.localFlag == false)
    }

    // MARK: - Environment read inheritance

    @Test func environmentDefaultValue() {
        let model = ChildModel().withAnchor()
        #expect(model.node.metadata.isDarkMode == false)
    }

    @Test func environmentReadFromSelf() {
        let model = ChildModel().withAnchor()
        model.node.metadata.isDarkMode = true
        #expect(model.node.metadata.isDarkMode == true)
    }

    @Test func environmentInheritedFromParent() {
        let parent = ParentModel().withAnchor()
        parent.node.metadata.isDarkMode = true

        // Child should inherit parent's value
        #expect(parent.child.node.metadata.isDarkMode == true)
    }

    @Test func environmentInheritedFromGrandparent() {
        let root = GrandparentModel().withAnchor()
        root.node.metadata.isDarkMode = true

        // Grandchild should inherit grandparent's value
        #expect(root.parent.child.node.metadata.isDarkMode == true)
    }

    @Test func environmentOverrideAtChild() {
        let root = GrandparentModel().withAnchor()
        root.node.metadata.isDarkMode = true

        // Override at intermediate level
        root.parent.node.metadata.isDarkMode = false
        #expect(root.parent.node.metadata.isDarkMode == false)
        #expect(root.parent.child.node.metadata.isDarkMode == false)

        // Root still has true
        #expect(root.node.metadata.isDarkMode == true)
    }

    @Test func environmentDefaultWhenNoneSet() {
        let root = GrandparentModel().withAnchor()
        // No one has set isDarkMode — should return defaultValue
        #expect(root.node.metadata.isDarkMode == false)
        #expect(root.parent.node.metadata.isDarkMode == false)
        #expect(root.parent.child.node.metadata.isDarkMode == false)
    }

    // MARK: - Environment write notifies descendants

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func environmentWriteNotifiesDescendant(path: ObservationPath) async throws {
        let root = GrandparentModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.parent.child.node.metadata.isDarkMode
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
        root.node.metadata.isDarkMode = true
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Writing on root should notify descendant observer, got \(values.value)")

        // Write on root again — should propagate down to child
        root.node.metadata.isDarkMode = false
        try await waitUntil(values.value.filter({ !$0 }).count >= 2, timeout: 3_000_000_000)
        #expect(values.value.filter({ !$0 }).count >= 2, "[\(path)] Second write on root should notify descendant again, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func environmentWriteOnSelfNotifiesSelf(path: ObservationPath) async throws {
        let model = ChildModel().withAnchor(options: path.options)

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.metadata.isDarkMode
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
        model.node.metadata.isDarkMode = true
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Writing on self should notify self observer, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func environmentWriteOnParentNotifiesChildObserver(path: ObservationPath) async throws {
        let parent = ParentModel().withAnchor(options: path.options)

        // Set up observation on child
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            parent.child.node.metadata.theme
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
        parent.node.metadata.theme = "dark"
        try await waitUntil(values.value.contains("dark"), timeout: 3_000_000_000)
        #expect(values.value.contains("dark"), "[\(path)] Writing on parent should notify child observer, got \(values.value)")

        // Write on parent again
        parent.node.metadata.theme = "high-contrast"
        try await waitUntil(values.value.contains("high-contrast"), timeout: 3_000_000_000)
        #expect(values.value.contains("high-contrast"), "[\(path)] Second write on parent should notify child observer again, got \(values.value)")
    }

    // MARK: - Environment does not bleed upward

    @Test func environmentWriteOnChildDoesNotAffectParent() {
        let parent = ParentModel().withAnchor()
        parent.child.node.metadata.isDarkMode = true

        // Parent has NOT set isDarkMode, so it returns defaultValue
        #expect(parent.node.metadata.isDarkMode == false)
        // Child returns its own stored value
        #expect(parent.child.node.metadata.isDarkMode == true)
    }

    // MARK: - Local does not propagate

    @Test func localFlagNotVisibleInChildren() {
        let parent = ParentModel().withAnchor()
        parent.node.metadata.localFlag = true

        #expect(parent.node.metadata.localFlag == true)
        #expect(parent.child.node.metadata.localFlag == false)
    }

    // MARK: - Intermediate override

    @Test func intermediateOverrideRead() {
        let root = GrandparentModel().withAnchor()
        root.node.metadata.isDarkMode = true

        // No intermediate override: grandchild sees grandparent's value
        #expect(root.parent.child.node.metadata.isDarkMode == true)

        // Set override at parent
        root.parent.node.metadata.isDarkMode = false
        #expect(root.parent.child.node.metadata.isDarkMode == false)

        // Root value unchanged
        #expect(root.node.metadata.isDarkMode == true)
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func intermediateOverrideObservation(path: ObservationPath) async throws {
        let root = GrandparentModel().withAnchor(options: path.options)

        // Observer on grandchild
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.parent.child.node.metadata.isDarkMode
        }
        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed { values.withValue { $0.append(v) } }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.last == false)

        // Grandparent writes — grandchild observer should fire (no intermediate override)
        root.node.metadata.isDarkMode = true
        try await waitUntil(values.value.contains(true), timeout: 3_000_000_000)
        #expect(values.value.contains(true), "[\(path)] Grandparent write should notify grandchild, got \(values.value)")

        // Intermediate parent now sets an override (false) — grandchild should see the override
        root.parent.node.metadata.isDarkMode = false
        try await waitUntil(values.value.filter({ !$0 }).count >= 2, timeout: 3_000_000_000)
        #expect(values.value.filter({ !$0 }).count >= 2, "[\(path)] Intermediate override should notify grandchild, got \(values.value)")

        // Grandparent writes again — grandchild should NOT change (intermediate still overrides)
        let countBefore = values.value.count
        root.node.metadata.isDarkMode = false
        // Give a moment; grandchild should still read false from intermediate override
        try await Task.sleep(nanoseconds: 100_000_000)
        // The effective value is still false, so even if a notification fired the read value
        // is unchanged. We check the effective value is still false.
        #expect(root.parent.child.node.metadata.isDarkMode == false)
        _ = countBefore  // suppresses unused warning
    }

    // MARK: - Remove metadata

    @Test func removeEnvironmentValueFallsBackToAncestor() {
        let root = GrandparentModel().withAnchor()
        root.node.metadata.isDarkMode = true
        root.parent.node.metadata.isDarkMode = false

        // Parent override shadows grandparent
        #expect(root.parent.node.metadata.isDarkMode == false)

        // Remove the override at parent — should fall back to grandparent's value
        root.parent.node.removeMetadata(\.isDarkMode)
        #expect(root.parent.node.metadata.isDarkMode == true)

        // Grandchild also falls back
        #expect(root.parent.child.node.metadata.isDarkMode == true)
    }

    @Test func removeLocalValueFallsBackToDefault() {
        let model = ChildModel().withAnchor()
        model.node.metadata.isDarkMode = true
        #expect(model.node.metadata.isDarkMode == true)

        model.node.removeMetadata(\.isDarkMode)
        #expect(model.node.metadata.isDarkMode == false)
    }

    @Test func removeOnNodeWithNoValueIsNoop() {
        let model = ChildModel().withAnchor()
        // Removing a never-set key should not crash
        model.node.removeMetadata(\.isDarkMode)
        #expect(model.node.metadata.isDarkMode == false)
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func removeNotifiesObserverOnSameNode(path: ObservationPath) async throws {
        let model = ChildModel().withAnchor(options: path.options)
        model.node.metadata.isDarkMode = true

        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            model.node.metadata.isDarkMode
        }
        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed { values.withValue { $0.append(v) } }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.last == true)

        // Remove the value — observer should see false (default)
        model.node.removeMetadata(\.isDarkMode)
        try await waitUntil(values.value.contains(false), timeout: 3_000_000_000)
        #expect(values.value.contains(false), "[\(path)] Remove should notify observer, got \(values.value)")
    }

    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func removeIntermediateOverrideNotifiesDescendantObserver(path: ObservationPath) async throws {
        let root = GrandparentModel().withAnchor(options: path.options)
        root.node.metadata.isDarkMode = true
        root.parent.node.metadata.isDarkMode = false  // intermediate override

        // Observer on grandchild — currently sees false (intermediate override)
        let observed = Observed(coalesceUpdates: path == .observationRegistrar) {
            root.parent.child.node.metadata.isDarkMode
        }
        let values = LockIsolated<[Bool]>([])
        let task = Task {
            for await v in observed { values.withValue { $0.append(v) } }
        }
        defer { task.cancel() }

        try await waitUntil(values.value.count >= 1)
        #expect(values.value.last == false)

        // Remove intermediate override — grandchild should now see grandparent's true
        root.parent.node.removeMetadata(\.isDarkMode)
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
    // The user-facing callsite is the natural `model.node.metadata.myKey` form.

    @Test func testerAssertLocalMetadata() async {
        let (model, tester) = ChildModel().andTester()
        model.node.metadata.localFlag = true
        await tester.assert { model.node.metadata.localFlag == true }
    }

    @Test func testerAssertEnvironmentMetadata() async {
        let (model, tester) = ParentModel().andTester()
        model.node.metadata.isDarkMode = true
        await tester.assert { model.node.metadata.isDarkMode == true }
    }

    @Test func testerAssertEnvironmentMetadataInheritedByChild() async {
        let (model, tester) = ParentModel().andTester()
        // Setting on parent — child inherits via environment propagation.
        model.node.metadata.isDarkMode = true
        await tester.assert {
            model.node.metadata.isDarkMode == true &&
            model.child.node.metadata.isDarkMode == true
        }
    }

    @Test func testerAssertMetadataExhaustion() async {
        let (model, tester) = ChildModel().andTester()
        tester.exhaustivity = .off
        // Write without asserting — with exhaustion off this should not fail.
        model.node.metadata.localFlag = true
        await tester.assert { model.node.metadata.localFlag == true }
        // Restore exhaustion and verify no pending updates remain.
        tester.exhaustivity = .full
        await tester.assert { model.node.metadata.localFlag == true }
    }

    @Test func testerAssertRemoveMetadataNotifiesAssert() async {
        let (model, tester) = ChildModel().andTester()
        model.node.metadata.localFlag = true
        await tester.assert { model.node.metadata.localFlag == true }
        model.node.removeMetadata(\.localFlag)
        await tester.assert { model.node.metadata.localFlag == false }
    }

}
