import Testing
import Observation
@testable import SwiftModel

/// Comprehensive tests for memoization behavior, particularly around performance and correctness
struct MemoizeTests {

    // MARK: - Basic Functionality

    @Test func testBasicMemoization() async throws {
        let model = BasicMemoizeModel().withAnchor()

        // First access should compute
        let first = model.doubled
        #expect(first == 0)
        #expect(model.accessCount == 1)

        // Second access should use cache (no recomputation)
        let second = model.doubled
        #expect(second == 0)
        #expect(model.accessCount == 2)  // Access count increases but computation doesn't

        // Change dependency
        model.value = 5

        // Access should recompute
        let third = model.doubled
        #expect(third == 10)
        #expect(model.accessCount == 3)
    }

    @Test func testMemoizeWithEquatableSkipsIdenticalValues() async throws {
        let model = EquatableMemoizeModel().withAnchor()

        // Wait for initial observation
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.updates == [0])

        // Change dependencies - product changes from 0 to 1
        model.value = 1
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.updates == [0, 1])

        // Change to same value (1 * 1 = 1, still 1)
        model.multiplier = 1
        try await Task.sleep(for: .milliseconds(10))

        // The Observed stream with removeDuplicates should filter this
        #expect(model.updates == [0, 1])  // No update, value still 1

        // Change to different value (1 * 2 = 2)
        model.multiplier = 2
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.updates == [0, 1, 2])
    }

    // MARK: - Bulk Update Performance (The Critical Issue)

    @Test func testBulkUpdatesWithoutTransaction() async throws {
        let model = BulkUpdateModel(itemCount: 100).withAnchor()

        // Track accesses
        let initialAccess = model.sortAccessCount

        // Modify all items without transaction
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }

        // Access the sorted value
        _ = model.sorted

        // Document current behavior: each mutation may trigger update
        let totalAccesses = model.sortAccessCount - initialAccess
        print("Accesses without transaction: \(totalAccesses)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test func testBulkUpdatesWithTransaction() async throws {
        let model = BulkUpdateModel(itemCount: 100).withAnchor()

        let initialAccess = model.sortAccessCount

        // Modify all items WITH transaction
        model.transaction {
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
        }

        // Access the sorted value
        _ = model.sorted

        let totalAccesses = model.sortAccessCount - initialAccess
        print("Accesses with transaction: \(totalAccesses)")

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

    @Test func testMemoizeWithChangingDependencies() async throws {
        let model = DynamicDependencyModel().withAnchor()

        #expect(model.conditional == 10)  // Uses valueA

        model.useA = false
        #expect(model.conditional == 20)  // Uses valueB

        // Change valueA (not currently tracked)
        model.valueA = 100
        #expect(model.conditional == 20)  // Should not change

        // Change valueB (currently tracked)
        model.valueB = 200
        #expect(model.conditional == 200)  // Should update
    }

    // MARK: - Transaction Defer Block Issue

    @Test func testMemoizeRecomputationDuringTransactionDefer() async throws {
        let model = TransactionDeferModel().withAnchor()
        
        // Initial access to setup memoization
        print("🟢 Initial access")
        #expect(model.computed == 0)
        #expect(model.computeCount == 1)
        
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
        let computeCountAfterTransaction = model.computeCount
        print("🔵 Computations after transaction: \(computeCountAfterTransaction - 1)")
        Issue.record("Computed \(computeCountAfterTransaction - 1) times during transaction defer")
        
        // Access after transaction should use cached value
        print("🟢 Accessing after transaction")
        _ = model.computed
        print("🔵 Final compute count: \(model.computeCount)")
        #expect(model.computeCount == computeCountAfterTransaction)
    }

    @Test func testMemoizeAccessDuringMutation() async throws {
        let model = AccessDuringMutationModel().withAnchor()
        
        // Initial access
        #expect(model.computed == 0)
        #expect(model.computeCount == 1)
        model.accessLog.removeAll()
        
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
        
        let computesDuringTransaction = model.computeCount - 1
        print("🔴 Computed \(computesDuringTransaction) times during mutation loop")
        print("🔴 Access log length: \(model.accessLog.count)")
        Issue.record("CURRENT: Computed \(computesDuringTransaction) times when accessed during mutations")
        
        // DESIRED BEHAVIOR (with transaction-scoped staleness):
        // - Compute count: 1 (only at transaction end)
        // - Access log: ["accessed" x 11, "computed" x 1]
        // 
        // This is the pathological case that needs optimization
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
    var accessCount = 0

    var doubled: Int {
        accessCount += 1
        return node.memoize(for: "doubled") {
            value * 2
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
    var sortAccessCount = 0

    init(itemCount: Int) {
        self.items = (0..<itemCount).map { Item(id: $0, value: 0) }
    }

    var sorted: [Item] {
        sortAccessCount += 1
        return node.memoize(for: "sorted") {
            items.sorted { $0.value < $1.value }
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

    var conditional: Int {
        node.memoize(for: "conditional") {
            useA ? valueA : valueB
        }
    }
}

@Model private struct TransactionDeferModel {
    var values: [Int] = []
    var computeCount = 0
    
    var computed: Int {
        computeCount += 1
        return node.memoize(for: "computed") {
            print("🔴 RECOMPUTING (count: \(computeCount))")
            return values.reduce(0, +)
        }
    }
}

@Model private struct AccessDuringMutationModel {
    var values: [Int] = []
    var computeCount = 0
    var accessLog: [String] = []
    
    var computed: Int {
        accessLog.append("accessed")
        return node.memoize(for: "computed") {
            computeCount += 1
            accessLog.append("computed")
            return values.reduce(0, +)
        }
    }
}
