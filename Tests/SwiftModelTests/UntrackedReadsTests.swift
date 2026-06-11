import Testing
import ConcurrencyExtras
import Foundation
@testable import SwiftModel

/// Tests for the public `withUntrackedModelReads { }` scope.
///
/// These validate that:
/// 1. Reads inside the scope return live (lock-protected) values for plain,
///    child-model, and model-collection properties.
/// 2. Reads inside the scope register NO observation dependencies (both the
///    AccessCollector and withObservationTracking paths).
/// 3. Writes inside the scope still notify observers normally.
/// 4. Framework dependency collection is immune: a memoize whose first access
///    happens inside an untracked scope still tracks its own dependencies.
@Suite(.backgroundCallIsolation)
struct UntrackedReadsTests {

    @Test func returnsLiveValues() {
        let model = UntrackedModel().withAnchor()
        model.value = 3
        model.name = "hello"

        let (value, name) = withUntrackedModelReads { (model.value, model.name) }
        #expect(value == 3)
        #expect(name == "hello")

        model.value = 4
        #expect(withUntrackedModelReads { model.value } == 4)
    }

    @Test func childAndCollectionReads() {
        let parent = UntrackedParent(children: [
            UntrackedChild(id: 0, value: 1),
            UntrackedChild(id: 1, value: 2),
        ]).withAnchor()

        let sum = withUntrackedModelReads { parent.children.reduce(0) { $0 + $1.value } }
        #expect(sum == 3)

        let childValue = withUntrackedModelReads { parent.child.value }
        #expect(childValue == 100)

        parent.children[0].value = 10
        #expect(withUntrackedModelReads { parent.children.reduce(0) { $0 + $1.value } } == 12)
    }

    @Test func nestedScopesAndPreAnchorReads() {
        let model = UntrackedModel().withAnchor()
        model.value = 5
        #expect(withUntrackedModelReads { withUntrackedModelReads { model.value } } == 5)

        // Pre-anchor (no context) reads take the direct branch.
        let unanchored = UntrackedModel(value: 9)
        #expect(withUntrackedModelReads { unanchored.value } == 9)
    }

    @Test func untrackedReadRegistersNoDependencies_AccessCollector() async throws {
        let model = UntrackedModel().withAnchor()
        let untrackedCount = LockIsolated(0)
        let trackedCount = LockIsolated(0)

        // Observer whose access closure reads inside an explicit untracked scope.
        let (cancelUntracked, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            access: { withUntrackedModelReads { model.value } },
            onUpdate: { _ in untrackedCount.withValue { $0 += 1 } }
        )
        defer { cancelUntracked() }

        // Sentinel observer with normal tracked reads — proves the write propagated
        // through the observation machinery before we assert the negative.
        let (cancelTracked, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            access: { model.value },
            onUpdate: { _ in trackedCount.withValue { $0 += 1 } }
        )
        defer { cancelTracked() }

        #expect(untrackedCount.value == 1)
        #expect(trackedCount.value == 1)

        model.value = 1
        try await waitUntil(trackedCount.value == 2)
        #expect(untrackedCount.value == 1, "untracked observer must not re-fire on writes")
    }

    @Test func untrackedReadRegistersNoDependencies_ObservationTracking() async throws {
        let model = UntrackedModel().withAnchor()
        let untrackedCount = LockIsolated(0)
        let trackedCount = LockIsolated(0)

        let (cancelUntracked, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { withUntrackedModelReads { model.value } },
            onUpdate: { _ in untrackedCount.withValue { $0 += 1 } }
        )
        defer { cancelUntracked() }

        let (cancelTracked, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in trackedCount.withValue { $0 += 1 } }
        )
        defer { cancelTracked() }

        #expect(untrackedCount.value == 1)
        #expect(trackedCount.value == 1)

        model.value = 1
        try await waitUntil(trackedCount.value == 2)
        #expect(untrackedCount.value == 1, "untracked observer must not re-fire on writes")
    }

    @Test func writesInsideScopeStillNotify() async throws {
        let model = UntrackedModel().withAnchor()
        let updateCount = LockIsolated(0)

        let (cancellable, _) = update(
            initial: false,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )
        defer { cancellable() }

        withUntrackedModelReads { model.value = 7 }
        try await waitUntil(updateCount.value == 1)
        #expect(model.value == 7)
    }

    @Test func memoizeSetUpInsideUntrackedScopeStillTracks() async throws {
        let model = UntrackedMemoizeModel().withAnchor()

        // First access — memoize dependency collection runs inside the scope but
        // must not inherit it (update() clears the flag around access()).
        let initial = withUntrackedModelReads { model.doubled }
        #expect(initial == 0)

        model.value = 21
        try await waitUntil(model.doubled == 42)
    }
}

// MARK: - Test Models

@Model private struct UntrackedModel: Sendable {
    var value = 0
    var name = ""
}

@Model private struct UntrackedChild: Identifiable, Sendable {
    let id: Int
    var value = 0
}

@Model private struct UntrackedParent: Sendable {
    var child = UntrackedChild(id: -1, value: 100)
    var children: [UntrackedChild] = []
}

@Model private struct UntrackedMemoizeModel: Sendable {
    var value = 0

    var doubled: Int {
        node.memoize(for: "doubled") { value * 2 }
    }
}
