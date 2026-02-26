import Testing
import Observation
import ConcurrencyExtras
import Foundation
import Dependencies
@testable import SwiftModel

/// Tests for dual ObservationRegistrar pattern
///
/// These tests validate that:
/// 1. Background observers get immediate updates (no mainCall delay)
/// 2. Main thread observers still work correctly
/// 3. willSet is called properly before mutations where safe
/// 4. SwiftUI pattern (main registrar) still gets dispatched updates
struct DualRegistrarTests {

    /// Test background thread modification → immediate background observer notification
    @Test func testBackgroundModificationImmediateBackgroundObserver() async throws {
        let (model, tester) = TestModel().andTester(options: [])
        tester.exhaustivity = .off

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
        await tester.assert(timeoutNanoseconds: 100_000_000) {  // 100ms should be plenty
            observerFired.value
        }

        #expect(observerFired.value, "Background observer should fire without mainCall delay")
    }

    /// Same test as above but using old .withAnchor() style (should also work now!)
    @Test func testBackgroundModificationImmediateBackgroundObserver_WithAnchor() async throws {
        let model = TestModel().withAnchor(options: [])

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
    @Test func testMainThreadModificationBothRegistrars() async throws {
        let (model, tester) = TestModel().andTester(options: [])
        tester.exhaustivity = .off

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
        await tester.assert(timeoutNanoseconds: 100_000_000) {
            mainObserverFired.value && backgroundObserverFired.value
        }
    }

    /// Same test as above but using old .withAnchor() style
    @Test func testMainThreadModificationBothRegistrars_WithAnchor() async throws {
        let model = TestModel().withAnchor(options: [])

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
    @Test func testMemoizeWithBackgroundObserver() async throws {
        let (model, tester) = MemoizeModel().andTester(options: [])
        tester.exhaustivity = .off

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
        await tester.assert(timeoutNanoseconds: 100_000_000) {
            changeDetected.value
        }

        #expect(changeDetected.value, "Background observer should have detected change")
        #expect(model.accessCount.value >= 1, "Memoized property should have been accessed")
    }

    /// Same test as above but using old .withAnchor() style
    @Test func testMemoizeWithBackgroundObserver_WithAnchor() async throws {
        let model = MemoizeModel().withAnchor(options: [])

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
        let model = TestModel().withAnchor(options: [.disableMemoizeCoalescing])
        
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
        
        try await observationTask.value
        
        #expect(values.value.count >= 3, "Should have observed at least 3 values")
        #expect(values.value.contains(10), "Apple's Observations should observe @Model value 10")
        #expect(values.value.contains(20), "Apple's Observations should observe @Model value 20")
        #expect(values.value.contains(42), "Apple's Observations should observe @Model value 42")
    }
    
    /// Test that Apple's Observations respects @Model transactions
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test
    func testAppleObservationsWithModelTransactions() async throws {
        let model = TestModel().withAnchor(options: [])
        
        let transactionCount = LockIsolated(0)
        let observationStarted = LockIsolated(false)
        
        let observationTask = Task {
            // Observations only emits when values change, not initially
            for try await value in Observations<Int, Never>({ 
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
        
        try await observationTask.value
        
        #expect(transactionCount.value == 2, "Should batch transaction changes into one observation")
    }
    
    /// Test that our Observed API works with pure @Observable types
    /// Verifies: Observed { observable.value } should work with Apple's @Observable
    /// NOTE: Disabled - Observed uses AccessCollector which doesn't support pure @Observable types
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test
    func testObservedWithPureObservable() async throws {
        let observable = PureObservableModel()
        
        let values = LockIsolated<[Int]>([])
        let setupComplete = LockIsolated(false)
        
        let observationTask = Task {
            // Note: coalesceUpdates parameter is ignored on iOS 17+ when observing pure @Observable types
            // withObservationTracking always uses coalescing to avoid synchronous recursion issues
            for await value in Observed(initial: true, { observable.value }) {
                if !setupComplete.value {
                    setupComplete.setValue(true)
                }
                values.withValue { $0.append(value) }
                if value == 42 {
                    break
                }
            }
        }
        
        try await waitUntil(setupComplete.value)
        
        observable.value = 10
        try await waitUntil(values.value.contains(10))
        
        observable.value = 20
        try await waitUntil(values.value.contains(20))
        
        observable.value = 42
        let _ = await observationTask.value

        #expect(values.value.count >= 3, "Should have observed at least 3 values")
        #expect(values.value.contains(10), "Our Observed should work with @Observable value 10")
        #expect(values.value.contains(20), "Our Observed should work with @Observable value 20")
        #expect(values.value.contains(42), "Our Observed should work with @Observable value 42")
    }
    
    /// Test bidirectional compatibility: both APIs work with both types
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test
    func testBidirectionalCompatibility() async throws {
        let model = TestModel().withAnchor(options: [])
        let observable = PureObservableModel()
        
        let modelValues = LockIsolated<[Int]>([])
        let modelSetupComplete = LockIsolated(false)
        let modelTask = Task {
            for try await value in Observations<Int, Never>({ model.value }) {
                if !modelSetupComplete.value {
                    modelSetupComplete.setValue(true)
                }
                modelValues.withValue { $0.append(value) }
                if value >= 10 {
                    break
                }
            }
        }
        
        let observableValues = LockIsolated<[Int]>([])
        let observableSetupComplete = LockIsolated(false)
        let observableTask = Task {
            for await value in Observed({ observable.value }) {
                if !observableSetupComplete.value {
                    observableSetupComplete.setValue(true)
                }
                observableValues.withValue { $0.append(value) }
                if value >= 20 {
                    break
                }
            }
        }
        
        try await waitUntil(modelSetupComplete.value && observableSetupComplete.value)
        
        model.value = 10
        observable.value = 20
        
        try await modelTask.value
        try await observableTask.value
        
        #expect(modelValues.value.contains(10), "Observations should work with @Model")
        #expect(observableValues.value.contains(20), "Observed should work with @Observable")
    }
    
    // MARK: - @Model + @Observable Interoperability Tests
    
    /// Test that @Model can hold an @Observable object as a property and observe its changes
    /// This proves the claim: "@Model can hold an @Observable object and they work together"
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test
    func testModelHoldingObservableObject() async throws {
        let observable = PureObservableModel()
        let model = ModelHoldingObservable(observable: observable).withAnchor(options: [])
        
        let changeDetected = LockIsolated(false)
        
        // Set up observation tracking on model's computed property that accesses observable
        let observationTask = Task {
            withObservationTracking {
                _ = model.doubledObservableValue
            } onChange: {
                changeDetected.setValue(true)
            }
        }
        
        await observationTask.value
        
        // Initial value should be accessible
        #expect(model.doubledObservableValue == 0, "Initial doubled value should be 0")
        
        // Change the observable object
        observable.value = 5
        
        // Wait for observation to propagate
        try await Task.sleep(for: .milliseconds(100))
        
        // The model should observe changes to the @Observable object
        #expect(model.doubledObservableValue == 10, "Model should read updated Observable value")
        #expect(changeDetected.value, "withObservationTracking should detect changes to @Observable via @Model")
    }
    
    /// Test that @Model can have an @Observable dependency (via Dependencies framework) and observe it
    /// This proves the claim: "A @Model can have a dependency that is @Observable and observe it via @Model"
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test
    func testModelWithObservableDependency() async throws {
        let observable = PureObservableModel()
        
        let model = ModelWithObservableDependency().withAnchor(options: []) {
            $0[PureObservableModel.self] = observable
        }
        
        let changeDetected = LockIsolated(false)
        
        // Set up observation tracking on model's computed property that accesses dependency
        let observationTask = Task {
            withObservationTracking {
                _ = model.dependencyValue
            } onChange: {
                changeDetected.setValue(true)
            }
        }
        
        await observationTask.value
        
        // Initial dependency value should be accessible
        #expect(model.dependencyValue == 0, "Initial dependency value should be 0")
        
        // Change the observable dependency
        observable.value = 42
        
        // Wait for observation to propagate
        try await Task.sleep(for: .milliseconds(100))
        
        // The model should observe changes to the @Observable dependency
        #expect(model.dependencyValue == 42, "Model should read updated Observable dependency")
        #expect(changeDetected.value, "withObservationTracking should detect changes to @Observable dependency via @Model")
    }
    
    /// Test that Observed stream works with @Model accessing @Observable
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test
    func testObservedStreamWithModelAccessingObservable() async throws {
        let observable = PureObservableModel()
        let model = ModelHoldingObservable(observable: observable).withAnchor(options: [])
        
        let values = LockIsolated<[Int]>([])
        
        let task = Task {
            for await value in Observed({ model.doubledObservableValue }) {
                values.withValue { $0.append(value) }
                if value >= 20 {
                    break
                }
            }
        }
        
        // Wait for initial value
        try await Task.sleep(for: .milliseconds(50))
        #expect(values.value.contains(0), "Should have initial value 0")
        
        // Change observable
        observable.value = 5
        try await Task.sleep(for: .milliseconds(100))
        
        #expect(values.value.contains(10), "Observed should track @Observable changes via @Model")
        
        observable.value = 10
        try await task.value
        
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
/// Pure @Observable type (not @Model) for testing interoperability
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Observable private class PureObservableModel: @unchecked Sendable {
    var value = 0
}

/// @Model that holds an @Observable object as a property
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Model private struct ModelHoldingObservable {
    var observable: PureObservableModel
    
    var doubledObservableValue: Int {
        observable.value * 2
    }
}

/// Dependency key for @Observable object
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension PureObservableModel: DependencyKey {
    static let liveValue = PureObservableModel()
    static let testValue = PureObservableModel()
}

/// @Model that accesses @Observable via dependency injection
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
@Model private struct ModelWithObservableDependency {
    @ModelDependency var observable: PureObservableModel
    
    var dependencyValue: Int {
        observable.value
    }
}

