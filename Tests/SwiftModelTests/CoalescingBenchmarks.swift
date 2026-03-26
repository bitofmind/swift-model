import Testing
import ConcurrencyExtras
import Foundation
@testable import SwiftModel

@Suite(.serialized, .tags(.benchmark))
struct CoalescingBenchmarks {

    /// Benchmark: AccessCollector without coalescing
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkAccessCollector_NoCoalescing() async throws {
        let model = CoalescingTestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let mutationCount = 100

        let (cancellable, _) = update(
            initial: false,  // Don't count initial
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: false,
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )

        defer { cancellable() }

        let start = ContinuousClock.now
        for i in 1...mutationCount {
            model.value = i
        }
        // Wait for all updates to complete
        try await waitUntil(updateCount.value == mutationCount)
        let duration = ContinuousClock.now - start

        let nanoseconds = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
        print("📊 AccessCollector (no coalescing): \(mutationCount) mutations → \(updateCount.value) updates in \(Double(nanoseconds) / 1_000_000)ms")
    }

    /// Benchmark: AccessCollector with coalescing
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkAccessCollector_WithCoalescing() async throws {
        let model = CoalescingTestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let mutationCount = 100

        let (cancellable, _) = update(
            initial: false,
            isSame: { $0 == $1 },
            useWithObservationTracking: false,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )

        defer { cancellable() }

        let start = ContinuousClock.now
        for i in 1...mutationCount {
            model.value = i
        }
        // Wait for coalesced update to complete
        try await waitUntil(updateCount.value >= 1)
        let duration = ContinuousClock.now - start

        let nanoseconds = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
        print("📊 AccessCollector (coalescing):    \(mutationCount) mutations → \(updateCount.value) updates in \(Double(nanoseconds) / 1_000_000)ms")
    }

    // Note: Cannot benchmark "ObservationTracking without coalescing"
    // withObservationTracking fundamentally requires async execution which inherently batches updates.
    // Non-coalescing benchmarks only available with AccessCollector.

    /// Benchmark: withObservationTracking with coalescing
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkObservationTracking_WithCoalescing() async throws {
        let model = CoalescingTestModel().withAnchor()
        let updateCount = LockIsolated(0)
        let mutationCount = 100

        let (cancellable, _) = update(
            initial: false,
            isSame: { $0 == $1 },
            useWithObservationTracking: true,
            useCoalescing: true,
            access: { model.value },
            onUpdate: { _ in updateCount.withValue { $0 += 1 } }
        )

        defer { cancellable() }

        let start = ContinuousClock.now
        for i in 1...mutationCount {
            model.value = i
        }
        // Wait for coalesced update to complete
        try await waitUntil(updateCount.value >= 1)
        let duration = ContinuousClock.now - start

        let nanoseconds = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
        print("📊 ObservationTracking (coalescing):    \(mutationCount) mutations → \(updateCount.value) updates in \(Double(nanoseconds) / 1_000_000)ms")
    }

    /// Performance comparison across all 4 paths with realistic computational work
    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkComparison() async throws {
        let mutationCount = 100
        let iterations = 5  // Run each benchmark 5 times

        var allResults: [String: [(updates: Int, durationMs: Double, avgWorkMs: Double)]] = [:]

        let simulateWork: @Sendable (Int) -> Int = { value in
            let data = (0..<1000).map { $0 + value }
            let result = data
                .filter { $0 % 3 == 0 || $0 % 5 == 0 }
                .map { $0 * 2 }
                .reduce(0, +)
            return result % 10000
        }

        // 1. AccessCollector without coalescing
        for _ in 0..<iterations {
            let model = CoalescingTestModel().withAnchor()
            let updateCount = LockIsolated(0)
            let totalWorkTime = LockIsolated(0.0)

            let (cancellable, _) = update(
                initial: false,
                isSame: { $0 == $1 },
                useWithObservationTracking: false,
                useCoalescing: false,
                access: { model.value },
                onUpdate: { value in
                    let workStart = ContinuousClock.now
                    _ = simulateWork(value)
                    let workDuration = ContinuousClock.now - workStart
                    let workMs = Double(workDuration.components.seconds * 1_000_000_000 + Int64(workDuration.components.attoseconds / 1_000_000_000)) / 1_000_000
                    totalWorkTime.withValue { $0 += workMs }
                    updateCount.withValue { $0 += 1 }
                }
            )

            let start = ContinuousClock.now
            for i in 1...mutationCount { model.value = i }
            while updateCount.value < mutationCount { await Task.yield() }
            let duration = ContinuousClock.now - start
            cancellable()

            let ns = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
            let avgWork = updateCount.value > 0 ? totalWorkTime.value / Double(updateCount.value) : 0
            allResults["AccessCollector (no coalescing)", default: []].append((updateCount.value, Double(ns) / 1_000_000, avgWork))
        }

        // 2. AccessCollector with coalescing
        for _ in 0..<iterations {
            let model = CoalescingTestModel().withAnchor()
            let updateCount = LockIsolated(0)
            let totalWorkTime = LockIsolated(0.0)

            let (cancellable, _) = update(
                initial: false,
                isSame: { $0 == $1 },
                useWithObservationTracking: false,
                useCoalescing: true,
                access: { model.value },
                onUpdate: { value in
                    let workStart = ContinuousClock.now
                    _ = simulateWork(value)
                    let workDuration = ContinuousClock.now - workStart
                    let workMs = Double(workDuration.components.seconds * 1_000_000_000 + Int64(workDuration.components.attoseconds / 1_000_000_000)) / 1_000_000
                    totalWorkTime.withValue { $0 += workMs }
                    updateCount.withValue { $0 += 1 }
                }
            )

            let start = ContinuousClock.now
            for i in 1...mutationCount { model.value = i }
            let previousCount = updateCount.value
            for _ in 0..<100 {
                if updateCount.value != previousCount { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(50))
            let duration = ContinuousClock.now - start
            cancellable()

            let ns = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
            let avgWork = updateCount.value > 0 ? totalWorkTime.value / Double(updateCount.value) : 0
            allResults["AccessCollector (coalescing)", default: []].append((updateCount.value, Double(ns) / 1_000_000, avgWork))
        }

        // 3. ObservationTracking with coalescing
        for _ in 0..<iterations {
            let model = CoalescingTestModel().withAnchor()
            let updateCount = LockIsolated(0)
            let totalWorkTime = LockIsolated(0.0)

            let (cancellable, _) = update(
                initial: false,
                isSame: { $0 == $1 },
                useWithObservationTracking: true,
                useCoalescing: true,
                access: { model.value },
                onUpdate: { value in
                    let workStart = ContinuousClock.now
                    _ = simulateWork(value)
                    let workDuration = ContinuousClock.now - workStart
                    let workMs = Double(workDuration.components.seconds * 1_000_000_000 + Int64(workDuration.components.attoseconds / 1_000_000_000)) / 1_000_000
                    totalWorkTime.withValue { $0 += workMs }
                    updateCount.withValue { $0 += 1 }
                }
            )

            let start = ContinuousClock.now
            for i in 1...mutationCount { model.value = i }
            let previousCount = updateCount.value
            for _ in 0..<100 {
                if updateCount.value != previousCount { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(50))
            let duration = ContinuousClock.now - start
            cancellable()

            let ns = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
            let avgWork = updateCount.value > 0 ? totalWorkTime.value / Double(updateCount.value) : 0
            allResults["ObservationTracking (coalescing)", default: []].append((updateCount.value, Double(ns) / 1_000_000, avgWork))
        }

        func removeOutliersAndAverage(_ values: [(updates: Int, durationMs: Double, avgWorkMs: Double)]) -> (updates: Int, durationMs: Double, avgWorkMs: Double) {
            guard values.count >= 3 else {
                return (values.map { $0.updates }.reduce(0, +) / values.count,
                        values.map { $0.durationMs }.reduce(0.0, +) / Double(values.count),
                        values.map { $0.avgWorkMs }.reduce(0.0, +) / Double(values.count))
            }
            let trimmed = Array(values.sorted { $0.durationMs < $1.durationMs }.dropFirst().dropLast())
            return (trimmed.map { $0.updates }.reduce(0, +) / trimmed.count,
                    trimmed.map { $0.durationMs }.reduce(0.0, +) / Double(trimmed.count),
                    trimmed.map { $0.avgWorkMs }.reduce(0.0, +) / Double(trimmed.count))
        }

        let results: [(path: String, updates: Int, durationMs: Double, avgWorkMs: Double)] = [
            ("AccessCollector (no coalescing)", removeOutliersAndAverage(allResults["AccessCollector (no coalescing)"]!).updates, removeOutliersAndAverage(allResults["AccessCollector (no coalescing)"]!).durationMs, removeOutliersAndAverage(allResults["AccessCollector (no coalescing)"]!).avgWorkMs),
            ("AccessCollector (coalescing)", removeOutliersAndAverage(allResults["AccessCollector (coalescing)"]!).updates, removeOutliersAndAverage(allResults["AccessCollector (coalescing)"]!).durationMs, removeOutliersAndAverage(allResults["AccessCollector (coalescing)"]!).avgWorkMs),
            ("ObservationTracking (coalescing)", removeOutliersAndAverage(allResults["ObservationTracking (coalescing)"]!).updates, removeOutliersAndAverage(allResults["ObservationTracking (coalescing)"]!).durationMs, removeOutliersAndAverage(allResults["ObservationTracking (coalescing)"]!).avgWorkMs)
        ]

        print("\n" + String(repeating: "=", count: 95))
        print("📊 PERFORMANCE COMPARISON: \(mutationCount) mutations with realistic work (\(iterations) iterations, outliers removed)")
        print(String(repeating: "=", count: 95))
        print("Path".padding(toLength: 42, withPad: " ", startingAt: 0) + "Updates  Total(ms)  Work/Update(ms)  Total Work(ms)")
        print(String(repeating: "-", count: 95))
        for result in results {
            let totalWork = Double(result.updates) * result.avgWorkMs
            print("\(result.path.padding(toLength: 42, withPad: " ", startingAt: 0))\(String(format: "%4d", result.updates))     \(String(format: "%6.1f", result.durationMs))     \(String(format: "%6.2f", result.avgWorkMs))           \(String(format: "%6.1f", totalWork))")
        }
        print(String(repeating: "=", count: 95))

        #expect(results.count == 3, "Should have 3 benchmark results")
        #expect(results[0].updates == mutationCount, "AccessCollector without coalescing should have \(mutationCount) updates")
        #expect(results[1].updates < 10, "AccessCollector with coalescing should have < 10 updates, got \(results[1].updates)")
        #expect(results[2].updates < 30, "ObservationTracking with coalescing should have < 30 updates, got \(results[2].updates)")

        let accessWorkReduction = (Double(results[0].updates) * results[0].avgWorkMs) / (Double(results[1].updates) * results[1].avgWorkMs)
        #expect(accessWorkReduction > 5.0, "AccessCollector coalescing should reduce work by >5x, got \(String(format: "%.1f", accessWorkReduction))x")

        if results.count == 3 {
            let accessNoCoal = results[0]
            let accessCoal = results[1]
            let obsCoal = results[2]
            let accessWorkSaved = (Double(accessNoCoal.updates) * accessNoCoal.avgWorkMs) - (Double(accessCoal.updates) * accessCoal.avgWorkMs)
            print("\n📈 IMPROVEMENTS WITH COALESCING:")
            print("  AccessCollector:")
            print("    Updates:      \(accessNoCoal.updates) → \(accessCoal.updates)  (\(accessNoCoal.updates / max(accessCoal.updates, 1))x reduction)")
            print("    Work saved:   \(String(format: "%.1f", accessWorkSaved))ms  (\(String(format: "%.1f", (accessWorkSaved / (Double(accessNoCoal.updates) * accessNoCoal.avgWorkMs)) * 100))% less computation)")
            print("    Total time:   \(String(format: "%.1f", accessNoCoal.durationMs))ms → \(String(format: "%.1f", accessCoal.durationMs))ms")
            print("  ObservationTracking:")
            print("    With coalescing: \(obsCoal.updates) updates, \(String(format: "%.1f", obsCoal.durationMs))ms")
            print(String(repeating: "=", count: 95) + "\n")
        }
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkComparisonWithTransactions() async throws {
        let mutationCount = 100
        let iterations = 5

        var allResults: [String: [(updates: Int, durationMs: Double, avgWorkMs: Double)]] = [:]

        let simulateWork: @Sendable (Int) -> Int = { value in
            let data = (0..<1000).map { $0 + value }
            return data.filter { $0 % 3 == 0 || $0 % 5 == 0 }.map { $0 * 2 }.reduce(0, +) % 10000
        }

        struct Config {
            let name: String
            let useObservation: Bool
            let useCoalescing: Bool
            let useTransaction: Bool
        }

        let configs: [Config] = [
            Config(name: "AC, NoCoal, NoTxn", useObservation: false, useCoalescing: false, useTransaction: false),
            Config(name: "AC, NoCoal, Txn", useObservation: false, useCoalescing: false, useTransaction: true),
            Config(name: "AC, Coal, NoTxn", useObservation: false, useCoalescing: true, useTransaction: false),
            Config(name: "AC, Coal, Txn", useObservation: false, useCoalescing: true, useTransaction: true),
            Config(name: "OT, Coal, NoTxn", useObservation: true, useCoalescing: true, useTransaction: false),
            Config(name: "OT, Coal, Txn", useObservation: true, useCoalescing: true, useTransaction: true),
        ]

        for config in configs {
            for _ in 0..<iterations {
                let model = withModelOptions(config.useObservation ? [] : [.disableObservationRegistrar]) { CoalescingTestModel().withAnchor() }
                let updateCount = LockIsolated(0)
                let totalWorkTime = LockIsolated(0.0)

                let (cancellable, _) = update(
                    initial: false,
                    isSame: { $0 == $1 },
                    useWithObservationTracking: config.useObservation,
                    useCoalescing: config.useCoalescing,
                    access: { model.value },
                    onUpdate: { value in
                        let workStart = ContinuousClock.now
                        _ = simulateWork(value)
                        let workDuration = ContinuousClock.now - workStart
                        let workMs = Double(workDuration.components.seconds * 1_000_000_000 + Int64(workDuration.components.attoseconds / 1_000_000_000)) / 1_000_000
                        totalWorkTime.withValue { $0 += workMs }
                        updateCount.withValue { $0 += 1 }
                    }
                )

                let start = ContinuousClock.now
                if config.useTransaction {
                    model.transaction { for i in 1...mutationCount { model.value = i } }
                } else {
                    for i in 1...mutationCount { model.value = i }
                }

                if config.useCoalescing {
                    var waited = 0
                    while updateCount.value == 0 && waited < 100 { await Task.yield(); waited += 1 }
                    for _ in 0..<5 { await Task.yield() }
                } else {
                    var waited = 0
                    while updateCount.value < mutationCount && waited < mutationCount * 2 { await Task.yield(); waited += 1 }
                }

                let duration = ContinuousClock.now - start
                cancellable()

                let ns = duration.components.seconds * 1_000_000_000 + Int64(duration.components.attoseconds / 1_000_000_000)
                let avgWork = updateCount.value > 0 ? totalWorkTime.value / Double(updateCount.value) : 0
                allResults[config.name, default: []].append((updateCount.value, Double(ns) / 1_000_000, avgWork))
            }
        }

        func removeOutliersAndAverage(_ values: [(updates: Int, durationMs: Double, avgWorkMs: Double)]) -> (updates: Int, durationMs: Double, avgWorkMs: Double) {
            guard values.count >= 3 else {
                return (values.map { $0.updates }.reduce(0, +) / values.count,
                        values.map { $0.durationMs }.reduce(0.0, +) / Double(values.count),
                        values.map { $0.avgWorkMs }.reduce(0.0, +) / Double(values.count))
            }
            let trimmed = Array(values.sorted { $0.durationMs < $1.durationMs }.dropFirst().dropLast())
            return (trimmed.map { $0.updates }.reduce(0, +) / trimmed.count,
                    trimmed.map { $0.durationMs }.reduce(0.0, +) / Double(trimmed.count),
                    trimmed.map { $0.avgWorkMs }.reduce(0.0, +) / Double(trimmed.count))
        }

        let results = configs.map { config -> (name: String, updates: Int, durationMs: Double, avgWorkMs: Double) in
            let avg = removeOutliersAndAverage(allResults[config.name]!)
            return (config.name, avg.updates, avg.durationMs, avg.avgWorkMs)
        }

        print("\n" + String(repeating: "=", count: 95))
        print("📊 UPDATE PERFORMANCE WITH TRANSACTIONS: \(mutationCount) mutations (\(iterations) iterations, outliers removed)")
        print(String(repeating: "=", count: 95))
        print("Configuration                  Updates  Total(ms)  Work/Update(ms)  Total Work(ms)")
        print(String(repeating: "-", count: 95))
        for result in results {
            let totalWork = Double(result.updates) * result.avgWorkMs
            print("\(result.name.padding(toLength: 31, withPad: " ", startingAt: 0))\(String(format: "%4d", result.updates))     \(String(format: "%6.1f", result.durationMs))     \(String(format: "%6.2f", result.avgWorkMs))           \(String(format: "%6.1f", totalWork))")
        }
        print(String(repeating: "=", count: 95))

        let acCoalNoTxn = results.first { $0.name == "AC, Coal, NoTxn" }!
        let acCoalTxn = results.first { $0.name == "AC, Coal, Txn" }!
        print("DEBUG: acCoalNoTxn.updates = \(acCoalNoTxn.updates)")
        print("DEBUG: acCoalTxn.updates = \(acCoalTxn.updates)")
        #expect(acCoalNoTxn.updates < 30, "AC with coalescing outside txn should have <30 updates, got \(acCoalNoTxn.updates)")
        #expect(acCoalTxn.updates < 30, "AC with coalescing in txn should now also have <30 updates, got \(acCoalTxn.updates)")
        print("✅ Coalescing works in both transaction modes!")
    }

    @available(iOS 16, macOS 13, tvOS 16, watchOS 9, *)
    @Test
    func benchmarkUnifiedComparison() async throws {
        let mutationCount = 100
        let iterations = 5

        print("\n" + String(repeating: "=", count: 120))
        print("📊 UNIFIED BENCHMARK: Memoize vs Update (100 mutations, 5 iterations, outliers removed)")
        print(String(repeating: "=", count: 120))

        struct Config {
            let name: String
            let useAC: Bool
            let useCoalescing: Bool
            let useTransaction: Bool
        }

        let configs: [Config] = [
            Config(name: "AC, NoCoal, NoTxn", useAC: true, useCoalescing: false, useTransaction: false),
            Config(name: "AC, NoCoal, Txn", useAC: true, useCoalescing: false, useTransaction: true),
            Config(name: "AC, Coal, NoTxn", useAC: true, useCoalescing: true, useTransaction: false),
            Config(name: "AC, Coal, Txn", useAC: true, useCoalescing: true, useTransaction: true),
            Config(name: "OT, NoCoal, NoTxn", useAC: false, useCoalescing: false, useTransaction: false),
            Config(name: "OT, NoCoal, Txn", useAC: false, useCoalescing: false, useTransaction: true),
            Config(name: "OT, Coal, NoTxn", useAC: false, useCoalescing: true, useTransaction: false),
            Config(name: "OT, Coal, Txn", useAC: false, useCoalescing: true, useTransaction: true),
        ]

        var updateResults: [String: [(callbacks: Int, time: Double)]] = [:]
        var memoizeResults: [String: [(computes: Int, time: Double)]] = [:]

        // === UPDATE BENCHMARKS ===
        for config in configs {
            for _ in 0..<iterations {
                let model = withModelOptions(config.useAC ? [.disableObservationRegistrar] : []) { CoalescingTestModel().withAnchor() }
                let callbackCount = LockIsolated(0)

                let (cancellable, _) = update(
                    initial: false,
                    isSame: { $0 == $1 },
                    useWithObservationTracking: !config.useAC,
                    useCoalescing: config.useCoalescing,
                    access: { model.value },
                    onUpdate: { _ in callbackCount.withValue { $0 += 1 } }
                )

                let start = ContinuousClock.now
                if config.useTransaction {
                    model.transaction { for i in 1...mutationCount { model.value = i } }
                } else {
                    for i in 1...mutationCount { model.value = i }
                }

                let maxWait = config.useCoalescing ? 100 : mutationCount * 2
                var waited = 0
                let expectedMin = config.useCoalescing ? 0 : mutationCount
                while callbackCount.value < expectedMin && waited < maxWait { await Task.yield(); waited += 1 }
                for _ in 0..<5 { await Task.yield() }

                let elapsed = ContinuousClock.now - start
                cancellable()
                updateResults[config.name, default: []].append((callbackCount.value, Double(elapsed.components.attoseconds) / 1_000_000_000_000_000))
            }
        }

        // === MEMOIZE BENCHMARKS ===
        for config in configs {
            for _ in 0..<iterations {
                let options: ModelOption = config.useAC ? [.disableObservationRegistrar] : []
                let coalescingOption: ModelOption = config.useCoalescing ? [] : [.disableMemoizeCoalescing]
                var model = CoalescingMemoizeTestModel(items: (0..<mutationCount).map { _ in CoalescingItemModel(value: 0) })
                model = withModelOptions(options.union(coalescingOption)) { model.withAnchor() }

                _ = model.sorted
                let initialComputes = model.sortCallCount.value

                let start = ContinuousClock.now
                if config.useTransaction {
                    model.transaction { for i in 0..<model.items.count { model.items[i].value += 1 } }
                } else {
                    for i in 0..<model.items.count { model.items[i].value += 1 }
                }
                _ = model.sorted
                let elapsed = ContinuousClock.now - start

                memoizeResults[config.name, default: []].append((model.sortCallCount.value - initialComputes, Double(elapsed.components.attoseconds) / 1_000_000_000_000_000))
            }
        }

        func removeOutliersAndAverage(_ values: [(count: Int, time: Double)]) -> (count: Int, time: Double) {
            guard values.count >= 3 else {
                return (values.map { $0.count }.reduce(0, +) / values.count,
                        values.map { $0.time }.reduce(0.0, +) / Double(values.count))
            }
            let trimmed = Array(values.sorted { $0.time < $1.time }.dropFirst().dropLast())
            return (trimmed.map { $0.count }.reduce(0, +) / trimmed.count,
                    trimmed.map { $0.time }.reduce(0.0, +) / Double(trimmed.count))
        }

        let processedUpdate = configs.map { config -> (name: String, callbacks: Int, time: Double) in
            let avg = removeOutliersAndAverage(updateResults[config.name]!.map { (count: $0.callbacks, time: $0.time) })
            return (config.name, avg.count, avg.time)
        }
        let processedMemoize = configs.map { config -> (name: String, computes: Int, time: Double) in
            let avg = removeOutliersAndAverage(memoizeResults[config.name]!.map { (count: $0.computes, time: $0.time) })
            return (config.name, avg.count, avg.time)
        }

        print("\n┌─ UPDATE STREAM (onUpdate callbacks) ─────────────────────────────────────────────────────────────┐")
        print("│ Configuration                  Callbacks  Time(ms)  │")
        print("├────────────────────────────────────────────────────│")
        for result in processedUpdate {
            print("│ \(result.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(String(format: "%8d", result.callbacks))  \(String(format: "%7.1f", result.time))  │")
        }
        print("└────────────────────────────────────────────────────┘")

        print("\n┌─ MEMOIZE (recomputations) ───────────────────────────────────────────────────────────────────────┐")
        print("│ Configuration                  Computes   Time(ms)  │")
        print("├────────────────────────────────────────────────────│")
        for result in processedMemoize {
            print("│ \(result.name.padding(toLength: 30, withPad: " ", startingAt: 0)) \(String(format: "%8d", result.computes))  \(String(format: "%7.1f", result.time))  │")
        }
        print("└────────────────────────────────────────────────────┘")

        let acNoCoalTxnUpdate = processedUpdate.first { $0.name == "AC, NoCoal, Txn" }!
        let otNoCoalTxnUpdate = processedUpdate.first { $0.name == "OT, NoCoal, Txn" }!
        print("\n📈 AC vs OT without coalescing + transaction:")
        print("   AC: \(acNoCoalTxnUpdate.callbacks) callbacks, OT: \(otNoCoalTxnUpdate.callbacks) callbacks")

        let acNoCoalNoTxn = processedUpdate.first { $0.name == "AC, NoCoal, NoTxn" }!
        let acCoalNoTxn = processedUpdate.first { $0.name == "AC, Coal, NoTxn" }!
        print("📈 Coalescing effect (AC, NoTxn): \(acNoCoalNoTxn.callbacks) → \(acCoalNoTxn.callbacks) callbacks")
        print("\n" + String(repeating: "=", count: 120) + "\n")
    }
}

// MARK: - Test Models

@Model private struct CoalescingTestModel {
    var value = 0
}

@Model private struct CoalescingItemModel {
    var value = 0
}

@Model private struct CoalescingMemoizeTestModel {
    var items: [CoalescingItemModel] = []
    let sortCallCount = LockIsolated(0)

    var sorted: [CoalescingItemModel] {
        node.memoize(for: "sorted") {
            sortCallCount.withValue { $0 += 1 }
            return items.sorted { $0.value < $1.value }
        }
    }
}
