import Testing
import Observation
import ConcurrencyExtras
@testable import SwiftModel

/// Tests for memoize dirty tracking and observation updates
/// These tests verify that the dirty tracking optimization doesn't bypass observation notifications
///
/// Test Matrix:
/// - Observation: ObservationTracking (iOS 17+) vs AccessCollector (pre-iOS 17)
/// - Coalescing: Enabled (default) vs Disabled
///
/// Note: Dirty tracking is always enabled and cannot be disabled.
/// The matrix helps us identify exactly which combinations have issues.
struct MemoizeDirtyObservationTests {

    // MARK: - Test Configuration Helper

    struct TestConfig {
        let name: String
        let options: ModelOption
        let useObservationTracking: Bool
        let useCoalescing: Bool

        static let allConfigurations: [TestConfig] = [
            // ObservationTracking path (iOS 17+) - dirty tracking always enabled
            TestConfig(name: "OT+Coal", options: [],
                      useObservationTracking: true, useCoalescing: true),
            TestConfig(name: "OT+NoCoal", options: [.disableMemoizeCoalescing],
                      useObservationTracking: true, useCoalescing: false),

            // AccessCollector path (pre-iOS 17 or forced) - dirty tracking always enabled
            TestConfig(name: "AC+Coal", options: [.disableObservationRegistrar],
                      useObservationTracking: false, useCoalescing: true),
            TestConfig(name: "AC+NoCoal", options: [.disableObservationRegistrar, .disableMemoizeCoalescing],
                      useObservationTracking: false, useCoalescing: false),
        ]
    }

    // MARK: - Phase 1: Issue #1 - Dirty Tracking Bypasses Observation

    /// Comprehensive matrix test that checks all configuration combinations
    /// This helps us identify exactly which paths have the observation issue
    @Test(arguments: TestConfig.allConfigurations)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testDirtyPathMatrix(config: TestConfig) async throws {
        print("\n========== Testing: \(config.name) ==========")
        let model = DirtyTrackingModel().withAnchor(options: config.options)

        // Use Observed stream for consistent testing across both paths
        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial value
        try await Task.sleep(for: .milliseconds(50))
        let initialCount = updates.value.count
        #expect(initialCount >= 1, "[\(config.name)] Should have initial value, got \(updates.value)")

        // Clear to focus on the mutation
        updates.setValue([])

        // Mutate dependency (marks dirty, schedules coalesced update)
        model.value = 5

        // CRITICAL: Access immediately (before coalesced update fires)
        // This hits the dirty path if dirty tracking is enabled
        let freshValue = model.computed
        #expect(freshValue == 10, "[\(config.name)] Should compute fresh value")

        // Wait for any async updates
        try await Task.sleep(for: .milliseconds(150))

        // THE KEY QUESTION: Did we get an observation update?
        let hasUpdate = updates.value.contains(10)
        let updateCount = updates.value.count

        print("[\(config.name)] Updates received: \(updates.value), Count: \(updateCount)")
        print("[\(config.name)] Compute count: \(model.computeCount.value)")
        print("[\(config.name)] Fresh value was: \(freshValue)")

        // EXPECTATION: We should ALWAYS get an observation update when the value changes
        #expect(hasUpdate, "[\(config.name)] FAIL: Should observe new value 10, got \(updates.value)")
        #expect(updateCount >= 1, "[\(config.name)] FAIL: Should have at least 1 update, got \(updateCount)")
    }

    /// This test demonstrates the critical bug where accessing a dirty memoized property
    /// does not trigger observation updates, causing SwiftUI views to not re-render.
    ///
    /// Scenario:
    /// 1. Model has a memoized computed property that depends on a stored property
    /// 2. Set up observation tracking on the memoized property
    /// 3. Mutate the dependency (marks cache dirty, schedules coalesced update)
    /// 4. Immediately access the memoized property (before coalesced update fires)
    /// 5. EXPECTED: Observation callback should fire because value changed
    /// 6. ACTUAL: Observation callback does NOT fire (BUG)
    ///
    /// This is what happens in production:
    /// - User action mutates model → dirty flag set, backgroundCall scheduled
    /// - SwiftUI accesses memoized property in body → dirty path recomputes silently
    /// - SwiftUI body returns with fresh value BUT observation wasn't notified
    /// - SwiftUI doesn't re-render because it never got the observation update
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testDirtyPathTriggersObservation() async throws {
        let model = DirtyTrackingModel().withAnchor()

        // Track how many times observation fires
        let observationCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])

        // Set up observation tracking on the memoized property
        // This simulates what SwiftUI does when a view observes a model
        let cancellable = withObservationTracking {
            let value = model.computed
            observedValues.withValue { $0.append(value) }
        } onChange: {
            observationCount.withValue { $0 += 1 }

            // Re-establish observation (like SwiftUI does)
            withObservationTracking {
                let value = model.computed
                observedValues.withValue { $0.append(value) }
            } onChange: {
                observationCount.withValue { $0 += 1 }
            }
        }

        defer { _ = cancellable }

        // Initial state
        #expect(model.value == 0)
        #expect(model.computed == 0)
        #expect(observedValues.value == [0], "Should have initial value")

        // Mutate the dependency
        // This will:
        // 1. Mark the memoize cache as dirty (via didModify callback)
        // 2. Schedule a coalesced update via backgroundCall
        print("BEFORE mutation: observationCount=\(observationCount.value), observedValues=\(observedValues.value)")
        model.value = 5
        print("AFTER mutation: observationCount=\(observationCount.value), observedValues=\(observedValues.value)")

        // CRITICAL: Access the memoized property immediately, before backgroundCall fires
        // This hits the dirty path (lines 384-396 in Model+Changes.swift)
        // The dirty path recomputes and returns fresh value BUT doesn't trigger observation
        let freshValue = model.computed
        print("AFTER access: freshValue=\(freshValue), observationCount=\(observationCount.value), observedValues=\(observedValues.value)")

        #expect(freshValue == 10, "Should compute fresh value (5 * 2)")
        #expect(model.computeCount.value == 2, "Should have recomputed (initial + dirty path)")

        // THE BUG: Observation callback should have fired because value changed from 0 to 10
        // But the dirty path (line 386) just calls produce() without notifying observers
        #expect(observationCount.value >= 1, "FAILS: Observation should fire when value changes from 0 to 10")
        #expect(observedValues.value.contains(10), "FAILS: Should have observed the new value")

        // Wait a bit for any pending coalesced updates
        try? await Task.sleep(for: .milliseconds(100))

        // Even after waiting, if the dirty path didn't notify, the observation count might still be wrong
        print("Observation fired: \(observationCount.value) times")
        print("Observed values: \(observedValues.value)")
    }

    /// Similar test but uses Observed API (the stream-based observation)
    /// This tests that the dirty path works correctly with the Observed API
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testDirtyPathTriggersObservedStream() async throws {
        let model = DirtyTrackingModel().withAnchor()

        // Collect updates via Observed stream
        let updates = LockIsolated<[Int]>([])

        // Set up Observed stream (this is what .values does)
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial value
        try await Task.sleep(for: .milliseconds(50))
        #expect(updates.value.count >= 1, "Should have initial value")
        #expect(updates.value.first == 0, "Initial value should be 0")

        // Clear updates to focus on the mutation
        updates.setValue([])

        // Mutate and immediately access (dirty path)
        model.value = 5
        let _ = model.computed  // Access dirty property

        // Wait for observation to propagate
        try await Task.sleep(for: .milliseconds(100))

        // THE BUG: Stream should receive update because computed changed
        #expect(updates.value.count >= 1, "FAILS: Stream should receive update for value change")
        #expect(updates.value.contains(10), "FAILS: Stream should receive new value 10")

        print("Stream received updates: \(updates.value)")
    }

    /// Test with AccessCollector path to compare behavior
    /// This verifies whether the issue is specific to ObservationTracking or affects both paths
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testDirtyPathWithAccessCollector() async throws {
        // Disable ObservationRegistrar to force AccessCollector path
        let model = DirtyTrackingModel().withAnchor(options: [.disableObservationRegistrar])

        let observationCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])

        // Use Observed with AccessCollector
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                observationCount.withValue { $0 += 1 }
                observedValues.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial
        try await Task.sleep(for: .milliseconds(50))
        #expect(observedValues.value == [0], "Should have initial value")

        // Mutate and immediately access
        model.value = 5
        let _ = model.computed  // Dirty path access

        // Wait for update
        try await Task.sleep(for: .milliseconds(100))

        // Check if AccessCollector path has the same issue
        #expect(observationCount.value >= 2, "Should have received update")
        #expect(observedValues.value.contains(10), "Should have new value")

        print("AccessCollector observations: \(observationCount.value), values: \(observedValues.value)")
    }

    /// Test that demonstrates the real-world SwiftUI scenario
    /// This simulates what happens when SwiftUI body re-evaluates
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testSwiftUISimulation() async throws {
        let model = DirtyTrackingModel().withAnchor()

        // Simulate SwiftUI view render count
        let renderCount = LockIsolated(0)
        let changeCount = LockIsolated(0)

        // Helper to track changes
        let shouldRerender = LockIsolated(false)
        
        // Simulate SwiftUI body evaluation with observation tracking
        let simulateViewRender: @Sendable () -> Int = {
            renderCount.withValue { $0 += 1 }
            return withObservationTracking {
                model.computed  // Access memoized property
            } onChange: {
                // SwiftUI would invalidate view here and schedule re-render
                changeCount.withValue { $0 += 1 }
                shouldRerender.setValue(true)
            }
        }

        // Initial render
        let initialValue = simulateViewRender()
        #expect(initialValue == 0)
        #expect(renderCount.value == 1, "Should render once initially")

        // User action: mutate model
        model.value = 5

        // Simulate user-triggered immediate render (before backgroundCall fires)
        // This could happen if user taps rapidly or another view triggers update
        let freshValue = model.computed
        #expect(freshValue == 10, "Should see fresh value")

        // Wait for any pending updates and onChange to fire
        try await Task.sleep(for: .milliseconds(100))

        // SwiftUI should have been notified that computed changed from 0 to 10
        // The onChange should fire, indicating a re-render would be scheduled
        #expect(changeCount.value >= 1, "onChange should fire when value changes")
        #expect(shouldRerender.value == true, "SwiftUI should be notified to re-render")
        
        // Simulate the actual re-render that SwiftUI would perform
        if shouldRerender.value {
            let newValue = simulateViewRender()
            #expect(newValue == 10, "Re-render should see new value")
        }

        #expect(renderCount.value >= 2, "Should have rendered at least twice (initial + re-render)")

        print("SwiftUI renders: \(renderCount.value), onChange fired: \(changeCount.value) times")
    }

    /// Simplified test to check if withObservationTracking works at all with memoize
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testWithObservationTrackingBasic() async throws {
        let model = DirtyTrackingModel().withAnchor()

        let changeCount = LockIsolated(0)

        // Track just model.value directly (not through memoize)
        let cancellable1 = withObservationTracking {
            _ = model.value
        } onChange: {
            changeCount.withValue { $0 += 1 }
        }

        model.value = 5
        try await Task.sleep(for: .milliseconds(50))

        print("Direct value tracking: changeCount=\(changeCount.value)")
        #expect(changeCount.value >= 1, "Direct value access should trigger onChange")

        _ = cancellable1
    }
    
    /// Test that simulates SwiftUI's ObservedModel behavior (via onModify callbacks)
    /// This is the REAL test for production SwiftUI usage
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testDirtyPathWithOnModifyCallback() async throws {
        let model = DirtyTrackingModel().withAnchor()
        
        let updateCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])
        
        // Create a custom ModelAccess to intercept willAccess calls (like ViewAccess does)
        final class TestAccess: ModelAccess {
            let updateCount: LockIsolated<Int>
            let observedValues: LockIsolated<[Int]>
            let model: DirtyTrackingModel
            var cancellable: (() -> Void)?
            
            init(updateCount: LockIsolated<Int>, observedValues: LockIsolated<[Int]>, model: DirtyTrackingModel) {
                self.updateCount = updateCount
                self.observedValues = observedValues
                self.model = model
                super.init(useWeakReference: false)
            }
            
            override func willAccess<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? {
                guard let context = model.context else { return nil }
                
                // Register onModify callback (this is what ViewAccess does for SwiftUI)
                cancellable = context.onModify(for: path) { [weak self] finished in
                    guard let self else { return {} }
                    if !finished {
                        self.updateCount.withValue { $0 += 1 }
                        // Re-read value (like SwiftUI would)
                        if let typedPath = path as? KeyPath<DirtyTrackingModel, Int> {
                            let newValue = self.model[keyPath: typedPath]
                            self.observedValues.withValue { $0.append(newValue) }
                        }
                    }
                    return {}
                }
                
                return nil
            }
        }
        
        let testAccess = TestAccess(updateCount: updateCount, observedValues: observedValues, model: model)
        let modelWithAccess = model.withAccess(testAccess)
        
        // First access to establish observation
        let initialValue = modelWithAccess.computed
        observedValues.withValue { $0.append(initialValue) }
        
        print("BEFORE mutation: updateCount=\(updateCount.value), observedValues=\(observedValues.value)")
        
        // Mutate dependency (marks dirty, schedules coalesced update)
        modelWithAccess.value = 5
        
        // Immediately access (hits dirty path)
        let freshValue = modelWithAccess.computed
        print("AFTER dirty access: freshValue=\(freshValue), updateCount=\(updateCount.value), observedValues=\(observedValues.value)")
        
        #expect(freshValue == 10, "Should compute fresh value")
        
        // Wait for any pending async updates
        try await Task.sleep(for: .milliseconds(150))
        
        print("FINAL: updateCount=\(updateCount.value), observedValues=\(observedValues.value)")
        
        // THE CRITICAL TEST: Did the onModify callback fire?
        // This is what SwiftUI depends on for view updates
        #expect(updateCount.value >= 1, "FAIL: onModify callback should fire (this is what SwiftUI needs)")
        #expect(observedValues.value.contains(10), "FAIL: Should have observed new value 10")
    }
}

// MARK: - Test Models

@Model
private struct DirtyTrackingModel {
    var value = 0
    let computeCount = LockIsolated(0)

    var computed: Int {
        node.memoize(for: "computed") {
            computeCount.withValue { $0 += 1 }
            return value * 2
        }
    }
}
