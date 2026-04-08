import Testing
import Observation
import ConcurrencyExtras
import Foundation
import Dependencies
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

        // Set up main thread observer
        let mainTask = Task { @MainActor in
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

        // Wait for both observation tasks to complete setup
        await mainTask.value
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

        // Set up main thread observer
        let mainTask = Task { @MainActor in
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

        // Wait for both observation tasks to complete setup
        await mainTask.value
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
        let observationTask = Task {
            withObservationTracking {
                _ = model.doubledObservableValue
            } onChange: {
                changeDetected.setValue(true)
            }
        }
        await observationTask.value

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
        let observationTask = Task {
            withObservationTracking {
                _ = model.dependencyValue
            } onChange: {
                changeDetected.setValue(true)
            }
        }
        await observationTask.value

        observable.value = 42
        try await waitUntil(changeDetected.value)

        #expect(model.dependencyValue == 42, "Model should read updated Observable dependency")
        #expect(changeDetected.value, "withObservationTracking should detect @Observable dependency changes via @Model")
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
    @Test func testObservedStreamWithModelAccessingObservable() async throws {
        let observable = PureObservableModel()
        let model = ModelHoldingObservable(observable: observable).withAnchor()

        let values = LockIsolated<[Int]>([])

        let task = Task {
            for await value in Observed({ model.doubledObservableValue }) {
                values.withValue { $0.append(value) }
                if value >= 20 { break }
            }
        }
        defer { task.cancel() }

        // Wait for the initial value (0) to be delivered.
        // Use waitUntil (kernel dispatch hops) instead of AsyncStream iter.next(), which
        // requires the cooperative thread pool to be responsive — unreliable on saturated CI.
        try await waitUntil(values.value.contains(0))
        #expect(values.value.contains(0))

        // Set value=5 → doubledObservableValue=10.
        // We set the next value only after waitUntil confirms the consumer processed the
        // previous one, so hasPendingUpdate is always false and tracking is re-registered.
        observable.value = 5
        try await waitUntil(values.value.contains(10))
        #expect(values.value.contains(10), "Observed should track @Observable changes via @Model")

        // Set value=10 → doubledObservableValue=20.
        observable.value = 10
        try await waitUntil(values.value.contains(20))
        #expect(values.value.contains(20), "Should continue tracking @Observable changes")
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

