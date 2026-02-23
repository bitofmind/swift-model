import Testing
import Observation
import ConcurrencyExtras
import Foundation
@testable import SwiftModel

/// Focused tests for the update() function behavior with both observation paths.
///
/// These tests use Swift Testing Attachments to capture debug state, allowing
/// the AI agent to see exactly what's happening during execution.
struct UpdateFunctionTests {

    /// Test basic withObservationTracking behavior
    @Test func testWithObservationTrackingBasic() async throws {
        // Connect DebugHook to Swift Testing Attachments
        let debugLog = LockIsolated<[String]>([])
        DebugHook.record = { message in
            debugLog.withValue { $0.append(message) }
        }
        defer { DebugHook.record = { _ in } }

        DebugHook.record("\n========== TEST START: testWithObservationTrackingBasic ==========")

        // Create a simple observable value (NOTE: won't actually trigger onChange for local vars)
        let sharedValue = LockIsolated(0)
        let updateCount = LockIsolated(0)

        DebugHook.record("[TEST] Setting up update with withObservationTracking=true")

        let cancellable = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: true,
            access: {
                let value = sharedValue.value
                DebugHook.record("[TEST] access() called, sharedValue=\(value)")
                return value
            },
            onUpdate: { (value: Int) in
                updateCount.withValue { $0 += 1 }
                DebugHook.record("[TEST] onUpdate called with value=\(value), updateCount=\(updateCount.value)")
            }
        )

        DebugHook.record("[TEST] Initial setup complete, updateCount=\(updateCount.value)")
        #expect(updateCount.value == 1, "Initial onUpdate should fire")

        // Change the value
        DebugHook.record("[TEST] Changing sharedValue from 0 to 5")
        sharedValue.setValue(5)

        // Wait a moment for onChange to fire
        DebugHook.record("[TEST] Waiting for onChange callbacks...")
        try await Task.sleep(for: .milliseconds(100))

        DebugHook.record("[TEST] After wait, updateCount=\(updateCount.value)")
        DebugHook.record("[TEST] Expected updateCount >= 2 (initial + onChange)")

        DebugHook.record("\n========== TEST END ==========\n")

        cancellable()
        DebugHook.record = { _ in }  // Reset hook before accessing log
        
        // Record final state as attachment  
        let finalLog = debugLog.value.joined(separator: "\n")
        _ = Attachment(finalLog)  // String conforms to Attachable

        // NOTE: This test documents that withObservationTracking doesn't track local variables
        // It only tracks Observable properties, so updateCount stays 1
        #expect(updateCount.value == 1, "Local variables don't trigger onChange")
    }

    /// Test AccessCollector path for comparison
    @Test func testAccessCollectorBasic() async throws {
        let debugLog = LockIsolated<[String]>([])
        DebugHook.record = { message in
            debugLog.withValue { $0.append(message) }
        }
        defer { DebugHook.record = { _ in } }

        DebugHook.record("\n========== TEST START: testAccessCollectorBasic ==========")

        let sharedValue = LockIsolated(0)
        let updateCount = LockIsolated(0)

        DebugHook.record("[TEST] Setting up update with useWithObservationTracking=false (AccessCollector)")

        let cancellable = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: false,
            access: {
                let value = sharedValue.value
                DebugHook.record("[TEST] access() called, sharedValue=\(value)")
                return value
            },
            onUpdate: { (value: Int) in
                updateCount.withValue { $0 += 1 }
                DebugHook.record("[TEST] onUpdate called with value=\(value), updateCount=\(updateCount.value)")
            }
        )

        DebugHook.record("[TEST] Initial setup complete, updateCount=\(updateCount.value)")
        #expect(updateCount.value == 1)

        DebugHook.record("[TEST] Changing sharedValue from 0 to 5")
        sharedValue.setValue(5)

        try await Task.sleep(for: .milliseconds(100))

        DebugHook.record("[TEST] After wait, updateCount=\(updateCount.value)")
        DebugHook.record("\n========== TEST END ==========\n")

        cancellable()
        DebugHook.record = { _ in }  // Reset hook before accessing log
        
        let finalLog = debugLog.value.joined(separator: "\n")
        _ = Attachment(finalLog)

        // AccessCollector doesn't track external variables, so updateCount stays 1
        // This is expected - AccessCollector tracks Model properties, not local variables
        #expect(updateCount.value == 1, "AccessCollector doesn't track external variables")
    }

    /// Test with Model to see actual dependency tracking
    @Test func testWithObservationTrackingWithModel() async throws {
        let debugLog = LockIsolated<[String]>([])
        DebugHook.record = { message in
            debugLog.withValue { $0.append(message) }
        }
        defer { DebugHook.record = { _ in } }

        DebugHook.record("\n========== TEST START: testWithObservationTrackingWithModel ==========")

        let (model, tester) = TestModel().andTester(options: [.useWithObservationTracking])
        tester.exhaustivity = .off
        let updateCount = LockIsolated(0)

        DebugHook.record("[TEST] Setting up observation on model.value")

        let cancellable = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: true,
            access: {
                let value = model.value
                DebugHook.record("[TEST] access() called, model.value=\(value)")
                return value
            },
            onUpdate: { (value: Int) in
                updateCount.withValue { $0 += 1 }
                DebugHook.record("[TEST] onUpdate called with value=\(value), updateCount=\(updateCount.value)")
            }
        )

        DebugHook.record("[TEST] Initial setup complete, updateCount=\(updateCount.value)")
        await tester.assert { updateCount.value == 1 }

        DebugHook.record("[TEST] Changing model.value from 0 to 5")
        model.value = 5
        await tester.assert { model.value == 5 }

        DebugHook.record("[TEST] Waiting for onChange callbacks via tester.assert...")
        await tester.assert(timeoutNanoseconds: 2_000_000_000) {
            updateCount.value >= 2
        }

        DebugHook.record("[TEST] After wait, updateCount=\(updateCount.value)")
        DebugHook.record("[TEST] model.value=\(model.value)")

        DebugHook.record("\n========== TEST END ==========\n")

        cancellable()
        DebugHook.record = { _ in }  // Reset hook before accessing log
        
        let finalLog = debugLog.value.joined(separator: "\n")
        _ = Attachment(finalLog)
    }
}

@Model private struct TestModel {
    var value = 0
}
