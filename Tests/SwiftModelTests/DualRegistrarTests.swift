import Testing
import Observation
import ConcurrencyExtras
import Foundation
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
        
        try await observationTask.value
        
        #expect(transactionCount.value == 2, "Should batch transaction changes into one observation")
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
