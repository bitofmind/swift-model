import Testing
import Observation
import ConcurrencyExtras
import Foundation
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
@Suite(.backgroundCallIsolation)
struct MemoizeDirtyObservationTests {

    // MARK: - Test Configuration Helper

    struct TestConfig {
        let name: String
        let options: ModelOption
        let useObservationTracking: Bool
        let useCoalescing: Bool

        static let allConfigurations: [TestConfig] = [
            // ObservationTracking path (iOS 17+) - always uses coalescing
            // Note: Cannot test OT+NoCoal - withObservationTracking requires async execution
            // which inherently batches updates
            TestConfig(name: "OT+Coal", options: [],
                      useObservationTracking: true, useCoalescing: true),

            // AccessCollector path (pre-iOS 17 or forced) - can run without coalescing
            // Note: Observed stream with .disableObservationRegistrar requires coalesceUpdates: false
            // to force AccessCollector path (withObservationTracking doesn't observe models without ObservationRegistrar)
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
        let model = withModelOptions(config.options) { DirtyTrackingModel().withAnchor() }

        // Use Observed stream for consistent testing across both paths
        let updates = LockIsolated<[Int]>([])
        let stream = Observed(coalesceUpdates: config.useCoalescing) { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(updates.value.count >= 1)
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

        // Wait for the observation update with proper timeout for heavy load
        let startTime = ContinuousClock.now
        while !updates.value.contains(10) {
            if ContinuousClock.now - startTime > .seconds(5) {
                break // Timeout after 5 seconds
            }
            try await Task.sleep(for: .milliseconds(10))
        }

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

        // Use update() function to continuously observe, which properly handles re-tracking
        let (cancellable, _) = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: true,
            useCoalescing: true
        ) {
            model.computed
        } onUpdate: { value in
            observationCount.withValue { $0 += 1 }
            observedValues.withValue { $0.append(value) }
        }

        defer { cancellable() }

        // Wait for initial observation to complete
        try await waitUntil(observedValues.value.count >= 1)
        
        // Initial state
        #expect(model.value == 0)
        #expect(model.computed == 0)
        #expect(observedValues.value == [0], "Should have initial value")
        
        let initialObservationCount = observationCount.value
        print("Initial state: observationCount=\(initialObservationCount), observedValues=\(observedValues.value)")

        // Mutate the dependency
        // This will:
        // 1. Mark the memoize cache as dirty (via didModify callback)
        // 2. Schedule a coalesced update via backgroundCall
        model.value = 5
        print("AFTER mutation: observationCount=\(observationCount.value), observedValues=\(observedValues.value)")

        // CRITICAL: Access the memoized property immediately, before backgroundCall fires
        // This hits the dirty path which recomputes and returns fresh value
        // For withObservationTracking, the dirty path does NOT notify synchronously (to avoid
        // infinite recursion). Instead, it keeps isDirty=true so performUpdate fires and
        // re-establishes tracking asynchronously.
        let freshValue = model.computed
        print("AFTER access: freshValue=\(freshValue), observationCount=\(observationCount.value), observedValues=\(observedValues.value)")

        #expect(freshValue == 10, "Should compute fresh value (5 * 2)")
        #expect(model.computeCount.value >= 2, "Should have recomputed at least once via dirty path")

        // Wait for the scheduled performUpdate to fire
        // Note: performUpdate is scheduled via backgroundCall, which might take some time
        print("Waiting for performUpdate to fire...")
        try await waitUntil(observationCount.value > initialObservationCount, timeout: 5_000_000_000)

        // After performUpdate fires, observation should be triggered and tracking re-established
        print("Observation fired: \(observationCount.value) times")
        print("Observed values: \(observedValues.value)")
        #expect(observationCount.value > initialObservationCount, "performUpdate should have triggered observation")
        #expect(observedValues.value.contains(10), "Should have observed the new value via performUpdate")
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
        try await waitUntil(updates.value.count >= 1)
        #expect(updates.value.count >= 1, "Should have initial value")
        #expect(updates.value.first == 0, "Initial value should be 0")

        // Clear updates to focus on the mutation
        updates.setValue([])

        // Mutate and immediately access (dirty path)
        model.value = 5
        let _ = model.computed  // Access dirty property

        // Wait for observation to propagate
        try await waitUntil(updates.value.count >= 1)

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
        let model = withModelOptions([.disableObservationRegistrar]) { DirtyTrackingModel().withAnchor() }

        let observationCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])

        // Use Observed with AccessCollector (coalesceUpdates: false forces AccessCollector path)
        let stream = Observed(coalesceUpdates: false) { model.computed }

        let task = Task {
            for await value in stream {
                observationCount.withValue { $0 += 1 }
                observedValues.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial
        try await waitUntil(observedValues.value.count >= 1)
        #expect(observedValues.value == [0], "Should have initial value")

        // Mutate and immediately access
        model.value = 5
        let _ = model.computed  // Dirty path access

        // Wait for update
        try await waitUntil(observationCount.value >= 2)

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
        try await waitUntil(changeCount.value >= 1)

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
        withObservationTracking {
            _ = model.value
        } onChange: {
            changeCount.withValue { $0 += 1 }
        }

        model.value = 5
        try await Task.sleep(for: .milliseconds(50))

        print("Direct value tracking: changeCount=\(changeCount.value)")
        #expect(changeCount.value >= 1, "Direct value access should trigger onChange")

    }
    
    /// Test that simulates SwiftUI's ObservedModel behavior (via onModify callbacks)
    /// This is the REAL test for production SwiftUI usage
    @Test()
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testDirtyPathWithOnModifyCallback() async throws {
        let model = DirtyTrackingModel().withAnchor()
        
        let updateCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])
        
        // Create a custom ModelAccess to intercept willAccess calls (like ViewAccess does)
        final class TestAccess: ModelAccess, @unchecked Sendable {
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
                cancellable = context.onModify(for: path) { [weak self] finished, _ in
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
        
        // Wait for the onModify callback to fire and observe the new value
        let startTime = ContinuousClock.now
        while !observedValues.value.contains(10) {
            if ContinuousClock.now - startTime > .seconds(5) {
                break // Timeout after 5 seconds
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        
        print("FINAL: updateCount=\(updateCount.value), observedValues=\(observedValues.value)")
        
        // THE CRITICAL TEST: Did the onModify callback fire?
        // This is what SwiftUI depends on for view updates
        #expect(updateCount.value >= 1, "FAIL: onModify callback should fire (this is what SwiftUI needs)")
        #expect(observedValues.value.contains(10), "FAIL: Should have observed new value 10")
    }

    // MARK: - Tracking Loss After isSame=true

    /// Regression test for: memoize loses tracking of `hoverID` after a rapid sequence of
    /// non-nil → nil → non-nil changes when the memoize closure returns the same equatable
    /// value (empty array) for the nil state. Without the fix, isDirty stays true indefinitely
    /// after a performUpdate where isSame=true, but hasPendingUpdate is cleared, so subsequent
    /// changes to hoverID do not trigger new observation updates.
    ///
    /// Scenario mirrors `contextPreviewSegments` in ParallelEditor:
    /// - `hoverID` nil  → memoize returns []
    /// - `hoverID` = X  → memoize returns [segment]   (triggers update, tracking re-established)
    /// - `hoverID` nil  → memoize returns []           (isSame([], []) would be true after
    ///                                                   performUpdate if isDirty not cleared)
    /// - `hoverID` = Y  → should trigger update        (BUG: tracking lost, no update fired)
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testMemoizeTrackingNotLostAfterIsSameTrue() async throws {
        let model = ConditionalMemoizeModel().withAnchor()

        let updates = LockIsolated<[[Int]]>([])
        let stream = Observed { model.segments }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        // Wait for initial empty value
        try await waitUntil(updates.value.count >= 1)
        #expect(updates.value.last == [], "Initial should be empty")
        updates.setValue([])

        // Hover over item 1 → [1]
        model.hoverID = 1
        try await waitUntil(updates.value.last == [1], timeout: 2_000_000_000)
        #expect(updates.value.last == [1], "Should see [1] after hover")
        updates.setValue([])

        // End hover → []
        model.hoverID = nil
        try await waitUntil(updates.value.last == [], timeout: 2_000_000_000)
        updates.setValue([])

        // Hover over item 2 → [2]
        // BUG: Without the fix, this change is not observed because isDirty was
        // never cleared after performUpdate saw isSame([], [])==true for the nil state.
        model.hoverID = 2
        try await waitUntil(updates.value.last == [2], timeout: 2_000_000_000)
        #expect(updates.value.last == [2], "Should see [2] — memoize must still track hoverID")

        // Repeat the cycle to confirm tracking persists
        updates.setValue([])
        model.hoverID = nil
        try await waitUntil(updates.value.last == [], timeout: 2_000_000_000)
        updates.setValue([])
        model.hoverID = 3
        try await waitUntil(updates.value.last == [3], timeout: 2_000_000_000)
        #expect(updates.value.last == [3], "Should see [3] — tracking must persist across cycles")
    }

    // MARK: - Sustained Tracking Tests

    /// Tests both observation paths for the isSame=true tracking-loss scenario.
    /// The existing testMemoizeTrackingNotLostAfterIsSameTrue only exercises the default
    /// (withObservationTracking) path. This parameterized test covers both.
    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testMemoizeTrackingNotLostAfterIsSameTrue_BothPaths(path: ObservationPath) async throws {
        let model = path.withOptions { ConditionalMemoizeModel().withAnchor() }

        let updates = LockIsolated<[[Int]]>([])
        let stream = Observed { model.segments }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(updates.value.count >= 1)
        #expect(updates.value.last == [], "[\(path)] Initial should be empty")

        // One full nil → X → nil → Y cycle (the exact bug scenario)
        model.hoverID = 1
        try await waitUntil(updates.value.last == [1], timeout: 2_000_000_000)
        #expect(updates.value.last == [1], "[\(path)] Should see [1]")

        model.hoverID = nil
        try await waitUntil(updates.value.last == [], timeout: 2_000_000_000)

        model.hoverID = 2
        try await waitUntil(updates.value.last == [2], timeout: 2_000_000_000)
        #expect(updates.value.last == [2], "[\(path)] Should see [2] — tracking must survive isSame=true")
    }

    /// Stress test: 50 nil → X → nil cycles, verifying tracking survives all of them.
    /// Exercises the "stops updating after a while" production scenario where repeated
    /// isSame=true cycles could accumulate state corruption.
    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testMemoizeTrackingSurvivedManyIsSameTrueCycles(path: ObservationPath) async throws {
        let model = path.withOptions { ConditionalMemoizeModel().withAnchor() }

        let updates = LockIsolated<[[Int]]>([])
        let stream = Observed { model.segments }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // 50 cycles of nil→X→nil. Each nil transition causes isSame([], [])==true.
        // After 50 cycles the subscription must still be alive.
        for i in 1...50 {
            model.hoverID = i
            try await waitUntil(updates.value.last == [i], timeout: 3_000_000_000)
            #expect(updates.value.last == [i], "[\(path)] Cycle \(i): should see [\(i)]")

            model.hoverID = nil
            try await waitUntil(updates.value.last == [], timeout: 3_000_000_000)
        }

        // Final check: subscription still alive after 10 cycles
        model.hoverID = 99
        try await waitUntil(updates.value.last == [99], timeout: 3_000_000_000)
        #expect(updates.value.last == [99], "[\(path)] Subscription must survive 10 isSame=true cycles")
    }

    /// Verifies that `produce` is always called when a dependency changes, even after
    /// many rapid mutations that coalesce into a single performUpdate.
    /// Specifically tests that the `access()` short-circuit (`!entry.isDirty`) inside
    /// `withObservationTracking { access() }` does not skip dependency re-registration.
    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testProduceCalledAfterRapidMutations(path: ObservationPath) async throws {
        let model = path.withOptions { DirtyTrackingModel().withAnchor() }
        let computeCountBefore = model.computeCount.value

        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // Fire 20 rapid mutations without awaiting between them
        for i in 1...20 {
            model.value = i
        }

        // Hop 1: wait for memoize performUpdate (per-test isolated queue).
        // Hop 2 (Observed performUpdate) is dispatched from the drain task, which
        // has no task-local, so it goes to the GLOBAL BackgroundCallQueue — not the
        // per-test queue. We cannot waitForCurrentItems on the global queue here.
        // Use a generous waitUntil timeout instead so the consumer task has time to
        // receive the value.
        await backgroundCall.waitForCurrentItems(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)

        // The final value must be observed (20 * 2 = 40)
        // 10 s covers: global queue drain (usually <100 ms) + consumer task scheduling (usually <500 ms).
        try await waitUntil(updates.value.contains(40), timeout: 10_000_000_000)
        #expect(updates.value.contains(40), "[\(path)] Final value 40 must be observed after 20 rapid mutations")

        // produce must have been called at least once to compute the new value
        #expect(model.computeCount.value > computeCountBefore, "[\(path)] produce must be called after rapid mutations")

        // Now fire another round to confirm the subscription is still alive
        updates.setValue([])
        for i in 1...20 {
            model.value = 20 + i
        }
        // Same two-hop delivery as above; only wait on per-test queue for hop 1.
        await backgroundCall.waitForCurrentItems(deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        // Final value: 40 * 2 = 80
        try await waitUntil(updates.value.contains(80), timeout: 10_000_000_000)
        #expect(updates.value.contains(80), "[\(path)] Subscription must survive a second round of rapid mutations")
    }

    /// Regression test for the produce-never-called symptom: verifies that after
    /// a full update cycle, a subsequent dependency change notifies observers.
    ///
    /// The `access()` closure passed to `withObservationTracking` short-circuits
    /// to the cached value when `isDirty == false`. This test verifies that
    /// `isDirty` is always `true` when `observe()` runs inside `performUpdate`,
    /// so `produce()` is called and dependencies are re-registered.
    @Test(arguments: ObservationPath.allCases)
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testSubscriptionNotLostAfterUpdateCycle(path: ObservationPath) async throws {
        let model = path.withOptions { DirtyTrackingModel().withAnchor() }

        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        try await waitUntil(updates.value.count >= 1)
        #expect(updates.value.last == 0, "[\(path)] Initial value should be 0")

        // First update cycle: value changes, produce is called, subscription re-established
        model.value = 1
        // 10 s covers global queue drain + consumer task scheduling under heavy CI load.
        try await waitUntil(updates.value.contains(2), timeout: 10_000_000_000)
        #expect(updates.value.contains(2), "[\(path)] First update: should observe 2")

        // Second update cycle: dependency changes again — subscription must still be live
        updates.setValue([])
        model.value = 5
        try await waitUntil(updates.value.contains(10), timeout: 10_000_000_000)
        #expect(updates.value.contains(10), "[\(path)] Second update: subscription must still be active")

        // Third cycle
        updates.setValue([])
        model.value = 10
        try await waitUntil(updates.value.contains(20), timeout: 10_000_000_000)
        #expect(updates.value.contains(20), "[\(path)] Third update: subscription must still be active")
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

/// Model that mimics contextPreviewSegments: returns a non-empty array when hoverID is set,
/// empty array otherwise. Used to test that memoize tracking is not lost when isSame=true.
@Model
private struct ConditionalMemoizeModel {
    var hoverID: Int?

    var segments: [Int] {
        node.memoize {
            guard let id = hoverID else { return [] }
            return [id]
        }
    }
}
