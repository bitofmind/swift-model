import Testing
import Observation
import ConcurrencyExtras
import Foundation
import Dependencies
import IdentifiedCollections
@testable import SwiftModel
import SwiftModel

/// Tests for dual ObservationRegistrar pattern
///
/// These tests validate that:
/// 1. Background observers get immediate updates (no mainCall delay)
/// 2. Main thread observers still work correctly
/// 3. willSet is called properly before mutations where safe
/// 4. SwiftUI pattern (main registrar) still gets dispatched updates
@Suite(.modelTesting(exhaustivity: .off))
struct DualRegistrarTests {

    /// Test background thread modification → immediate background observer notification
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func testBackgroundModificationImmediateBackgroundObserver() async throws {
        let model = TestModel().withAnchor()

        let observerFired = LockIsolated(false)

        // Set up background observer using withObservationTracking
        let observationTask = Task.detached {
            withObservationTracking {
                _ = model.value
            } onChange: {
                observerFired.setValue(true)
            }
        }

        // Wait for observation task to complete setup
        await observationTask.value

        // Modify from another background thread
        model.value = 42

        // Observer should fire immediately (synchronously on background registrar)
        await expect(observerFired.value)

        #expect(observerFired.value, "Background observer should fire without mainCall delay")
    }

    /// Same test as above but using old .withAnchor() style (should also work now!)
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func testBackgroundModificationImmediateBackgroundObserver_WithAnchor() async throws {
        let model = TestModel().withAnchor()

        let observerFired = LockIsolated(false)

        // Set up background observer using withObservationTracking
        let observationTask = Task.detached {
            withObservationTracking {
                _ = model.value
            } onChange: {
                observerFired.setValue(true)
            }
        }

        // Wait for observation task to complete setup
        await observationTask.value

        // Modify from another background thread
        model.value = 42

        // With dual registrar, this should work synchronously now!
        // No polling needed - just check directly
        #expect(observerFired.value, "Background observer should fire synchronously with dual registrar")
    }

    /// Test main thread modification → both registrars notified immediately
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func testMainThreadModificationBothRegistrars() async throws {
        let model = TestModel().withAnchor()

        let mainObserverFired = LockIsolated(false)
        let backgroundObserverFired = LockIsolated(false)

        // Set up main thread observer via MainActor.run (avoids Task scheduling latency)
        await MainActor.run {
            withObservationTracking {
                _ = model.value
            } onChange: {
                mainObserverFired.setValue(true)
            }
        }

        // Set up background thread observer
        let bgTask = Task.detached {
            withObservationTracking {
                _ = model.value
            } onChange: {
                backgroundObserverFired.setValue(true)
            }
        }
        await bgTask.value

        // Modify on main thread
        await MainActor.run {
            model.value = 42
        }

        // Both observers should fire immediately (main thread modification)
        await expect(mainObserverFired.value && backgroundObserverFired.value)
    }

    /// Same test as above but using old .withAnchor() style
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func testMainThreadModificationBothRegistrars_WithAnchor() async throws {
        let model = TestModel().withAnchor()

        let mainObserverFired = LockIsolated(false)
        let backgroundObserverFired = LockIsolated(false)

        // Set up main thread observer via MainActor.run (avoids Task scheduling latency)
        await MainActor.run {
            withObservationTracking {
                _ = model.value
            } onChange: {
                mainObserverFired.setValue(true)
            }
        }

        // Set up background thread observer
        let bgTask = Task.detached {
            withObservationTracking {
                _ = model.value
            } onChange: {
                backgroundObserverFired.setValue(true)
            }
        }
        await bgTask.value

        // Modify on main thread
        await MainActor.run {
            model.value = 42
        }

        // Both observers should fire immediately - no polling needed!
        #expect(mainObserverFired.value && backgroundObserverFired.value, "Both registrars should fire synchronously")
    }

    /// Test that memoize works correctly with background observers
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func testMemoizeWithBackgroundObserver() async throws {
        let model = MemoizeModel().withAnchor()

        let changeDetected = LockIsolated(false)

        // Set up background observer on memoized property
        let observationTask = Task.detached {
            withObservationTracking {
                _ = model.doubled
            } onChange: {
                changeDetected.setValue(true)
            }
        }

        // Wait for observation setup to complete
        await observationTask.value

        // Initial access should have happened
        #expect(model.accessCount.value == 1, "Should have accessed once during setup")

        // Change underlying value
        model.value = 5

        // Background observer should detect change without mainCall delay
        await expect(changeDetected.value)

        #expect(changeDetected.value, "Background observer should have detected change")
        #expect(model.accessCount.value >= 1, "Memoized property should have been accessed")
    }

    /// Same test as above but using old .withAnchor() style
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func testMemoizeWithBackgroundObserver_WithAnchor() async throws {
        let model = MemoizeModel().withAnchor()

        let changeDetected = LockIsolated(false)

        // Set up background observer on memoized property
        let observationTask = Task.detached {
            withObservationTracking {
                _ = model.doubled
            } onChange: {
                changeDetected.setValue(true)
            }
        }

        // Wait for observation setup to complete
        await observationTask.value

        // Initial access should have happened
        #expect(model.accessCount.value == 1, "Should have accessed doubled once during setup")
        #expect(model.computeCount.value == 1, "Should have computed once during setup")

        // Change underlying value
        model.value = 5

        // Background observer should detect change synchronously - no polling!
        #expect(changeDetected.value, "Background observer should have detected change synchronously")
        // Note: accessCount and computeCount may have increased due to change notification
        #expect(model.accessCount.value >= 1, "Should have accessed at least once")
        #expect(model.computeCount.value >= 1, "Should have computed at least once")
    }
    
    // MARK: - Apple's Observations API Interop Tests (macOS 26.0+)
    // NOTE: These tests pass individually but fail when run with all tests
    // TODO: Investigate test isolation issue
    //
    // Guarded with canImport(ObjectiveC) to skip Linux CI: `Observations` is a macOS 26.0+
    // feature and its delivery relies on the cooperative thread pool. On Linux under heavy
    // parallel-test load the pool is saturated and `Observations` never delivers, causing
    // both hangs and timeouts. Since these tests validate Apple-platform API interop only,
    // there is no value running them on Linux.
#if canImport(ObjectiveC)
    /// Test that Apple's Observations API works with @Model types
    /// Verifies: Observations { model.value } should track changes to @Model properties
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test
    func testAppleObservationsWithModel() async throws {
        let model = withModelOptions([.disableMemoizeCoalescing]) { TestModel().withAnchor() }
        
        let values = LockIsolated<[Int]>([])
        let observationStarted = LockIsolated(false)
        
        let observationTask = Task {
            // Observations only emits when values change, not initially
            for try await value in Observations<Int, Never>({ 
                observationStarted.setValue(true)
                return model.value 
            }) {
                values.withValue { $0.append(value) }
                if value == 42 {
                    break
                }
            }
        }
        
        // Wait for observation to actually start
        try await waitUntil(observationStarted.value)

        // Add small delays between changes to ensure they're observed separately
        model.value = 10
        try await waitUntil(values.value.contains(10))

        model.value = 20
        try await waitUntil(values.value.contains(20))

        model.value = 42
        try await waitUntil(values.value.contains(42))
        observationTask.cancel()

        #expect(values.value.count >= 3, "Should have observed at least 3 values")
        #expect(values.value.contains(10), "Apple's Observations should observe @Model value 10")
        #expect(values.value.contains(20), "Apple's Observations should observe @Model value 20")
        #expect(values.value.contains(42), "Apple's Observations should observe @Model value 42")
    }

    /// Test that Apple's Observations respects @Model transactions
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test
    func testAppleObservationsWithModelTransactions() async throws {
        let model = TestModel().withAnchor()

        let transactionCount = LockIsolated(0)
        let observationStarted = LockIsolated(false)

        let observationTask = Task {
            // Observations only emits when values change, not initially
            for try await _ in Observations<Int, Never>({
                observationStarted.setValue(true)
                return model.value
            }) {
                transactionCount.withValue { $0 += 1 }
                if transactionCount.value >= 2 {
                    break
                }
            }
        }

        // Wait for observation to actually start
        try await waitUntil(observationStarted.value)

        model.node.transaction {
            model.value = 10
            model.value = 20
            model.value = 30
        }

        model.value = 40
        try await waitUntil(transactionCount.value >= 2)
        observationTask.cancel()

        #expect(transactionCount.value == 2, "Should batch transaction changes into one observation")
    }
#endif // canImport(ObjectiveC)

    // MARK: - @Model + @Observable Interoperability Tests

    /// Test that @Model can hold an @Observable object as a stored property and that
    /// withObservationTracking correctly detects changes that flow through the @Model
    /// computed property into the embedded @Observable.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testModelHoldingObservableObject() async throws {
        let observable = PureObservableModel()
        let model = ModelHoldingObservable(observable: observable).withAnchor()

        #expect(model.doubledObservableValue == 0, "Initial doubled value should be 0")

        let changeDetected = LockIsolated(false)

        // withObservationTracking is synchronous — no Task wrapper needed.
        withObservationTracking {
            _ = model.doubledObservableValue
        } onChange: {
            changeDetected.setValue(true)
        }

        // Mutating the @Observable directly fires withObservationTracking's onChange
        // because withObservationTracking captures dependencies on ALL ObservationRegistrar
        // accesses — both @Model's registrar and the embedded @Observable's registrar.
        observable.value = 5
        try await waitUntil(changeDetected.value)

        #expect(model.doubledObservableValue == 10, "Model should read updated Observable value")
        #expect(changeDetected.value, "withObservationTracking should detect @Observable changes via @Model")
    }

    /// Test that @Model can access an @Observable via @ModelDependency and that
    /// withObservationTracking correctly detects changes to the injected dependency.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testModelWithObservableDependency() async throws {
        let observable = PureObservableModel()
        let model = ModelWithObservableDependency().withAnchor {
            $0[PureObservableModel.self] = observable
        }

        #expect(model.dependencyValue == 0, "Initial dependency value should be 0")

        let changeDetected = LockIsolated(false)

        // withObservationTracking is synchronous — no Task wrapper needed.
        withObservationTracking {
            _ = model.dependencyValue
        } onChange: {
            changeDetected.setValue(true)
        }

        observable.value = 42
        try await waitUntil(changeDetected.value)

        #expect(model.dependencyValue == 42, "Model should read updated Observable dependency")
        #expect(changeDetected.value, "withObservationTracking should detect @Observable dependency changes via @Model")
    }

    /// Regression test: `Observed { isStandby }` with default coalesceUpdates=true
    /// (withObservationTracking path) must detect transitions when `isStandby` depends on
    /// a @Model-typed @ModelDependency property.
    ///
    /// Previously, changes to a @Model dependency's properties were missed by the
    /// withObservationTracking path, causing waitForFirst(of: false) to hang.
    /// The AccessCollector path (coalesceUpdates: false) worked correctly.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedStreamWithModelDependencyProperty() async {
        let model = StandbyModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }

        // coalesceUpdates defaults to true → withObservationTracking path
        var iter = Observed({ model.isStandby }).makeAsyncIterator()

        let v0 = await iter.next()
        #expect(v0 == true, "Initial: isInForeground=false → isStandby=true")

        // Trigger the dep model property change via nonmutating set routing through dep context
        model.node[EnvDepModel.self].isInForeground = true

        let v1 = await iter.next()
        #expect(v1 == false, "After isInForeground=true → isStandby=false via @ModelDependency")
    }

    /// Variant: two-property `||` isStandby matching the production StreamModel pattern.
    /// `isStandby = configIsStandby || !env.isInForeground` with configIsStandby=false,
    /// so `env.isInForeground` is the only factor. Both sides are tracked (no short-circuit).
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedStreamWithModelDependencyTwoFactorStandby() async {
        let model = TwoFactorStandbyModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }

        var iter = Observed({ model.isStandby }).makeAsyncIterator()

        let v0 = await iter.next()
        // configIsStandby = false, isInForeground = false → isStandby = false || true = true
        #expect(v0 == true, "Initial: configIsStandby=false, isInForeground=false → isStandby=true")

        model.node[EnvDepModel.self].isInForeground = true

        let v1 = await iter.next()
        #expect(v1 == false, "After isInForeground=true → isStandby=false || false=false")
    }

    /// Tests that `Observed { isStandby }` correctly emits `false` when both
    /// `configIsStandby` flips false AND `isInForeground` is already true — the production
    /// scenario where the dep model property changed BEFORE the config property.
    /// This exercises the re-registration path: tracking was on configIsStandby only
    /// (short-circuit since configIsStandby=true), then config changes, performUpdate
    /// re-registers and picks up the new dep model state.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedStreamWithModelDependencyShortCircuitThenChange() async {
        let model = TwoFactorStandbyModel(configIsStandby: true).withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }

        var iter = Observed({ model.isStandby }).makeAsyncIterator()
        let v0 = await iter.next()
        // configIsStandby=true → short-circuit → only config tracked, isStandby=true
        #expect(v0 == true)

        // First: dep model changes (not tracked due to short-circuit)
        model.node[EnvDepModel.self].isInForeground = true
        // isStandby = true || false = true — no change, no emission

        // Then: config changes, which IS tracked; performUpdate re-evaluates
        // and picks up the already-changed isInForeground → isStandby = false
        model.configIsStandby = false

        let v1 = await iter.next()
        #expect(v1 == false, "configIsStandby=false + isInForeground already true → isStandby=false")
    }

    /// Test that Observed streams correctly re-fire when a @Model computed property
    /// that reads an embedded @Observable changes.
    ///
    /// The delivery chain is:
    ///   observable.value changes
    ///   → withObservationTracking onChange fires synchronously
    ///   → schedules performUpdate on the test's BackgroundCallQueue
    ///   → performUpdate re-evaluates the closure, gets the new value, yields to the stream
    ///
    /// Each observable change is triggered only after waitUntil confirms the previous value
    /// was delivered. This guarantees hasPendingUpdate is false and tracking is re-registered
    /// before the next change, making coalescing and timing races impossible.
    /// waitUntil uses kernel dispatch hops (DispatchQueue.global) rather than cooperative
    /// pool awaits, so it works correctly even when the cooperative thread pool is saturated.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedStreamWithModelAccessingObservable() async {
        let observable = PureObservableModel()
        let model = ModelHoldingObservable(observable: observable).withAnchor()

        // Consume Observed directly in the test body rather than a separate Task so that
        // each mutation is triggered only after iter.next() confirms the previous value was
        // consumed, keeping hasPendingUpdate false and ensuring re-registration before the
        // next change.
        var iter = Observed({ model.doubledObservableValue }).makeAsyncIterator()

        let v0 = await iter.next()
        #expect(v0 == 0, "Initial value should be 0")

        // value=5 → doubledObservableValue=10
        observable.value = 5
        let v10 = await iter.next()
        #expect(v10 == 10, "Observed should track @Observable changes via @Model")

        // value=10 → doubledObservableValue=20
        observable.value = 10
        let v20 = await iter.next()
        #expect(v20 == 20, "Should continue tracking @Observable changes")
    }

}

// MARK: - Test Models

@Model private struct TestModel {
    var value = 0
}

@Model private struct MemoizeModel {
    var value = 0
    let accessCount = LockIsolated(0)
    let computeCount = LockIsolated(0)

    var doubled: Int {
        accessCount.withValue { $0 += 1 }
        return node.memoize(for: "doubled") {
            computeCount.withValue { $0 += 1 }
            return value * 2
        }
    }
}
// MARK: - @Observable interop test models

/// A pure @Observable type (not @Model) used for interoperability tests.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Observable private final class PureObservableModel: @unchecked Sendable {
    var value = 0
}

/// @Model that holds an @Observable object as a stored property.
/// The computed property reads through the @Observable, making changes to the embedded
/// object detectable via withObservationTracking and Observed.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Model private struct ModelHoldingObservable {
    var observable: PureObservableModel

    var doubledObservableValue: Int {
        observable.value * 2
    }
}

/// DependencyKey conformance so PureObservableModel can be injected via @ModelDependency.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension PureObservableModel: DependencyKey {
    static let liveValue = PureObservableModel()
    static let testValue = PureObservableModel()
}

/// @Model that accesses a PureObservableModel via @ModelDependency.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Model private struct ModelWithObservableDependency {
    @ModelDependency var observable: PureObservableModel

    var dependencyValue: Int {
        observable.value
    }
}

// MARK: - Dynamic IdentifiedArray insertion models (regression for commit 36c41a7)

/// Simulates a stream that has a standby property derived from a @Model dep.
/// Mirrors the production `StreamModel.isStandby` pattern.
@Model private struct DynamicStreamModel: Identifiable {
    let id: UUID
    var isStandby: Bool { !node[EnvDepModel.self].isInForeground }
}

/// Container model mirroring `StreamsModel<Config>`.
/// `streams: IdentifiedArrayOf<DynamicStreamModel>` exercises the sentinel-keyed
/// MutableCollection path introduced in commit 36c41a7.
@Model private struct StreamContainerModel {
    var streams: IdentifiedArrayOf<DynamicStreamModel> = []

    func addStream(id: UUID) {
        streams[id: id] = DynamicStreamModel(id: id)
    }

    func removeStream(id: UUID) {
        streams[id: id] = nil
    }
}

// MARK: - @Model dependency regression test models

@Model private struct EnvDepModel {
    var isInForeground: Bool
}

extension EnvDepModel: DependencyKey {
    static let liveValue = EnvDepModel(isInForeground: true)
    static let testValue = EnvDepModel(isInForeground: false)
}

/// Model whose `isStandby` depends solely on a @Model dependency property.
@Model private struct StandbyModel {
    var isStandby: Bool { !node[EnvDepModel.self].isInForeground }
}

/// Model whose `isStandby` mirrors the production `StreamModel` pattern:
/// `configIsStandby || !env.isInForeground`
@Model private struct TwoFactorStandbyModel {
    var configIsStandby = false
    var isStandby: Bool { configIsStandby || !node[EnvDepModel.self].isInForeground }
}

/// A dep-context model that itself uses EnvDepModel AND holds a StandbyModel child.
/// Used to verify that nearestDependencyContext returns the ROOT's EnvDepModel override
/// (not ServiceModelWithEnv's own nested EnvDepModel dep) when StandbyModel does the lookup.
@Model private struct ServiceModelWithEnv {
    var standbyChild = StandbyModel()
    /// ServiceModelWithEnv itself references EnvDepModel so setupModelDependency creates
    /// its own nested EnvDepModel dep context for this service.
    var serviceIsInForeground: Bool { node[EnvDepModel.self].isInForeground }
}

extension ServiceModelWithEnv: DependencyKey {
    static let liveValue = ServiceModelWithEnv()
    static let testValue = ServiceModelWithEnv()
}

/// Minimal root model — just an anchor point for dep context tests.
@Model private struct AppContainerModel {}

// MARK: - Production-like tests (no TestAccess, concurrent writes)

/// Tests that run WITHOUT `.modelTesting` to match production conditions:
/// no TestAccess as ModelAccess.current, dep model writes from concurrent tasks.
@Suite
struct ProductionLikeDepObservationTests {

    /// Regression: `Observed { isStandby }` (withObservationTracking path) must detect
    /// dep model property changes when NO TestAccess is active (production conditions).
    ///
    /// In `.modelTesting`, TestAccess is `ModelAccess.current` and `shouldPropagateToChildren`
    /// stamps it on dep models, adding a secondary observation path. This test runs without
    /// TestAccess to verify the withObservationTracking path alone is sufficient.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedDepPropertyWithoutTestAccess() async {
        let model = StandbyModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }
        defer { _ = model }

        var iter = Observed({ model.isStandby }).makeAsyncIterator()
        let v0 = await iter.next()
        #expect(v0 == true)

        // Write from a detached task to simulate a concurrent background notification handler.
        await Task.detached {
            model.node[EnvDepModel.self].isInForeground = true
        }.value

        let v1 = await iter.next()
        #expect(v1 == false, "Observed must detect dep model change without TestAccess")
    }

    /// Same as above with the two-factor isStandby pattern.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedTwoFactorDepWithoutTestAccess() async {
        let model = TwoFactorStandbyModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }
        defer { _ = model }

        var iter = Observed({ model.isStandby }).makeAsyncIterator()
        let v0 = await iter.next()
        #expect(v0 == true)

        await Task.detached {
            model.node[EnvDepModel.self].isInForeground = true
        }.value

        let v1 = await iter.next()
        #expect(v1 == false, "Two-factor isStandby must detect dep model change without TestAccess")
    }

    /// Regression: dep lookup via `nearestDependencyContext` must return the ROOT's explicit
    /// override, not the dep context's own nested default, when a dep model (ServiceModel) has
    /// its own EnvDepModel dep AND the root sets an explicit EnvDepModel override.
    ///
    /// If `StandbyModel` is a child of `ServiceModel` (a dep context), the old
    /// `nearestDependencyContext` would find `ServiceModel`'s own EnvDepModel dep (with the
    /// default isInForeground=false) rather than the root's override (isInForeground=false,
    /// then changed to true). The StandbyModel would then observe the wrong dep context and
    /// never see the root's EnvDepModel change. The new isDepContext-aware logic skips the dep
    /// context's own lookup and climbs to the root first.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testObservedDepPropertyWithNestedDepContext() async {
        // Anchor a ServiceModel whose child StandbyModel observes isStandby.
        // Root explicitly overrides EnvDepModel to isInForeground=false.
        // ServiceModel internally uses EnvDepModel too (has its own dep context for it).
        // After anchoring, we change the ROOT's EnvDepModel.isInForeground=true and
        // expect StandbyModel to observe isStandby=false.
        let service = ServiceModelWithEnv().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }
        defer { _ = service }

        let standby = service.standbyChild

        var iter = Observed({ standby.isStandby }).makeAsyncIterator()
        let v0 = await iter.next()
        #expect(v0 == true, "Initial: isInForeground=false via root override → isStandby=true")

        // Change the ROOT's EnvDepModel override. The standbyChild must observe THIS change.
        service.node[EnvDepModel.self].isInForeground = true

        let v1 = await iter.next()
        #expect(v1 == false, "Root EnvDepModel change must propagate to child's isStandby")
    }

    /// Regression: a dep context (isDepContext=true) observing its OWN property that reads
    /// a dep model must share the SAME dep context instance as the root's explicit override.
    ///
    /// Production pattern: `StreamModel` is a dep context of `AppModel`. Root sets
    /// `$0[EnvModel.self] = EnvModel(isInForeground: false)`. `StreamModel.isStandby`
    /// reads `node[EnvModel.self].isInForeground`. `Observed { streamModel.isStandby }` is
    /// called from `StreamModel.onActivate()`. Then root code calls
    /// `app.node[EnvModel.self].isInForeground = true` — this must fire the observation.
    ///
    /// The `isDepContext` fix in `nearestDependencyContext` ensures the dep context's lazy
    /// `node[EnvModel.self]` access starts from PARENT (root) and finds root's dep context
    /// instance (D2), not its own dep-loop instance (D1, which may exist if dep-loop ordering
    /// put the service dep before the env dep). Without the fix, root's write to D2 would not
    /// notify the observer watching D1 → hang.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testDepContextSelfObservingPropertySharesRootDepContext() async {
        // AppContainerModel is the true root. ServiceModelWithEnv is a dep context
        // (isDepContext=true) of AppContainerModel. Root also sets EnvDepModel override.
        // Observation is on service.serviceIsInForeground — read from the dep context itself.
        let app = AppContainerModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
            $0[ServiceModelWithEnv.self] = ServiceModelWithEnv()
        }
        defer { _ = app }

        let service = app.node[ServiceModelWithEnv.self]

        var iter = Observed({ service.serviceIsInForeground }).makeAsyncIterator()
        let v0 = await iter.next()
        #expect(v0 == false, "Initial: EnvDepModel.isInForeground=false")

        // Write from ROOT — must reach service's observer because both share the same
        // dep context instance for EnvDepModel (via the isDepContext fix).
        app.node[EnvDepModel.self].isInForeground = true

        let v1 = await iter.next()
        #expect(v1 == true, "Root EnvDepModel change must propagate to dep context self-observer")
    }

    /// Regression for commit 36c41a7: dynamically adding a stream to an IdentifiedArrayOf
    /// (via `streams[id: id] = stream`) must correctly activate the new stream and wire its
    /// dep-model observation. The new stream's `isStandby` must respond to root EnvDepModel changes.
    ///
    /// Before 36c41a7: `IdentifiedArray: ModelContainer` used cursor-keyed registration.
    /// After 36c41a7: IdentifiedArray uses sentinel-keyed (`\C.self`) registration via
    /// `visitCollection` / `_performCollectionSet` / `updateContextForCollection`.
    /// Both registration paths must correctly activate the new stream and wire dep observation.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testDynamicallyAddedStreamObservesDepChanges() async {
        // Root anchored with EnvDepModel in standby (isInForeground=false).
        let container = StreamContainerModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }
        defer { _ = container }

        // Dynamically add a stream — mirrors updateSegments adding a new StreamModel.
        let streamID = UUID()
        container.addStream(id: streamID)

        guard let stream = container.streams[id: streamID] else {
            Issue.record("Stream not found after addStream")
            return
        }

        // The new stream must observe isStandby via the root's EnvDepModel dep context.
        var iter = Observed({ stream.isStandby }).makeAsyncIterator()
        let v0 = await iter.next()
        #expect(v0 == true, "isInForeground=false → isStandby=true for dynamically added stream")

        // Change root's EnvDepModel — must reach the stream's observer.
        container.node[EnvDepModel.self].isInForeground = true

        let v1 = await iter.next()
        #expect(v1 == false, "Root dep change must propagate to dynamically-added stream's isStandby")
    }

    /// Regression: removing a stream and re-adding it must also work correctly.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func testRemovedAndReaddedStreamObservesDepChanges() async {
        let container = StreamContainerModel().withAnchor {
            $0[EnvDepModel.self] = EnvDepModel(isInForeground: false)
        }
        defer { _ = container }

        let streamID = UUID()
        container.addStream(id: streamID)
        container.removeStream(id: streamID)
        container.addStream(id: streamID)  // re-add after removal

        guard let stream = container.streams[id: streamID] else {
            Issue.record("Stream not found after re-add")
            return
        }

        var iter = Observed({ stream.isStandby }).makeAsyncIterator()
        let v0 = await iter.next()
        #expect(v0 == true, "isStandby=true after re-add (isInForeground=false)")

        container.node[EnvDepModel.self].isInForeground = true

        let v1 = await iter.next()
        #expect(v1 == false, "Root dep change must propagate to re-added stream's isStandby")
    }
}

