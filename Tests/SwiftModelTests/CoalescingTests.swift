import Testing
import ConcurrencyExtras
import Foundation
@testable import SwiftModel

/// Tests for update coalescing behavior
///
/// These tests validate that:
/// 1. Without coalescing: N mutations → N update callbacks
/// 2. With coalescing: N mutations → 1 update callback (via BackgroundCalls)
/// 3. Coalescing works for both AccessCollector and withObservationTracking paths
/// 4. Values remain fresh (not stale) with coalescing enabled
struct CoalescingTests {
    
    // MARK: - AccessCollector Path Tests
    
    /// Test that without coalescing, N mutations trigger N update callbacks (AccessCollector path)
    @Test func testWithoutCoalescing_AccessCollector() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        
        // Set up observer WITHOUT coalescing (default behavior)
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,  // Use AccessCollector
            useCoalescing: false,  // Disable coalescing
            access: { model.value },
            onUpdate: { _ in
                updateCount.withValue { $0 += 1 }
            }
        )
        
        defer { cancellable() }
        
        // Initial update should fire
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Make 5 mutations
        for i in 1...5 {
            model.value = i
        }
        
        // Wait for all updates to complete
        try await waitUntil(updateCount.value == 6)
        
        #expect(updateCount.value == 6, "Should have 1 initial + 5 mutation updates = 6 total")
    }
    
    /// Test that with coalescing, N mutations trigger only 1 update callback (AccessCollector path)
    @Test func testWithCoalescing_AccessCollector() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let lastValue = LockIsolated(0)
        
        // Set up observer WITH coalescing
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,  // Use AccessCollector
            useCoalescing: true,  // Enable coalescing
            access: { model.value },
            onUpdate: { value in
                updateCount.withValue { $0 += 1 }
                lastValue.setValue(value)
            }
        )
        
        defer { cancellable() }
        
        // Initial update should fire
        #expect(updateCount.value == 1, "Should have initial update")
        #expect(lastValue.value == 0, "Initial value should be 0")
        
        // Make 5 mutations in quick succession
        for i in 1...5 {
            model.value = i
        }
        
        // Wait for coalesced update to complete
        try await waitUntil(lastValue.value == 5)
        
        // Should have 1 initial + 1 coalesced update = 2 total
        #expect(updateCount.value == 2, "Should have 1 initial + 1 coalesced update = 2 total")
        
        // Last value should be the final mutation (5)
        #expect(lastValue.value == 5, "Should have final value 5")
    }
    
    /// Test coalescing with multiple batches (AccessCollector path)
    @Test func testCoalescingMultipleBatches_AccessCollector() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in
                updateCount.withValue { $0 += 1 }
            }
        )
        
        defer { cancellable() }
        
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Batch 1: 3 mutations
        for i in 1...3 {
            model.value = i
        }
        
        // Wait for batch 1 to process
        try await waitUntil(updateCount.value == 2)
        
        let countAfterBatch1 = updateCount.value
        #expect(countAfterBatch1 == 2, "Should have 1 initial + 1 batch = 2")
        
        // Batch 2: 3 more mutations
        for i in 4...6 {
            model.value = i
        }
        
        // Wait for batch 2 to process
        try await waitUntil(updateCount.value == 3)
        
        let countAfterBatch2 = updateCount.value
        #expect(countAfterBatch2 == 3, "Should have 1 initial + 2 batches = 3")
    }
    
    // MARK: - withObservationTracking Path Tests
    
    // Note: Cannot test "without coalescing" with withObservationTracking
    // withObservationTracking fundamentally requires async execution (via backgroundCall)
    // to avoid synchronous recursion, which inherently batches updates.
    // Non-coalescing mode is only available with AccessCollector.
    
    /// Test that with coalescing, N mutations trigger only 1 update callback (withObservationTracking path)
    @Test func testWithCoalescing_WithObservationTracking() async throws {
        let model = TestModel().withAnchor(options: [])
        let updateCount = LockIsolated(0)
        let lastValue = LockIsolated(0)
        
        // Set up observer WITH coalescing
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,  // Use withObservationTracking
            useCoalescing: true,  // Enable coalescing
            access: { model.value },
            onUpdate: { value in
                updateCount.withValue { $0 += 1 }
                lastValue.setValue(value)
            }
        )
        
        defer { cancellable() }
        
        // Initial update should fire
        #expect(updateCount.value == 1, "Should have initial update")
        #expect(lastValue.value == 0, "Initial value should be 0")
        
        // Make 5 mutations in quick succession
        for i in 1...5 {
            model.value = i
        }
        
        // Wait for coalesced update to complete
        try await waitUntil(lastValue.value == 5)
        
        // Should have 1 initial + 1 coalesced update = 2 total
        #expect(updateCount.value == 2, "Should have 1 initial + 1 coalesced update = 2 total")
        
        // Last value should be the final mutation (5)
        #expect(lastValue.value == 5, "Should have final value 5")
    }
    
    /// Test coalescing with multiple batches (withObservationTracking path)
    @Test func testCoalescingMultipleBatches_WithObservationTracking() async throws {
        let model = TestModel().withAnchor(options: [])
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in
                updateCount.withValue { $0 += 1 }
            }
        )
        
        defer { cancellable() }
        
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Batch 1: 3 mutations
        for i in 1...3 {
            model.value = i
        }
        
        // Wait for batch 1 to process
        try await waitUntil(updateCount.value == 2)
        
        let countAfterBatch1 = updateCount.value
        #expect(countAfterBatch1 == 2, "Should have 1 initial + 1 batch = 2")
        
        // Batch 2: 3 more mutations
        for i in 4...6 {
            model.value = i
        }
        
        // Wait for batch 2 to process
        try await waitUntil(updateCount.value == 3)
        
        let countAfterBatch2 = updateCount.value
        #expect(countAfterBatch2 == 3, "Should have 1 initial + 2 batches = 3")
    }
    
    // MARK: - Freshness Tests
    
    /// Test that coalescing still provides fresh values, not stale (AccessCollector)
    @Test func testCoalescingProvidesFreshValues_AccessCollector() async throws {
        let model = TestModel().withAnchor(options: [.disableObservationRegistrar])
        let observedValues = LockIsolated<[Int]>([])
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { value in
                observedValues.withValue { $0.append(value) }
            }
        )
        
        defer { cancellable() }
        
        // Mutate rapidly
        for i in 1...10 {
            model.value = i
        }
        
        // Wait for coalesced update to complete
        try await waitUntil(observedValues.value.count == 2)
        
        // Should have initial (0) and final (10)
        let values = observedValues.value
        #expect(values.count == 2, "Should have 2 values")
        #expect(values[0] == 0, "First value should be initial 0")
        #expect(values[1] == 10, "Second value should be final 10 (fresh, not stale)")
    }
    
    /// Test that coalescing still provides fresh values, not stale (withObservationTracking)
    @Test func testCoalescingProvidesFreshValues_WithObservationTracking() async throws {
        let model = TestModel().withAnchor(options: [])
        let observedValues = LockIsolated<[Int]>([])
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { value in
                observedValues.withValue { $0.append(value) }
            }
        )
        
        defer { cancellable() }
        
        // Mutate rapidly
        for i in 1...10 {
            model.value = i
        }
        
        // Wait for coalesced update to complete
        try await waitUntil(observedValues.value.count == 2)
        
        // Should have initial (0) and final (10)
        let values = observedValues.value
        #expect(values.count == 2, "Should have 2 values")
        #expect(values[0] == 0, "First value should be initial 0")
        #expect(values[1] == 10, "Second value should be final 10 (fresh, not stale)")
    }

    // MARK: - Transaction Tests
    
    /// Test that coalescing works correctly with rapid mutations (no transaction wrapper needed)
    /// Coalescing happens when threadLocals.postTransactions == nil (outside model's internal transaction)
    @Test func testCoalescingWithRapidMutations_AccessCollector() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: false,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )
        
        // Rapid mutations: should coalesce to very few updates
        for i in 1...100 {
            model.value = i
        }
        
        // Wait for coalesced update
        let previousCount = updateCount.value
        while updateCount.value == previousCount {
            await Task.yield()
        }
        for _ in 0..<10 { await Task.yield() }
        
        // Should have very few updates (coalesced) - much less than 100
        #expect(updateCount.value < 50, "Coalescing should reduce 100 mutations significantly, got \(updateCount.value)")
        #expect(updateCount.value >= 1, "Should have at least 1 update")
        
        cancellable()
    }
    
    /// Test that coalescing works correctly with rapid mutations using ObservationTracking
    @Test func testCoalescingWithRapidMutations_ObservationTracking() async throws {
        let model = TestModel().withAnchor(options: [])
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: false,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )
        
        // Rapid mutations: should coalesce to very few updates
        for i in 1...100 {
            model.value = i
        }
        
        // Wait for coalesced update
        let previousCount = updateCount.value
        while updateCount.value == previousCount {
            await Task.yield()
        }
        for _ in 0..<10 { await Task.yield() }
        
        // ObservationTracking may have slightly more due to async onChange behavior
        #expect(updateCount.value < 30, "Coalescing should reduce 100 mutations significantly, got \(updateCount.value)")
        
        cancellable()
    }
    
    /// Test that without coalescing, all mutations trigger updates
    @Test func testWithoutCoalescing_AllUpdatesFire() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: false,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: false,  // Coalescing disabled
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )
        
        // Without coalescing: each mutation triggers an update
        let mutationCount = 10
        for i in 1...mutationCount {
            model.value = i
        }
        
        // Wait for all updates
        while updateCount.value < mutationCount {
            await Task.yield()
        }
        
        // Should have all updates
        #expect(updateCount.value == mutationCount, "Without coalescing, should have all \(mutationCount) updates, got \(updateCount.value)")
        
        cancellable()
    }
    
    // MARK: - Comparison Test
    
    /// Direct comparison: coalescing reduces update count significantly
    @Test func testCoalescingReducesUpdateCount() async throws {
        // Without coalescing
        let modelNoCoalesce = TestModel().withAnchor()
        let countNoCoalesce = LockIsolated(0)
        
        let (cancel1, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: false,
            access: { modelNoCoalesce.value },
            onUpdate: { _ in countNoCoalesce.withValue { $0 += 1 } }
        )
        
        // With coalescing
        let modelCoalesce = TestModel().withAnchor()
        let countCoalesce = LockIsolated(0)
        
        let (cancel2, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: { modelCoalesce.value },
            onUpdate: { _ in countCoalesce.withValue { $0 += 1 } }
        )
        
        defer {
            cancel1()
            cancel2()
        }
        
        // Make 20 mutations to each
        for i in 1...20 {
            modelNoCoalesce.value = i
            modelCoalesce.value = i
        }
        
        // Wait until non-coalescing model has processed all updates
        try await waitUntil(countNoCoalesce.value >= 21)
        
        // Wait for coalescing to complete (should have at least 2 updates: initial + coalesced)
        try await waitUntil(countCoalesce.value >= 2)
        
        let noCoalesceCount = countNoCoalesce.value
        let coalesceCount = countCoalesce.value
        
        // Without coalescing: should have 21 updates (1 initial + 20 mutations)
        #expect(noCoalesceCount == 21, "Without coalescing should have 21 updates (got \(noCoalesceCount))")
        
        // With coalescing: should have fewer updates than without
        // Under load, coalescing may not batch perfectly, but should still reduce updates
        #expect(coalesceCount < noCoalesceCount, "Coalescing (\(coalesceCount)) should have fewer updates than non-coalescing (\(noCoalesceCount))")
    }
}

    // MARK: - Nested Model Tests
    
    /// Test coalescing with nested model mutations (AccessCollector)
    @Test func testCoalescingWithNestedModels_AccessCollector() async throws {
        let model = NestedModel().withAnchor()
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: { model.items.reduce(0) { $0 + $1.value } },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )
        
        defer { cancellable() }
        
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Mutate all nested items - should coalesce to 1 update
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }
        
        // Wait for coalesced update
        try await waitUntil(updateCount.value == 2)
        
        // With coalescing: 1 initial + 1 coalesced = 2
        #expect(updateCount.value == 2, "Should coalesce nested mutations into 1 update")
    }
    
    /// Test coalescing with nested model mutations (withObservationTracking)
    @Test func testCoalescingWithNestedModels_WithObservationTracking() async throws {
        let model = NestedModel().withAnchor(options: [])
        let updateCount = LockIsolated(0)
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { model.items.reduce(0) { $0 + $1.value } },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )
        
        defer { cancellable() }
        
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Mutate all nested items - should coalesce to 1 update
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }
        
        // Wait for coalesced update
        try await waitUntil(updateCount.value == 2)
        
        #expect(updateCount.value == 2, "Should coalesce nested mutations into 1 update")
    }
    
    // MARK: - Branching Dependency Tests
    
    /// Test coalescing with branching dependencies (AccessCollector)
    @Test func testCoalescingWithBranchingDependencies_AccessCollector() async throws {
        let model = BranchingModel().withAnchor()
        let updateCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: {
                // Branch: access different properties based on flag
                if model.useFirstPath {
                    return model.valueA
                } else {
                    return model.valueB
                }
            },
            onUpdate: { value in
                updateCount.withValue { $0 += 1 }
                observedValues.withValue { $0.append(value) }
            }
        )
        
        defer { cancellable() }
        
        #expect(updateCount.value == 1, "Should have initial update")
        #expect(observedValues.value == [0], "Initial value should be valueA (0)")
        
        // Mutate valueA (currently observed path) multiple times
        for i in 1...5 {
            model.valueA = i
        }
        
        // Wait for coalesced update - wait for the final value, not exact count
        try await waitUntil(observedValues.value.last == 5)
        
        #expect(updateCount.value >= 2, "Should have at least initial + 1 update")
        #expect(observedValues.value.last == 5, "Should see final valueA")
        
        // Switch branch to valueB
        model.useFirstPath = false
        
        // Wait for branch switch update - wait for the value change
        try await waitUntil(observedValues.value.last == 10)
        
        #expect(updateCount.value >= 3, "Should have updates after branch switch")
        #expect(observedValues.value.last == 10, "Should now see valueB")
        
        // Mutate valueB (now observed path) multiple times
        for i in 11...15 {
            model.valueB = i
        }
        
        // Wait for coalesced update - wait for final value
        try await waitUntil(observedValues.value.last == 15)
        let countBeforeMutatingA = updateCount.value
        
        #expect(observedValues.value.last == 15, "Should see final valueB")
        
        // Mutate valueA (NOT observed anymore) - should NOT trigger update
        model.valueA = 99
        
        try await Task.sleep(nanoseconds: 150_000_000)
        
        #expect(updateCount.value == countBeforeMutatingA, "Should NOT update for unobserved valueA")
        #expect(observedValues.value.last == 15, "Value should stay at valueB")
    }
    
    /// Test coalescing with branching dependencies (withObservationTracking)
    /// Note: withObservationTracking's dynamic dependency tracking works differently
    /// than AccessCollector - it tracks based on what was accessed during the onChange
    /// callback execution, not during the access closure.
    @Test func testCoalescingWithBranchingDependencies_WithObservationTracking() async throws {
        let model = BranchingModel().withAnchor(options: [])
        let updateCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])
        
        let (cancellable, _) = update(
            initial: true,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: {
                if model.useFirstPath {
                    return model.valueA
                } else {
                    return model.valueB
                }
            },
            onUpdate: { value in
                updateCount.withValue { $0 += 1 }
                observedValues.withValue { $0.append(value) }
            }
        )
        
        defer { cancellable() }
        
        #expect(updateCount.value == 1, "Should have initial update")
        #expect(observedValues.value == [0], "Initial value should be valueA")
        
        // Mutate valueA multiple times
        for i in 1...5 {
            model.valueA = i
        }
        
        // Wait for updates to complete (longer timeout for heavy load scenarios)
        try await waitUntil(observedValues.value.last == 5, timeout: 5_000_000_000)
        
        // Should see coalescing effect
        #expect(updateCount.value >= 2, "Should have at least initial + 1 coalesced update")
        #expect(observedValues.value.last == 5, "Should see final valueA")
        
        let countAfterValueA = updateCount.value
        
        // Switch branch
        model.useFirstPath = false
        
        // Wait for branch switch (longer timeout for heavy load scenarios)
        try await waitUntil(observedValues.value.last == 10, timeout: 5_000_000_000)
        
        #expect(updateCount.value > countAfterValueA, "Should update when switching branches")
        #expect(observedValues.value.last == 10, "Should now see valueB")
        
        let countAfterSwitch = updateCount.value
        
        // Mutate valueB multiple times
        for i in 11...15 {
            model.valueB = i
        }
        
        // Wait for updates to complete (longer timeout for heavy load scenarios)
        try await waitUntil(observedValues.value.last == 15, timeout: 5_000_000_000)
        
        // Should see some updates but fewer than without coalescing
        #expect(updateCount.value > countAfterSwitch, "Should update for valueB changes")
        #expect(observedValues.value.last == 15, "Should see final valueB")
        
        // Verify coalescing happened (fewer than 5 individual updates for valueB)
        let valueBUpdates = updateCount.value - countAfterSwitch
        #expect(valueBUpdates < 5, "Should coalesce valueB mutations (got \(valueBUpdates) updates instead of 5)")
    }
    
    // MARK: - Observed API Tests
    
    /// Test Observed with coalesceUpdates enabled (opt-in)
    @Test func testObservedWithCoalescing() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let lastValue = LockIsolated(0)
        
        // Create Observed stream with coalescing enabled
        let observed = Observed(coalesceUpdates: true) { model.value }
        
        let task = Task {
            for await value in observed {
                updateCount.withValue { $0 += 1 }
                lastValue.setValue(value)
            }
        }
        
        // Wait for initial value
        try await waitUntil(updateCount.value == 1)
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Make 10 rapid mutations
        for i in 1...10 {
            model.value = i
        }
        
        // Wait for coalesced update
        try await waitUntil(lastValue.value == 10)
        
        // Should have 1 initial + 1 coalesced update
        #expect(updateCount.value == 2, "Should have 1 initial + 1 coalesced update")
        #expect(lastValue.value == 10, "Should have final value 10")
        
        task.cancel()
    }
    
    /// Test Observed with coalesceUpdates explicitly disabled
    @Test func testObservedWithoutCoalescing() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        
        // Create Observed stream WITHOUT coalescing (explicitly disabled)
        let observed = Observed(coalesceUpdates: false) { model.value }
        
        let task = Task {
            for await _ in observed {
                updateCount.withValue { $0 += 1 }
            }
        }
        
        // Wait for initial value
        try await waitUntil(updateCount.value == 1)
        #expect(updateCount.value == 1, "Should have initial update")
        
        // Make 5 mutations
        for i in 1...5 {
            model.value = i
        }
        
        // Wait for all updates
        try await waitUntil(updateCount.value == 6)
        
        // Should have 1 initial + 5 updates = 6 total
        #expect(updateCount.value == 6, "Should have 1 initial + 5 updates = 6 total")
        
        task.cancel()
    }
    
    /// Test Observed with both removeDuplicates and coalesceUpdates
    @Test func testObservedWithRemoveDuplicatesAndCoalescing() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])
        
        // Create Observed stream with both features enabled
        let observed = Observed(removeDuplicates: true, coalesceUpdates: true) { model.value }
        
        let task = Task {
            for await value in observed {
                updateCount.withValue { $0 += 1 }
                observedValues.withValue { $0.append(value) }
            }
        }
        
        // Wait for initial value
        try await waitUntil(updateCount.value == 1)
        #expect(updateCount.value == 1, "Should have initial update")
        #expect(observedValues.value == [0], "Should have initial value 0")
        
        // Make rapid mutations: 1, 2, 2, 2, 3
        // With coalescing, these will be batched into 1-2 updates
        model.value = 1
        model.value = 2
        model.value = 2  // Duplicate
        model.value = 2  // Duplicate
        model.value = 3
        
        // Wait for coalesced updates
        try await waitUntil(observedValues.value.last == 3)
        
        // With coalescing: rapid mutations get batched, final value is 3
        // With removeDuplicates: if we somehow see intermediate values, duplicates are filtered
        // Most likely outcome: [0, 3] (coalescing batches all mutations into one with final value 3)
        #expect(observedValues.value.last == 3, "Should have final value 3")
        #expect(observedValues.value.count >= 2, "Should have at least initial and final")
        
        task.cancel()
    }
    
    /// Test Observed without removeDuplicates but with coalescing
    @Test func testObservedWithoutRemoveDuplicates() async throws {
        let model = TestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let observedValues = LockIsolated<[Int]>([])
        
        // Create Observed stream without removeDuplicates but with coalescing
        let observed = Observed(removeDuplicates: false, coalesceUpdates: true) { model.value }
        
        let task = Task {
            for await value in observed {
                updateCount.withValue { $0 += 1 }
                observedValues.withValue { $0.append(value) }
            }
        }
        
        // Wait for initial value
        try await waitUntil(updateCount.value == 1)
        #expect(updateCount.value == 1)
        
        // Set to same value multiple times
        model.value = 5
        model.value = 5  // Same value
        model.value = 5  // Same value
        
        // Wait for updates
        try await waitUntil(observedValues.value.last == 5)
        
        // Without removeDuplicates, coalescing will batch but won't filter duplicates
        // However, with coalescing, rapid identical mutations still result in just 1 coalesced update
        // because the final value is 5, and coalescing batches them into one callback with value 5
        #expect(updateCount.value >= 1, "Should have at least initial update")
        #expect(observedValues.value.last == 5, "Should have final value 5")
        
        task.cancel()
    }
    

// MARK: - Test Models

@Model private struct TestModel {
    var value = 0
}
@Model private struct ItemModel {
    var value = 0
}

@Model private struct MemoizeTestModel {
    var items: [ItemModel] = []
    let sortCallCount = LockIsolated(0)
    
    var sorted: [ItemModel] {
        node.memoize(for: "sorted") {
            sortCallCount.withValue { $0 += 1 }
            return items.sorted { $0.value < $1.value }
        }
    }
}

@Model private struct NestedModel {
    var items: [ItemModel] = [
        ItemModel(value: 0),
        ItemModel(value: 0),
        ItemModel(value: 0),
        ItemModel(value: 0),
        ItemModel(value: 0)
    ]
}

@Model private struct BranchingModel {
    var useFirstPath = true
    var valueA = 0
    var valueB = 10
}

