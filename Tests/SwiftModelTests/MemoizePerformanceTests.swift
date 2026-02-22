import Testing
import Observation
@testable import SwiftModel

/// Performance benchmarks for memoization optimization
struct MemoizePerformanceTests {

    @Test func benchmarkBulkUpdatesCurrentBehavior() async throws {
        let model = BenchmarkModel(itemCount: 1000).withAnchor()

        let startTime = ContinuousClock.now

        // Modify all items
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }

        // Force computation
        _ = model.sorted

        let elapsed = ContinuousClock.now - startTime
        let milliseconds = elapsed.components.attoseconds / 1_000_000_000_000_000

        print("Bulk updates (1000 items) took: \(milliseconds)ms")
        print("Sort was called: \(model.sortCallCount) times")
        print("Accesses: \(model.sortAccessCount)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test func benchmarkBulkUpdatesWithTransaction() async throws {
        let model = BenchmarkModel(itemCount: 1000).withAnchor()

        let startTime = ContinuousClock.now

        model.transaction {
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
        }

        // Force computation
        _ = model.sorted

        let elapsed = ContinuousClock.now - startTime
        let milliseconds = elapsed.components.attoseconds / 1_000_000_000_000_000

        print("Bulk updates with transaction (1000 items) took: \(milliseconds)ms")
        print("Sort was called: \(model.sortCallCount) times")
        print("Accesses: \(model.sortAccessCount)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test func benchmarkRepeatedAccess() async throws {
        let model = BenchmarkModel(itemCount: 100).withAnchor()

        let startTime = ContinuousClock.now

        // Access many times without changing data
        for _ in 0..<1000 {
            _ = model.sorted
        }

        let elapsed = ContinuousClock.now - startTime
        let milliseconds = elapsed.components.attoseconds / 1_000_000_000_000_000

        print("1000 repeated accesses took: \(milliseconds)ms")
        print("Sort was called: \(model.sortCallCount) times")
        print("Accesses: \(model.sortAccessCount)")

        // Should only compute once
        #expect(model.sortCallCount == 1)
    }

    @Test func benchmarkBulkUpdatesWithNestedModels() async throws {
        let model = NestedModelBenchmark(itemCount: 1000).withAnchor()

        let startTime = ContinuousClock.now

        // Modify all nested model items
        for i in 0..<model.items.count {
            model.items[i].value += 1
        }

        // Force computation
        _ = model.sorted

        let elapsed = ContinuousClock.now - startTime
        let milliseconds = elapsed.components.attoseconds / 1_000_000_000_000_000

        print("🔍 Bulk updates with nested Models (1000 items) took: \(milliseconds)ms")
        print("🔍 Sort was called: \(model.sortCallCount) times")
        print("🔍 Accesses: \(model.sortAccessCount)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @Test func benchmarkBulkUpdatesWithNestedModelsAndTransaction() async throws {
        let model = NestedModelBenchmark(itemCount: 1000).withAnchor()

        let startTime = ContinuousClock.now

        model.transaction {
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
        }

        // Force computation
        _ = model.sorted

        let elapsed = ContinuousClock.now - startTime
        let milliseconds = elapsed.components.attoseconds / 1_000_000_000_000_000

        print("🔍 Bulk updates with nested Models + transaction (1000 items) took: \(milliseconds)ms")
        print("🔍 Sort was called: \(model.sortCallCount) times")
        print("🔍 Accesses: \(model.sortAccessCount)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }
}

@Model private struct BenchmarkModel {
    struct Item: Equatable {
        var id: Int
        var value: Int
    }

    var items: [Item] = []
    var sortCallCount = 0
    var sortAccessCount = 0

    init(itemCount: Int) {
        self.items = (0..<itemCount).map { Item(id: $0, value: 0) }
    }

    var sorted: [Item] {
        sortAccessCount += 1
        return node.memoize(for: "sorted") {
            sortCallCount += 1
            return items.sorted { $0.id < $1.id }
        }
    }
}

@Model private struct NestedModelBenchmark {
    @Model struct ItemModel: Equatable {
        var id: Int
        var value: Int
    }

    var items: [ItemModel] = []
    var sortCallCount = 0
    var sortAccessCount = 0

    init(itemCount: Int) {
        self.items = (0..<itemCount).map { ItemModel(id: $0, value: 0) }
    }

    var sorted: [ItemModel] {
        sortAccessCount += 1
        return node.memoize(for: "sorted") {
            sortCallCount += 1
            return items.sorted { $0.id < $1.id }
        }
    }
}

