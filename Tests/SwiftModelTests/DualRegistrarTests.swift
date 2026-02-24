import Testing
import Observation
import ConcurrencyExtras
import Foundation
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
        let (model, tester) = TestModel().andTester(options: [.useWithObservationTracking])
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
        let model = TestModel().withAnchor(options: [.useWithObservationTracking])

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
        let (model, tester) = TestModel().andTester(options: [.useWithObservationTracking])
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
        let model = TestModel().withAnchor(options: [.useWithObservationTracking])

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
        let (model, tester) = MemoizeModel().andTester(options: [.useWithObservationTracking])
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
        await tester.assert { model.accessCount == 1 }

        // Change underlying value
        model.value = 5

        // Background observer should detect change without mainCall delay
        await tester.assert(timeoutNanoseconds: 100_000_000) {
            changeDetected.value
        }

        #expect(changeDetected.value, "Background observer should have detected change")
        #expect(model.accessCount >= 1, "Memoized property should have been accessed")
    }

    /// Same test as above but using old .withAnchor() style
    @Test func testMemoizeWithBackgroundObserver_WithAnchor() async throws {
        let model = MemoizeModel().withAnchor(options: [.useWithObservationTracking])

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
        #expect(model.accessCount == 1, "Should have accessed doubled once during setup")

        // Change underlying value
        model.value = 5

        // Background observer should detect change synchronously - no polling!
        #expect(changeDetected.value, "Background observer should have detected change synchronously")
        #expect(model.accessCount >= 1, "Memoized property should have been accessed")
    }
}

// MARK: - Test Models

@Model private struct TestModel {
    var value = 0
}

@Model private struct MemoizeModel {
    var value = 0
    var accessCount = 0

    var doubled: Int {
        accessCount += 1
        return node.memoize(for: "doubled") {
            value * 2
        }
    }
}
