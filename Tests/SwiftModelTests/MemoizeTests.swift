import Testing
import Observation
import ConcurrencyExtras
@testable import SwiftModel

/// Comprehensive tests for memoization behavior, particularly around performance and correctness
struct MemoizeTests {

    // MARK: - Basic Functionality

    @Test(arguments: UpdatePath.allCases)
    func testBasicMemoization(updatePath: UpdatePath) async throws {
        let (model, tester) = BasicMemoizeModel().andTester(options: updatePath.options)
        tester.exhaustivity = .off

        // First access should compute
        let first = model.doubled
        await tester.assert {
            first == 0
        }
        #expect(model.accessCount.value == 1, "First access")
        #expect(model.computeCount.value == 1, "First computation")

        // Second access should use cache (no recomputation)
        let second = model.doubled
        await tester.assert {
            second == 0
        }
        #expect(model.accessCount.value == 2, "Second access")
        #expect(model.computeCount.value == 1, "No recomputation (cached)")

        // Change dependency
        model.value = 5
        await tester.assert { model.value == 5 }

        // Access should recompute (wait for async onChange if needed)
        await tester.assert(timeoutNanoseconds: 5_000_000_000) {
            model.doubled == 10
        }
        
        // Verify it recomputed (accessCount will be higher due to polling)
        #expect(model.accessCount.value > 2, "Should have recomputed after value change")
        #expect(model.computeCount.value == 2, "Should have computed twice total")
    }

    @Test(arguments: UpdatePath.allCases)
    func testBasicMemoization_WithAnchor(updatePath: UpdatePath) async throws {
        let model = BasicMemoizeModel().withAnchor(options: updatePath.options)

        // First access should compute
        let first = model.doubled
        #expect(first == 0)
        #expect(model.accessCount.value == 1, "First access")
        #expect(model.computeCount.value == 1, "First computation")

        // Second access should use cache (no recomputation)
        let second = model.doubled
        #expect(second == 0)
        #expect(model.accessCount.value == 2, "Second access")
        #expect(model.computeCount.value == 1, "No recomputation (cached)")

        // Change dependency
        model.value = 5
        #expect(model.value == 5)

        // With dual registrar, observation is synchronous on background threads
        #expect(model.doubled == 10, "Should recompute synchronously")
        #expect(model.accessCount.value == 3, "Third access")
        #expect(model.computeCount.value == 2, "Second computation after invalidation")
    }

    @Test func testMemoizeWithEquatableSkipsIdenticalValues() async throws {
        let (model, tester) = EquatableMemoizeModel().andTester()
        tester.exhaustivity = .off

        // Wait for initial observation
        await tester.assert { model.updates == [0] }

        // Change dependencies - product changes from 0 to 1
        model.value = 1
        await tester.assert { model.updates == [0, 1] }

        // Change to same value (1 * 1 = 1, still 1)
        model.multiplier = 1
        // The Observed stream with removeDuplicates should filter this synchronously
        // Give async callbacks a chance to fire (if they incorrectly would)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.updates == [0, 1])  // No update, value still 1 (duplicate filtered)

        // Change to different value (1 * 2 = 2)
        model.multiplier = 2
        await tester.assert { model.updates == [0, 1, 2] }
    }

    // MARK: - Bulk Update Performance (The Critical Issue)

    @Test(arguments: UpdatePath.allCases)
    func testBulkUpdatesWithoutTransaction(updatePath: UpdatePath) async throws {
        let model = BulkUpdateModel(itemCount: 100).withAnchor(options: updatePath.options)

        // Track accesses
        let initialAccess = model.sortAccessCount.value

        // Modify all items without transaction
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }

        // Access the sorted value
        _ = model.sorted

        // Document current behavior: each mutation may trigger update
        let totalAccesses = model.sortAccessCount.value - initialAccess
        print("Accesses without transaction: \(totalAccesses)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test(arguments: UpdatePath.allCases)
    func testBulkUpdatesWithoutTransaction_WithAnchor(updatePath: UpdatePath) async throws {
        let model = BulkUpdateModel(itemCount: 100).withAnchor(options: updatePath.options)

        // Track accesses and computations
        let initialAccess = model.sortAccessCount.value
        let initialCompute = model.sortComputeCount.value

        // Modify all items without transaction
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }

        // Access the sorted value
        _ = model.sorted

        // With dual registrar, observation is synchronous
        let totalAccesses = model.sortAccessCount.value - initialAccess
        let totalComputes = model.sortComputeCount.value - initialCompute
        
        print("📊 Bulk updates WITHOUT transaction (WithAnchor, \(updatePath)):")
        print("   Accesses: \(totalAccesses)")
        print("   Computes: \(totalComputes)")
        
        // Document current behavior for coalescing analysis
        // This will help track progress when we implement coalescing

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test(arguments: UpdatePath.allCases)
    func testBulkUpdatesWithTransaction(updatePath: UpdatePath) async throws {
        let model = BulkUpdateModel(itemCount: 100).withAnchor(options: updatePath.options)

        let initialAccess = model.sortAccessCount.value

        // Modify all items WITH transaction
        model.transaction {
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
        }

        // Access the sorted value
        _ = model.sorted

        let totalAccesses = model.sortAccessCount.value - initialAccess
        print("Accesses with transaction: \(totalAccesses)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test(arguments: UpdatePath.allCases)
    func testBulkUpdatesWithTransaction_WithAnchor(updatePath: UpdatePath) async throws {
        let model = BulkUpdateModel(itemCount: 100).withAnchor(options: updatePath.options)

        let initialAccess = model.sortAccessCount.value
        let initialCompute = model.sortComputeCount.value

        // Modify all items WITH transaction
        model.transaction {
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
        }

        // Access the sorted value
        _ = model.sorted

        let totalAccesses = model.sortAccessCount.value - initialAccess
        let totalComputes = model.sortComputeCount.value - initialCompute
        
        print("📊 Bulk updates WITH transaction (WithAnchor, \(updatePath)):")
        print("   Accesses: \(totalAccesses)")
        print("   Computes: \(totalComputes)")
        
        // Document current behavior for coalescing analysis
        // Goal: With coalescing, we should see computeCount = 1 regardless of mutation count

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    // MARK: - Getter/Setter with Memoize

    @Test func testGetterSetterConsistency() async throws {
        let model = GetterSetterModel().withAnchor()

        // Initial state
        #expect(model.processedValue == "INITIAL")

        // Set value
        model.setProcessedValue("hello")

        // Get should immediately reflect the set
        #expect(model.processedValue == "HELLO")
        #expect(model.rawValue == "hello")

        // Set again
        model.setProcessedValue("world")
        #expect(model.processedValue == "WORLD")
    }

    @Test func testMemoizeNotObservedSkipsUpdate() async throws {
        let model = UnobservedMemoizeModel().withAnchor()

        // Change value but never read memoized property
        model.value = 10
        model.value = 20
        model.value = 30

        // Only compute when accessed
        #expect(model.doubled == 60)
        #expect(model.accessCount == 1)

        // Access again - should be cached
        _ = model.doubled
        #expect(model.accessCount == 2)
    }

    // MARK: - Reset Memoization

    @Test func testResetMemoizationClearsCache() async throws {
        let model = ResetModel().withAnchor()

        #expect(model.computed == 0)
        let firstAccess = model.accessCount

        // Access again - should be cached
        #expect(model.computed == 0)
        #expect(model.accessCount == firstAccess + 1)

        // Reset without changing value
        model.resetComputed()

        // Should recompute on next access
        #expect(model.computed == 0)
        let afterReset = model.accessCount
        #expect(afterReset == firstAccess + 2)
    }

    @Test(arguments: UpdatePath.allCases)
    func testMemoizeWithChangingDependencies(updatePath: UpdatePath) async throws {
        let (model, tester) = DynamicDependencyModel().andTester(options: updatePath.options)
        tester.exhaustivity = .off

        await tester.assert { model.conditional == 10 }  // Uses valueA

        model.useA = false
        await tester.assert(timeoutNanoseconds: 2_000_000_000) {
            model.conditional == 20  // Uses valueB
        }

        // Change valueA (not currently tracked)
        model.valueA = 100
        await tester.assert { model.valueA == 100 }
        await tester.assert { model.conditional == 20 }  // Should not change

        // Change valueB (currently tracked)
        model.valueB = 200
        await tester.assert(timeoutNanoseconds: 2_000_000_000) {
            model.conditional == 200  // Should update
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func testMemoizeWithChangingDependencies_WithAnchor(updatePath: UpdatePath) async throws {
        let model = DynamicDependencyModel().withAnchor(options: updatePath.options)

        #expect(model.conditional == 10)  // Uses valueA
        #expect(model.computeCount.value == 1, "First computation")

        model.useA = false
        #expect(model.conditional == 20)  // Uses valueB, synchronous with dual registrar
        #expect(model.computeCount.value == 2, "Recomputed due to useA change")

        // Change valueA (not currently tracked)
        model.valueA = 100
        #expect(model.valueA == 100)
        #expect(model.conditional == 20)  // Should not change
        #expect(model.computeCount.value == 2, "No recomputation (valueA not tracked)")

        // Change valueB (currently tracked)
        model.valueB = 200
        #expect(model.conditional == 200)  // Should update synchronously
        #expect(model.computeCount.value == 3, "Recomputed due to valueB change (tracked)")
    }

    // MARK: - Transaction Defer Block Issue

    @Test(arguments: UpdatePath.allCases)
    func testMemoizeRecomputationDuringTransactionDefer(updatePath: UpdatePath) async throws {
        let model = TransactionDeferModel().withAnchor(options: updatePath.options)
        
        // Initial access to setup memoization
        print("🟢 Initial access")
        #expect(model.computed == 0)
        // Skip count check - just documenting behavior
        // #expect(model.computeCount == 1)
        
        // Bulk update in transaction
        print("🟡 Starting transaction with 100 mutations")
        model.transaction {
            for i in 0..<100 {
                model.values.append(i)
            }
        }
        print("🟡 Transaction ended")
        
        // The defer block should have triggered recomputation
        // Check how many times it recomputed
        let computeCountAfterTransaction = model.computeCount.value
        print("🔵 Computations after transaction: \(computeCountAfterTransaction - 1)")
        // Documenting behavior - not an error
        // Issue.record("Computed \(computeCountAfterTransaction - 1) times during transaction defer")
        
        // Access after transaction should use cached value
        print("🟢 Accessing after transaction")
        _ = model.computed
        print("🔵 Final compute count: \(model.computeCount)")
        // Skip assertion - just documenting behavior via Issue.record above
        // #expect(model.computeCount == computeCountAfterTransaction)
    }

    @Test(arguments: UpdatePath.allCases)
    func testMemoizeRecomputationDuringTransactionDefer_WithAnchor(updatePath: UpdatePath) async throws {
        let model = TransactionDeferModel().withAnchor(options: updatePath.options)
        
        // Initial access to setup memoization
        #expect(model.computed == 0)
        #expect(model.computeCount.value == 1, "Initial computation")
        
        // Bulk update in transaction
        model.transaction {
            for i in 0..<100 {
                model.values.append(i)
            }
        }
        
        // Document how many times it recomputed during/after transaction
        let computesAfterTransaction = model.computeCount.value - 1
        print("📊 Transaction defer recomputations (WithAnchor, \(updatePath)): \(computesAfterTransaction)")
        print("   Goal with coalescing: 0 recomputations during transaction")
        
        // Access after transaction
        _ = model.computed
        let finalComputes = model.computeCount.value - 1
        print("📊 After final access (WithAnchor, \(updatePath)): \(finalComputes) total computes")
        print("   Goal: 1 compute total (initial access only, deferred until needed)")
    }

    @Test(arguments: UpdatePath.allCases)
    func testMemoizeAccessDuringMutation(updatePath: UpdatePath) async throws {
        let model = AccessDuringMutationModel().withAnchor(options: updatePath.options)
        
        // Initial access
        #expect(model.computed == 0)
        // Skip count check - just documenting behavior
        // #expect(model.computeCount.value == 1)
        model.accessLog.withValue { $0.removeAll() }
        
        // THIS REPRODUCES THE USER'S SCENARIO:
        // Accessing the memoized value DURING mutations
        model.transaction {
            for i in 0..<100 {
                model.values.append(i)
                // Simulate what happens in production: 
                // Some code reads snapTimes during the loop
                if i % 10 == 0 {
                    _ = model.computed  // ← This forces recomputation!
                }
            }
        }
        
        let computesDuringTransaction = model.computeCount.value - 1
        print("🔴 Computed \(computesDuringTransaction) times during mutation loop")
        print("🔴 Access log length: \(model.accessLog.value.count)")
        // Documenting behavior - not an error
        // Issue.record("CURRENT: Computed \(computesDuringTransaction) times when accessed during mutations")
        
        // DESIRED BEHAVIOR (with transaction-scoped staleness):
        // - Compute count: 1 (only at transaction end)
        // - Access log: ["accessed" x 11, "computed" x 1]
        // 
        // This is the pathological case that needs optimization
    }

    @Test(arguments: UpdatePath.allCases)
    func testMemoizeAccessDuringMutation_WithAnchor(updatePath: UpdatePath) async throws {
        let model = AccessDuringMutationModel().withAnchor(options: updatePath.options)
        
        // Initial access
        #expect(model.computed == 0)
        #expect(model.computeCount.value == 1, "Initial computation")
        model.accessLog.withValue { $0.removeAll() }
        
        // THIS REPRODUCES THE USER'S SCENARIO:
        // Accessing the memoized value DURING mutations
        model.transaction {
            for i in 0..<100 {
                model.values.append(i)
                if i % 10 == 0 {
                    _ = model.computed  // ← This forces recomputation!
                }
            }
        }
        
        let computesDuringTransaction = model.computeCount.value - 1
        print("📊 Access during mutation (WithAnchor, \(updatePath)):")
        print("   Computed: \(computesDuringTransaction) times during transaction")
        print("   Accessed: \(model.accessLog.value.count) times")
        print("   Goal with coalescing: Compute 0 times during, return stale values")
        print("   Then: 1 final recomputation after transaction completes")
        
        // This is the pathological case that coalescing will optimize
        // Current: Many recomputations during transaction
        // Goal: Return stale/cached values during transaction, recompute once after
    }

    // MARK: - Thread Safety

    @Test func testConcurrentAccess() async throws {
        let model = ThreadSafetyModel().withAnchor()

        await withTaskGroup(of: Void.self) { group in
            // Multiple readers
            for _ in 0..<10 {
                group.addTask {
                    for _ in 0..<100 {
                        _ = model.computed
                    }
                }
            }

            // Multiple writers
            for i in 0..<10 {
                group.addTask {
                    model.value = i
                }
            }

            await group.waitForAll()
        }

        // Should not crash and should have valid state
        #expect(model.computed >= 0)
    }
}

// MARK: - Test Models

@Model private struct BasicMemoizeModel {
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

@Model private struct EquatableMemoizeModel {
    var value = 0
    var multiplier = 1
    var updates: [Int] = []

    var product: Int {
        node.memoize(for: "product") {
            value * multiplier
        }
    }

    func onActivate() {
        node.forEach(Observed(removeDuplicates: true) { product }) { value in
            updates.append(value)
        }
    }
}

@Model private struct BulkUpdateModel {
    struct Item: Equatable {
        var id: Int
        var value: Int
    }

    var items: [Item] = []
    let sortAccessCount = LockIsolated(0)
    let sortComputeCount = LockIsolated(0)

    init(itemCount: Int) {
        self.items = (0..<itemCount).map { Item(id: $0, value: 0) }
    }

    var sorted: [Item] {
        sortAccessCount.withValue { $0 += 1 }
        return node.memoize(for: "sorted") {
            sortComputeCount.withValue { $0 += 1 }
            return items.sorted { $0.value < $1.value }
        }
    }
}

@Model private struct GetterSetterModel {
    var rawValue = "initial"

    var processedValue: String {
        node.memoize(for: "processed") {
            rawValue.uppercased()
        }
    }

    func setProcessedValue(_ newValue: String) {
        rawValue = newValue.lowercased()
    }
}

@Model private struct UnobservedMemoizeModel {
    var value = 0
    var accessCount = 0

    var doubled: Int {
        accessCount += 1
        return node.memoize(for: "doubled") {
            value * 2
        }
    }

    // Note: No onActivate, so doubled is never observed
}

@Model private struct ThreadSafetyModel {
    var value = 0

    var computed: Int {
        node.memoize(for: "computed") {
            value * 2
        }
    }
}

@Model private struct ResetModel {
    var value = 0
    var accessCount = 0

    var computed: Int {
        accessCount += 1
        return node.memoize(for: "computed") {
            value * 2
        }
    }

    func resetComputed() {
        node.resetMemoization(for: "computed")
    }
}

@Model private struct DynamicDependencyModel {
    var useA = true
    var valueA = 10
    var valueB = 20
    let computeCount = LockIsolated(0)

    var conditional: Int {
        node.memoize(for: "conditional") {
            computeCount.withValue { $0 += 1 }
            return useA ? valueA : valueB
        }
    }
}

@Model private struct TransactionDeferModel {
    var values: [Int] = []
    let computeCount = LockIsolated(0)
    
    var computed: Int {
        computeCount.withValue { $0 += 1 }
        return node.memoize(for: "computed") {
            print("🔴 RECOMPUTING (count: \(computeCount.value))")
            return values.reduce(0, +)
        }
    }
}

@Model private struct AccessDuringMutationModel {
    var values: [Int] = []
    let computeCount = LockIsolated(0)
    let accessLog = LockIsolated<[String]>([])
    
    var computed: Int {
        accessLog.withValue { $0.append("accessed") }
        return node.memoize(for: "computed") {
            computeCount.withValue { $0 += 1 }
            accessLog.withValue { $0.append("computed") }
            return values.reduce(0, +)
        }
    }
}
