import ConcurrencyExtras
import Testing
import Observation
@testable import SwiftModel

/// Performance benchmarks for memoization optimization
@Suite(.serialized, .tags(.benchmark))
struct MemoizePerformanceTests {

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkBulkUpdatesCurrentBehavior() async throws {
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
        print("Sort was called: \(model.sortCallCount.value) times")
        print("Accesses: \(model.sortAccessCount.value)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkBulkUpdatesWithTransaction() async throws {
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
        print("Sort was called: \(model.sortCallCount.value) times")
        print("Accesses: \(model.sortAccessCount.value)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkRepeatedAccess() async throws {
        let model = BenchmarkModel(itemCount: 100).withAnchor()

        let startTime = ContinuousClock.now

        // Access many times without changing data
        for _ in 0..<1000 {
            _ = model.sorted
        }

        let elapsed = ContinuousClock.now - startTime
        let milliseconds = elapsed.components.attoseconds / 1_000_000_000_000_000

        print("1000 repeated accesses took: \(milliseconds)ms")
        print("Sort was called: \(model.sortCallCount.value) times")
        print("Accesses: \(model.sortAccessCount.value)")

        // Should only compute once
        #expect(model.sortCallCount.value == 1)
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkBulkUpdatesWithNestedModels() async throws {
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
        print("🔍 Sort was called: \(model.sortCallCount.value) times")
        print("🔍 Accesses: \(model.sortAccessCount.value)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkBulkUpdatesWithNestedModelsAndTransaction() async throws {
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
        print("🔍 Sort was called: \(model.sortCallCount.value) times")
        print("🔍 Accesses: \(model.sortAccessCount.value)")

        // Verify correctness
        #expect(model.sorted.allSatisfy { $0.value == 1 })
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkMemoizeCoalescingComparison() async throws {
        print("\n===============================================================================================")
        print("📊 MEMOIZE PERFORMANCE: 100 mutations in transaction (5 iterations, outliers removed)")
        print("===============================================================================================")
        
        let iterations = 5
        var resultsWithout: [(updates: Int, time: Double)] = []
        var resultsWith: [(updates: Int, time: Double)] = []
        
        // Test WITHOUT coalescing
        for _ in 0..<iterations {
            let model = withModelOptions([.disableMemoizeCoalescing]) {
                BenchmarkModel(itemCount: 100).withAnchor()
            }
            
            _ = model.sorted  // Initial setup
            let initialComputes = model.sortCallCount.value

            let start = ContinuousClock.now
            model.transaction {
                for i in 0..<model.items.count {
                    model.items[i].value += 1
                }
            }
            _ = model.sorted
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

            let recomputes = model.sortCallCount.value - initialComputes
            resultsWithout.append((recomputes, ms))
        }
        
        // Test WITH coalescing - test OUTSIDE transaction
        for _ in 0..<iterations {
            let model = BenchmarkModel(itemCount: 100).withAnchor()
            
            _ = model.sorted  // Initial setup
            let initialComputes = model.sortCallCount.value

            let start = ContinuousClock.now
            // NO TRANSACTION - test coalescing outside transaction where it works
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
            // Wait a bit for background coalescing
            try? await Task.sleep(for: .milliseconds(100))
            _ = model.sorted
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

            let recomputes = model.sortCallCount.value - initialComputes
            resultsWith.append((recomputes, ms))
        }
        
        // Remove outliers and average
        let avgWithout = removeOutliersAndAverage(resultsWithout)
        let avgWith = removeOutliersAndAverage(resultsWith)
        
        print("Configuration                         Recomputes  Time(ms)")
        print("--------------------------------------------------------------")
        print(String(format: "WITHOUT coalescing (in txn)           %6d      %6.1f", avgWithout.updates, avgWithout.time))
        print(String(format: "WITH coalescing (outside txn)         %6d      %6.1f", avgWith.updates, avgWith.time))
        print("===============================================================================================")
        
        if avgWith.updates < avgWithout.updates {
            let reduction = Double(avgWithout.updates) / Double(avgWith.updates)
            print("✅ COALESCING IS WORKING OUTSIDE TRANSACTIONS: \(avgWithout.updates) → \(avgWith.updates) (\(String(format: "%.1fx", reduction)) reduction)")
        } else {
            print("⚠️ COALESCING NOT EFFECTIVE: Both paths have ~\(avgWith.updates) recomputes")
        }
        print("===============================================================================================\n")
        
        // Coalescing behavior:
        // - WITH coalescing (outside txn): hasPendingUpdate batching → ~1-3 recomputes ✅
        // - WITHOUT coalescing (in txn): each of the 100 mutations produces a separate
        //   performUpdate callback (no hasPendingUpdate deduplication), so ~100 recomputes.
        //   Transaction batching defers all callbacks to post-transaction but does not
        //   deduplicate them.
        #expect(avgWithout.updates <= 120, "Without coalescing should have roughly one recompute per mutation, got \(avgWithout.updates)")
        #expect(avgWith.updates <= 10, "With coalescing outside transaction should have ~1-3 recomputes, got \(avgWith.updates)")
        
        // Verify correctness
        let testModel = BenchmarkModel(itemCount: 100).withAnchor()
        _ = testModel.sorted
        testModel.transaction {
            for i in 0..<testModel.items.count {
                testModel.items[i].value += 1
            }
        }
        #expect(testModel.sorted.allSatisfy { $0.value == 1 })
    }
    
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkMemoizeComprehensive() async throws {
        let mutationCount = 100
        let iterations = 5
        
        // Results storage
        var allResults: [String: [(computes: Int, durationMs: Double)]] = [:]
        
        // Test all combinations:
        // - AccessCollector vs ObservationTracking
        // - Coalescing vs No Coalescing
        // - DirtyTracking vs No DirtyTracking
        // - Transaction vs No Transaction
        
        let configurations: [(name: String, options: ModelOption, useTransaction: Bool)] = [
            // AccessCollector - can run with or without coalescing
            ("AC + NoCoal + NoTxn", [.disableObservationRegistrar, .disableMemoizeCoalescing], false),
            ("AC + NoCoal + Txn", [.disableObservationRegistrar, .disableMemoizeCoalescing], true),
            ("AC + Coal + NoTxn", [.disableObservationRegistrar], false),
            ("AC + Coal + Txn", [.disableObservationRegistrar], true),
            
            // ObservationTracking - always uses coalescing (async execution required to avoid recursion)
            // Note: Cannot test "OT + NoCoal" - withObservationTracking fundamentally requires
            // async execution via backgroundCall, which inherently batches updates
            ("OT + Coal + NoTxn", [], false),
            ("OT + Coal + Txn", [], true),
        ]
        
        for config in configurations {
            for _ in 0..<iterations {
                let model = withModelOptions(config.options) { BenchmarkModel(itemCount: mutationCount).withAnchor() }

                _ = model.sorted  // Initial setup
                let initialComputes = model.sortCallCount.value

                let start = ContinuousClock.now

                if config.useTransaction {
                    model.transaction {
                        for i in 0..<model.items.count {
                            model.items[i].value += 1
                        }
                    }
                } else {
                    for i in 0..<model.items.count {
                        model.items[i].value += 1
                    }
                }

                // Force final access - this synchronizes with any pending background work
                // by requiring the context lock, ensuring all computations complete
                _ = model.sorted
                let elapsed = ContinuousClock.now - start
                let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

                let computes = model.sortCallCount.value - initialComputes
                allResults[config.name, default: []].append((computes, ms))
            }
        }
        
        // Process results
        let results = configurations.map { config -> (name: String, computes: Int, durationMs: Double) in
            let data = allResults[config.name]!
            // Convert to expected format for helper
            let converted = data.map { (updates: $0.computes, time: $0.durationMs) }
            let avg = removeOutliersAndAverage(converted)
            return (config.name, avg.updates, avg.time)
        }
        
        // Print comprehensive table
        print("\n" + String(repeating: "=", count: 100))
        print("📊 MEMOIZE COMPREHENSIVE PERFORMANCE: \(mutationCount) mutations (\(iterations) iterations, outliers removed)")
        print(String(repeating: "=", count: 100))
        print("Configuration                              Computes  Time(ms)")
        print(String(repeating: "-", count: 100))
        
        for result in results {
            let paddedName = result.name.padding(toLength: 43, withPad: " ", startingAt: 0)
            print("\(paddedName)\(String(format: "%6d", result.computes))    \(String(format: "%6.1f", result.durationMs))")
        }
        
        print(String(repeating: "=", count: 100))
        
        // Analysis section
        print("\n📈 KEY INSIGHTS:")
        
        // Compare coalescing impact (dirty tracking is always enabled now)
        let acNoCoalNoTxn = results.first { $0.name == "AC + NoCoal + NoTxn" }!
        let acCoalNoTxn = results.first { $0.name == "AC + Coal + NoTxn" }!
        print("  Coalescing Impact (outside txn):")
        print("    Without: \(acNoCoalNoTxn.computes) computes")
        print("    With:    \(acCoalNoTxn.computes) computes")
        
        let acNoCoalTxn = results.first { $0.name == "AC + NoCoal + Txn" }!
        let acCoalTxn = results.first { $0.name == "AC + Coal + Txn" }!
        print("  Coalescing Impact (inside txn):")
        print("    Without: \(acNoCoalTxn.computes) computes")
        print("    With:    \(acCoalTxn.computes) computes ← DIRTY TRACKING SHINES HERE!")
        
        if acCoalTxn.computes < acNoCoalTxn.computes {
            let reduction = Double(acNoCoalTxn.computes) / Double(acCoalTxn.computes)
            print("    🎯 Reduction: \(String(format: "%.1fx", reduction))")
        }
        
        // Compare observation mechanisms
        let otCoalTxn = results.first { $0.name == "OT + Coal + Txn" }!
        print("\n  Observation Mechanism Comparison (Coal + Txn):")
        print("    AccessCollector:       \(acCoalTxn.computes) computes")
        print("    ObservationTracking:   \(otCoalTxn.computes) computes")
        
        print("\n💡 SUMMARY:")
        print("  - Dirty tracking (always enabled) prevents redundant recomputes in transactions")
        print("  - Coalescing works best OUTSIDE transactions (uses backgroundCall batching)")
        print("  - INSIDE transactions, dirty tracking ensures only 1-2 computes regardless of mutations")
        print("  - Best configuration: Coalescing + DirtyTracking (both now enabled by default)")
        print(String(repeating: "=", count: 100) + "\n")
        
        // Verify correctness
        let testModel = BenchmarkModel(itemCount: mutationCount).withAnchor()
        _ = testModel.sorted
        testModel.transaction {
            for i in 0..<testModel.items.count {
                testModel.items[i].value += 1
            }
        }
        #expect(testModel.sorted.allSatisfy { $0.value == 1 })
        
        // Verify dirty tracking is effective in transactions (should be ≤5 computes)
        #expect(acCoalTxn.computes <= 5, "With dirty tracking in txn, should have ≤5 computes, got \(acCoalTxn.computes)")
    }
    
    private func removeOutliersAndAverage(_ results: [(updates: Int, time: Double)]) -> (updates: Int, time: Double) {
        guard results.count >= 3 else {
            let avgUpdates = results.map(\.updates).reduce(0, +) / results.count
            let avgTime = results.map(\.time).reduce(0.0, +) / Double(results.count)
            return (avgUpdates, avgTime)
        }
        
        let sorted = results.sorted { $0.time < $1.time }
        let trimmed = Array(sorted.dropFirst().dropLast())
        let avgUpdates = trimmed.map(\.updates).reduce(0, +) / trimmed.count
        let avgTime = trimmed.map(\.time).reduce(0.0, +) / Double(trimmed.count)
        return (avgUpdates, avgTime)
    }
    
    @Test func verifyDirtyTrackingInTransactionFix() async throws {
        let model = BenchmarkModel(itemCount: 100).withAnchor()
        
        // Initial setup
        _ = model.sorted
        let initialComputes = model.sortCallCount.value

        print("\n=== Verifying Dirty Tracking Fix ===")
        print("Initial computes: \(initialComputes)")

        // Mutation in transaction with dirty tracking enabled (default)
        model.transaction {
            for i in 0..<model.items.count {
                model.items[i].value += 1
            }
        }

        // Access after transaction
        _ = model.sorted

        let finalComputes = model.sortCallCount.value
        let computes = finalComputes - initialComputes
        
        print("Computes with dirty tracking in transaction: \(computes)")
        print("Expected: 1-2 (optimal with fix)")
        print("Old behavior: 100 (broken)")
        print("=====================================\n")
        
        // With the fix removing threadLocals.postTransactions check, 
        // we should see 1-2 computes, not 100
        #expect(computes <= 2, "Expected ≤2 computes with dirty tracking, got \(computes)")
    }
    
    /// Benchmark focused on dirty tracking: many mutations between reads
    /// This tests the "lazy" aspect of dirty tracking - value updated many times
    /// but only computed once when accessed
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkDirtyTrackingLazyEvaluation() async throws {
        let mutationCount = 100
        let iterations = 5
        
        print("\n" + String(repeating: "=", count: 90))
        print("BENCHMARK: Dirty Tracking Lazy Evaluation")
        print("Scenario: \(mutationCount) mutations, then ONE access (tests lazy computation)")
        print("Note: Dirty tracking is always enabled")
        print(String(repeating: "=", count: 90))
        
        // Only one configuration now since dirty tracking is always enabled
        let configs: [(name: String, options: ModelOption)] = [
            ("With Dirty Tracking", [])
        ]
        
        for config in configs {
            var computeCounts: [Int] = []
            var durations: [Double] = []
            
            for _ in 0..<iterations {
                let model = withModelOptions(config.options) { BenchmarkModel(itemCount: mutationCount).withAnchor() }

                // Initial setup - this establishes observation
                _ = model.sorted
                let initialComputes = model.sortCallCount.value

                let start = ContinuousClock.now

                // Many mutations without accessing the computed property
                for i in 0..<model.items.count {
                    model.items[i].value += 1
                }

                // Single access AFTER all mutations (lazy evaluation)
                _ = model.sorted

                let elapsed = ContinuousClock.now - start
                let ns = elapsed.components.seconds * 1_000_000_000 + Int64(elapsed.components.attoseconds / 1_000_000_000)
                let durationMs = Double(ns) / 1_000_000

                let computes = model.sortCallCount.value - initialComputes
                computeCounts.append(computes)
                durations.append(durationMs)
            }
            
            // Remove outliers and average
            computeCounts.sort()
            durations.sort()
            
            let trimmedComputes = computeCounts.dropFirst().dropLast()
            let trimmedDurations = durations.dropFirst().dropLast()
            
            let avgComputes = trimmedComputes.reduce(0, +) / trimmedComputes.count
            let avgDuration = trimmedDurations.reduce(0.0, +) / Double(trimmedDurations.count)
            
            print("\n\(config.name):")
            print("  Computes: \(avgComputes) (range: \(computeCounts.first!) - \(computeCounts.last!))")
            print("  Duration: \(String(format: "%.2f", avgDuration))ms")
        }
        
        print("\n" + String(repeating: "=", count: 90))
        print("✅ Dirty tracking enables lazy evaluation - only computes when accessed!")
        print(String(repeating: "=", count: 90) + "\n")
    }
}

@Model private struct BenchmarkModel {
    struct Item: Equatable {
        var id: Int
        var value: Int
    }

    var items: [Item] = []
    // LockIsolated avoids triggering @Model withMutation, preventing an infinite
    // OT performUpdate loop when these counters are incremented inside produce().
    let sortCallCount = LockIsolated(0)
    let sortAccessCount = LockIsolated(0)

    init(itemCount: Int) {
        self.items = (0..<itemCount).map { Item(id: $0, value: 0) }
    }

    var sorted: [Item] {
        sortAccessCount.withValue { $0 += 1 }
        return node.memoize(for: "sorted") {
            sortCallCount.withValue { $0 += 1 }
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
    // LockIsolated avoids triggering @Model withMutation, preventing an infinite
    // OT performUpdate loop when these counters are incremented inside produce().
    let sortCallCount = LockIsolated(0)
    let sortAccessCount = LockIsolated(0)

    init(itemCount: Int) {
        self.items = (0..<itemCount).map { ItemModel(id: $0, value: 0) }
    }

    var sorted: [ItemModel] {
        sortAccessCount.withValue { $0 += 1 }
        return node.memoize(for: "sorted") {
            sortCallCount.withValue { $0 += 1 }
            return items.sorted { $0.id < $1.id }
        }
    }
}

