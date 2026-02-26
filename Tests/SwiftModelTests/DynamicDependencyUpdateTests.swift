import Testing
@testable import SwiftModel
import ConcurrencyExtras
import Observation

/// Tests to isolate the dynamic dependency tracking issue with withObservationTracking
/// 
/// This test file focuses on the `update()` function directly to understand why:
/// - AccessCollector works correctly with dynamic dependencies
/// - withObservationTracking fails with dynamic dependencies
@Model fileprivate struct SwitchingModel {
    var useA = true
    var valueA = 10
    var valueB = 20

    var computed: Int {
        useA ? valueA : valueB
    }
}

@Suite struct DynamicDependencyUpdateTests {

    // MARK: - Direct update() Tests
    
    /// Test update() with AccessCollector and dynamic dependencies
    @Test
    func testUpdateWithAccessCollector_DynamicDependencies() async throws {
        let model = SwitchingModel().withAnchor(options: [.disableObservationRegistrar, .disableMemoizeCoalescing])
        
        let values = LockIsolated<[Int]>([])
        
        // Use update() directly with AccessCollector
        let cancellable = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: false,
            useCoalescing: false
        ) {
            model.computed
        } onUpdate: { value in
            values.withValue { $0.append(value) }
        }
        
        defer { cancellable() }
        
        // Initial value should be tracked
        #expect(values.value == [10], "Should have initial value")
        
        // Change valueA (currently tracked)
        model.valueA = 15
        #expect(values.value == [10, 15], "Should observe valueA change")
        
        // Switch to valueB
        model.useA = false
        #expect(values.value == [10, 15, 20], "Should observe switch to valueB")
        
        // Change valueB (now tracked)
        model.valueB = 25
        #expect(values.value == [10, 15, 20, 25], "Should observe valueB change")
        
        // Change valueA (no longer tracked)
        model.valueA = 99
        #expect(values.value == [10, 15, 20, 25], "Should NOT observe valueA change (not tracked)")
    }
    
    /// Test update() with withObservationTracking and dynamic dependencies
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testUpdateWithObservationTracking_DynamicDependencies() async throws {
        let model = SwitchingModel().withAnchor(options: [])
        
        let values = LockIsolated<[Int]>([])
        
        // Use update() directly with withObservationTracking
        let cancellable = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: true,
            useCoalescing: true  // Required for withObservationTracking
        ) {
            model.computed
        } onUpdate: { value in
            values.withValue { $0.append(value) }
        }
        
        defer { cancellable() }
        
        // Wait for initial value
        try await waitUntil(values.value.contains(10))
        
        // Change valueA (currently tracked)
        model.valueA = 15
        try await waitUntil(values.value.contains(15), timeout: 2_000_000_000)
        
        print("After valueA change: \(values.value)")
        
        // Switch to valueB
        model.useA = false
        try await waitUntil(values.value.contains(20), timeout: 2_000_000_000)
        
        print("After switch to valueB: \(values.value)")
        
        // Change valueB (now tracked) - THIS IS WHERE IT MIGHT FAIL
        model.valueB = 25
        try await waitUntil(values.value.contains(25), timeout: 2_000_000_000)
        
        print("After valueB change: \(values.value)")
        
        // Verify we got the valueB change
        #expect(values.value.contains(25), "Should observe valueB change after switching")
    }
    
    /// Test update() with withObservationTracking and rapid branch switching
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testUpdateWithObservationTracking_RapidSwitching() async throws {
        let model = SwitchingModel().withAnchor(options: [])
        
        let values = LockIsolated<[Int]>([])
        let updateCount = LockIsolated(0)
        
        // Use update() directly with withObservationTracking
        let cancellable = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: true,
            useCoalescing: true
        ) {
            model.computed
        } onUpdate: { value in
            updateCount.withValue { $0 += 1 }
            values.withValue { $0.append(value) }
            print("Update #\(updateCount.value): value=\(value)")
        }
        
        defer { cancellable() }
        
        // Wait for initial value
        try await waitUntil(values.value.count >= 1)
        print("Initial: \(values.value)")
        
        // Rapid sequence: switch branch, change value, switch back
        model.useA = false  // Switch to B (should see 20)
        model.valueB = 25   // Change B (should see 25)
        model.useA = true   // Switch back to A (should see 10)

        // Wait for coalesced updates to fire
        // With coalescing, we might not see all intermediate values
        try await waitUntil(values.value.count >= 2, timeout: 2_000_000_000)

        print("Final values: \(values.value), updateCount: \(updateCount.value)")

        // Due to coalescing, we might see different sequences:
        // - [10, 20, 25, 10] - all updates
        // - [10, 25, 10] - coalesced useA=false + valueB=25
        // - [10, 10] - heavily coalesced (less likely but possible)
        // The key is that we should see SOME updates and dynamic tracking should work
        let finalValues = values.value

        // We should have at least initial value and one update
        #expect(finalValues.count >= 2, "Should receive at least initial + one update")
        #expect(finalValues.first == 10, "Initial value should be 10")
    }
    
    // MARK: - Diagnostic Tests
    
    /// Compare AccessCollector vs withObservationTracking side-by-side
    @Test
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    func testCompareBothPaths() async throws {
        // AccessCollector path
        let modelAC = SwitchingModel().withAnchor(options: [.disableObservationRegistrar, .disableMemoizeCoalescing])
        let valuesAC = LockIsolated<[Int]>([])
        
        let cancelAC = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: false,
            useCoalescing: false
        ) {
            modelAC.computed
        } onUpdate: { value in
            valuesAC.withValue { $0.append(value) }
        }
        
        defer { cancelAC() }
        
        // withObservationTracking path
        let modelOT = SwitchingModel().withAnchor(options: [])
        let valuesOT = LockIsolated<[Int]>([])
        
        let cancelOT = update(
            initial: true,
            isSame: nil,
            useWithObservationTracking: true,
            useCoalescing: true
        ) {
            modelOT.computed
        } onUpdate: { value in
            valuesOT.withValue { $0.append(value) }
        }
        
        defer { cancelOT() }
        
        // Wait for initial values
        try await waitUntil(valuesOT.value.count >= 1)
        
        print("Initial - AC: \(valuesAC.value), OT: \(valuesOT.value)")
        
        // Perform same operations on both
        modelAC.useA = false
        modelOT.useA = false
        
        try await waitUntil(valuesOT.value.count >= 2, timeout: 2_000_000_000)
        
        print("After switch - AC: \(valuesAC.value), OT: \(valuesOT.value)")
        
        modelAC.valueB = 25
        modelOT.valueB = 25
        
        try await waitUntil(valuesOT.value.count >= 3, timeout: 2_000_000_000)
        
        print("After valueB change - AC: \(valuesAC.value), OT: \(valuesOT.value)")
        
        // AccessCollector should definitely have 25
        #expect(valuesAC.value.contains(25), "AccessCollector should track valueB")
        
        // withObservationTracking might not have 25 (this is the bug)
        if !valuesOT.value.contains(25) {
            print("BUG CONFIRMED: withObservationTracking didn't re-track valueB after switch")
        }
    }
}
