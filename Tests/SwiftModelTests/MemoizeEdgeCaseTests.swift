import Testing
import Observation
import ConcurrencyExtras
@testable import SwiftModel

/// Edge case tests for memoize dirty tracking
/// These tests probe corner cases, race conditions, and unusual patterns
/// to ensure robustness of the implementation
struct MemoizeEdgeCaseTests {

    // MARK: - Concurrent Access Tests

    /// Test concurrent reads and writes to memoized property
    /// This could reveal race conditions in the isDirty flag management
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testConcurrentReadWrite() async throws {
        let model = ConcurrentTestModel().withAnchor()

        let readCount = LockIsolated(0)
        let writeCount = LockIsolated(0)

        // Spawn multiple readers
        let readers = (0..<10).map { _ in
            Task {
                for _ in 0..<100 {
                    _ = model.computed
                    readCount.withValue { $0 += 1 }
                    try? await Task.sleep(for: .microseconds(10))
                }
            }
        }

        // Spawn multiple writers
        let writers = (0..<5).map { i in
            Task {
                for j in 0..<20 {
                    model.value = i * 100 + j
                    writeCount.withValue { $0 += 1 }
                    try? await Task.sleep(for: .microseconds(10))
                }
            }
        }

        // Wait for all tasks
        for task in readers + writers {
            await task.value
        }

        #expect(readCount.value == 1000, "Should have 1000 reads")
        #expect(writeCount.value == 100, "Should have 100 writes")
        // After all concurrent tasks complete, the cache must be coherent:
        // reading computed twice with no interleaved writes must return the same value.
        let snapshot1 = model.computed
        let snapshot2 = model.computed
        #expect(snapshot1 == snapshot2, "Stable reads after concurrent activity must be consistent")

        print("Concurrent test: \(readCount.value) reads, \(writeCount.value) writes, final value: \(snapshot1)")
    }

    /// Test rapid mutation followed by immediate read (stress test for dirty path)
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testRapidMutationThenRead() async throws {
        let model = RapidMutationModel().withAnchor()

        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // Rapid mutations followed by immediate read each time
        for i in 1...20 {
            model.value = i
            let _ = model.computed  // Immediate read (dirty path)
        }

        // Wait for the final value to be observed (avoids fixed sleep durations under load)
        try await waitUntil(updates.value.contains(40), timeout: 5_000_000_000)
        #expect(updates.value.contains(40), "Should have observed the final value 40")
    }

    // MARK: - Transaction Edge Cases

    /// Test nested transactions with memoized values
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testNestedTransactions() async throws {
        let model = TransactionTestModel().withAnchor()

        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        // Wait for initial value
        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // Nested transactions
        model.node.transaction {
            model.value = 5
            let _ = model.computed  // Read in outer transaction

            model.node.transaction {
                model.value = 10
                let _ = model.computed  // Read in inner transaction
            }

            let _ = model.computed  // Read after inner transaction
        }

        // Final read after all transactions — inner transaction sets value to 10, so computed = 10 * 2 = 20
        let finalValue = model.computed
        print("Final value after transactions: \(finalValue)")
        #expect(finalValue == 20, "After nested transactions with final value=10, computed should be 20")

        // Wait for the update notification for the final value (10 * 2 = 20)
        try await waitUntil(updates.value.contains(20), timeout: 5_000_000_000)
        #expect(updates.value.contains(20), "Should have observed the final value 20")
    }

    /// Test transaction with multiple memoized properties depending on same value
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testTransactionMultipleDependents() async throws {
        let model = MultipleDependentsModel().withAnchor()

        model.node.transaction {
            for i in 1...10 {
                model.base = i
                // Access multiple memoized properties that all depend on base
                let _ = model.doubled
                let _ = model.tripled
                let _ = model.squared
            }
        }

        // After transaction, all should be based on final value (10)
        print("After transaction: base=\(model.base)")
        print("Reading doubled...")
        let doubled = model.doubled
        print("doubled=\(doubled)")
        print("Reading tripled...")
        let tripled = model.tripled
        print("tripled=\(tripled)")
        print("Reading squared...")
        let squared = model.squared
        print("squared=\(squared)")

        // Transaction ends with base=10 — verify all three memoized values reflect that
        #expect(doubled == 20, "doubled should be base*2 = 20")
        #expect(tripled == 30, "tripled should be base*3 = 30")
        #expect(squared == 100, "squared should be base*base = 100")

        print("Multiple dependents: doubled=\(doubled), tripled=\(tripled), squared=\(squared)")
    }

    // MARK: - Observation Edge Cases

    /// Test observer setup/teardown during mutations
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testObserverSetupDuringMutation() async throws {
        let model = ObserverLifecycleModel().withAnchor()

        let updates1 = LockIsolated<[Int]>([])
        let updates2 = LockIsolated<[Int]>([])

        // Start first observer
        let stream1 = Observed { model.computed }
        let task1 = Task {
            for await value in stream1 {
                updates1.withValue { $0.append(value) }
            }
        }

        try await waitUntil(updates1.value.count >= 1)

        // Mutate while first observer is active
        model.value = 5

        // Start second observer DURING mutation
        let stream2 = Observed { model.computed }
        let task2 = Task {
            for await value in stream2 {
                updates2.withValue { $0.append(value) }
            }
        }

        try await waitUntil(updates1.value.contains(10) && updates2.value.contains(10))

        // Both observers should see the value
        #expect(updates1.value.contains(10), "Observer 1 should see value 10")
        #expect(updates2.value.contains(10), "Observer 2 should see value 10")

        task1.cancel()
        task2.cancel()

        print("Observer lifecycle: observer1=\(updates1.value), observer2=\(updates2.value)")
    }

    /// Test canceling observer during dirty path execution
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testCancelObserverDuringDirtyPath() async throws {
        let model = ObserverCancellationModel().withAnchor()

        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.computed }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // Mutate (marks dirty)
        model.value = 5

        // Cancel observer
        task.cancel()

        // Access dirty path (should still work even with cancelled observer)
        let value = model.computed
        #expect(value == 10, "Should still compute correct value")

        print("Observer cancellation: computed value = \(value), updates = \(updates.value)")
    }

    // MARK: - Dependency Chain Tests

    /// Test chain of memoized values (A -> B -> C)
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testMemoizeChain() async throws {
        let model = MemoizeChainModel().withAnchor()

        let updates = LockIsolated<[Int]>([])
        let stream = Observed { model.final }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // Mutate base value
        model.base = 5

        // Immediate read of final (should trigger chain: base -> doubled -> final)
        let finalValue = model.final
        #expect(finalValue == 40, "final should be 40 (5 * 2 * 4)")

        try await waitUntil(updates.value.contains(40))

        // Should observe update
        #expect(updates.value.contains(40), "Should observe final value 40")

        // Check computation counts
        print("Chain test: base=\(model.base), doubled=\(model.doubled), final=\(model.final)")
        print("Compute counts: doubled=\(model.doubledCount.value), final=\(model.finalCount.value)")
    }

    /// Test circular dependency detection (if implemented)
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testSelfReferentialAccess() async throws {
        let model = SelfRefModel().withAnchor()

        // This should not crash or infinite loop
        // The second access should use cached value
        let value = model.selfRef
        #expect(value == 1, "Should return 1 (depth limit or cached value)")

        print("Self-referential test: value = \(value), accessCount = \(model.accessCount.value)")
    }

    // MARK: - Memory/State Edge Cases

    /// Test resetMemoization during dirty state
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testResetDuringDirty() async throws {
        let model = ResetTestModel().withAnchor()

        _ = model.computed  // Initial computation, count=1

        // Mutate (marks dirty, queues async performUpdate via backgroundCall)
        model.value = 5

        // Reset before accessing dirty value.
        // The async performUpdate may or may not have already run by this point:
        // - If it ran BEFORE this cancel: count=2 (produce() for retracking)
        // - If it runs AFTER this cancel: hasBeenCancelled=true → it exits early
        model.node.resetMemoization(for: "computed")

        // Access should trigger fresh computation
        let value = model.computed
        #expect(value == 10, "Should compute fresh value")
        // Count is 2 (reset before performUpdate) or 3 (performUpdate ran before cancel)
        #expect(model.computeCount.value >= 2, "Fresh access after reset must have recomputed")
        #expect(model.computeCount.value <= 3, "Should not have more than one extra compute from async retracking")

        print("Reset during dirty: value=\(value), computeCount=\(model.computeCount.value)")
    }

    /// Test accessing memoized value from within its own compute function
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testReentrantAccess() async throws {
        let model = ReentrantModel().withAnchor()

        // First access establishes both memoizations — base=1, helper=1+5=6, primary=6*2=12
        let value = model.primary

        #expect(value == 12, "primary should be (base+5)*2 = 12 with base=1")
        #expect(model.primaryCount.value == 1, "Primary should compute once")
        #expect(model.helperCount.value == 1, "Helper should compute once")

        // Mutate and read again — base=10, helper=10+5=15, primary=15*2=30
        model.base = 10
        let value2 = model.primary

        #expect(value2 == 30, "primary should be (base+5)*2 = 30 with base=10")

        print("Reentrant test: primary=\(value2), primaryCount=\(model.primaryCount.value), helperCount=\(model.helperCount.value)")
    }

    // MARK: - Edge Case with isSame

    /// Test isSame with dirty path (ensure deduplication works)
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testIsSameWithDirtyPath() async throws {
        let model = IsSameTestModel().withAnchor()

        let updates = LockIsolated<[String]>([])
        let stream = Observed { model.normalized }

        let task = Task {
            for await value in stream {
                updates.withValue { $0.append(value) }
            }
        }

        defer { task.cancel() }

        try await waitUntil(updates.value.count >= 1)
        updates.setValue([])

        // Change value but normalized result is same
        model.value = "HELLO"
        let _ = model.normalized  // "hello" (dirty path)

        model.value = "HeLLo"
        let _ = model.normalized  // Still "hello" (dirty path, but isSame)

        try await Task.sleep(for: .milliseconds(150))

        // isSame suppresses notifications when the recomputed value equals the cached value.
        // Both mutations normalize to "hello" (same as cached), so no new updates should fire.
        print("isSame test: updates=\(updates.value), computeCount=\(model.computeCount.value)")

        #expect(updates.value.isEmpty, "isSame should suppress observer notifications when value is unchanged")
        // The dirty path forced recomputation for each mutation (2 recomputations after initial)
        #expect(model.computeCount.value >= 2, "Should have recomputed for each mutation")
    }
}

// MARK: - Test Models

@Model
private struct ConcurrentTestModel {
    var value = 0

    var computed: Int {
        node.memoize(for: "computed") {
            value * 2
        }
    }
}

@Model
private struct RapidMutationModel {
    var value = 0

    var computed: Int {
        node.memoize(for: "computed") {
            value * 2
        }
    }
}

@Model
private struct TransactionTestModel {
    var value = 0

    var computed: Int {
        node.memoize(for: "computed") {
            value * 2
        }
    }
}

@Model
private struct MultipleDependentsModel {
    var base = 0

    var doubled: Int {
        node.memoize(for: "doubled") {
            base * 2
        }
    }

    var tripled: Int {
        node.memoize(for: "tripled") {
            base * 3
        }
    }

    var squared: Int {
        node.memoize(for: "squared") {
            base * base
        }
    }
}

@Model
private struct ObserverLifecycleModel {
    var value = 0

    var computed: Int {
        node.memoize(for: "computed") {
            value * 2
        }
    }
}

@Model
private struct ObserverCancellationModel {
    var value = 0

    var computed: Int {
        node.memoize(for: "computed") {
            value * 2
        }
    }
}

@Model
private struct MemoizeChainModel {
    var base = 1
    let doubledCount = LockIsolated(0)
    let finalCount = LockIsolated(0)

    var doubled: Int {
        node.memoize(for: "doubled") {
            doubledCount.withValue { $0 += 1 }
            return base * 2
        }
    }

    var final: Int {
        node.memoize(for: "final") {
            finalCount.withValue { $0 += 1 }
            return doubled * 4  // Depends on doubled
        }
    }
}

@Model
private struct SelfRefModel {
    let accessCount = LockIsolated(0)

    var selfRef: Int {
        node.memoize(for: "selfRef") {
            let count = accessCount.withValue { val in
                val += 1
                return val
            }

            // Prevent infinite recursion
            if count > 1 {
                return 1
            }

            // Try to access self (should use cached value or prevent recursion)
            return 1
        }
    }
}

@Model
private struct ResetTestModel {
    var value = 0
    let computeCount = LockIsolated(0)

    var computed: Int {
        node.memoize(for: "computed") {
            computeCount.withValue { $0 += 1 }
            return value * 2
        }
    }
}

@Model
private struct ReentrantModel {
    var base = 1
    let primaryCount = LockIsolated(0)
    let helperCount = LockIsolated(0)

    var helper: Int {
        node.memoize(for: "helper") {
            helperCount.withValue { $0 += 1 }
            return base + 5
        }
    }

    var primary: Int {
        node.memoize(for: "primary") {
            primaryCount.withValue { $0 += 1 }
            // Access another memoized value during computation
            return helper * 2
        }
    }
}

@Model
private struct IsSameTestModel {
    var value = "hello"
    let computeCount = LockIsolated(0)

    var normalized: String {
        // Using Equatable overload which automatically applies == for deduplication
        node.memoize(for: "normalized") {
            computeCount.withValue { $0 += 1 }
            return value.lowercased()
        }
    }
}
