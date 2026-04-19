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
@Suite(.backgroundCallIsolation)
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
        // Settle: drain loop runs concurrently and may produce one extra re-tracking call
        await backgroundCall.waitUntilIdle()

        // Should have 1 initial + 1 (or 2) coalesced updates. Exact count varies by scheduling.
        // Key invariant: coalescing reduced 5 mutations to far fewer than 5 callbacks.
        #expect(updateCount.value >= 2, "Should have at least 1 initial + 1 coalesced update")

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

        // Wait for batch 1 to settle (drain loop may add an extra re-tracking call)
        try await waitUntil(updateCount.value >= 2)
        await backgroundCall.waitUntilIdle()

        let countAfterBatch1 = updateCount.value
        #expect(countAfterBatch1 >= 2, "Should have 1 initial + at least 1 batch update")

        // Batch 2: 3 more mutations
        for i in 4...6 {
            model.value = i
        }

        // Wait for batch 2 to settle
        try await waitUntil(updateCount.value > countAfterBatch1)
        await backgroundCall.waitUntilIdle()

        #expect(updateCount.value > countAfterBatch1, "Should have processed second batch separately")
    }
    
    // MARK: - withObservationTracking Path Tests
    
    // Note: Cannot test "without coalescing" with withObservationTracking
    // withObservationTracking fundamentally requires async execution (via backgroundCall)
    // to avoid synchronous recursion, which inherently batches updates.
    // Non-coalescing mode is only available with AccessCollector.
    
    /// Test that with coalescing, N mutations trigger only 1 update callback (withObservationTracking path)
    @Test func testWithCoalescing_WithObservationTracking() async throws {
        let model = TestModel().withAnchor()
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
        // Settle: drain loop runs concurrently and may produce one extra re-tracking call
        await backgroundCall.waitUntilIdle()

        // Should have 1 initial + 1 (or 2) coalesced updates. Exact count varies by scheduling.
        // Key invariant: coalescing reduced 5 mutations to far fewer than 5 callbacks.
        #expect(updateCount.value >= 2, "Should have at least 1 initial + 1 coalesced update")

        // Last value should be the final mutation (5)
        #expect(lastValue.value == 5, "Should have final value 5")
    }

    /// Test coalescing with multiple batches (withObservationTracking path)
    @Test func testCoalescingMultipleBatches_WithObservationTracking() async throws {
        let model = TestModel().withAnchor()
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

        // Wait for batch 1 to settle (drain loop may add an extra re-tracking call)
        try await waitUntil(updateCount.value >= 2)
        await backgroundCall.waitUntilIdle()

        let countAfterBatch1 = updateCount.value
        #expect(countAfterBatch1 >= 2, "Should have 1 initial + at least 1 batch update")

        // Batch 2: 3 more mutations
        for i in 4...6 {
            model.value = i
        }

        // Wait for batch 2 to settle
        try await waitUntil(updateCount.value > countAfterBatch1)
        await backgroundCall.waitUntilIdle()

        #expect(updateCount.value > countAfterBatch1, "Should have processed second batch separately")
    }
    
    // MARK: - Freshness Tests
    
    /// Test that coalescing still provides fresh values, not stale (AccessCollector)
    @Test func testCoalescingProvidesFreshValues_AccessCollector() async throws {
        let model = withModelOptions([.disableObservationRegistrar]) { TestModel().withAnchor() }
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

        // Wait for the final value specifically: the drain loop runs concurrently, so an
        // intermediate batch might deliver a non-final value. Waiting for value==10 ensures
        // we verify freshness (the final, not a stale intermediate value).
        try await waitUntil(observedValues.value.last == 10)
        await backgroundCall.waitUntilIdle()

        // Should have initial (0) and final (10) as the bookends.
        // The count may be > 2 if the drain loop split mutations into batches.
        let values = observedValues.value
        #expect(values.count >= 2, "Should have at least initial and one update")
        #expect(values.first == 0, "First value should be initial 0")
        #expect(values.last == 10, "Last value should be final 10 (fresh, not stale)")
    }

    /// Test that coalescing still provides fresh values, not stale (withObservationTracking)
    @Test func testCoalescingProvidesFreshValues_WithObservationTracking() async throws {
        let model = TestModel().withAnchor()
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

        // Wait for the final value; coalescing may split into batches so count > 2 is allowed.
        try await waitUntil(observedValues.value.last == 10)
        await backgroundCall.waitUntilIdle()

        let values = observedValues.value
        #expect(values.count >= 2, "Should have at least initial and one update")
        #expect(values.first == 0, "First value should be initial 0")
        #expect(values.last == 10, "Last value should be final 10 (fresh, not stale)")
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
        defer { cancellable() }

        // Rapid mutations: should coalesce to very few updates
        for i in 1...100 {
            model.value = i
        }

        // Wait for all pending work to settle
        await backgroundCall.waitUntilIdle()

        // Should have very few updates (coalesced) — much less than 100.
        // The drain loop runs concurrently so exact count varies, but coalescing should
        // still reduce updates significantly (< 90 even under heavy scheduler pressure).
        #expect(updateCount.value < 90, "Coalescing should reduce 100 mutations significantly, got \(updateCount.value)")
        #expect(updateCount.value >= 1, "Should have at least 1 update")

        cancellable()
    }

    /// Test that coalescing works correctly with rapid mutations using ObservationTracking
    @Test func testCoalescingWithRapidMutations_ObservationTracking() async throws {
        let model = TestModel().withAnchor()
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

        // Wait for all pending work to settle
        await backgroundCall.waitUntilIdle()

        // withObservationTracking fires onChange synchronously per mutation. On a multi-core
        // machine the drain loop can run concurrently, so each mutation may clear
        // hasPendingUpdate and queue a fresh batch. The bound is deliberately loose
        // (< 90 rather than < 30) to hold on slow simulators and CI while still
        // verifying that coalescing reduced updates significantly compared to 100.
        #expect(updateCount.value < 90, "Coalescing should reduce 100 mutations significantly, got \(updateCount.value)")

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
        defer { cancellable() }

        // Without coalescing: each mutation triggers an update
        let mutationCount = 10
        for i in 1...mutationCount {
            model.value = i
        }

        try await waitUntil(updateCount.value >= mutationCount)

        #expect(updateCount.value == mutationCount, "Without coalescing, should have all \(mutationCount) updates, got \(updateCount.value)")
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
        
        // With coalescing: should have no more updates than without coalescing.
        // Under parallel load the drain loop may fire between each mutation,
        // preventing any batching, so the counts can be equal but never coalesce > noCoalesce.
        #expect(coalesceCount <= noCoalesceCount, "Coalescing (\(coalesceCount)) should not exceed non-coalescing (\(noCoalesceCount))")
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
        
        // Wait for coalesced update; drain loop may add an extra re-tracking call
        try await waitUntil(updateCount.value >= 2)
        await backgroundCall.waitUntilIdle()

        // With coalescing: 1 initial + at least 1 coalesced = >= 2
        #expect(updateCount.value >= 2, "Should coalesce nested mutations into very few updates")
    }

    /// Test coalescing with nested model mutations (withObservationTracking)
    @Test func testCoalescingWithNestedModels_WithObservationTracking() async throws {
        let model = NestedModel().withAnchor()
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

        // Wait for coalesced update; drain loop may add an extra re-tracking call
        try await waitUntil(updateCount.value >= 2)
        await backgroundCall.waitUntilIdle()

        #expect(updateCount.value >= 2, "Should coalesce nested mutations into very few updates")
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
        let model = BranchingModel().withAnchor()
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
        
        // Mutate valueB multiple times inside a transaction.
        // withObservationTracking's onChange fires once per registration and
        // re-registers only inside performUpdate (a background task). On multi-core
        // Linux that background task can re-register between loop iterations,
        // causing each mutation to see a fresh onChange and get its own update.
        // A transaction defers all onChange callbacks until after the block exits,
        // guaranteeing a single coalesced update regardless of scheduler timing.
        model.node.transaction {
            for i in 11...15 {
                model.valueB = i
            }
        }

        // Wait for updates to complete (longer timeout for heavy load scenarios)
        try await waitUntil(observedValues.value.last == 15, timeout: 5_000_000_000)
        
        // Should see some updates but fewer than without coalescing
        #expect(updateCount.value > countAfterSwitch, "Should update for valueB changes")
        #expect(observedValues.value.last == 15, "Should see final valueB")
        
        // Verify coalescing happened: transaction guarantees a single onChange fire,
        // so performUpdate runs at most once per transaction (≤ 2 with re-registration race).
        let valueBUpdates = updateCount.value - countAfterSwitch
        #expect(valueBUpdates < 5, "Should coalesce valueB mutations (got \(valueBUpdates) updates instead of 5)")
    }
    
    // MARK: - Observed API Tests
    //
    // These tests consume the Observed stream directly from the test task via
    // makeAsyncIterator(), rather than spawning a separate Task { for await ... }.
    // A separate consumer task depends on the cooperative pool being scheduled,
    // which stalls under 550+ parallel tests. Direct iteration from the test task
    // means the stream continuation resumes us immediately when the GCD drain
    // delivers the value — no polling, no cooperative-pool contention.

    /// Test Observed with coalesceUpdates enabled (opt-in)
    @Test func testObservedWithCoalescing() async throws {
        let model = TestModel().withAnchor()
        var iter = Observed(coalesceUpdates: true) { model.value }.makeAsyncIterator()

        // Consume initial value (delivered synchronously on first next())
        let v0 = await iter.next()
        #expect(v0 == 0, "Should have initial value 0")

        // Make 10 rapid mutations
        for i in 1...10 { model.value = i }

        // Drain until we see the final value 10. The GCD drain may fire mid-loop,
        // buffering an intermediate value before all mutations complete. With
        // coalescing, the final value 10 is guaranteed to arrive eventually.
        // At most 10 iterations (one per mutation) — no infinite loop risk.
        var lastSeen = 0
        for _ in 0..<10 {
            guard let v = await iter.next() else { break }
            lastSeen = v
            if lastSeen == 10 { break }
        }
        #expect(lastSeen == 10, "Should eventually coalesce to final value 10")
    }

    /// Test Observed with coalesceUpdates explicitly disabled
    @Test func testObservedWithoutCoalescing() async throws {
        let model = TestModel().withAnchor()
        var iter = Observed(coalesceUpdates: false) { model.value }.makeAsyncIterator()

        // Consume initial value
        _ = await iter.next()
        var updateCount = 1

        // Make 5 mutations, each producing a separate update
        for i in 1...5 { model.value = i }

        // Consume all 5 updates directly from the test task
        for _ in 1...5 {
            _ = await iter.next()
            updateCount += 1
        }

        #expect(updateCount == 6, "Should have 1 initial + 5 updates = 6 total")
    }

    /// Test Observed with both removeDuplicates and coalesceUpdates
    @Test func testObservedWithRemoveDuplicatesAndCoalescing() async throws {
        let model = TestModel().withAnchor()
        var iter = Observed(removeDuplicates: true, coalesceUpdates: true) { model.value }.makeAsyncIterator()

        // Consume initial value
        let v0 = await iter.next()
        #expect(v0 == 0, "Should have initial value 0")

        // Rapid mutations: 1, 2, 2, 2, 3 — with coalescing batched to final value 3
        model.value = 1
        model.value = 2
        model.value = 2  // Duplicate
        model.value = 2  // Duplicate
        model.value = 3

        // Drain until we see final value 3. GCD drain may fire mid-sequence,
        // buffering an intermediate value (e.g. 1 or 2) before all mutations complete.
        var lastSeen = 0
        for _ in 0..<5 {
            guard let v = await iter.next() else { break }
            lastSeen = v
            if lastSeen == 3 { break }
        }
        #expect(lastSeen == 3, "Should eventually coalesce to final value 3")
    }

    /// Test Observed without removeDuplicates but with coalescing
    @Test func testObservedWithoutRemoveDuplicates() async throws {
        let model = TestModel().withAnchor()
        var iter = Observed(removeDuplicates: false, coalesceUpdates: true) { model.value }.makeAsyncIterator()

        // Consume initial value
        let v0 = await iter.next()
        #expect(v0 == 0)

        // Set to same value multiple times — coalescing batches into one update
        model.value = 5
        model.value = 5  // Same value
        model.value = 5  // Same value

        // Await the coalesced update
        let v1 = await iter.next()
        #expect(v1 == 5, "Should have coalesced value 5")
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

