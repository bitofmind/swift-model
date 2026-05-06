import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

// MARK: - Mock

/// Test-side facsimile of ViewAccess.
///
/// Mirrors the core behaviour of ViewAccess exactly:
/// - Registers a per-path `onModify` callback via `context.onModify`.
/// - On modification, enqueues `mainCall { fireCount += 1 }` so delivery
///   is guaranteed on the main thread (mirrors `objectWillChange.send()`).
/// - `shouldPropagateToChildren = true` so child model reads also register deps.
///
/// We do NOT re-register after each fire (ViewAccess does that via SwiftUI's re-render
/// cycle). For these tests a single registration per property is sufficient.
private final class MockViewAccess: ModelAccess, @unchecked Sendable {
    let fireCount = LockIsolated(0)
    let firedOnMain = LockIsolated([Bool]())
    private let lock = NSLock()
    private var cancellables: [() -> Void] = []

    init() {
        super.init(useWeakReference: true)
    }

    override func willAccess<M: Model, Value>(
        from context: Context<M>,
        at path: KeyPath<M._ModelState, Value> & Sendable
    ) -> (() -> Void)? {
        guard !ModelAccess.isInModelTaskContext else { return nil }

        let cancellation = context.onModify(for: path) { [weak self] finished, _ in
            guard let self else { return {} }
            return {
                if !finished {
                    mainCall {
                        self.fireCount.withValue { $0 += 1 }
                        self.firedOnMain.withValue { $0.append(isOnMainThread) }
                    }
                }
            }
        }
        lock.withLock { cancellables.append(cancellation) }
        return nil
    }

    override var shouldPropagateToChildren: Bool { true }

    func cancelAll() {
        let cs = lock.withLock { let result = cancellables; cancellables = []; return result }
        for c in cs { c() }
    }
}

// MARK: - Test models

@Model
private struct WatchModel {
    var count: Int = 0
    var name: String = "initial"
    var child: ChildWatch = .init()
}

@Model
private struct ChildWatch {
    var value: Int = 0
    var label: String = "child"
}

// MARK: - Helpers

/// Simulates what ObservedModel.update() does: stamps `access` onto `model`
/// and reads properties through it (the "body evaluation" window).
/// The `body` closure receives the access-stamped model.
private func simulateBodyEvaluation<M: Model>(
    _ model: M,
    access: MockViewAccess,
    body: (M) -> Void
) {
    let stamped = model.withAccess(access)
    body(stamped)
}

// MARK: - Tests

@Suite("ViewAccess — fine-grained update tracking (iOS 16 path)")
struct ViewAccessTests {

    // MARK: Basic dependency registration

    /// Accessing a property during body registers it as a dependency.
    /// Modifying that property triggers the update callback.
    @Test func accessedPropertyTriggersUpdate() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.count   // register dependency on `count`
        }

        model.count = 42
        await mainCall.waitUntilIdle()
        #expect(access.fireCount.value == 1)
    }

    /// A property NOT accessed during body is not registered as a dependency.
    /// Modifying it must NOT trigger the update callback.
    @Test func nonAccessedPropertyDoesNotTriggerUpdate() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.count   // only `count` registered; `name` is not
        }

        model.name = "changed"
        await mainCall.waitUntilIdle()
        #expect(access.fireCount.value == 0, "Modifying a non-accessed property must not trigger a view update")
    }

    /// Multiple properties accessed in body each register independently.
    @Test func multipleAccessedPropertiesEachRegisterSeparately() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.count
            _ = m.name
        }

        model.count = 1
        await mainCall.waitUntilIdle()
        let afterCount = access.fireCount.value

        model.name = "new"
        await mainCall.waitUntilIdle()
        let afterName = access.fireCount.value

        #expect(afterCount == 1, "count change should fire once")
        #expect(afterName == 2, "name change should fire once more")
    }

    // MARK: Child model tracking (shouldPropagateToChildren)

    /// `shouldPropagateToChildren = true` means reading a child model's property
    /// during body registers a dependency on that child property.
    @Test func childPropertyTriggersUpdateWhenAccessed() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.child.value   // access child.value through the stamped model
        }

        model.child.value = 99
        await mainCall.waitUntilIdle()
        #expect(access.fireCount.value == 1, "Modifying an accessed child property must trigger a view update")
    }

    /// A child property NOT accessed in body should NOT trigger an update.
    @Test func nonAccessedChildPropertyDoesNotTriggerUpdate() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.child.value   // value accessed; label is not
        }

        model.child.label = "ignored"
        await mainCall.waitUntilIdle()
        #expect(access.fireCount.value == 0, "Modifying a non-accessed child property must not trigger a view update")
    }

    /// Accessing only the root model's property while NOT reading into the child
    /// means child mutations are not tracked.
    @Test func accessingRootOnlyDoesNotTrackChild() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.count   // root only — child not accessed
        }

        model.child.value = 7
        await mainCall.waitUntilIdle()
        #expect(access.fireCount.value == 0)
    }

    // MARK: Main-thread delivery

    /// All update callbacks must arrive on the main thread even when the model
    /// is mutated from a background thread. This is the regression guard for the
    /// `@MainActor` drain-loop fix in `mainCallQueueDrainLoop`.
    @Test func updatesDeliveredOnMainThreadFromBackground() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.count
        }

        // Mutate from multiple background threads to exercise multi-batch delivery.
        for i in 1...4 {
            await Task.detached {
                model.count = i
            }.value
            await Task.yield()  // give the drain loop a chance to yield between batches
        }

        await mainCall.waitUntilIdle()

        let fired = access.firedOnMain.value
        #expect(fired.count == 4)
        #if canImport(Darwin)
        #expect(fired.allSatisfy { $0 }, "All ViewAccess-style callbacks must arrive on the main thread")
        #endif
    }

    // MARK: Cleanup

    /// Cancelling all registrations means subsequent mutations produce no callbacks.
    @Test func cancellingRegistrationsStopsFiring() async {
        let model = WatchModel().withAnchor()
        let access = MockViewAccess()

        simulateBodyEvaluation(model, access: access) { m in
            _ = m.count
        }

        access.cancelAll()

        model.count = 100
        await mainCall.waitUntilIdle()
        #expect(access.fireCount.value == 0, "Cancelled registrations must not fire")
    }
}
