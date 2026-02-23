import Testing
import Observation
@testable import SwiftModel
import ConcurrencyExtras

/// Diagnostic tests to understand withObservationTracking + memoize interaction
struct DiagnosticMemoizeTest {

    /// Test WITH sleep: Wait for onChange before accessing memoized value
    @Test func testWithSleepBeforeAccess() async throws {
        print("\n========== WITH SLEEP BEFORE ACCESS ==========")

        let (model, tester) = BasicMemoizeModel().andTester(options: [.useWithObservationTracking])
        tester.exhaustivity = .off
        
        // Capture onUpdate calls
        let onUpdateLog = LockIsolated<[String]>([])
        DebugHook.record = { message in
            if message.contains("[memoize]") {
                onUpdateLog.withValue { $0.append(message) }
            }
        }
        defer { DebugHook.record = { _ in } }

        print("1️⃣ First access")
        _ = model.doubled
        await tester.assert { model.accessCount == 1 }
        print("   accessCount: \(model.accessCount), doubled: \(model.doubled)")

        print("\n2️⃣ Changing value to 5")
        model.value = 5
        await tester.assert { model.value == 5 }
        
        print("\n3️⃣ Waiting for onChange → onUpdate chain via tester.assert...")
        // Wait for cache to be invalidated and recomputed
        await tester.assert(timeoutNanoseconds: 5_000_000_000) {
            model.doubled == 10
        }
        
        print("   Final: doubled=\(model.doubled), accessCount=\(model.accessCount)")
        print("   ✅ SUCCESS!")
        print("\n========== TEST PASSED ==========\n")
    }
    
    /// Test WITHOUT sleep: Access immediately after mutation
    @Test func testWithoutSleep() async throws {
        print("\n========== WITHOUT SLEEP ==========")

        let (model, tester) = BasicMemoizeModel().andTester(options: [.useWithObservationTracking])
        tester.exhaustivity = .off
        
        let onUpdateLog = LockIsolated<[String]>([])
        DebugHook.record = { message in
            if message.contains("[memoize]") {
                onUpdateLog.withValue { $0.append(message) }
            }
        }
        defer { DebugHook.record = { _ in } }

        print("1️⃣ First access")
        _ = model.doubled
        await tester.assert { model.accessCount == 1 }

        print("\n2️⃣ Changing value to 5")
        model.value = 5
        await tester.assert { model.value == 5 }
        
        print("\n3️⃣ Accessing doubled IMMEDIATELY (no wait)")
        let result = model.doubled
        print("   Result: \(result), accessCount: \(model.accessCount)")
        print("   onUpdate log: \(onUpdateLog.value)")
        
        if result == 0 {
            print("   ❌ Got stale cache value!")
            print("   This proves: onChange fires async, we accessed before onUpdate ran")
            
            // Wait for onChange to eventually fire using tester.assert
            await tester.assert(timeoutNanoseconds: 1_000_000_000) {
                model.doubled == 10
            }
            print("\n4️⃣ After onChange completes:")
            print("   doubled: \(model.doubled), accessCount: \(model.accessCount)")
        }
        
        // This test documents the race condition
        #expect(result == 0, "Expected stale value due to race condition")
        
        print("\n========== TEST PASSED (documented race) ==========\n")
    }

    /// Test using ModelTester.assert polling
    @Test func testWithTesterAssertPolling() async throws {
        print("\n========== WITH TESTER.ASSERT POLLING ==========")

        let (model, tester) = BasicMemoizeModel().andTester(options: [.useWithObservationTracking])
        tester.exhaustivity = .off
        
        let onUpdateLog = LockIsolated<[String]>([])
        DebugHook.record = { message in
            if message.contains("[memoize]") {
                onUpdateLog.withValue { $0.append(message) }
                print("   [DEBUG] \(message)")
            }
        }
        defer { DebugHook.record = { _ in } }

        print("1️⃣ First access")
        _ = model.doubled
        await tester.assert { model.accessCount == 1 }

        print("\n2️⃣ Changing value to 5")
        model.value = 5
        await tester.assert { model.value == 5 }
        
        print("\n3️⃣ Using tester.assert to poll for updated value...")
        print("   This continuously accesses model.doubled until it equals 10 or times out")
        
        // This should work IF onUpdate eventually fires
        await tester.assert(timeoutNanoseconds: 2_000_000_000) {
            model.doubled == 10
        }
        
        print("   ✅ SUCCESS: onUpdate fired and cache was updated!")
        print("   onUpdate log: \(onUpdateLog.value)")
        print("\n========== TEST PASSED ==========\n")
    }
}

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
